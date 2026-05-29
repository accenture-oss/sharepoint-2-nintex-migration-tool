# ============================================================
#  Test-K2SourceFormat.ps1
#  Extract full Source XML from TestKprxWF + analyze structure
#  Run in PowerShell ISE on K2 VM
# ============================================================

$ErrorActionPreference = "Continue"
$k2Bin = "C:\Program Files\K2\Bin"
$K2Server = "localhost"
$K2Port = 5555
$connStr = "Integrated=True;IsPrimaryLogin=True;Authenticate=True;EncryptedPassword=False;Host=$K2Server;Port=$K2Port"
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$outputFile = Join-Path $scriptDir "Test-K2SourceFormat-Results.txt"
$exportDir = Join-Path $scriptDir "k2-export\_source_study"

if (-not (Test-Path $exportDir)) { New-Item -Path $exportDir -ItemType Directory -Force | Out-Null }

Start-Transcript -Path $outputFile -Force

Write-Host "============================================" -ForegroundColor White
Write-Host "  K2 Source XML Study" -ForegroundColor White
Write-Host "============================================`n" -ForegroundColor White

# Load assemblies
foreach ($dll in @("SourceCode.Framework.dll","SourceCode.HostClientAPI.dll","SourceCode.Workflow.Management.dll")) {
    $p = Join-Path $k2Bin $dll
    if (Test-Path $p) { [System.Reflection.Assembly]::LoadFrom($p) | Out-Null }
}

# Connect
$mgmt = New-Object SourceCode.Workflow.Management.WorkflowManagementServer
$mgmt.CreateConnection()
$mgmt.Connection.Open($connStr)
Write-Host "Connected to K2 Management Server" -ForegroundColor Green

# ============================================================
# Get FULL Source XML from TestKprxWF (simplest workflow: 3 activities, 0 data fields)
# ProcID=13 (Version 2)
# ============================================================
Write-Host "`n[1] Extracting TestKprxWF Source XML (ProcID=13)..." -ForegroundColor Yellow

$srcBytes = $mgmt.GetProcessSource(13)
$srcXml = [System.Text.Encoding]::UTF8.GetString($srcBytes)
$srcFile = Join-Path $exportDir "TestKprxWF_v2.source.xml"
[System.IO.File]::WriteAllText($srcFile, $srcXml, [System.Text.Encoding]::UTF8)
Write-Host "  Source XML: $($srcXml.Length) chars" -ForegroundColor Green
Write-Host "  Saved to: $srcFile" -ForegroundColor DarkGray

# Print the FULL source XML
Write-Host "`n=== TestKprxWF Source XML (FULL) ===" -ForegroundColor Cyan
Write-Host $srcXml
Write-Host "=== END ===" -ForegroundColor Cyan

# ============================================================
# Also get Source XML from Framework Core Reference (simple: 4 activities)
# ProcID=14 (Version 2)
# ============================================================
Write-Host "`n[2] Extracting FrameworkGeneric.Workflow.Reference Source (ProcID=14)..." -ForegroundColor Yellow

$srcBytes2 = $mgmt.GetProcessSource(14)
$srcXml2 = [System.Text.Encoding]::UTF8.GetString($srcBytes2)
$srcFile2 = Join-Path $exportDir "FrameworkGeneric_v2.source.xml"
[System.IO.File]::WriteAllText($srcFile2, $srcXml2, [System.Text.Encoding]::UTF8)
Write-Host "  Source XML: $($srcXml2.Length) chars" -ForegroundColor Green

# Print first 5000 chars for comparison
Write-Host "`n=== FrameworkGeneric Source XML (first 5000 chars) ===" -ForegroundColor Cyan
Write-Host ($srcXml2.Substring(0, [Math]::Min(5000, $srcXml2.Length)))
Write-Host "=== END ===" -ForegroundColor Cyan

# ============================================================
# Also get KPRX from TestKprxWF and save as file for analysis
# ============================================================
Write-Host "`n[3] Saving TestKprxWF KPRX bytes..." -ForegroundColor Yellow
$kprxBytes = $mgmt.GetProcessKprx(13)
$kprxFile = Join-Path $exportDir "TestKprxWF_v2.kprx"
[System.IO.File]::WriteAllBytes($kprxFile, $kprxBytes)
Write-Host "  KPRX: $($kprxBytes.Length) bytes -> $kprxFile" -ForegroundColor Green

# ============================================================
# Check what New-Package generates when packaging the existing TestKprxWF
# ============================================================
Write-Host "`n[4] Using New-Package to package TestKprxWF from server..." -ForegroundColor Yellow
Add-PSSnapin SourceCode.Deployment.PowerShell -ErrorAction SilentlyContinue

# Try using InputFileName with a KPRX file
$testKspxFromKprx = Join-Path $exportDir "TestKprxWF_from_kprx.kspx"
try {
    New-Package -FileName $testKspxFromKprx -InputFileName $kprxFile -Description "Test from KPRX" -ConnectionString $connStr
    Write-Host "  New-Package from KPRX: $([math]::Round((Get-Item $testKspxFromKprx).Length/1KB))KB" -ForegroundColor Green
} catch {
    Write-Host "  New-Package from KPRX failed: $($_.Exception.Message)" -ForegroundColor Red
}

# Try using Write-PackageConfig first
Write-Host "`n[5] Generating package config for TestKprxWF..." -ForegroundColor Yellow
$configFile = Join-Path $exportDir "TestKprxWF_package.config"
$kspxFromConfig = Join-Path $exportDir "TestKprxWF_from_config.kspx"
try {
    Write-PackageConfig -InputFile $kprxFile -OutputFile $configFile -ConnectionString $connStr
    Write-Host "  Package config generated: $configFile" -ForegroundColor Green
    Write-Host "  Config content:" -ForegroundColor DarkCyan
    Get-Content $configFile | Write-Host
} catch {
    Write-Host "  Write-PackageConfig failed: $($_.Exception.Message)" -ForegroundColor Red
}

# ============================================================
# Try deploying the KPRX directly with Deploy-Package
# ============================================================
Write-Host "`n[6] Deploying KPRX directly with Deploy-Package..." -ForegroundColor Yellow
try {
    Deploy-Package -FileName $kprxFile -K2Host $K2Server -Port $K2Port -Integrated $true -IsPrimaryLogin $true -NoAnalyze
    Write-Host "  DEPLOY KPRX SUCCESS!" -ForegroundColor Green
} catch {
    Write-Host "  Deploy KPRX failed: $($_.Exception.Message)" -ForegroundColor Red
}

# ============================================================
# Try deploying the Source XML with Deploy-Package
# ============================================================
Write-Host "`n[7] Deploying Source XML directly with Deploy-Package..." -ForegroundColor Yellow
try {
    Deploy-Package -FileName $srcFile -K2Host $K2Server -Port $K2Port -Integrated $true -IsPrimaryLogin $true -NoAnalyze
    Write-Host "  DEPLOY SOURCE SUCCESS!" -ForegroundColor Green
} catch {
    Write-Host "  Deploy Source failed: $($_.Exception.Message)" -ForegroundColor Red
}

$mgmt.Connection.Close()

Write-Host "`n============================================" -ForegroundColor White
Write-Host "  Source Format Study Complete!" -ForegroundColor White
Write-Host "============================================" -ForegroundColor White

Stop-Transcript
