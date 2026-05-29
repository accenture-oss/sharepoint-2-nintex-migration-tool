# ============================================================
#  Test-K2Deploy-Final.ps1
#  Two approaches: (A) PDM API with connection, (B) Clone .kspx
#  Run in PowerShell ISE on K2 VM
# ============================================================

$ErrorActionPreference = "Continue"
$k2Bin = "C:\Program Files\K2\Bin"
$K2Server = "localhost"
$K2Port = 5555
$connStr = "Integrated=True;IsPrimaryLogin=True;Authenticate=True;EncryptedPassword=False;Host=$K2Server;Port=$K2Port"
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$outputFile = Join-Path $scriptDir "Test-K2Deploy-Final-Results.txt"
$exportDir = Join-Path $scriptDir "k2-export\_final"

if (-not (Test-Path $exportDir)) { New-Item -Path $exportDir -ItemType Directory -Force | Out-Null }

Start-Transcript -Path $outputFile -Force

Write-Host "============================================" -ForegroundColor White
Write-Host "  K2 Final Deployment Test" -ForegroundColor White
Write-Host "============================================`n" -ForegroundColor White

# Load assemblies
foreach ($dll in @(
    "SourceCode.Framework.dll",
    "SourceCode.HostClientAPI.dll",
    "SourceCode.Workflow.Management.dll",
    "SourceCode.Deployment.Management.dll",
    "SourceCode.EnvironmentSettings.Client.dll"
)) {
    $p = Join-Path $k2Bin $dll; if (Test-Path $p) { [System.Reflection.Assembly]::LoadFrom($p) | Out-Null }
}
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

# ============================================================
# APPROACH A: PackageDeploymentManager with proper connection
# ============================================================
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  APPROACH A: PDM API with Connection" -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan

