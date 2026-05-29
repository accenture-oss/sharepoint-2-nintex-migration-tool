# ============================================================
#  Deploy-K2-SimpleReplace.ps1
#  
#  ALMOST THERE! Errors reduced to 2 (from 6+).
#  Issue: Regex broke the KPRX (added 1187 extra bytes).
#
#  FIX: Use simple .Replace() with EXACT known values:
#    Guid: 65aaa9ae4e5b4d8b839d9edf44eea93a -> new
#    Name: TestKprxWF -> SPD_Migrated_Approval
#    CategoryPath: Workflow -> SPD Migration
#
#  Keep SmO/Forms/Views COMPLETELY unchanged.
#
#  Run in PowerShell ISE on K2 VM
# ============================================================

$ErrorActionPreference = "Continue"
$k2Bin = "C:\Program Files\K2\Bin"
$connStr = "Integrated=True;IsPrimaryLogin=True;Authenticate=True;EncryptedPassword=False;Host=localhost;Port=5555"
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$outputFile = Join-Path $scriptDir "Deploy-K2-SimpleReplace-Results.txt"
$exportDir = Join-Path $scriptDir "k2-export\_simple"

if (-not (Test-Path $exportDir)) { New-Item -Path $exportDir -ItemType Directory -Force | Out-Null }

Start-Transcript -Path $outputFile -Force

Write-Host "============================================" -ForegroundColor White
Write-Host "  K2 Deploy - Simple .Replace()" -ForegroundColor White
Write-Host "============================================`n" -ForegroundColor White

Get-ChildItem "$k2Bin\SourceCode.*.dll" | ForEach-Object {
    try { [System.Reflection.Assembly]::LoadFrom($_.FullName) | Out-Null } catch {}
}
Add-Type -AssemblyName System.IO.Compression
Add-PSSnapin SourceCode.Deployment.PowerShell -ErrorAction SilentlyContinue

# Get KPRX as raw bytes
$mgmt = New-Object SourceCode.Workflow.Management.WorkflowManagementServer
$mgmt.CreateConnection()
$mgmt.Connection.Open($connStr)
$kprxBytes = $mgmt.GetProcessKprx(13)
$mgmt.Connection.Close()
$kprxStr = [System.Text.Encoding]::UTF8.GetString($kprxBytes)
Write-Host "KPRX: $($kprxBytes.Length) bytes" -ForegroundColor Green

# ============================================================
# STEP 1: Simple .Replace() on KNOWN values
# ============================================================
Write-Host "`n[1] Simple .Replace()..." -ForegroundColor Yellow

$newGuid = [System.Guid]::NewGuid().ToString("N")  # 32-char hex, no dashes

# Known values from KPRX (confirmed in previous output):
# <Guid>65aaa9ae4e5b4d8b839d9edf44eea93a</Guid>
# <Name>TestKprxWF</Name>
# <DisplayName>TestKprxWF</DisplayName>
# <CategoryPath>Workflow</CategoryPath>

$modStr = $kprxStr

# Replace Process Guid (this is a 32-char hex in the KPRX)
$modStr = $modStr.Replace(
    "<Guid>65aaa9ae4e5b4d8b839d9edf44eea93a</Guid>",
    "<Guid>$newGuid</Guid>")
Write-Host "  Guid: 65aaa9ae... -> $newGuid" -ForegroundColor Green

# Replace Process Name  
$modStr = $modStr.Replace(
    "<Name>TestKprxWF</Name>",
    "<Name>SPD_Migrated_Approval</Name>")
Write-Host "  Name: TestKprxWF -> SPD_Migrated_Approval" -ForegroundColor Green

# Replace Display Name
$modStr = $modStr.Replace(
    "<DisplayName>TestKprxWF</DisplayName>",
    "<DisplayName>SPD Migrated Approval Workflow</DisplayName>")
Write-Host "  DisplayName updated" -ForegroundColor Green

# Replace CategoryPath (be careful - only replace the Process-level one)
# The KPRX has: <CategoryPath>Workflow</CategoryPath> near the end
$modStr = $modStr.Replace(
    "<CategoryPath>Workflow</CategoryPath>",
    "<CategoryPath>SPD Migration</CategoryPath>")
Write-Host "  CategoryPath: Workflow -> SPD Migration" -ForegroundColor Green

# Also replace ExtenderNamespace (uses same GUID)
$modStr = $modStr.Replace(
    "<ExtenderNamespace>65aaa9ae4e5b4d8b839d9edf44eea93a</ExtenderNamespace>",
    "<ExtenderNamespace>$newGuid</ExtenderNamespace>")
Write-Host "  ExtenderNamespace updated" -ForegroundColor Green

