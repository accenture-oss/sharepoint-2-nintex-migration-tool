# ============================================================
#  Deploy-K2-RealModel.ps1
#  
#  KEY INSIGHT: Keep the REAL definition.model (5652KB) from 
#  Model.Save() - it has the correct schema. Just do targeted 
#  string replacements for the workflow entry.
#
#  Delete ALL non-essential files but keep the real model.
#  Explicitly name the old WF file (no -like wildcards).
#
#  Run in PowerShell ISE on K2 VM
# ============================================================

$ErrorActionPreference = "Continue"
$k2Bin = "C:\Program Files\K2\Bin"
$connStr = "Integrated=True;IsPrimaryLogin=True;Authenticate=True;EncryptedPassword=False;Host=localhost;Port=5555"
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$outputFile = Join-Path $scriptDir "Deploy-K2-RealModel-Results.txt"
$exportDir = Join-Path $scriptDir "k2-export\_realmodel"

if (-not (Test-Path $exportDir)) { New-Item -Path $exportDir -ItemType Directory -Force | Out-Null }

Start-Transcript -Path $outputFile -Force

Write-Host "============================================" -ForegroundColor White
Write-Host "  K2 Deploy - Real Model + WF Swap" -ForegroundColor White
Write-Host "============================================`n" -ForegroundColor White

# Load assemblies
Get-ChildItem "$k2Bin\SourceCode.*.dll" | ForEach-Object {
    try { [System.Reflection.Assembly]::LoadFrom($_.FullName) | Out-Null } catch {}
}
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

# Get KPRX
Write-Host "[1] Getting KPRX..." -ForegroundColor Yellow
$mgmt = New-Object SourceCode.Workflow.Management.WorkflowManagementServer
$mgmt.CreateConnection()
$mgmt.Connection.Open($connStr)
$kprxBytes = $mgmt.GetProcessKprx(13)
$mgmt.Connection.Close()
Write-Host "  KPRX: $($kprxBytes.Length) bytes" -ForegroundColor Green

# Save template via PDM Model.Save()
Write-Host "`n[2] Creating template via Model.Save()..." -ForegroundColor Yellow
$pdm = New-Object SourceCode.Deployment.Management.PackageDeploymentManager
$pdmConn = $pdm.CreateConnection()
$pdmConn.Open($connStr)

$stream = [System.IO.File]::OpenRead("C:\Program Files\K2\Setup\App Framework Core.kspx")
$s1 = "T_$(Get-Date -Format 'yyyyMMddHHmmss')"
$session = $pdm.CreateSession($s1, $stream)
$stream.Close()
$templateKspx = Join-Path $exportDir "template.kspx"
$outStream = [System.IO.File]::Create($templateKspx)
$session.Model.Save($outStream)
$outStream.Close()
$pdm.CloseSession($s1)
Write-Host "  Template: $([math]::Round((Get-Item $templateKspx).Length/1KB))KB" -ForegroundColor Green

# Extract
Write-Host "`n[3] Extracting..." -ForegroundColor Yellow
$extractDir = Join-Path $exportDir "extract"
if (Test-Path $extractDir) { Remove-Item $extractDir -Recurse -Force }
[System.IO.Compression.ZipFile]::ExtractToDirectory($templateKspx, $extractDir)

$allFiles = Get-ChildItem $extractDir -File
Write-Host "  Total files: $($allFiles.Count)" -ForegroundColor DarkGray

# KNOWN old WF filename from previous output (exact name with + character)
$oldWfExactName = "FrameworkGeneric.Workflow_A4GH3Iisqu1GSLbFpPmkPSdQ2+g.Reference"
$newWfFileName = "SPDMigratedApproval.Workflow"

# Check if old WF file exists
$oldWfPath = Join-Path $extractDir $oldWfExactName
Write-Host "  Old WF exists: $(Test-Path $oldWfPath)" -ForegroundColor $(if(Test-Path $oldWfPath){"Green"}else{"Red"})