$pdmSuccess = $false
try {
    $pdm = New-Object SourceCode.Deployment.Management.PackageDeploymentManager
    Write-Host "[A1] PDM created" -ForegroundColor Green

    # Try CreateConnection and open it
    Write-Host "[A2] Creating connection..." -ForegroundColor Yellow
    $conn = $pdm.CreateConnection()
    Write-Host "  Connection type: $($conn.GetType().FullName)" -ForegroundColor DarkGray

    # List connection methods
    $conn.GetType().GetMethods() | Where-Object { $_.DeclaringType.FullName -like "SourceCode.*" } | Sort-Object Name -Unique | ForEach-Object {
        $ps = ($_.GetParameters() | ForEach-Object { "$($_.ParameterType.Name) $($_.Name)" }) -join ", "
        Write-Host "  CONN: $($_.ReturnType.Name) $($_.Name)($ps)" -ForegroundColor DarkGray
    }

    Write-Host "[A3] Opening connection..." -ForegroundColor Yellow
    $conn.Open($connStr)
    Write-Host "  Connected! IsConnected=$($conn.GetType().GetProperty('IsConnected'))" -ForegroundColor Green

    # Create a session
    Write-Host "[A4] Creating empty session..." -ForegroundColor Yellow
    $sessionName = "SPD_Migration_$(Get-Date -Format 'yyyyMMddHHmmss')"
    $session = $pdm.CreateSession($sessionName)
    Write-Host "  Session created: $($session.GetType().FullName)" -ForegroundColor Green

    # List ALL session methods
    Write-Host "`n  === ClientSession Methods ===" -ForegroundColor Cyan
    $session.GetType().GetMethods() | Where-Object { $_.DeclaringType.FullName -like "SourceCode.*" } | Sort-Object Name | ForEach-Object {
        $ps = ($_.GetParameters() | ForEach-Object { "$($_.ParameterType.Name) $($_.Name)" }) -join ", "
        Write-Host "  SESSION: $($_.ReturnType.Name) $($_.Name)($ps)" -ForegroundColor DarkCyan
    }

    # List ALL session properties
    Write-Host "`n  === ClientSession Properties ===" -ForegroundColor Cyan
    $session.GetType().GetProperties() | ForEach-Object {
        $val = try { $_.GetValue($session) } catch { "ERR" }
        Write-Host "  PROP: $($_.PropertyType.Name) $($_.Name) = $val" -ForegroundColor DarkCyan
    }

    # Try getting the model/items from session
    Write-Host "`n[A5] Exploring session model..." -ForegroundColor Yellow
    try {
        $model = $session.GetType().GetProperty("Model")
        if ($model) {
            $modelObj = $model.GetValue($session)
            Write-Host "  Model type: $($modelObj.GetType().FullName)" -ForegroundColor Green
            $modelObj.GetType().GetMethods() | Where-Object { $_.DeclaringType.FullName -like "SourceCode.*" } | Sort-Object Name | ForEach-Object {
                $ps = ($_.GetParameters() | ForEach-Object { "$($_.ParameterType.Name) $($_.Name)" }) -join ", "
                Write-Host "  MODEL: $($_.ReturnType.Name) $($_.Name)($ps)" -ForegroundColor DarkYellow
            }
            $modelObj.GetType().GetProperties() | ForEach-Object {
                $val = try { $_.GetValue($modelObj) } catch { "ERR" }
                Write-Host "  MODEL PROP: $($_.PropertyType.Name) $($_.Name) = $val" -ForegroundColor DarkYellow
            }
        }
    } catch { Write-Host "  Model exploration: $($_.Exception.Message)" -ForegroundColor Red }

    # Try creating a session FROM a working .kspx file  
    Write-Host "`n[A6] Creating session from existing .kspx..." -ForegroundColor Yellow
    $kspxPath = "C:\Program Files\K2\Setup\App Installer.kspx"
    if (Test-Path $kspxPath) {
        $kspxStream = [System.IO.File]::OpenRead($kspxPath)
        $session2Name = "SPD_FromKspx_$(Get-Date -Format 'yyyyMMddHHmmss')"
        $session2 = $pdm.CreateSession($session2Name, $kspxStream)
        $kspxStream.Close()
        Write-Host "  Session from .kspx created!" -ForegroundColor Green

        # Check what's inside
        try {
            $model2 = $session2.GetType().GetProperty("Model").GetValue($session2)
            Write-Host "  Model2 Name: $($model2.GetType().GetProperty('Name').GetValue($model2))" -ForegroundColor Green

            # List members/items in the model
            $membersSet = $model2.GetType().GetProperty("Members")
            if ($membersSet) {
                $members = $membersSet.GetValue($model2)
                Write-Host "  Members type: $($members.GetType().FullName)" -ForegroundColor DarkGray
                Write-Host "  Members count: $($members.Count)" -ForegroundColor Green
                $i = 0
                foreach ($member in $members) {
                    if ($i -ge 10) { Write-Host "  ... and more" -ForegroundColor DarkGray; break }
                    Write-Host "  Member[$i]: $($member.GetType().Name) Name=$($member.Name) ItemType=$($member.ItemType)" -ForegroundColor DarkYellow
                    $i++
                }
            }
        } catch { Write-Host "  Model2 exploration: $($_.Exception.Message)" -ForegroundColor Red }

        # NOW try Send to deploy it
        Write-Host "`n[A7] Deploying App Installer via PDM Send()..." -ForegroundColor Yellow
        try {
            $syncState = [SourceCode.Deployment.Management.SyncState]::Deploy
            $result = $pdm.Send($session2Name, $syncState)
            Write-Host "  Send result: $result" -ForegroundColor Green

            # Poll progress
            for ($j = 0; $j -lt 10; $j++) {
                Start-Sleep -Seconds 1
                $progResult = $null
                $hasProgress = $pdm.GetProgress($session2Name, [SourceCode.Deployment.Management.SessionMode]::Normal, [ref]$progResult)
                Write-Host "  Progress[$j]: hasProgress=$hasProgress result=$progResult" -ForegroundColor DarkGray
                if (-not $hasProgress) { break }
            }

            $succ = [uint32]0; $fail = [uint32]0
            $pdm.GetDeploymentResults($session2Name, [ref]$succ, [ref]$fail)
            Write-Host "  RESULTS: Succeeded=$succ Failed=$fail" -ForegroundColor $(if($fail -eq 0){"Green"}else{"Red"})
        } catch { Write-Host "  Send failed: $($_.Exception.Message)" -ForegroundColor Red }

        $pdm.CloseSession($session2Name)
    }

    $pdm.CloseSession($sessionName)
    $pdm.Dispose()
    $pdmSuccess = $true
    Write-Host "`n  PDM APPROACH: SUCCESS!" -ForegroundColor Green

} catch {
    Write-Host "  PDM APPROACH FAILED: $($_.Exception.Message)" -ForegroundColor Red
    if ($_.Exception.InnerException) {
        Write-Host "  Inner: $($_.Exception.InnerException.Message)" -ForegroundColor DarkRed
    }
}

