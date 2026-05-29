# ============================================================
#  Deploy-K2-FindLog.ps1
#  
#  FIND the real K2 error log + check CategoryPath collision
#  + try deploying the UNMODIFIED KPRX (just file swap, no  
#  identity changes) to see if the I/O error is from the KPRX
#  modifications or something else entirely.
#
#  Run in PowerShell ISE on K2 VM
# ============================================================

$ErrorActionPreference = "Continue"
$k2Bin = "C:\Program Files\K2\Bin"
$connStr = "Integrated=True;IsPrimaryLogin=True;Authenticate=True;EncryptedPassword=False;Host=localhost;Port=5555"
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$outputFile = Join-Path $scriptDir "Deploy-K2-FindLog-Results.txt"
$exportDir = Join-Path $scriptDir "k2-export\_findlog"

if (-not (Test-Path $exportDir)) { New-Item -Path $exportDir -ItemType Directory -Force | Out-Null }

Start-Transcript -Path $outputFile -Force

Write-Host "============================================" -ForegroundColor White
Write-Host "  K2 Deploy - Find Log + Test Unmodified" -ForegroundColor White
Write-Host "============================================`n" -ForegroundColor White

Get-ChildItem "$k2Bin\SourceCode.*.dll" | ForEach-Object {
    try { [System.Reflection.Assembly]::LoadFrom($_.FullName) | Out-Null } catch {}
}
Add-Type -AssemblyName System.IO.Compression
Add-PSSnapin SourceCode.Deployment.PowerShell -ErrorAction SilentlyContinue

# ============================================================
# STEP 1: Find ALL K2 log files
# ============================================================
Write-Host "[1] Searching for K2 logs..." -ForegroundColor Yellow

# Exact K2 HostServer log locations per Nintex docs
$logSearchPaths = @(
    "C:\Program Files\K2\HostServer\Bin",
    "C:\Program Files (x86)\K2 blackpearl\Host Server\bin",
    "C:\Program Files\K2\Bin",
    "C:\ProgramData\SourceCode\HostServer",
    "C:\ProgramData\SourceCode"
)
foreach ($dir in $logSearchPaths) {
    if (Test-Path $dir) {
        Write-Host "  Checking: $dir" -ForegroundColor DarkGray
        $logs = Get-ChildItem $dir -Filter "HostServer*" -ErrorAction SilentlyContinue |
            Where-Object { $_.Extension -in ".log",".txt" }
        foreach ($log in $logs) {
            Write-Host "  ** FOUND: $($log.FullName) ($([math]::Round($log.Length/1KB))KB, $($log.LastWriteTime)) **" -ForegroundColor Green
            # Show last 30 lines
            Write-Host "  --- Last 30 lines ---" -ForegroundColor Cyan
            Get-Content $log.FullName -Tail 30 -ErrorAction SilentlyContinue | ForEach-Object {
                Write-Host "  $_" -ForegroundColor DarkYellow
            }
        }
        # Also check for any .log files
        $anyLogs = Get-ChildItem $dir -Filter "*.log" -ErrorAction SilentlyContinue | 
            Where-Object { $_.LastWriteTime -gt (Get-Date).AddHours(-2) }
        foreach ($al in $anyLogs) {
            Write-Host "  Recent: $($al.FullName) ($([math]::Round($al.Length/1KB))KB)" -ForegroundColor DarkCyan
        }
    }
}

# HostServerLogging.config - show full content
Write-Host "`n  HostServerLogging.config:" -ForegroundColor Yellow
$logConfigs = @(
    "C:\Program Files\K2\HostServer\Bin\HostServerLogging.config",
    "C:\Program Files\K2\Bin\HostServerLogging.config",
    "C:\Program Files (x86)\K2 blackpearl\Host Server\bin\HostServerLogging.config"
)
foreach ($lc in $logConfigs) {
    if (Test-Path $lc) {
        Write-Host "  FOUND: $lc" -ForegroundColor Green
        $content = Get-Content $lc -Raw
        Write-Host $content -ForegroundColor DarkYellow
        break
    }
}
# Also search recursively
Get-ChildItem "C:\Program Files\K2" -Recurse -Filter "HostServerLogging.config" -ErrorAction SilentlyContinue | ForEach-Object {
    Write-Host "  Config at: $($_.FullName)" -ForegroundColor Green
}

# Windows Event Log - use Get-WinEvent (more reliable)
Write-Host "`n  Windows Event Log (K2 errors):" -ForegroundColor Yellow
try {
    $events = Get-WinEvent -LogName Application -MaxEvents 50 -ErrorAction SilentlyContinue |
        Where-Object { $_.ProviderName -like "*K2*" -or $_.ProviderName -like "*SourceCode*" -or 
                       ($_.Level -le 2 -and $_.Message -like "*I/O*") }
    foreach ($ev in $events | Select-Object -First 10) {
        Write-Host "  [$($ev.TimeCreated)] [$($ev.ProviderName)] $($ev.Message.Substring(0, [Math]::Min(500, $ev.Message.Length)))" -ForegroundColor DarkYellow
    }
    if (-not $events) { Write-Host "  No K2 events found" -ForegroundColor DarkGray }
} catch {
    Write-Host "  WinEvent: $($_.Exception.Message)" -ForegroundColor DarkGray
}

