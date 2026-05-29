# ============================================================
#  Test-K2Deploy-Swap.ps1
#  
#  PROVEN STRATEGY:
#  1. Load App Framework Core.kspx via PDM (WORKS - tested)
#  2. Model.Save() to get properly formatted .kspx (WORKS - tested) 
#  3. Replace workflow KPRX file inside the saved ZIP
#  4. Deploy the modified .kspx via PDM session.Deploy()
#
#  Run in PowerShell ISE on K2 VM
# ============================================================

$ErrorActionPreference = "Continue"
$k2Bin = "C:\Program Files\K2\Bin"
$connStr = "Integrated=True;IsPrimaryLogin=True;Authenticate=True;EncryptedPassword=False;Host=localhost;Port=5555"
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$outputFile = Join-Path $scriptDir "Test-K2Deploy-Swap-Results.txt"
$exportDir = Join-Path $scriptDir "k2-export\_swap"

if (-not (Test-Path $exportDir)) { New-Item -Path $exportDir -ItemType Directory -Force | Out-Null }

Start-Transcript -Path $outputFile -Force

Write-Host "============================================" -ForegroundColor White
Write-Host "  K2 Workflow KPRX Swap Deploy" -ForegroundColor White
Write-Host "============================================`n" -ForegroundColor White

# Load assemblies
Get-ChildItem "$k2Bin\SourceCode.*.dll" | ForEach-Object {
    try { [System.Reflection.Assembly]::LoadFrom($_.FullName) | Out-Null } catch {}
}
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

# ============================================================
# STEP 1: Get TestKprxWF KPRX
# ============================================================
Write-Host "[1] Getting TestKprxWF KPRX..." -ForegroundColor Yellow
$mgmt = New-Object SourceCode.Workflow.Management.WorkflowManagementServer
$mgmt.CreateConnection()
$mgmt.Connection.Open($connStr)
$kprxBytes = $mgmt.GetProcessKprx(13)
Write-Host "  KPRX: $($kprxBytes.Length) bytes" -ForegroundColor Green

# Also get the KPRX XML to modify it
$kprxXml = [System.Text.Encoding]::UTF8.GetString($kprxBytes)
# Remove BOM if present
if ($kprxXml[0] -eq [char]0xFEFF) { $kprxXml = $kprxXml.Substring(1) }
$mgmt.Connection.Close()

# ============================================================
# STEP 2: Load App Framework Core .kspx and Save as template
# ============================================================
Write-Host "`n[2] Creating template from App Framework Core..." -ForegroundColor Yellow
$pdm = New-Object SourceCode.Deployment.Management.PackageDeploymentManager
$pdmConn = $pdm.CreateConnection()
$pdmConn.Open($connStr)

$kspxPath = "C:\Program Files\K2\Setup\App Framework Core.kspx"
$stream = [System.IO.File]::OpenRead($kspxPath)
$s1 = "Template_$(Get-Date -Format 'yyyyMMddHHmmss')"
$session = $pdm.CreateSession($s1, $stream)
$stream.Close()

# Save as .kspx
$templateKspx = Join-Path $exportDir "template.kspx"
$outStream = [System.IO.File]::Create($templateKspx)
$session.Model.Save($outStream)
$outStream.Close()
$pdm.CloseSession($s1)
Write-Host "  Template saved: $([math]::Round((Get-Item $templateKspx).Length/1KB))KB" -ForegroundColor Green

# ============================================================
# STEP 3: Modify the template .kspx ZIP
#  - Replace the workflow KPRX file with our TestKprxWF KPRX
#  - Update definition.model to reference new process name
# ============================================================
Write-Host "`n[3] Modifying template .kspx..." -ForegroundColor Yellow

# Extract
$extractDir = Join-Path $exportDir "template_extract"
if (Test-Path $extractDir) { Remove-Item $extractDir -Recurse -Force }
[System.IO.Compression.ZipFile]::ExtractToDirectory($templateKspx, $extractDir)

# Find the workflow file
$wfFile = Get-ChildItem $extractDir -Filter "FrameworkGeneric*" | Select-Object -First 1
Write-Host "  Original WF file: $($wfFile.Name) ($([math]::Round($wfFile.Length/1KB))KB)" -ForegroundColor DarkGray

# Read the definition.model
$defModelPath = Join-Path $extractDir "definition.model"
$defContent = Get-Content $defModelPath -Raw -Encoding UTF8

# Replace the workflow path/name in definition.model
# Original: "Framework Core\FrameworkGeneric.Workflow.Reference"  
# New:      "SPD Migration\TestKprxWF.SPDMigrated"  
$defContent = $defContent.Replace("Framework Core\FrameworkGeneric.Workflow.Reference", "SPD Migration\TestKprxWF.SPDMigrated")
$defContent = $defContent.Replace("FrameworkGeneric%2EWorkflow%2EReference", "TestKprxWF%2ESPDMigrated")
$defContent = $defContent.Replace("App Framework Core", "SPD Migration Package")

# Also update the workflow file reference
$oldWfFileName = $wfFile.Name
$newWfFileName = "TestKprxWF_SPDMigrated.Workflow"

# If definition.model references the file name, update it
$defContent = $defContent.Replace($oldWfFileName, $newWfFileName)

# Write updated definition.model
[System.IO.File]::WriteAllText($defModelPath, $defContent, [System.Text.Encoding]::UTF8)
Write-Host "  Updated definition.model" -ForegroundColor Green