# Verify size - should be very close to original
$modBytes = [System.Text.Encoding]::UTF8.GetBytes($modStr)
$sizeDiff = $modBytes.Length - $kprxBytes.Length
Write-Host "`n  Size: $($modBytes.Length) (diff: $sizeDiff bytes)" -ForegroundColor $(if([Math]::Abs($sizeDiff) -lt 200){"Green"}else{"Red"})

# Show the identity section
$viewsIdx = $modStr.IndexOf('</Views>')
if ($viewsIdx -gt 0) {
    $tail = $modStr.Substring($viewsIdx, [Math]::Min(350, $modStr.Length - $viewsIdx))
    Write-Host "  Identity: $tail" -ForegroundColor Cyan
}

# ============================================================
# STEP 2: Build .kspx
# ============================================================
Write-Host "`n[2] Building .kspx..." -ForegroundColor Yellow

$pdm = New-Object SourceCode.Deployment.Management.PackageDeploymentManager
$pdmConn = $pdm.CreateConnection()
$pdmConn.Open($connStr)
$stream = [System.IO.File]::OpenRead("C:\Program Files\K2\Setup\App Framework Core.kspx")
$s1 = "SR_$(Get-Date -Format 'yyyyMMddHHmmss')"
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
        continue
    }
    $es = $entry.Open()
    $fs = [System.IO.File]::Create((Join-Path $extractDir $entry.Name))
    $es.CopyTo($fs)
    $fs.Close()
    $es.Close()
}
$archive.Dispose()

$newWfName = "SPDMigratedApproval.Workflow"
[System.IO.File]::WriteAllBytes((Join-Path $extractDir $newWfName), $modBytes)
Write-Host "  Skipped: $oldWfName" -ForegroundColor Green
Write-Host "  Added: $newWfName ($([math]::Round($modBytes.Length/1KB))KB)" -ForegroundColor Green

# Update definition.model - MINIMAL changes ONLY for WF
$defPath = Join-Path $extractDir "definition.model"
$defContent = [System.IO.File]::ReadAllText($defPath, [System.Text.Encoding]::UTF8)
if ($oldWfName) { $defContent = $defContent.Replace($oldWfName, $newWfName) }
$defContent = $defContent.Replace("Framework Core\FrameworkGeneric.Workflow.Reference", "SPD Migration\SPD_Migrated_Approval")
$defContent = $defContent.Replace("FrameworkGeneric%2EWorkflow%2EReference", "SPD_Migrated_Approval")
$defContent = $defContent.Replace("FrameworkGeneric.Workflow.Reference", "SPD_Migrated_Approval")
# Update the WF category path in definition model only for the WF folder entry
$defContent = $defContent.Replace(
    "urn:SourceCode/Categories?Framework_Core#Path.%2Froot%2FApps%2FK2%2FFramework%2FCore%2FWorkflows%2F",
    "urn:SourceCode/Categories?SPD_Migration#Path.%2Froot%2FApps%2FK2%2FFramework%2FCore%2FWorkflows%2F")
[System.IO.File]::WriteAllText($defPath, $defContent, [System.Text.Encoding]::UTF8)
Write-Host "  definition.model updated" -ForegroundColor Green

# Repack
$finalKspx = Join-Path $exportDir "simple_deploy.kspx"
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
# STEP 3: Deploy
# ============================================================
Write-Host "`n[3] Deploy-Package..." -ForegroundColor Yellow
$deployConfigXml = Join-Path $exportDir "deploy_config.xml"
Write-DeploymentConfig -InputFile $finalKspx -OutputFile $deployConfigXml
Write-Host "  Config generated" -ForegroundColor Green

Deploy-Package -FileName $finalKspx -ConfigFile $deployConfigXml -ConnectionString $connStr
Write-Host "`n  Deploy-Package completed!" -ForegroundColor Green

# Also check the K2 host server log for errors
Write-Host "`n[3b] K2 HostServer log (last 30 lines):" -ForegroundColor Yellow
$logPaths = @(
    "C:\ProgramData\SourceCode\HostServer\Logs\HostServer.log",
    "C:\Program Files\K2\HostServer\Bin\HostServer.log",
    "C:\Program Files\K2\Bin\HostServer.log"
)
foreach ($lp in $logPaths) {
    if (Test-Path $lp) {
        Write-Host "  Found: $lp" -ForegroundColor Green
        Get-Content $lp -Tail 30 | ForEach-Object { Write-Host "  $_" -ForegroundColor DarkGray }
        break
    }
}
# Search for any log files 
Get-ChildItem "C:\ProgramData\SourceCode" -Recurse -Filter "*.log" -ErrorAction SilentlyContinue | ForEach-Object {
    Write-Host "  Log: $($_.FullName) ($([math]::Round($_.Length/1KB))KB)" -ForegroundColor DarkCyan
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