# ============================================================
# STEP 2: Check how many times "<CategoryPath>Workflow</CategoryPath>"
# appears in the KPRX (collision check)
# ============================================================
Write-Host "`n[2] CategoryPath collision check..." -ForegroundColor Yellow
$mgmt = New-Object SourceCode.Workflow.Management.WorkflowManagementServer
$mgmt.CreateConnection()
$mgmt.Connection.Open($connStr)
$kprxBytes = $mgmt.GetProcessKprx(13)
$mgmt.Connection.Close()
$kprxStr = [System.Text.Encoding]::UTF8.GetString($kprxBytes)

$catMatches = [regex]::Matches($kprxStr, '<CategoryPath>[^<]*</CategoryPath>')
Write-Host "  <CategoryPath> occurrences: $($catMatches.Count)" -ForegroundColor Cyan
foreach ($cm in $catMatches) {
    Write-Host "    $($cm.Value)" -ForegroundColor DarkGray
}

# ============================================================
# STEP 3: Deploy UNMODIFIED KPRX (just swap file, no identity change)
# This tests: is the I/O error from our changes, or inherent?
# ============================================================
Write-Host "`n[3] Deploy with UNMODIFIED KPRX..." -ForegroundColor Yellow

$pdm = New-Object SourceCode.Deployment.Management.PackageDeploymentManager
$pdmConn = $pdm.CreateConnection()
$pdmConn.Open($connStr)
$stream = [System.IO.File]::OpenRead("C:\Program Files\K2\Setup\App Framework Core.kspx")
$s1 = "FL_$(Get-Date -Format 'yyyyMMddHHmmss')"
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
        continue  # Skip old WF
    }
    $es = $entry.Open()
    $fs = [System.IO.File]::Create((Join-Path $extractDir $entry.Name))
    $es.CopyTo($fs)
    $fs.Close()
    $es.Close()
}
$archive.Dispose()

# Use ORIGINAL KPRX bytes - NO modifications
$newWfName = "TestKprxWF.Workflow"
[System.IO.File]::WriteAllBytes((Join-Path $extractDir $newWfName), $kprxBytes)
Write-Host "  Using UNMODIFIED KPRX as $newWfName" -ForegroundColor Green

# Update definition.model - only change the file reference
$defPath = Join-Path $extractDir "definition.model"
$defContent = [System.IO.File]::ReadAllText($defPath, [System.Text.Encoding]::UTF8)
if ($oldWfName) { $defContent = $defContent.Replace($oldWfName, $newWfName) }
# Change WF name to match the KPRX's original name (TestKprxWF, CategoryPath=Workflow)  
$defContent = $defContent.Replace("Framework Core\FrameworkGeneric.Workflow.Reference", "Workflow\TestKprxWF")
$defContent = $defContent.Replace("FrameworkGeneric%2EWorkflow%2EReference", "TestKprxWF")
$defContent = $defContent.Replace("FrameworkGeneric.Workflow.Reference", "TestKprxWF")
[System.IO.File]::WriteAllText($defPath, $defContent, [System.Text.Encoding]::UTF8)

# Repack
$finalKspx = Join-Path $exportDir "unmod_deploy.kspx"
if (Test-Path $finalKspx) { Remove-Item $finalKspx -Force }
$outZip = [System.IO.Compression.ZipFile]::Open($finalKspx, [System.IO.Compression.ZipArchiveMode]::Create)
foreach ($f in [System.IO.Directory]::GetFiles($extractDir)) {
    $fn = [System.IO.Path]::GetFileName($f)
    $e = $outZip.CreateEntry($fn)
    $es = $e.Open(); $fs = [System.IO.File]::OpenRead($f); $fs.CopyTo($es); $fs.Close(); $es.Close()
}
$outZip.Dispose()

$deployConfigXml = Join-Path $exportDir "deploy_config.xml"
Write-DeploymentConfig -InputFile $finalKspx -OutputFile $deployConfigXml
Deploy-Package -FileName $finalKspx -ConfigFile $deployConfigXml -ConnectionString $connStr
Write-Host "`n  Unmodified deploy completed!" -ForegroundColor Green

# ============================================================
# VERIFY
# ============================================================
Write-Host "`n[4] Processes:" -ForegroundColor Yellow
$mgmt2 = New-Object SourceCode.Workflow.Management.WorkflowManagementServer
$mgmt2.CreateConnection()
$mgmt2.Connection.Open($connStr)
foreach ($ps in $mgmt2.GetProcSets()) {
    $m = if ($ps.ProcSetID -gt 11) { " <<< NEW!" } else { "" }
    Write-Host "  $($ps.FullName) (ID=$($ps.ProcSetID))$m" -ForegroundColor $(if($m){"Green"}else{"DarkGray"})
}
Write-Host "  Total: $($mgmt2.GetProcSets().Count)" -ForegroundColor Yellow
$mgmt2.Connection.Close()
$pdm.Dispose()

Stop-Transcript
