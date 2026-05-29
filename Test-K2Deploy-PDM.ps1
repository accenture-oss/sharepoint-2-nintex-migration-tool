# ============================================================
#  Test-K2Deploy-PDM.ps1
#  Use PDM API: Load .kspx -> Deploy() 
#  Run in PowerShell ISE on K2 VM
# ============================================================

$ErrorActionPreference = "Continue"
$k2Bin = "C:\Program Files\K2\Bin"
$connStr = "Integrated=True;IsPrimaryLogin=True;Authenticate=True;EncryptedPassword=False;Host=localhost;Port=5555"
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$outputFile = Join-Path $scriptDir "Test-K2Deploy-PDM-Results.txt"
$exportDir = Join-Path $scriptDir "k2-export\_pdm"

if (-not (Test-Path $exportDir)) { New-Item -Path $exportDir -ItemType Directory -Force | Out-Null }

Start-Transcript -Path $outputFile -Force

Write-Host "============================================" -ForegroundColor White
Write-Host "  K2 PDM Deploy Test" -ForegroundColor White
Write-Host "============================================`n" -ForegroundColor White

# Load assemblies
foreach ($dll in @(
    "SourceCode.Framework.dll","SourceCode.HostClientAPI.dll",
    "SourceCode.Workflow.Management.dll","SourceCode.Deployment.Management.dll",
    "SourceCode.EnvironmentSettings.Client.dll","SourceCode.ComponentModel.dll"
)) {
    $p = Join-Path $k2Bin $dll; if (Test-Path $p) { [System.Reflection.Assembly]::LoadFrom($p) | Out-Null }
}
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

# ============================================================
# STEP 1: Build .kspx from real workflow KPRX  
# ============================================================
Write-Host "[1] Getting KPRX from TestKprxWF..." -ForegroundColor Yellow
$mgmt = New-Object SourceCode.Workflow.Management.WorkflowManagementServer
$mgmt.CreateConnection()
$mgmt.Connection.Open($connStr)
$kprxBytes = $mgmt.GetProcessKprx(13)
Write-Host "  KPRX: $($kprxBytes.Length) bytes" -ForegroundColor Green

# Also get the KPRX as XML text to check format
$kprxText = [System.Text.Encoding]::UTF8.GetString($kprxBytes)
$isXml = $kprxText.TrimStart([char]0xFEFF).StartsWith("<?xml") -or $kprxText.TrimStart([char]0xFEFF).StartsWith("<Process")
Write-Host "  KPRX is XML: $isXml" -ForegroundColor $(if($isXml){"Green"}else{"Red"})
if ($isXml) {
    Write-Host "  First 200 chars: $($kprxText.Substring(0, [Math]::Min(200, $kprxText.Length)))" -ForegroundColor DarkGray
}

# Get the FrameworkGeneric workflow KPRX too (it's the XML one inside .kspx)
Write-Host "`n[1b] Getting FrameworkGeneric KPRX (ProcID=14)..." -ForegroundColor Yellow
$kprxBytes2 = $mgmt.GetProcessKprx(14)
$kprxText2 = [System.Text.Encoding]::UTF8.GetString($kprxBytes2)
$isXml2 = $kprxText2.TrimStart([char]0xFEFF).StartsWith("<?xml") -or $kprxText2.TrimStart([char]0xFEFF).StartsWith("<Process")
Write-Host "  KPRX2: $($kprxBytes2.Length) bytes, isXML=$isXml2" -ForegroundColor $(if($isXml2){"Green"}else{"Red"})
if ($isXml2) {
    Write-Host "  First 300 chars: $($kprxText2.Substring(0, [Math]::Min(300, $kprxText2.Length)))" -ForegroundColor DarkGray
}
$mgmt.Connection.Close()

# ============================================================
# STEP 2: Connect PDM
# ============================================================
Write-Host "`n[2] Connecting PDM..." -ForegroundColor Yellow
$pdm = New-Object SourceCode.Deployment.Management.PackageDeploymentManager
$conn = $pdm.CreateConnection()
$conn.Open($connStr)
Write-Host "  Connected!" -ForegroundColor Green

