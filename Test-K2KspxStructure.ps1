# ============================================================
#  Test-K2KspxStructure.ps1
#  Extract and study the internal structure of a working .kspx
#  Then clone it with modified KPRX to create new workflows
#  Run in PowerShell ISE on K2 VM
# ============================================================

$ErrorActionPreference = "Continue"
$k2Bin = "C:\Program Files\K2\Bin"
$K2Server = "localhost"
$K2Port = 5555
$connStr = "Integrated=True;IsPrimaryLogin=True;Authenticate=True;EncryptedPassword=False;Host=$K2Server;Port=$K2Port"
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$outputFile = Join-Path $scriptDir "Test-K2KspxStructure-Results.txt"
$exportDir = Join-Path $scriptDir "k2-export\_kspx_study"

if (-not (Test-Path $exportDir)) { New-Item -Path $exportDir -ItemType Directory -Force | Out-Null }

Start-Transcript -Path $outputFile -Force

Write-Host "============================================" -ForegroundColor White
Write-Host "  K2 .kspx Internal Structure Study" -ForegroundColor White
Write-Host "============================================`n" -ForegroundColor White

Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

# ============================================================
# STEP 1: Find all .kspx files available
# ============================================================
Write-Host "[STEP 1] Finding .kspx files..." -ForegroundColor Yellow
$setupDir = "C:\Program Files\K2\Setup"
$kspxFiles = Get-ChildItem $setupDir -Filter "*.kspx" -Recurse -ErrorAction SilentlyContinue
foreach ($f in $kspxFiles) {
    Write-Host "  $($f.Name) ($([math]::Round($f.Length/1KB))KB) -> $($f.FullName)" -ForegroundColor DarkGray
}

# ============================================================
# STEP 2: Extract smallest .kspx and show its internal structure
# ============================================================
Write-Host "`n[STEP 2] Extracting .kspx internal structure..." -ForegroundColor Yellow

# Use the first .kspx found
$kspxFile = $kspxFiles | Sort-Object Length | Select-Object -First 1
if (-not $kspxFile) {
    Write-Host "  No .kspx files found!" -ForegroundColor Red
    Stop-Transcript
    return
}
Write-Host "  Using: $($kspxFile.Name) ($([math]::Round($kspxFile.Length/1KB))KB)" -ForegroundColor Cyan

$extractDir = Join-Path $exportDir "extracted_$($kspxFile.BaseName)"
if (Test-Path $extractDir) { Remove-Item $extractDir -Recurse -Force }

try {
    [System.IO.Compression.ZipFile]::ExtractToDirectory($kspxFile.FullName, $extractDir)
    Write-Host "  Extracted to: $extractDir" -ForegroundColor Green

    # List all files in the extracted .kspx
    Write-Host "`n  === .kspx Internal Files ===" -ForegroundColor Cyan
    Get-ChildItem $extractDir -Recurse | ForEach-Object {
        $relPath = $_.FullName.Replace($extractDir, "")
        if ($_.PSIsContainer) {
            Write-Host "  DIR:  $relPath" -ForegroundColor DarkCyan
        } else {
            Write-Host "  FILE: $relPath ($([math]::Round($_.Length/1KB))KB)" -ForegroundColor DarkGray

            # Show first 500 chars of each file
            try {
                $content = Get-Content $_.FullName -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
                if ($content) {
                    $preview = $content.Substring(0, [Math]::Min(500, $content.Length))
                    Write-Host "        PREVIEW: $preview" -ForegroundColor DarkYellow
                }
            } catch {
                # Binary file
                $bytes = [System.IO.File]::ReadAllBytes($_.FullName)
                $hexPreview = ($bytes[0..([Math]::Min(50, $bytes.Length-1))] | ForEach-Object { $_.ToString("X2") }) -join " "
                Write-Host "        BINARY: $hexPreview" -ForegroundColor DarkYellow
            }
        }
    }
} catch {
    Write-Host "  Extract failed: $($_.Exception.Message)" -ForegroundColor Red
}