# Delete old WF file
if (Test-Path $oldWfPath) {
    Remove-Item -LiteralPath $oldWfPath -Force
    Write-Host "  Deleted old WF: $oldWfExactName" -ForegroundColor Green
} else {
    # Try to find it
    Write-Host "  Searching for workflow files..." -ForegroundColor Yellow
    foreach ($f in $allFiles) {
        if ($f.Name -match "FrameworkGeneric" -or $f.Name -match "\.Workflow" -or $f.Name -match "\.Reference") {
            Write-Host "    FOUND: $($f.Name) ($([math]::Round($f.Length/1KB))KB)" -ForegroundColor Cyan
            Remove-Item -LiteralPath $f.FullName -Force
            Write-Host "    DELETED: $($f.Name)" -ForegroundColor Green
            $oldWfExactName = $f.Name
        }
    }
}

# Write our KPRX as the new WF file
$newWfPath = Join-Path $extractDir $newWfFileName
[System.IO.File]::WriteAllBytes($newWfPath, $kprxBytes)
Write-Host "  Added: $newWfFileName ($([math]::Round($kprxBytes.Length/1KB))KB)" -ForegroundColor Green

# Update definition.model - targeted string replacements ONLY
Write-Host "`n[4] Updating definition.model..." -ForegroundColor Yellow
$defModelPath = Join-Path $extractDir "definition.model"
$defBytes = [System.IO.File]::ReadAllBytes($defModelPath)
$defContent = [System.Text.Encoding]::UTF8.GetString($defBytes)
$originalLen = $defContent.Length

# Replace the file reference (fileitem element)
# Old: file="FrameworkGeneric.Workflow_A4GH3Iisqu1GSLbFpPmkPSdQ2+g.Reference"
# New: file="SPDMigratedApproval.Workflow"
$replaced1 = $defContent.Replace($oldWfExactName, $newWfFileName)
$diff1 = if ($replaced1.Length -ne $defContent.Length -or $replaced1 -ne $defContent) { "YES" } else { "NO" }
Write-Host "  Replace file ref ($oldWfExactName -> $newWfFileName): $diff1" -ForegroundColor $(if($diff1 -eq "YES"){"Green"}else{"Red"})
$defContent = $replaced1

# Replace process name
$replaced2 = $defContent.Replace("Framework Core\FrameworkGeneric.Workflow.Reference", "SPD Migration\SPDMigratedApproval")
$diff2 = if ($replaced2 -ne $defContent) { "YES" } else { "NO" }
Write-Host "  Replace process name: $diff2" -ForegroundColor $(if($diff2 -eq "YES"){"Green"}else{"Red"})
$defContent = $replaced2

# Replace URL-encoded process name
$replaced3 = $defContent.Replace("FrameworkGeneric%2EWorkflow%2EReference", "SPDMigratedApproval")
$diff3 = if ($replaced3 -ne $defContent) { "YES" } else { "NO" }
Write-Host "  Replace URL-encoded name: $diff3" -ForegroundColor $(if($diff3 -eq "YES"){"Green"}else{"Red"})
$defContent = $replaced3

# Replace category folder name
$replaced4 = $defContent.Replace("Framework_Core", "SPD_Migration")
$diff4 = if ($replaced4 -ne $defContent) { "YES" } else { "NO" }
Write-Host "  Replace folder name: $diff4" -ForegroundColor $(if($diff4 -eq "YES"){"Green"}else{"Red"})
$defContent = $replaced4

# Replace package name
$defContent = $defContent.Replace("App Framework Core", "SPD Migration Package")

# Write back
[System.IO.File]::WriteAllBytes($defModelPath, [System.Text.Encoding]::UTF8.GetBytes($defContent))
Write-Host "  definition.model: $([math]::Round($defContent.Length/1KB))KB (was $([math]::Round($originalLen/1KB))KB)" -ForegroundColor Green

