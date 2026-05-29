# ============================================================
#  Deploy-K2-FillIdentity.ps1
#  
#  ROOT CAUSE CONFIRMED: KPRX has EMPTY <Guid>, <Name>, 
#  <DisplayName>, <CategoryPath> elements!
#  
#  FIX: Fill these with real values, package, deploy.
#  Also: Use Write-DeploymentConfig -InputFile -OutputFile properly
#
#  Run in PowerShell ISE on K2 VM
# ============================================================

$ErrorActionPreference = "Continue"
$k2Bin = "C:\Program Files\K2\Bin"
$connStr = "Integrated=True;IsPrimaryLogin=True;Authenticate=True;EncryptedPassword=False;Host=localhost;Port=5555"
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$outputFile = Join-Path $scriptDir "Deploy-K2-FillIdentity-Results.txt"
$exportDir = Join-Path $scriptDir "k2-export\_fillid"

if (-not (Test-Path $exportDir)) { New-Item -Path $exportDir -ItemType Directory -Force | Out-Null }

Start-Transcript -Path $outputFile -Force

Write-Host "============================================" -ForegroundColor White
Write-Host "  K2 Deploy - Fill KPRX Identity" -ForegroundColor White
Write-Host "============================================`n" -ForegroundColor White

Get-ChildItem "$k2Bin\SourceCode.*.dll" | ForEach-Object {
    try { [System.Reflection.Assembly]::LoadFrom($_.FullName) | Out-Null } catch {}
}
Add-Type -AssemblyName System.IO.Compression

# Get KPRX
$mgmt = New-Object SourceCode.Workflow.Management.WorkflowManagementServer
$mgmt.CreateConnection()
$mgmt.Connection.Open($connStr)
$kprxBytes = $mgmt.GetProcessKprx(13)
$kprxXml = [System.Text.Encoding]::UTF8.GetString($kprxBytes)
if ($kprxXml[0] -eq [char]0xFEFF) { $kprxXml = $kprxXml.Substring(1) }
$mgmt.Connection.Close()
Write-Host "KPRX: $($kprxBytes.Length) bytes" -ForegroundColor Green

# ============================================================
# STEP 1: Show current EMPTY identity elements
# ============================================================
Write-Host "`n[1] Current identity elements:" -ForegroundColor Yellow
$xml = [xml]$kprxXml
$root = $xml.DocumentElement

$identityFields = @("Guid", "Name", "DisplayName", "CategoryPath", "Description", "FolderPath", "ProcSetFolderName")
foreach ($field in $identityFields) {
    $node = $root.SelectSingleNode("//*[local-name()='$field']")
    if ($node) {
        Write-Host "  <$field>$($node.InnerText)</$field>" -ForegroundColor $(if($node.InnerText){"Green"}else{"Red"})
    } else {
        Write-Host "  <$field> NOT FOUND" -ForegroundColor DarkGray
    }
}

# ============================================================
# STEP 2: Fill identity elements
# ============================================================
Write-Host "`n[2] Filling identity..." -ForegroundColor Yellow

$newGuid = [System.Guid]::NewGuid().ToString()
$newName = "SPD_Migrated_Approval"
$newDisplayName = "SPD Migrated Approval Workflow"
$newCategoryPath = "SPD Migration"

# Set values using XPath
$guidNode = $root.SelectSingleNode("//*[local-name()='Guid']")
if ($guidNode) { $guidNode.InnerText = $newGuid; Write-Host "  Guid = $newGuid" -ForegroundColor Green }

$nameNode = $root.SelectSingleNode("//*[local-name()='Name']")
if ($nameNode) { $nameNode.InnerText = $newName; Write-Host "  Name = $newName" -ForegroundColor Green }

$displayNode = $root.SelectSingleNode("//*[local-name()='DisplayName']")
if ($displayNode) { $displayNode.InnerText = $newDisplayName; Write-Host "  DisplayName = $newDisplayName" -ForegroundColor Green }

$catNode = $root.SelectSingleNode("//*[local-name()='CategoryPath']")
if ($catNode) { $catNode.InnerText = $newCategoryPath; Write-Host "  CategoryPath = $newCategoryPath" -ForegroundColor Green }