# ============================================================
# APPROACH B: Clone .kspx ZIP (fallback)
# ============================================================
Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "  APPROACH B: Clone .kspx + Deploy" -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan

# Step 1: Get KPRX from existing TestKprxWF workflow
Write-Host "[B1] Getting KPRX from TestKprxWF..." -ForegroundColor Yellow
$mgmt = New-Object SourceCode.Workflow.Management.WorkflowManagementServer
$mgmt.CreateConnection()
$mgmt.Connection.Open($connStr)

$kprxBytes = $mgmt.GetProcessKprx(13)  # TestKprxWF
Write-Host "  KPRX: $($kprxBytes.Length) bytes" -ForegroundColor Green

# Step 2: Extract App Framework Core.kspx (has a workflow inside)
Write-Host "[B2] Extracting App Framework Core.kspx (has FrameworkGeneric.Workflow)..." -ForegroundColor Yellow
$sourceKspx = "C:\Program Files\K2\Setup\App Framework Core.kspx"
$extractDir = Join-Path $exportDir "clone_base"
if (Test-Path $extractDir) { Remove-Item $extractDir -Recurse -Force }
[System.IO.Compression.ZipFile]::ExtractToDirectory($sourceKspx, $extractDir)

# Find the workflow file inside
$wfFiles = Get-ChildItem $extractDir -Filter "*Workflow*" -Recurse
Write-Host "  Found workflow files:" -ForegroundColor DarkGray
foreach ($wf in $wfFiles) {
    Write-Host "    $($wf.Name) ($([math]::Round($wf.Length/1KB))KB)" -ForegroundColor DarkGray
    # Read first 100 bytes to understand format
    $bytes = [System.IO.File]::ReadAllBytes($wf.FullName)
    $hex = ($bytes[0..50] | ForEach-Object { $_.ToString("X2") }) -join " "
    Write-Host "    First bytes: $hex" -ForegroundColor DarkYellow
}

# Step 3: Read the definition.model to understand workflow entries
Write-Host "`n[B3] Reading definition.model workflow entries..." -ForegroundColor Yellow
$defModel = Join-Path $extractDir "definition.model"
$defContent = Get-Content $defModel -Raw -Encoding UTF8
# Find workflow-related entries
$wfMatches = [regex]::Matches($defContent, 'itemtype="12"[^>]*')
Write-Host "  Workflow entries (itemtype=12): $($wfMatches.Count)" -ForegroundColor Green
foreach ($m in $wfMatches) {
    Write-Host "  WF: $($m.Value.Substring(0, [Math]::Min(200, $m.Value.Length)))" -ForegroundColor DarkYellow
}

# Also check for process references
$procMatches = [regex]::Matches($defContent, 'ns="urn:SourceCode/Workflow[^"]*"[^>]*name="[^"]*"')
Write-Host "  Process entries: $($procMatches.Count)" -ForegroundColor Green
foreach ($m in $procMatches) {
    Write-Host "  PROC: $($m.Value.Substring(0, [Math]::Min(200, $m.Value.Length)))" -ForegroundColor DarkYellow
}

# Step 4: Create a MINIMAL .kspx with just our KPRX
Write-Host "`n[B4] Building minimal .kspx with TestKprxWF KPRX..." -ForegroundColor Yellow

$newKspxPath = Join-Path $exportDir "SPD_Migrated_Test.kspx"
if (Test-Path $newKspxPath) { Remove-Item $newKspxPath -Force }

