##############################################################
# K2 Package Format Discovery
# Understand what New-Package and Send-Deploy-Package expect
##############################################################

$outFile = Join-Path (Get-Location) "Test-K2Package-Results.txt"
Start-Transcript -Path $outFile -Force | Out-Null

$k2Bin = "C:\Program Files\K2\Bin"

Write-Host "============================================"
Write-Host "  K2 Package Format Discovery"
Write-Host "============================================"

# Load snap-in
Add-PSSnapin SourceCode.Deployment.PowerShell -ErrorAction SilentlyContinue

# 1. Extract and study a real .kspx package
Write-Host "`n[1] Analyzing smallest .kspx: CustomStep.kspx"
$kspxFile = "C:\Program Files\K2\Setup\CustomStep.kspx"
if (-not (Test-Path $kspxFile)) {
    $kspxFile = "C:\Program Files\K2\Setup\K2 Basic Task Form.kspx"
}

$tempDir = Join-Path $env:TEMP "kspx_study_$(Get-Date -Format 'HHmmss')"
if (Test-Path $tempDir) { Remove-Item $tempDir -Recurse -Force }

Add-Type -AssemblyName System.IO.Compression.FileSystem
[System.IO.Compression.ZipFile]::ExtractToDirectory($kspxFile, $tempDir)

Write-Host "  Extracted to: $tempDir"
Get-ChildItem $tempDir -Recurse | ForEach-Object {
    $rel = $_.FullName.Replace($tempDir, "").TrimStart("\")
    if (-not $_.PSIsContainer) {
        Write-Host "  $rel ($([math]::Round($_.Length/1KB))KB)"
    }
}

# Show definition.model (first 100 lines - this is the key file)
$defModel = Join-Path $tempDir "definition.model"
if (Test-Path $defModel) {
    Write-Host "`n[2] definition.model (first 100 lines):"
    Get-Content $defModel -First 100 | ForEach-Object { Write-Host "  $_" }
} else {
    Write-Host "`n[2] No definition.model found"
    # List all files and show whatever model file exists
    Get-ChildItem $tempDir -Filter "*.model" | ForEach-Object {
        Write-Host "  Model file: $($_.Name) ($([math]::Round($_.Length/1KB))KB)"
        Write-Host "  First 50 lines:"
        Get-Content $_.FullName -First 50 | ForEach-Object { Write-Host "    $_" }
    }
}

# Show changesets.model
$csModel = Join-Path $tempDir "changesets.model"
if (Test-Path $csModel) {
    Write-Host "`n[3] changesets.model (first 50 lines):"
    Get-Content $csModel -First 50 | ForEach-Object { Write-Host "  $_" }
}

# Show properties.model
$propModel = Join-Path $tempDir "properties.model"
if (Test-Path $propModel) {
    Write-Host "`n[4] properties.model:"
    Get-Content $propModel | ForEach-Object { Write-Host "  $_" }
}

# 2. Try Write-PackageConfig to see what format it produces
Write-Host "`n[5] Testing Write-PackageConfig..."
$outConfig = Join-Path $env:TEMP "test-pkg-config.xml"
try {
    Write-PackageConfig -InputFile $kspxFile -OutputFile $outConfig
    Write-Host "  Write-PackageConfig output:"
    Get-Content $outConfig | ForEach-Object { Write-Host "    $_" }
} catch {
    Write-Host "  Write-PackageConfig failed: $($_.Exception.Message)"
}

# 3. Try Write-DeploymentConfig
Write-Host "`n[6] Testing Write-DeploymentConfig..."
$outDeploy = Join-Path $env:TEMP "test-deploy-config.xml"
try {
    Write-DeploymentConfig -InputFile $kspxFile -OutputFile $outDeploy
    Write-Host "  Write-DeploymentConfig output:"
    Get-Content $outDeploy | ForEach-Object { Write-Host "    $_" }
} catch {
    Write-Host "  Write-DeploymentConfig failed: $($_.Exception.Message)"
}

# 4. Try Send-Deploy-Package with an existing K2 .kspx to verify it works at all
Write-Host "`n[7] Testing Send-Deploy-Package with existing K2 package (WhatIf)..."
try {
    Send-Deploy-Package -FileName $kspxFile -K2Host "localhost" -Port 5555 -Integrated $true -IsPrimaryLogin $true -WhatIf
    Write-Host "  WhatIf passed!"
} catch {
    Write-Host "  Send-Deploy-Package WhatIf failed: $($_.Exception.Message)"
}

# 5. Try to understand New-Package InputFileName format
Write-Host "`n[8] New-Package InputFileName format probe..."
# Create a minimal test input
$minimalInput = @"
<?xml version="1.0" encoding="utf-8"?>
<Package>
  <Items>
    <Item Type="Process" Name="TestProcess" />
  </Items>
</Package>
"@
$testInput = Join-Path $env:TEMP "test-input.xml"
$minimalInput | Out-File $testInput -Encoding UTF8
$testKspx = Join-Path $env:TEMP "test-output.kspx"

try {
    $connStr = "Integrated=True;IsPrimaryLogin=True;Authenticate=True;EncryptedPassword=False;Host=localhost;Port=5555"
    New-Package -FileName $testKspx -InputFileName $testInput -Description "Test" -ConnectionString $connStr
    Write-Host "  New-Package succeeded!"
} catch {
    Write-Host "  New-Package error: $($_.Exception.Message)"
    Write-Host "  Inner: $($_.Exception.InnerException.Message)"
}

# 6. Try New-Package WITHOUT InputFileName (maybe it connects to server and lets you select)
Write-Host "`n[9] New-Package without InputFileName..."
try {
    $connStr2 = "Integrated=True;IsPrimaryLogin=True;Authenticate=True;EncryptedPassword=False;Host=localhost;Port=5555"
    New-Package -FileName (Join-Path $env:TEMP "test2.kspx") -ConnectionString $connStr2
    Write-Host "  New-Package (no input) succeeded!"
} catch {
    Write-Host "  Error: $($_.Exception.Message)"
}

# Cleanup
Remove-Item $tempDir -Recurse -Force -ErrorAction SilentlyContinue

Write-Host "`n============================================"
Write-Host "  Discovery Complete!"
Write-Host "============================================"

Stop-Transcript | Out-Null
Write-Host "Output saved to: $outFile" -ForegroundColor Green