# Save modified KPRX
$modKprxFile = Join-Path $exportDir "filled_identity.kprx"
$settings = New-Object System.Xml.XmlWriterSettings
$settings.Encoding = [System.Text.Encoding]::UTF8
$settings.Indent = $false  # Keep original formatting
$writer = [System.Xml.XmlWriter]::Create($modKprxFile, $settings)
$xml.Save($writer)
$writer.Close()
Write-Host "  Saved: $modKprxFile" -ForegroundColor Green

# Verify
$verXml = [xml](Get-Content $modKprxFile -Raw -Encoding UTF8)
$vRoot = $verXml.DocumentElement
Write-Host "`n  Verification:" -ForegroundColor Yellow
foreach ($field in $identityFields) {
    $node = $vRoot.SelectSingleNode("//*[local-name()='$field']")
    if ($node) { Write-Host "  <$field>$($node.InnerText)</$field>" -ForegroundColor $(if($node.InnerText){"Green"}else{"Red"}) }
}

# ============================================================
# STEP 3: Load snap-in, list params (NO interactive calls)
# ============================================================
Write-Host "`n[3] Loading P&D snap-in..." -ForegroundColor Yellow
Add-PSSnapin SourceCode.Deployment.PowerShell -ErrorAction SilentlyContinue
Write-Host "  Snap-in loaded" -ForegroundColor Green

# ============================================================
# STEP 4: Manual kspx with filled KPRX + deploy
# ============================================================
Write-Host "`n[4] Manual kspx deploy with filled KPRX..." -ForegroundColor Yellow

# Use the proven PDM path but with the filled KPRX
$pdm = New-Object SourceCode.Deployment.Management.PackageDeploymentManager
$pdmConn = $pdm.CreateConnection()
$pdmConn.Open($connStr)

$stream = [System.IO.File]::OpenRead("C:\Program Files\K2\Setup\App Framework Core.kspx")
$s1 = "FI_$(Get-Date -Format 'yyyyMMddHHmmss')"
$session = $pdm.CreateSession($s1, $stream)
$stream.Close()

$templateKspx = Join-Path $exportDir "template.kspx"
$outStream = [System.IO.File]::Create($templateKspx)
$session.Model.Save($outStream)
$outStream.Close()
$pdm.CloseSession($s1)

# Manual extract, swap, repack
$archive = [System.IO.Compression.ZipFile]::OpenRead($templateKspx)
$extractDir = Join-Path $exportDir "extract"
if (Test-Path $extractDir) { Remove-Item $extractDir -Recurse -Force }
New-Item $extractDir -ItemType Directory -Force | Out-Null

$oldWfName = $null
foreach ($entry in $archive.Entries) {
    if ($entry.Name -match "FrameworkGeneric") {
        $oldWfName = $entry.Name
        continue # Skip old WF
    }
    $es = $entry.Open()
    $fs = [System.IO.File]::Create((Join-Path $extractDir $entry.Name))
    $es.CopyTo($fs)
    $fs.Close()
    $es.Close()
}
$archive.Dispose()
Write-Host "  Skipped: $oldWfName" -ForegroundColor Green

# Write filled KPRX
$newWfName = "SPDMigratedApproval.Workflow"
$filledKprxBytes = [System.IO.File]::ReadAllBytes($modKprxFile)
[System.IO.File]::WriteAllBytes((Join-Path $extractDir $newWfName), $filledKprxBytes)
Write-Host "  Added: $newWfName ($([math]::Round($filledKprxBytes.Length/1KB))KB)" -ForegroundColor Green

# Update definition.model
$defPath = Join-Path $extractDir "definition.model"
$defContent = [System.IO.File]::ReadAllText($defPath, [System.Text.Encoding]::UTF8)
if ($oldWfName) { $defContent = $defContent.Replace($oldWfName, $newWfName) }
$defContent = $defContent.Replace("Framework Core\FrameworkGeneric.Workflow.Reference", "$newCategoryPath\$newName")
$defContent = $defContent.Replace("FrameworkGeneric%2EWorkflow%2EReference", $newName)
$defContent = $defContent.Replace("FrameworkGeneric.Workflow.Reference", $newName)
$defContent = $defContent.Replace("Framework_Core", $newCategoryPath.Replace(" ","_"))
$defContent = $defContent.Replace("Framework Core", $newCategoryPath)
$defContent = $defContent.Replace("App Framework Core", "SPD Migration Package")
[System.IO.File]::WriteAllText($defPath, $defContent, [System.Text.Encoding]::UTF8)