# Build minimal definition.model
$minimalDef = @"
<?xml version="1.0" encoding="utf-8"?>
<model id="1" name="SPD Migrated Test" itemtype="2" apiver="9" ns="" excl="False" desc="Migrated from SharePoint Designer" solution="" nextid="100" minorApiVer="5">
  <set id="2" name="Members" itemtype="4" apiver="9" readonly="False" count="1" xmlns="urn:SourceCode/ComponentModel">
    <ct id="3" name="SPD_Migrated_WF" itemtype="12" apiver="9" ns="urn:SourceCode/Workflow" excl="False" displayname="SPD Migrated Workflow" scope="0" file="SPD_Migrated_WF.Workflow" />
  </set>
</model>
"@

$minimalProps = @"
<?xml version="1.0" encoding="utf-8"?>
<modelproperties name="SPD Migrated Test" desc="Migrated from SharePoint Designer" solution="" apiver="9" minorApiVer="4">
  <customproperties created="$(Get-Date -Format 'yyyy-MM-ddTHH:mm:ss.fffffffZ')" modified="$(Get-Date -Format 'yyyy-MM-ddTHH:mm:ss.fffffffZ')" PackageTool="1" PackagePlatform="2" DefaultPage="0" />
</modelproperties>
"@

try {
    $zipStream = [System.IO.File]::Create($newKspxPath)
    $archive = New-Object System.IO.Compression.ZipArchive($zipStream, [System.IO.Compression.ZipArchiveMode]::Create)

    # Add definition.model
    $entry = $archive.CreateEntry("definition.model")
    $writer = New-Object System.IO.StreamWriter($entry.Open())
    $writer.Write($minimalDef)
    $writer.Dispose()

    # Add properties.model
    $entry = $archive.CreateEntry("properties.model")
    $writer = New-Object System.IO.StreamWriter($entry.Open())
    $writer.Write($minimalProps)
    $writer.Dispose()

    # Add validation.model (4 null bytes)
    $entry = $archive.CreateEntry("validation.model")
    $vs = $entry.Open()
    $vs.Write([byte[]]@(0,0,0,0), 0, 4)
    $vs.Dispose()

    # Add the KPRX as a workflow file
    $entry = $archive.CreateEntry("SPD_Migrated_WF.Workflow")
    $ws = $entry.Open()
    $ws.Write($kprxBytes, 0, $kprxBytes.Length)
    $ws.Dispose()

    $archive.Dispose()
    $zipStream.Dispose()

    Write-Host "  Created: $newKspxPath ($([math]::Round((Get-Item $newKspxPath).Length/1KB))KB)" -ForegroundColor Green
} catch {
    Write-Host "  ZIP creation failed: $($_.Exception.Message)" -ForegroundColor Red
}

# Step 5: Deploy the custom .kspx
Write-Host "`n[B5] Deploying custom .kspx with Deploy-Package..." -ForegroundColor Yellow
Add-PSSnapin SourceCode.Deployment.PowerShell -ErrorAction SilentlyContinue
try {
    Deploy-Package -FileName $newKspxPath -K2Host $K2Server -Port $K2Port -Integrated $true -IsPrimaryLogin $true -NoAnalyze
    Write-Host "  DEPLOY SUCCESS!" -ForegroundColor Green
} catch {
    Write-Host "  Deploy failed: $($_.Exception.Message)" -ForegroundColor Red
}

# Step 6: Verify - check if the workflow appears
Write-Host "`n[B6] Verifying deployment..." -ForegroundColor Yellow
$allProcs = $mgmt.GetProcSets()
$xml = [xml]$allProcs
$procs = $xml.SelectNodes("//proc")
Write-Host "  Total processes on server: $($procs.Count)" -ForegroundColor DarkGray
foreach ($p in $procs) {
    if ($p.Name -like "*SPD*" -or $p.Name -like "*Migrat*") {
        Write-Host "  FOUND: $($p.Name) (ID=$($p.procid))" -ForegroundColor Green
    }
}

$mgmt.Connection.Close()

Write-Host "`n============================================" -ForegroundColor White
Write-Host "  Final Deployment Test Complete!" -ForegroundColor White
Write-Host "============================================" -ForegroundColor White

Stop-Transcript
