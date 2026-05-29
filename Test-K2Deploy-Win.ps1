# ============================================================
#  Test-K2Deploy-Win.ps1
#  Fix Deploy() + Build valid .kspx from Model.Save()
#  Run in PowerShell ISE on K2 VM
# ============================================================

$ErrorActionPreference = "Continue"
$k2Bin = "C:\Program Files\K2\Bin"
$connStr = "Integrated=True;IsPrimaryLogin=True;Authenticate=True;EncryptedPassword=False;Host=localhost;Port=5555"
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$outputFile = Join-Path $scriptDir "Test-K2Deploy-Win-Results.txt"

Start-Transcript -Path $outputFile -Force

Write-Host "============================================" -ForegroundColor White
Write-Host "  K2 WINNING Deploy Test" -ForegroundColor White
Write-Host "============================================`n" -ForegroundColor White

# Load ALL deployment assemblies
$loaded = @()
Get-ChildItem "$k2Bin\SourceCode.*.dll" | ForEach-Object {
    try { [System.Reflection.Assembly]::LoadFrom($_.FullName) | Out-Null; $loaded += $_.Name } catch {}
}
Write-Host "Loaded $($loaded.Count) assemblies" -ForegroundColor DarkGray

# ============================================================
# TEST 1: Deploy existing .kspx via PDM with correct option
# ============================================================
Write-Host "`n=== TEST 1: Deploy .kspx via session.Deploy() ===" -ForegroundColor Cyan

$pdm = New-Object SourceCode.Deployment.Management.PackageDeploymentManager
$conn = $pdm.CreateConnection()
$conn.Open($connStr)
Write-Host "PDM Connected!" -ForegroundColor Green

$kspxPath = "C:\Program Files\K2\Setup\App Framework Core.kspx"
$stream = [System.IO.File]::OpenRead($kspxPath)
$s1 = "Deploy1_$(Get-Date -Format 'yyyyMMddHHmmss')"
$session = $pdm.CreateSession($s1, $stream)
$stream.Close()
Write-Host "Session: $s1, Model=$($session.Model.Name), Members=$($session.Model.Members.Count)" -ForegroundColor Green

# Use SetOption instead of property
Write-Host "Setting NoAnalyze via SetOption..." -ForegroundColor Yellow
try { $session.SetOption("NoAnalyze", $true) } catch { Write-Host "  SetOption NoAnalyze: $($_.Exception.Message)" -ForegroundColor Red }
try { $session.SetOption("ExcludeAll", $false) } catch { Write-Host "  SetOption ExcludeAll: $($_.Exception.Message)" -ForegroundColor Red }

Write-Host "Calling Deploy()..." -ForegroundColor Yellow
try {
    $session.Deploy()
    Write-Host "DEPLOY() SUCCEEDED!" -ForegroundColor Green
    
    # Wait and check results
    Start-Sleep -Seconds 3
    $dr = $session.DeploymentResults
    Write-Host "DeploymentResults: $dr" -ForegroundColor DarkGray
    if ($dr) {
        $dr.GetType().GetProperties() | ForEach-Object {
            try { Write-Host "  $($_.Name) = $($_.GetValue($dr))" -ForegroundColor DarkYellow } catch {}
        }
    }
} catch {
    Write-Host "Deploy() failed: $($_.Exception.Message)" -ForegroundColor Red
    if ($_.Exception.InnerException) { Write-Host "  Inner: $($_.Exception.InnerException.Message)" -ForegroundColor DarkRed }
}
$pdm.CloseSession($s1)

# ============================================================
# TEST 2: Find Send's SyncState - search ALL loaded assemblies
# ============================================================
Write-Host "`n=== TEST 2: Find SyncState enum ===" -ForegroundColor Cyan
$allEnums = [System.AppDomain]::CurrentDomain.GetAssemblies() | ForEach-Object {
    try { $_.GetTypes() | Where-Object { $_.IsEnum -and $_.FullName -like "*Sync*" } } catch {}
}
Write-Host "SyncState-like enums:" -ForegroundColor Yellow
$allEnums | ForEach-Object { 
    Write-Host "  $($_.FullName) in $($_.Assembly.GetName().Name)" -ForegroundColor DarkGray
    [System.Enum]::GetNames($_) | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkCyan }
}