# ============================================================
# STEP 3: Load the EXISTING App Framework Core.kspx and deploy
# This proves the full PDM pipeline works
# ============================================================
Write-Host "`n[3] Loading App Framework Core.kspx into PDM session..." -ForegroundColor Yellow
$kspxPath = "C:\Program Files\K2\Setup\App Framework Core.kspx"
$stream = [System.IO.File]::OpenRead($kspxPath)
$sessionName = "Test_Deploy_$(Get-Date -Format 'yyyyMMddHHmmss')"
$session = $pdm.CreateSession($sessionName, $stream)
$stream.Close()
Write-Host "  Session: $sessionName" -ForegroundColor Green
Write-Host "  Model: $($session.Model.Name)" -ForegroundColor Green
Write-Host "  Members: $($session.Model.Members.Count)" -ForegroundColor Green

# Try Deploy() directly (simpler than Send)
Write-Host "`n[3b] Deploying via session.Deploy()..." -ForegroundColor Yellow
try {
    $session.NoAnalyze = $true
    $session.Deploy()
    Write-Host "  Deploy() completed!" -ForegroundColor Green
    
    # Check results
    $results = $session.DeploymentResults
    if ($results) {
        Write-Host "  DeploymentResults type: $($results.GetType().FullName)" -ForegroundColor DarkGray
        $results.GetType().GetProperties() | ForEach-Object {
            $val = try { $_.GetValue($results) } catch { "ERR" }
            Write-Host "  RESULT: $($_.Name) = $val" -ForegroundColor DarkYellow
        }
    }
} catch {
    Write-Host "  Deploy() failed: $($_.Exception.Message)" -ForegroundColor Red
    
    # Try session.Send() with proper enum
    Write-Host "`n[3c] Trying session.Send() instead..." -ForegroundColor Yellow
    try {
        # Find SyncState enum
        $syncType = [SourceCode.Deployment.Management.PackageDeploymentManager].Assembly.GetTypes() | Where-Object { $_.Name -eq "SyncState" }
        if ($syncType) {
            Write-Host "  Found SyncState: $($syncType.FullName)" -ForegroundColor Green
            [System.Enum]::GetNames($syncType) | ForEach-Object { Write-Host "    Value: $_" -ForegroundColor DarkGray }
            $deployState = [System.Enum]::Parse($syncType, "Deploy")
            $result = $session.Send($deployState)
            Write-Host "  Send() result: $result" -ForegroundColor Green
        } else {
            Write-Host "  SyncState enum not found in assembly" -ForegroundColor Red
            # List all enums in the assembly
            [SourceCode.Deployment.Management.PackageDeploymentManager].Assembly.GetTypes() | Where-Object { $_.IsEnum } | ForEach-Object {
                Write-Host "  ENUM: $($_.FullName)" -ForegroundColor DarkGray
            }
        }
    } catch {
        Write-Host "  Send() also failed: $($_.Exception.Message)" -ForegroundColor Red
    }
}

$pdm.CloseSession($sessionName)

# ============================================================
# STEP 4: Try loading our CUSTOM .kspx
# Build it properly this time using the REAL workflow XML format  
# ============================================================
Write-Host "`n[4] Building proper .kspx from real KPRX..." -ForegroundColor Yellow

# Read the actual workflow file from extracted App Framework Core
$sourceKspx = "C:\Program Files\K2\Setup\App Framework Core.kspx"
$tempExtract = Join-Path $exportDir "temp_extract"
if (Test-Path $tempExtract) { Remove-Item $tempExtract -Recurse -Force }
[System.IO.Compression.ZipFile]::ExtractToDirectory($sourceKspx, $tempExtract)

# Get the real definition.model and extract JUST the workflow entry pattern
$realDefModel = Get-Content (Join-Path $tempExtract "definition.model") -Raw -Encoding UTF8
# Find the workflow (process) section
$wfPattern = [regex]::Match($realDefModel, 'ns="urn:SourceCode/Workflows"[^>]*file="[^"]*"')
Write-Host "  Real WF entry: $($wfPattern.Value)" -ForegroundColor DarkGray