# Props
$pp = Join-Path $extractDir "properties.model"
$pc = [System.IO.File]::ReadAllText($pp, [System.Text.Encoding]::UTF8)
$pc = $pc.Replace("App Framework Core", "SPD Migration Package")
[System.IO.File]::WriteAllText($pp, $pc, [System.Text.Encoding]::UTF8)

# Repack
$finalKspx = Join-Path $exportDir "filled_deploy.kspx"
if (Test-Path $finalKspx) { Remove-Item $finalKspx -Force }
$outZip = [System.IO.Compression.ZipFile]::Open($finalKspx, [System.IO.Compression.ZipArchiveMode]::Create)
foreach ($f in [System.IO.Directory]::GetFiles($extractDir)) {
    $fn = [System.IO.Path]::GetFileName($f)
    $e = $outZip.CreateEntry($fn)
    $es = $e.Open(); $fs = [System.IO.File]::OpenRead($f); $fs.CopyTo($es); $fs.Close(); $es.Close()
}
$outZip.Dispose()
Write-Host "  Package: $([math]::Round((Get-Item $finalKspx).Length/1KB))KB" -ForegroundColor Green

# Deploy
$ds = [System.IO.File]::OpenRead($finalKspx)
$s2 = "FID_$(Get-Date -Format 'yyyyMMddHHmmss')"
try {
    $session2 = $pdm.CreateSession($s2, $ds)
    $ds.Close()
    Write-Host "  Members: $($session2.Model.Members.Count)" -ForegroundColor Green
    $session2.SetOption("NoAnalyze", $true)
    $session2.Deploy()
    Start-Sleep -Seconds 5
    $count = 0; foreach ($r in $session2.DeploymentResults) { $count++ }
    Write-Host "  DEPLOYED: $count items" -ForegroundColor Green
    $pdm.CloseSession($s2)
} catch {
    try { $ds.Close() } catch {}
    Write-Host "  Error: $($_.Exception.Message)" -ForegroundColor Red
}

# Try Write-DeploymentConfig + Deploy-Package (correct params)
Write-Host "`n  Write-DeploymentConfig + Deploy-Package..." -ForegroundColor Yellow
$deployConfigXml = Join-Path $exportDir "deploy_config.xml"
try {
    Write-DeploymentConfig -InputFile $finalKspx -OutputFile $deployConfigXml -ErrorAction Stop
    Write-Host "  Config generated: $deployConfigXml" -ForegroundColor Green
    $cfgContent = Get-Content $deployConfigXml -Raw -ErrorAction SilentlyContinue
    Write-Host "  Config (first 500): $($cfgContent.Substring(0, [Math]::Min(500, $cfgContent.Length)))" -ForegroundColor DarkYellow
    
    Deploy-Package -FileName $finalKspx -ConfigFile $deployConfigXml -ConnectionString $connStr -ErrorAction Stop
    Write-Host "  Deploy-Package SUCCEEDED!" -ForegroundColor Green
} catch {
    Write-Host "  Error: $($_.Exception.Message)" -ForegroundColor Red
}

# Also try direct Deploy-Package
Write-Host "`n  Direct Deploy-Package..." -ForegroundColor Yellow
try {
    Deploy-Package -FileName $finalKspx -NoAnalyze -K2Host "localhost" -Port 5555 -Integrated -ErrorAction Stop
    Write-Host "  Direct Deploy-Package SUCCEEDED!" -ForegroundColor Green
} catch {
    Write-Host "  Direct Deploy-Package: $($_.Exception.Message)" -ForegroundColor Red
}

# ============================================================
# VERIFY
# ============================================================
Write-Host "`n[5] Processes:" -ForegroundColor Yellow
$mgmt2 = New-Object SourceCode.Workflow.Management.WorkflowManagementServer
$mgmt2.CreateConnection()
$mgmt2.Connection.Open($connStr)
foreach ($ps in $mgmt2.GetProcSets()) {
    $m = if ($ps.FullName -like "*SPD*" -or $ps.FullName -like "*Migrat*" -or $ps.ProcSetID -gt 11) { " <<< NEW!" } else { "" }
    Write-Host "  $($ps.FullName) (ID=$($ps.ProcSetID))$m" -ForegroundColor $(if($m){"Green"}else{"DarkGray"})
}
Write-Host "  Total: $($mgmt2.GetProcSets().Count)" -ForegroundColor Yellow
$mgmt2.Connection.Close()
$pdm.Dispose()

Stop-Transcript
