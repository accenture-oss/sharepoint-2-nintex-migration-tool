# ============================================================
#  Test-K2Deploy-Swap2.ps1
#  
#  FIXED: Properly replace workflow file reference in 
#  definition.model and delete old workflow file
#
#  Run in PowerShell ISE on K2 VM
# ============================================================

$ErrorActionPreference = "Continue"
$k2Bin = "C:\Program Files\K2\Bin"
$connStr = "Integrated=True;IsPrimaryLogin=True;Authenticate=True;EncryptedPassword=False;Host=localhost;Port=5555"
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$outputFile = Join-Path $scriptDir "Test-K2Deploy-Swap2-Results.txt"
$exportDir = Join-Path $scriptDir "k2-export\_swap2"

if (-not (Test-Path $exportDir)) { New-Item -Path $exportDir -ItemType Directory -Force | Out-Null }

Start-Transcript -Path $outputFile -Force

Write-Host "============================================" -ForegroundColor White
Write-Host "  K2 Workflow KPRX Swap Deploy v2" -ForegroundColor White
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
$mgmt.Connection.Close()

# ============================================================
# STEP 2: Load .kspx and Save as template
# ============================================================
Write-Host "`n[2] Creating template..." -ForegroundColor Yellow
$pdm = New-Object SourceCode.Deployment.Management.PackageDeploymentManager
$pdmConn = $pdm.CreateConnection()
$pdmConn.Open($connStr)

$kspxPath = "C:\Program Files\K2\Setup\App Framework Core.kspx"
$stream = [System.IO.File]::OpenRead($kspxPath)
$s1 = "Tmpl_$(Get-Date -Format 'yyyyMMddHHmmss')"
$session = $pdm.CreateSession($s1, $stream)
$stream.Close()

$templateKspx = Join-Path $exportDir "template.kspx"
$outStream = [System.IO.File]::Create($templateKspx)
$session.Model.Save($outStream)
$outStream.Close()
$pdm.CloseSession($s1)
Write-Host "  Template: $([math]::Round((Get-Item $templateKspx).Length/1KB))KB" -ForegroundColor Green

# ============================================================
# STEP 3: Extract and modify
# ============================================================
Write-Host "`n[3] Extracting and modifying template..." -ForegroundColor Yellow

$extractDir = Join-Path $exportDir "extract"
if (Test-Path $extractDir) { Remove-Item $extractDir -Recurse -Force }
[System.IO.Compression.ZipFile]::ExtractToDirectory($templateKspx, $extractDir)

# Find ALL files - look for the workflow file (contains KPRX XML)
Write-Host "  Finding workflow file..." -ForegroundColor Yellow
$allFiles = Get-ChildItem $extractDir -File -Recurse
foreach ($f in $allFiles) {
    if ($f.Name -like "*Workflow*" -or $f.Name -like "*FrameworkGeneric*") {
        Write-Host "  FOUND: $($f.Name) ($([math]::Round($f.Length/1KB))KB)" -ForegroundColor Green
    }
}

# The workflow file is: FrameworkGeneric.Workflow_A4GH3Iisqu1GSLbFpPmkPSdQ2+g.Reference
$oldWfFile = Get-ChildItem $extractDir -File | Where-Object { $_.Name -like "FrameworkGeneric.Workflow*" }
if ($oldWfFile) {
    Write-Host "  Old WF file: $($oldWfFile.Name)" -ForegroundColor DarkGray
    $oldWfFileName = $oldWfFile.Name
} else {
    Write-Host "  ERROR: Workflow file not found!" -ForegroundColor Red
    # List all files in root
    Get-ChildItem $extractDir -File | ForEach-Object { Write-Host "    $($_.Name)" -ForegroundColor DarkGray }
}

# New workflow file name (same pattern: Name_Hash.DisplayName)
$newWfFileName = "SPD_Migration_TestKprxWF_MIGRATED.SPDWorkflow"

# Read definition.model and find the file= reference
$defModelPath = Join-Path $extractDir "definition.model"
$defBytes = [System.IO.File]::ReadAllBytes($defModelPath)
$defContent = [System.Text.Encoding]::UTF8.GetString($defBytes)

# Show the file= references
$fileRefs = [regex]::Matches($defContent, 'file="([^"]*)"')
Write-Host "  File references in definition.model:" -ForegroundColor Yellow
foreach ($fr in $fileRefs) {
    Write-Host "    file=`"$($fr.Groups[1].Value)`"" -ForegroundColor DarkYellow
}

# Replace old WF file reference with new one
if ($oldWfFileName) {
    Write-Host "`n  Replacing '$oldWfFileName' -> '$newWfFileName'" -ForegroundColor Cyan
    $defContent = $defContent.Replace($oldWfFileName, $newWfFileName)
}

# Replace process display name 
$defContent = $defContent.Replace("Framework Core\FrameworkGeneric.Workflow.Reference", "SPD Migration\SPDMigratedWF")
$defContent = $defContent.Replace("FrameworkGeneric%2EWorkflow%2EReference", "SPDMigratedWF")
$defContent = $defContent.Replace("App Framework Core", "SPD Migration Package v2")