# Update properties.model
$propsPath = Join-Path $extractDir "properties.model"
if (Test-Path $propsPath) {
    $pc = [System.IO.File]::ReadAllText($propsPath, [System.Text.Encoding]::UTF8)
    $pc = $pc.Replace("App Framework Core", "SPD Migration Package")
    [System.IO.File]::WriteAllText($propsPath, $pc, [System.Text.Encoding]::UTF8)
}

# Show final state
Write-Host "`n  Final package:" -ForegroundColor Yellow
$finalFiles = Get-ChildItem $extractDir -File
Write-Host "  Files: $($finalFiles.Count)" -ForegroundColor DarkGray
foreach ($f in $finalFiles) {
    $tag = ""
    if ($f.Name -eq $newWfFileName) { $tag = " <<< OUR WORKFLOW" }
    if ($f.Name -eq "definition.model") { $tag = " <<< MODIFIED" }
    Write-Host "    $($f.Name) ($([math]::Round($f.Length/1KB))KB)$tag" -ForegroundColor DarkGray
}

# ============================================================
# STEP 5: Package + Deploy
# ============================================================
Write-Host "`n[5] Packaging + Deploying..." -ForegroundColor Yellow
$finalKspx = Join-Path $exportDir "SPD_RealModel.kspx"
if (Test-Path $finalKspx) { Remove-Item $finalKspx -Force }
[System.IO.Compression.ZipFile]::CreateFromDirectory($extractDir, $finalKspx)
Write-Host "  Package: $([math]::Round((Get-Item $finalKspx).Length/1KB))KB" -ForegroundColor Green

$deployStream = [System.IO.File]::OpenRead($finalKspx)
$s2 = "RM_$(Get-Date -Format 'yyyyMMddHHmmss')"
try {
    $session2 = $pdm.CreateSession($s2, $deployStream)
    $deployStream.Close()
    Write-Host "  Model: $($session2.Model.Name) Members: $($session2.Model.Members.Count)" -ForegroundColor Green
    
    # Show workflow members
    foreach ($m in $session2.Model.Members) {
        $ns = try { $m.Namespace } catch { "" }
        if ($ns -like "*Workflow*" -or $m.Name -like "*SPD*" -or $m.Name -like "*Migrat*") {
            Write-Host "  ** $($m.Name) ns=$ns **" -ForegroundColor Cyan
        }
    }
    
    $session2.SetOption("NoAnalyze", $true)
    $session2.Deploy()
    
    Start-Sleep -Seconds 5
    $count = 0; foreach ($r in $session2.DeploymentResults) { $count++ }
    Write-Host "`n  DEPLOYED: $count items" -ForegroundColor Green
    $pdm.CloseSession($s2)
} catch {
    try { $deployStream.Close() } catch {}
    Write-Host "  Deploy failed: $($_.Exception.Message)" -ForegroundColor Red
    if ($_.Exception.InnerException) { Write-Host "  Inner: $($_.Exception.InnerException.Message)" -ForegroundColor DarkRed }
}

# ============================================================
# STEP 6: Verify
# ============================================================
Write-Host "`n[6] Verifying..." -ForegroundColor Yellow
$mgmt2 = New-Object SourceCode.Workflow.Management.WorkflowManagementServer
$mgmt2.CreateConnection()
$mgmt2.Connection.Open($connStr)
$allProcs = $mgmt2.GetProcSets()
foreach ($ps in $allProcs) {
    $marker = ""
    if ($ps.FullName -like "*SPD*" -or $ps.FullName -like "*Migrat*") { $marker = " <<< NEW!" }
    Write-Host "  $($ps.FullName) (ID=$($ps.ProcSetID))$marker" -ForegroundColor $(if($marker){"Green"}else{"DarkGray"})
}
Write-Host "  Total: $($allProcs.Count) processes" -ForegroundColor Yellow
$mgmt2.Connection.Close()
$pdm.Dispose()

Write-Host "`n============================================" -ForegroundColor White
Write-Host "  Real Model Deploy Complete!" -ForegroundColor White  
Write-Host "============================================" -ForegroundColor White

Stop-Transcript