# Replace the workflow file with our KPRX
# Also modify the KPRX to use new process name
$modifiedKprx = $kprxXml
# The KPRX has folder path info - let's check and update if needed
Write-Host "  KPRX process path in XML:" -ForegroundColor DarkGray
$processMatch = [regex]::Match($modifiedKprx, 'FolderName="[^"]*"')
if ($processMatch.Success) {
    Write-Host "    $($processMatch.Value)" -ForegroundColor DarkYellow
}

# Write the KPRX as the new workflow file
$newWfPath = Join-Path $extractDir $newWfFileName
# Delete old workflow file
Remove-Item $wfFile.FullName -Force
# Write new one (with BOM to match original format)
$bom = [System.Text.Encoding]::UTF8.GetPreamble()
$kprxNewBytes = [System.Text.Encoding]::UTF8.GetBytes($modifiedKprx)
$allBytes = $bom + $kprxNewBytes
[System.IO.File]::WriteAllBytes($newWfPath, $allBytes)
Write-Host "  Wrote new WF: $newWfFileName ($([math]::Round($allBytes.Length/1KB))KB)" -ForegroundColor Green

# Update properties.model
$propsPath = Join-Path $extractDir "properties.model"
if (Test-Path $propsPath) {
    $propsContent = Get-Content $propsPath -Raw -Encoding UTF8
    $propsContent = $propsContent.Replace("App Framework Core", "SPD Migration Package")
    [System.IO.File]::WriteAllText($propsPath, $propsContent, [System.Text.Encoding]::UTF8)
    Write-Host "  Updated properties.model" -ForegroundColor Green
}

# List modified files
Write-Host "  Modified package contents:" -ForegroundColor Yellow
Get-ChildItem $extractDir -Recurse -File | ForEach-Object {
    Write-Host "    $($_.Name) ($([math]::Round($_.Length/1KB))KB)" -ForegroundColor DarkGray
}

# ============================================================
# STEP 4: Re-package as .kspx ZIP
# ============================================================
Write-Host "`n[4] Re-packaging as .kspx..." -ForegroundColor Yellow
$modifiedKspx = Join-Path $exportDir "SPD_Migration.kspx"
if (Test-Path $modifiedKspx) { Remove-Item $modifiedKspx -Force }
[System.IO.Compression.ZipFile]::CreateFromDirectory($extractDir, $modifiedKspx)
Write-Host "  Created: $modifiedKspx ($([math]::Round((Get-Item $modifiedKspx).Length/1KB))KB)" -ForegroundColor Green

# ============================================================
# STEP 5: Deploy via PDM
# ============================================================
Write-Host "`n[5] Deploying modified .kspx via PDM..." -ForegroundColor Yellow
$deployStream = [System.IO.File]::OpenRead($modifiedKspx)
$s2 = "Deploy_SPD_$(Get-Date -Format 'yyyyMMddHHmmss')"
try {
    $session2 = $pdm.CreateSession($s2, $deployStream)
    $deployStream.Close()
    Write-Host "  Session: $s2" -ForegroundColor Green
    Write-Host "  Model: $($session2.Model.Name), Members: $($session2.Model.Members.Count)" -ForegroundColor Green
    
    # List members to verify
    foreach ($m in $session2.Model.Members) {
        $ns = try { $m.Namespace } catch { "" }
        if ($ns -like "*Workflow*" -or $m.Name -like "*SPD*" -or $m.Name -like "*TestKprx*") {
            Write-Host "  ** $($m.Name) ns=$ns **" -ForegroundColor Green
        }
    }
    
    # Deploy
    $session2.SetOption("NoAnalyze", $true)
    $session2.Deploy()
    Write-Host "`n  DEPLOY SUCCEEDED!" -ForegroundColor Green
    
    Start-Sleep -Seconds 3
    $dr = $session2.DeploymentResults
    if ($dr) {
        $count = 0
        foreach ($r in $dr) { $count++ }
        Write-Host "  Deployed $count items" -ForegroundColor Green
    }
    
    $pdm.CloseSession($s2)
} catch {
    $deployStream.Close()
    Write-Host "  Deploy failed: $($_.Exception.Message)" -ForegroundColor Red
    if ($_.Exception.InnerException) { Write-Host "  Inner: $($_.Exception.InnerException.Message)" -ForegroundColor DarkRed }
}

# ============================================================
# STEP 6: Verify on K2 server
# ============================================================
Write-Host "`n[6] Verifying on K2 server..." -ForegroundColor Yellow
$mgmt2 = New-Object SourceCode.Workflow.Management.WorkflowManagementServer
$mgmt2.CreateConnection()
$mgmt2.Connection.Open($connStr)
$procSets = $mgmt2.GetProcSets()
Write-Host "  All processes:" -ForegroundColor Yellow
foreach ($ps in $procSets) {
    $marker = ""
    if ($ps.FullName -like "*SPD*" -or $ps.FullName -like "*Migrat*") { $marker = " <<<< NEW!" }
    Write-Host "  $($ps.FullName) (ID=$($ps.ProcSetID))$marker" -ForegroundColor $(if($marker){"Green"}else{"DarkGray"})
}
$mgmt2.Connection.Close()

$pdm.Dispose()

Write-Host "`n============================================" -ForegroundColor White
Write-Host "  Workflow Swap Deploy Complete!" -ForegroundColor White
Write-Host "============================================" -ForegroundColor White

Stop-Transcript