# Also check what Send() expects
$sendMethod = $session.GetType().GetMethods() | Where-Object { $_.Name -eq "Send" }
foreach ($sm in $sendMethod) {
    $ps = ($sm.GetParameters() | ForEach-Object { "$($_.ParameterType.FullName) $($_.Name)" }) -join ", "
    Write-Host "Send signature: $($sm.ReturnType.FullName) Send($ps)" -ForegroundColor Yellow
}

# ============================================================
# TEST 3: Load .kspx using CreateSession(name, stream), 
#  then modify model name and deploy as different package
# ============================================================
Write-Host "`n=== TEST 3: Clone .kspx, modify and deploy ===" -ForegroundColor Cyan

$stream2 = [System.IO.File]::OpenRead($kspxPath)
$s2 = "Clone_$(Get-Date -Format 'yyyyMMddHHmmss')"
$session2 = $pdm.CreateSession($s2, $stream2)
$stream2.Close()

$model = $session2.Model
Write-Host "Original model: $($model.Name)" -ForegroundColor DarkGray

# Change the name to simulate our migration package
$model.Name = "SPD_Migrated_Test_Package"
$model.Description = "Test migration from SharePoint Designer"
Write-Host "Modified model: $($model.Name)" -ForegroundColor Green

# Try to deploy the modified session
Write-Host "Deploying modified session..." -ForegroundColor Yellow
try {
    $session2.SetOption("NoAnalyze", $true)
    $session2.Deploy()
    Write-Host "CLONE DEPLOY SUCCEEDED!" -ForegroundColor Green
    Start-Sleep -Seconds 3
    $dr2 = $session2.DeploymentResults
    if ($dr2) {
        $dr2.GetType().GetProperties() | ForEach-Object {
            try { Write-Host "  $($_.Name) = $($_.GetValue($dr2))" -ForegroundColor DarkYellow } catch {}
        }
    }
} catch {
    Write-Host "Clone deploy failed: $($_.Exception.Message)" -ForegroundColor Red
}
$pdm.CloseSession($s2)

# ============================================================
# TEST 4: The REAL test - Load .kspx, then ALSO load our KPRX
#  workflow into it using session.Load() with a KSPX wrapper
# ============================================================
Write-Host "`n=== TEST 4: Build .kspx with our KPRX inside ===" -ForegroundColor Cyan

# Get real KPRX
$mgmt = New-Object SourceCode.Workflow.Management.WorkflowManagementServer
$mgmt.CreateConnection()
$mgmt.Connection.Open($connStr)
$kprxBytes = $mgmt.GetProcessKprx(13) # TestKprxWF
Write-Host "Got KPRX: $($kprxBytes.Length) bytes" -ForegroundColor Green
$mgmt.Connection.Close()

# Build a .kspx ZIP that wraps just this KPRX
# Use the EXACT format we found: workflow file starts with <?xml
Add-Type -AssemblyName System.IO.Compression

$kspxMemStream = New-Object System.IO.MemoryStream
$archive = New-Object System.IO.Compression.ZipArchive($kspxMemStream, [System.IO.Compression.ZipArchiveMode]::Create, $true)

# definition.model - use the ns pattern we found in real packages
$defXml = @"
<?xml version="1.0" encoding="utf-8"?>
<model id="1" name="SPD Migration" itemtype="2" apiver="9" ns="" excl="False" desc="SPD Migrated Workflows" solution="" nextid="100" minorApiVer="5">
  <set id="2" name="Members" itemtype="4" apiver="9" readonly="False" count="1" xmlns="urn:SourceCode/ComponentModel">
    <ct id="3" name="SPD_Migration_TestKprxWF" itemtype="16" apiver="9" ns="urn:SourceCode/Workflows" excl="False" displayname="SPD Migration\TestKprxWF.Workflow" scope="0" file="TestKprxWF_Workflow">
      <set id="4" name="Members" itemtype="4" apiver="9" readonly="False" count="0" />
    </ct>
  </set>
</model>
"@

$entry = $archive.CreateEntry("definition.model")
$es = $entry.Open()
$bytes = [System.Text.Encoding]::UTF8.GetBytes($defXml)
$es.Write($bytes, 0, $bytes.Length)
$es.Dispose()

# properties.model
$propsXml = @"
<?xml version="1.0" encoding="utf-8"?>
<modelproperties name="SPD Migration" desc="SPD Migrated Workflows" solution="" apiver="9" minorApiVer="4">
  <customproperties created="2026-05-24T02:17:00Z" modified="2026-05-24T02:17:00Z" PackageTool="1" PackagePlatform="2" DefaultPage="0" />
