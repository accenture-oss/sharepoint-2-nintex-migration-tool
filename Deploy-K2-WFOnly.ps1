# ============================================================
#  Deploy-K2-WFOnly.ps1
#  
#  I/O error during process compile = SmartObject references
#  broken because we renamed Framework_Core -> SPD_Migration
#  in definition.model, but the KPRX still references original
#  SmartObject GUIDs under the old names.
#
#  FIX: Keep ALL definition.model entries unchanged EXCEPT
#  the workflow entry. No renaming of SmartObjects/Forms/Views.
#
#  Run in PowerShell ISE on K2 VM
# ============================================================

$ErrorActionPreference = "Continue"
$k2Bin = "C:\Program Files\K2\Bin"
$connStr = "Integrated=True;IsPrimaryLogin=True;Authenticate=True;EncryptedPassword=False;Host=localhost;Port=5555"
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$outputFile = Join-Path $scriptDir "Deploy-K2-WFOnly-Results.txt"
$exportDir = Join-Path $scriptDir "k2-export\_wfonly"

if (-not (Test-Path $exportDir)) { New-Item -Path $exportDir -ItemType Directory -Force | Out-Null }

Start-Transcript -Path $outputFile -Force

Write-Host "============================================" -ForegroundColor White
Write-Host "  K2 Deploy - WF Only (keep SmO/Forms)" -ForegroundColor White
Write-Host "============================================`n" -ForegroundColor White

Get-ChildItem "$k2Bin\SourceCode.*.dll" | ForEach-Object {
    try { [System.Reflection.Assembly]::LoadFrom($_.FullName) | Out-Null } catch {}
}
Add-Type -AssemblyName System.IO.Compression
Add-PSSnapin SourceCode.Deployment.PowerShell -ErrorAction SilentlyContinue

# Get KPRX and modify identity via RAW string replacement
$mgmt = New-Object SourceCode.Workflow.Management.WorkflowManagementServer
$mgmt.CreateConnection()
$mgmt.Connection.Open($connStr)
$kprxBytes = $mgmt.GetProcessKprx(13)
$mgmt.Connection.Close()
$kprxStr = [System.Text.Encoding]::UTF8.GetString($kprxBytes)

# ============================================================
# STEP 1: RAW replace identity ONLY  
# ============================================================
Write-Host "[1] Raw identity replacement..." -ForegroundColor Yellow
$newGuid = [System.Guid]::NewGuid().ToString("N")  # No dashes, matches K2 format
$newName = "SPD_Migrated_Approval"
$newDisplayName = "SPD Migrated Approval Workflow"
$newCategoryPath = "SPD Migration"

# Show original
$viewsEnd = $kprxStr.IndexOf('</Views>')
$tail = $kprxStr.Substring($viewsEnd)
Write-Host "  Original tail: $($tail.Substring(0, [Math]::Min(300,$tail.Length)))" -ForegroundColor DarkGray

# Replace Guid (no dashes to match K2 format: 65aaa9ae4e5b4d8b839d9edf44eea93a)
$modStr = [regex]::Replace($kprxStr,
    '(</Views><Guid>)[^<]*(</Guid>)',
    "`$1$newGuid`$2")

# Replace Name
$modStr = [regex]::Replace($modStr,
    '(</Guid><Name>)[^<]*(</Name>)',
    "`$1$newName`$2")

# Replace DisplayName
$modStr = [regex]::Replace($modStr,
    '(</Name><DisplayName>)[^<]*(</DisplayName>)',
    "`$1$newDisplayName`$2")

# Replace CategoryPath
$modStr = [regex]::Replace($modStr,
    '<CategoryPath>[^<]*</CategoryPath>',
    "<CategoryPath>$newCategoryPath</CategoryPath>")

# Show modified tail
$viewsEnd2 = $modStr.IndexOf('</Views>')
$tail2 = $modStr.Substring($viewsEnd2)
Write-Host "  Modified tail: $($tail2.Substring(0, [Math]::Min(300,$tail2.Length)))" -ForegroundColor Green

# Convert back to bytes - use SAME encoding as original
$modBytes = [System.Text.Encoding]::UTF8.GetBytes($modStr)
Write-Host "  Size: $($modBytes.Length) (was $($kprxBytes.Length))" -ForegroundColor $(if($modBytes.Length -eq $kprxBytes.Length){"Green"}else{"Yellow"})

# ============================================================  
# STEP 2: Build .kspx - KEEP all original entries, ONLY swap WF
# ============================================================
Write-Host "`n[2] Building .kspx (minimal changes)..." -ForegroundColor Yellow

$pdm = New-Object SourceCode.Deployment.Management.PackageDeploymentManager
$pdmConn = $pdm.CreateConnection()
$pdmConn.Open($connStr)
$stream = [System.IO.File]::OpenRead("C:\Program Files\K2\Setup\App Framework Core.kspx")
$s1 = "WO_$(Get-Date -Format 'yyyyMMddHHmmss')"
$session = $pdm.CreateSession($s1, $stream)
$stream.Close()
$templateKspx = Join-Path $exportDir "template.kspx"
$outStream = [System.IO.File]::Create($templateKspx)
$session.Model.Save($outStream)
$outStream.Close()
$pdm.CloseSession($s1)