# Write updated definition.model
[System.IO.File]::WriteAllBytes($defModelPath, [System.Text.Encoding]::UTF8.GetBytes($defContent))
Write-Host "  Updated definition.model" -ForegroundColor Green

# Delete old workflow file and write new one
if ($oldWfFile -and (Test-Path $oldWfFile.FullName)) {
    Remove-Item $oldWfFile.FullName -Force
    Write-Host "  Deleted old WF file" -ForegroundColor Green
}

$newWfPath = Join-Path $extractDir $newWfFileName
[System.IO.File]::WriteAllBytes($newWfPath, $kprxBytes)
Write-Host "  Wrote new WF: $newWfFileName ($([math]::Round($kprxBytes.Length/1KB))KB)" -ForegroundColor Green

# Update properties.model
$propsPath = Join-Path $extractDir "properties.model"
if (Test-Path $propsPath) {
    $propsContent = [System.IO.File]::ReadAllText($propsPath, [System.Text.Encoding]::UTF8)
    $propsContent = $propsContent.Replace("App Framework Core", "SPD Migration Package v2")
    [System.IO.File]::WriteAllText($propsPath, $propsContent, [System.Text.Encoding]::UTF8)
}

# Verify - show file= references AFTER modification
$defContentAfter = [System.IO.File]::ReadAllText($defModelPath, [System.Text.Encoding]::UTF8)
$fileRefsAfter = [regex]::Matches($defContentAfter, 'file="([^"]*)"')
Write-Host "`n  File references AFTER modification:" -ForegroundColor Yellow
foreach ($fr in $fileRefsAfter) {
    Write-Host "    file=`"$($fr.Groups[1].Value)`"" -ForegroundColor DarkYellow
}

# ============================================================
# STEP 4: Re-package
# ============================================================
Write-Host "`n[4] Re-packaging..." -ForegroundColor Yellow
$modifiedKspx = Join-Path $exportDir "SPD_Migration_v2.kspx"
if (Test-Path $modifiedKspx) { Remove-Item $modifiedKspx -Force }
[System.IO.Compression.ZipFile]::CreateFromDirectory($extractDir, $modifiedKspx)
Write-Host "  Created: $([math]::Round((Get-Item $modifiedKspx).Length/1KB))KB" -ForegroundColor Green

# ============================================================
# STEP 5: Deploy
# ============================================================
Write-Host "`n[5] Deploying via PDM..." -ForegroundColor Yellow
$deployStream = [System.IO.File]::OpenRead($modifiedKspx)
$s2 = "Deploy_v2_$(Get-Date -Format 'yyyyMMddHHmmss')"
try {
    $session2 = $pdm.CreateSession($s2, $deployStream)
    $deployStream.Close()
    Write-Host "  Model: $($session2.Model.Name), Members: $($session2.Model.Members.Count)" -ForegroundColor Green
    
    # Show workflow members
    foreach ($m in $session2.Model.Members) {
        $ns = try { $m.Namespace } catch { "" }
        if ($ns -like "*Workflow*") {
            Write-Host "  WF: $($m.Name) ns=$ns" -ForegroundColor Cyan
        }
    }
    
    $session2.SetOption("NoAnalyze", $true)
    $session2.Deploy()
    
    Start-Sleep -Seconds 5
    $dr = $session2.DeploymentResults
    $count = 0; $failed = 0
    if ($dr) {
        foreach ($r in $dr) { 
            $count++
            # Check if this result has an error
            try {
                $status = $r.GetType().GetProperty("Status").GetValue($r)
                $itemName = $r.GetType().GetProperty("ItemDisplayName").GetValue($r)
                if ("$status" -ne "Succeeded" -and "$status" -ne "0") {
                    $failed++
                    $errMsg = try { $r.GetType().GetProperty("Error").GetValue($r) } catch { "" }
                    Write-Host "  FAILED: $itemName Status=$status Error=$errMsg" -ForegroundColor Red
                }
            } catch {}
        }
    }
    Write-Host "`n  DEPLOYED: $count items ($failed failed)" -ForegroundColor $(if($failed -eq 0){"Green"}else{"Yellow"})
    
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
$procSets = $mgmt2.GetProcSets()
Write-Host "  All processes on K2:" -ForegroundColor Yellow
foreach ($ps in $procSets) {
    $marker = ""
    if ($ps.FullName -like "*SPD*" -or $ps.FullName -like "*Migrat*") { $marker = " <<<< NEW!" }
    Write-Host "  $($ps.FullName) (ID=$($ps.ProcSetID))$marker" -ForegroundColor $(if($marker){"Green"}else{"DarkGray"})
}
$mgmt2.Connection.Close()

$pdm.Dispose()

Write-Host "`n============================================" -ForegroundColor White
Write-Host "  Swap Deploy v2 Complete!" -ForegroundColor White
Write-Host "============================================" -ForegroundColor White

Stop-Transcript