</modelproperties>
"@
$entry = $archive.CreateEntry("properties.model")
$es = $entry.Open()
$bytes = [System.Text.Encoding]::UTF8.GetBytes($propsXml)
$es.Write($bytes, 0, $bytes.Length)
$es.Dispose()

# validation.model (4 null bytes)
$entry = $archive.CreateEntry("validation.model")
$es = $entry.Open()
$es.Write([byte[]]@(0,0,0,0), 0, 4)
$es.Dispose()

# The KPRX workflow file
$entry = $archive.CreateEntry("TestKprxWF_Workflow")
$es = $entry.Open()
$es.Write($kprxBytes, 0, $kprxBytes.Length)
$es.Dispose()

$archive.Dispose()

# Now load this into a PDM session
$kspxMemStream.Position = 0
Write-Host "Built in-memory .kspx: $($kspxMemStream.Length) bytes" -ForegroundColor Green

$s3 = "Custom_$(Get-Date -Format 'yyyyMMddHHmmss')"
try {
    $session3 = $pdm.CreateSession($s3, $kspxMemStream)
    Write-Host "Session from custom .kspx: Model=$($session3.Model.Name), Members=$($session3.Model.Members.Count)" -ForegroundColor Green
    
    foreach ($member in $session3.Model.Members) {
        Write-Host "  Member: $($member.Name) Type=$($member.ItemType)" -ForegroundColor DarkYellow
    }

    # Deploy it
    Write-Host "Deploying custom .kspx via PDM..." -ForegroundColor Yellow
    $session3.SetOption("NoAnalyze", $true)
    $session3.Deploy()
    Write-Host "CUSTOM DEPLOY SUCCEEDED!" -ForegroundColor Green
    
    Start-Sleep -Seconds 3
    $dr3 = $session3.DeploymentResults
    if ($dr3) {
        $dr3.GetType().GetProperties() | ForEach-Object {
            try { Write-Host "  $($_.Name) = $($_.GetValue($dr3))" -ForegroundColor DarkYellow } catch {}
        }
    }
    
    $pdm.CloseSession($s3)
} catch {
    Write-Host "Custom .kspx failed: $($_.Exception.Message)" -ForegroundColor Red
    if ($_.Exception.InnerException) { Write-Host "  Inner: $($_.Exception.InnerException.Message)" -ForegroundColor DarkRed }
}

$kspxMemStream.Dispose()

# ============================================================
# VERIFY: Check K2 for any new processes
# ============================================================
Write-Host "`n=== VERIFICATION ===" -ForegroundColor Cyan
$mgmt2 = New-Object SourceCode.Workflow.Management.WorkflowManagementServer
$mgmt2.CreateConnection()
$mgmt2.Connection.Open($connStr)
$procSets = $mgmt2.GetProcSets()
Write-Host "Process sets type: $($procSets.GetType().FullName)" -ForegroundColor DarkGray

# Try iterating the ProcessSets object
try {
    foreach ($ps in $procSets) {
        Write-Host "ProcSet: $($ps.FullName) (ProcSetID=$($ps.ProcSetID))" -ForegroundColor DarkYellow
    }
} catch {
    # Try different approach
    try {
        $procSets.GetType().GetProperties() | ForEach-Object {
            Write-Host "  PROP: $($_.Name) = $(try{$_.GetValue($procSets)}catch{'ERR'})" -ForegroundColor DarkGray
        }
        $procSets.GetType().GetMethods() | Where-Object { $_.DeclaringType.FullName -like "SourceCode*" } | ForEach-Object {
            Write-Host "  METHOD: $($_.Name)" -ForegroundColor DarkGray
        }
    } catch {}
}

# Use GetProcSetsByPath to find our migrated workflow
try {
    $allProcXml = $mgmt2.GetProcSetsCompact($true)
    Write-Host "`nAll processes (compact):" -ForegroundColor Yellow
    Write-Host $allProcXml -ForegroundColor DarkGray
} catch {
    Write-Host "GetProcSetsCompact failed: $($_.Exception.Message)" -ForegroundColor Red
}

$mgmt2.Connection.Close()
$pdm.Dispose()

Write-Host "`n============================================" -ForegroundColor White
Write-Host "  WINNING Deploy Test Complete!" -ForegroundColor White  
Write-Host "============================================" -ForegroundColor White

Stop-Transcript