$extractDir = Join-Path $exportDir "extract"
if (Test-Path $extractDir) { Remove-Item $extractDir -Recurse -Force }
New-Item $extractDir -ItemType Directory -Force | Out-Null

$archive = [System.IO.Compression.ZipFile]::OpenRead($templateKspx)
$oldWfName = $null
foreach ($entry in $archive.Entries) {
    if ($entry.Name -match "FrameworkGeneric\.Workflow") {
        $oldWfName = $entry.Name
        continue  # Skip old WF file only
    }
    $es = $entry.Open()
    $fs = [System.IO.File]::Create((Join-Path $extractDir $entry.Name))
    $es.CopyTo($fs)
    $fs.Close()
    $es.Close()
}
$archive.Dispose()

# Write modified KPRX
$newWfName = "SPDMigratedApproval.Workflow"
[System.IO.File]::WriteAllBytes((Join-Path $extractDir $newWfName), $modBytes)
Write-Host "  Skipped: $oldWfName" -ForegroundColor Green
Write-Host "  Added: $newWfName" -ForegroundColor Green

# Update definition.model - MINIMAL changes
# ONLY change the workflow-related entries, keep SmO/Forms/Views intact
$defPath = Join-Path $extractDir "definition.model"
$defContent = [System.IO.File]::ReadAllText($defPath, [System.Text.Encoding]::UTF8)

# Step A: Replace the WF file reference
if ($oldWfName) { 
    $defContent = $defContent.Replace($oldWfName, $newWfName)
    Write-Host "  Replaced file ref" -ForegroundColor Green
}

# Step B: Replace ONLY the workflow name/path (not folder categories)
# "Framework Core\FrameworkGeneric.Workflow.Reference" -> "SPD Migration\SPD_Migrated_Approval"  
$defContent = $defContent.Replace("Framework Core\FrameworkGeneric.Workflow.Reference", "$newCategoryPath\$newName")
$defContent = $defContent.Replace("FrameworkGeneric%2EWorkflow%2EReference", [System.Uri]::EscapeDataString($newName))
$defContent = $defContent.Replace("FrameworkGeneric.Workflow.Reference", $newName)

# DO NOT replace Framework_Core or "Framework Core" globally!
# Only replace in the specific Workflows category path
# urn:SourceCode/Categories?Workflows -> keep as-is  
# But update the WF folder: Framework_Core under Workflows
$defContent = $defContent.Replace(
    "urn:SourceCode/Categories?Framework_Core#Path.%2Froot%2FApps%2FK2%2FFramework%2FCore%2FWorkflows%2F",
    "urn:SourceCode/Categories?SPD_Migration#Path.%2Froot%2FApps%2FK2%2FFramework%2FCore%2FWorkflows%2F")

# Replace display name for the WF folder
$defContent = [regex]::Replace($defContent,
    'displayname="Framework Core\\FrameworkGeneric',
    "displayname=`"$newCategoryPath\\$newName")

[System.IO.File]::WriteAllText($defPath, $defContent, [System.Text.Encoding]::UTF8)

# DO NOT modify properties.model - keep original package name
Write-Host "  definition.model updated (WF entries only)" -ForegroundColor Green

# Repack
$finalKspx = Join-Path $exportDir "wfonly_deploy.kspx"
if (Test-Path $finalKspx) { Remove-Item $finalKspx -Force }
$outZip = [System.IO.Compression.ZipFile]::Open($finalKspx, [System.IO.Compression.ZipArchiveMode]::Create)
foreach ($f in [System.IO.Directory]::GetFiles($extractDir)) {
    $fn = [System.IO.Path]::GetFileName($f)
    $e = $outZip.CreateEntry($fn)
    $es = $e.Open(); $fs = [System.IO.File]::OpenRead($f); $fs.CopyTo($es); $fs.Close(); $es.Close()
}
$outZip.Dispose()
Write-Host "  Package: $([math]::Round((Get-Item $finalKspx).Length/1KB))KB" -ForegroundColor Green

# ============================================================
# STEP 3: Deploy via Write-DeploymentConfig + Deploy-Package
# Use -ErrorAction Continue so we see detailed results
# ============================================================
Write-Host "`n[3] Deploy-Package..." -ForegroundColor Yellow
$deployConfigXml = Join-Path $exportDir "deploy_config.xml"
try {
    Write-DeploymentConfig -InputFile $finalKspx -OutputFile $deployConfigXml
    Write-Host "  Config generated" -ForegroundColor Green
} catch {
    Write-Host "  Config error: $($_.Exception.Message)" -ForegroundColor Red
}

# Deploy with Continue so we see per-item results
$ErrorActionPreference = "Continue"
try {
    Deploy-Package -FileName $finalKspx -ConfigFile $deployConfigXml -ConnectionString $connStr
    Write-Host "`n  Deploy-Package completed!" -ForegroundColor Green
} catch {
    Write-Host "  Error: $($_.Exception.Message)" -ForegroundColor Red
}

# ============================================================
# VERIFY
# ============================================================
Write-Host "`n[4] Processes:" -ForegroundColor Yellow
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