# ============================================================
# STEP 3: Also extract ALL .kspx files for comparison
# ============================================================
Write-Host "`n[STEP 3] Extracting all .kspx files for comparison..." -ForegroundColor Yellow
foreach ($f in $kspxFiles) {
    $dir = Join-Path $exportDir "extracted_$($f.BaseName)"
    if (Test-Path $dir) { continue }
    try {
        [System.IO.Compression.ZipFile]::ExtractToDirectory($f.FullName, $dir)
        $files = Get-ChildItem $dir -Recurse -File
        Write-Host "  $($f.Name): $($files.Count) files" -ForegroundColor DarkGray
        foreach ($file in $files) {
            Write-Host "    $($file.Name) ($([math]::Round($file.Length/1KB))KB)" -ForegroundColor DarkGray
        }
    } catch {
        Write-Host "  $($f.Name) extract failed: $($_.Exception.Message)" -ForegroundColor Red
    }
}

# ============================================================
# STEP 4: Create a MINIMAL .kspx by packaging just a simple KPRX
#  using the PackageDeploymentManager API
# ============================================================
Write-Host "`n[STEP 4] Testing PackageDeploymentManager to create .kspx..." -ForegroundColor Yellow

foreach ($dll in @(
    "SourceCode.Framework.dll",
    "SourceCode.HostClientAPI.dll",
    "SourceCode.Workflow.Management.dll",
    "SourceCode.Deployment.Management.dll",
    "SourceCode.EnvironmentSettings.Client.dll"
)) {
    $p = Join-Path $k2Bin $dll
    if (Test-Path $p) { [System.Reflection.Assembly]::LoadFrom($p) | Out-Null }
}

try {
    $pdm = New-Object SourceCode.Deployment.Management.PackageDeploymentManager
    Write-Host "  PackageDeploymentManager created!" -ForegroundColor Green

    # List all methods
    $pdm.GetType().GetMethods() | Where-Object { $_.DeclaringType.FullName -like "SourceCode.*" } | Sort-Object Name | ForEach-Object {
        $ps = ($_.GetParameters() | ForEach-Object { "$($_.ParameterType.Name) $($_.Name)" }) -join ", "
        Write-Host "  $($_.ReturnType.Name) $($_.Name)($ps)" -ForegroundColor DarkGray
    }

    # Try CreateSession
    Write-Host "`n  Creating session..." -ForegroundColor Cyan
    $session = $pdm.CreateSession("test_migration_$(Get-Date -Format 'yyyyMMddHHmmss')")
    Write-Host "  Session: $($session.GetType().Name)" -ForegroundColor Green

    # List session methods
    $session.GetType().GetMethods() | Where-Object { $_.DeclaringType.FullName -like "SourceCode.*" } | Sort-Object Name | ForEach-Object {
        $ps = ($_.GetParameters() | ForEach-Object { "$($_.ParameterType.Name) $($_.Name)" }) -join ", "
        Write-Host "  SESSION: $($_.ReturnType.Name) $($_.Name)($ps)" -ForegroundColor DarkCyan
    }

    # List session properties
    $session.GetType().GetProperties() | ForEach-Object {
        $val = try { $_.GetValue($session) } catch { "N/A" }
        Write-Host "  SESSION PROP: $($_.PropertyType.Name) $($_.Name) = $val" -ForegroundColor DarkCyan
    }

    $pdm.CloseSession($session.Name)
    $pdm.Dispose()
} catch {
    Write-Host "  PDM failed: $($_.Exception.Message)" -ForegroundColor Red
    if ($_.Exception.InnerException) {
        Write-Host "  Inner: $($_.Exception.InnerException.Message)" -ForegroundColor DarkRed
    }
}

Write-Host "`n============================================" -ForegroundColor White
Write-Host "  KSPX Structure Study Complete!" -ForegroundColor White
Write-Host "============================================" -ForegroundColor White

Stop-Transcript