# Get the real workflow file name+content
$realWfFile = Get-ChildItem $tempExtract -Filter "FrameworkGeneric*" | Select-Object -First 1
Write-Host "  Real WF file: $($realWfFile.Name) ($([math]::Round($realWfFile.Length/1KB))KB)" -ForegroundColor DarkGray

# Now build a proper .kspx using Model.Save()
Write-Host "`n[5] Using Model to build .kspx programmatically..." -ForegroundColor Yellow
try {
    $session2Name = "Build_Custom_$(Get-Date -Format 'yyyyMMddHHmmss')"
    $session2 = $pdm.CreateSession($session2Name)
    
    $model = $session2.Model
    $model.Name = "SPD_Migrated_Workflows"
    $model.Description = "Workflows migrated from SharePoint Designer"
    Write-Host "  Empty model created: $($model.Name)" -ForegroundColor Green

    # Try to load the KPRX into the model
    Write-Host "  Trying to load KPRX into model..." -ForegroundColor Yellow
    
    # Upload the KPRX bytes as a stream
    $kprxStream = New-Object System.IO.MemoryStream(,$kprxBytes2)
    try {
        $loadResult = $session2.Load($kprxStream, $null)
        Write-Host "  Load result: $loadResult" -ForegroundColor Green
        Write-Host "  Model members after load: $($model.Members.Count)" -ForegroundColor Green
        foreach ($member in $model.Members) {
            Write-Host "    Member: $($member.Name) Type=$($member.ItemType)" -ForegroundColor DarkYellow
        }
    } catch {
        Write-Host "  Load KPRX failed: $($_.Exception.Message)" -ForegroundColor Red
    }
    $kprxStream.Dispose()

    # Try loading a REAL .kspx into the session instead
    Write-Host "`n[5b] Loading real .kspx into empty session..." -ForegroundColor Yellow 
    $kspxStream2 = [System.IO.File]::OpenRead($kspxPath)
    try {
        $loadResult2 = $session2.Load($kspxStream2, $null)
        Write-Host "  Load .kspx result: $loadResult2" -ForegroundColor Green
        Write-Host "  Model members: $($model.Members.Count)" -ForegroundColor Green
    } catch {
        Write-Host "  Load .kspx failed: $($_.Exception.Message)" -ForegroundColor Red
    }
    $kspxStream2.Close()

    # Now try saving the model as a NEW .kspx
    Write-Host "`n[5c] Saving model as new .kspx..." -ForegroundColor Yellow
    $newKspx = Join-Path $exportDir "Model_Generated.kspx"
    $outStream = [System.IO.File]::Create($newKspx)
    try {
        $model.Save($outStream)
        $outStream.Close()
        Write-Host "  Saved: $newKspx ($([math]::Round((Get-Item $newKspx).Length/1KB))KB)" -ForegroundColor Green
    } catch {
        $outStream.Close()
        Write-Host "  Save failed: $($_.Exception.Message)" -ForegroundColor Red
    }

    # Deploy this saved .kspx
    if ((Test-Path $newKspx) -and (Get-Item $newKspx).Length -gt 0) {
        Write-Host "`n[5d] Deploying model-generated .kspx..." -ForegroundColor Yellow
        Add-PSSnapin SourceCode.Deployment.PowerShell -ErrorAction SilentlyContinue
        try {
            Deploy-Package -FileName $newKspx -K2Host localhost -Port 5555 -Integrated $true -IsPrimaryLogin $true -NoAnalyze
            Write-Host "  DEPLOY SUCCESS!" -ForegroundColor Green
        } catch {
            Write-Host "  Deploy failed: $($_.Exception.Message)" -ForegroundColor Red
        }
    }

    $pdm.CloseSession($session2Name)
} catch {
    Write-Host "  Model build failed: $($_.Exception.Message)" -ForegroundColor Red
    if ($_.Exception.InnerException) {
        Write-Host "  Inner: $($_.Exception.InnerException.Message)" -ForegroundColor DarkRed
    }
}

$pdm.Dispose()

Write-Host "`n============================================" -ForegroundColor White
Write-Host "  PDM Deploy Test Complete!" -ForegroundColor White
Write-Host "============================================" -ForegroundColor White

Stop-Transcript
