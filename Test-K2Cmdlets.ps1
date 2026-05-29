##############################################################
# K2 Deployment - Cmdlet Discovery
# Get the exact parameters for Send-Deploy-Package
##############################################################

$outFile = Join-Path (Get-Location) "Test-K2Cmdlets-Results.txt"
Start-Transcript -Path $outFile -Force | Out-Null

$k2Bin = "C:\Program Files\K2\Bin"

Write-Host "============================================"
Write-Host "  K2 Cmdlet Parameter Discovery"
Write-Host "============================================"

# Load the snap-in
Write-Host "[1] Loading K2 Deployment Snap-in..."
try {
    Add-PSSnapin SourceCode.Deployment.PowerShell -ErrorAction Stop
    Write-Host "  Snap-in loaded!" -ForegroundColor Green
} catch {
    Write-Host "  Snap-in failed, trying module import..."
    Import-Module (Join-Path $k2Bin "SourceCode.Deployment.PowerShell.dll") -ErrorAction Stop
    Write-Host "  Module loaded!" -ForegroundColor Green
}

# Get detailed help for each cmdlet
foreach ($cmdlet in @("New-Package", "Send-Deploy-Package", "Send-Refresh-Package", "Write-DeploymentConfig", "Write-PackageConfig")) {
    Write-Host ""
    Write-Host "============================================"
    Write-Host "  CMDLET: $cmdlet"
    Write-Host "============================================"
    
    # Get command info
    $cmd = Get-Command $cmdlet -ErrorAction SilentlyContinue
    if ($cmd) {
        Write-Host "  Type: $($cmd.CommandType)"
        Write-Host "  Module: $($cmd.ModuleName)"
        
        # Parameters
        Write-Host "  Parameters:"
        foreach ($param in $cmd.Parameters.GetEnumerator()) {
            $p = $param.Value
            if ($p.Name -notmatch "^(Verbose|Debug|ErrorAction|ErrorVariable|WarningAction|WarningVariable|OutBuffer|OutVariable|InformationAction|InformationVariable|PipelineVariable)$") {
                $mandatory = if ($p.Attributes | Where-Object { $_.Mandatory }) { "[REQUIRED]" } else { "[optional]" }
                $type = $p.ParameterType.Name
                Write-Host "    $mandatory $type $($p.Name)"
                # Aliases
                if ($p.Aliases.Count -gt 0) {
                    Write-Host "      Aliases: $($p.Aliases -join ', ')"
                }
            }
        }
        
        # Get help
        Write-Host ""
        Write-Host "  Help:"
        try {
            $help = Get-Help $cmdlet -Full -ErrorAction SilentlyContinue
            if ($help.Synopsis) { Write-Host "    Synopsis: $($help.Synopsis)" }
            if ($help.Description) { 
                foreach ($d in $help.Description) {
                    Write-Host "    Description: $($d.Text)"
                }
            }
            if ($help.examples) {
                Write-Host "    Examples:"
                foreach ($ex in $help.examples.example) {
                    Write-Host "      $($ex.title)"
                    Write-Host "      $($ex.code)"
                }
            }
        } catch {
            Write-Host "    (no help available)"
        }
    } else {
        Write-Host "  NOT FOUND"
    }
}

# Also try to examine a .kspx file structure
Write-Host ""
Write-Host "============================================"
Write-Host "  .kspx File Structure Analysis"
Write-Host "============================================"
$kspx = "C:\Program Files\K2\Setup\K2 Basic Task Form.kspx"
if (Test-Path $kspx) {
    Write-Host "  Analyzing: $kspx"
    Write-Host "  Size: $([math]::Round((Get-Item $kspx).Length/1KB))KB"
    
    # kspx is a ZIP file - extract and list contents
    try {
        $tempDir = Join-Path $env:TEMP "kspx_inspect"
        if (Test-Path $tempDir) { Remove-Item $tempDir -Recurse -Force }
        
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        [System.IO.Compression.ZipFile]::ExtractToDirectory($kspx, $tempDir)
        
        Write-Host "  Contents:"
        Get-ChildItem $tempDir -Recurse | ForEach-Object {
            $rel = $_.FullName.Replace($tempDir, "").TrimStart("\")
            if ($_.PSIsContainer) {
                Write-Host "    DIR:  $rel"
            } else {
                Write-Host "    FILE: $rel ($([math]::Round($_.Length/1KB))KB)"
            }
        }
        
        # Show XML manifest files
        $xmlFiles = Get-ChildItem $tempDir -Filter "*.xml" -Recurse
        foreach ($xf in $xmlFiles) {
            Write-Host ""
            Write-Host "  --- $($xf.Name) (first 30 lines) ---"
            Get-Content $xf.FullName -First 30 | ForEach-Object { Write-Host "    $_" }
        }
        
        # Cleanup
        Remove-Item $tempDir -Recurse -Force
    } catch {
        Write-Host "  Error extracting: $($_.Exception.Message)"
    }
}

Write-Host ""
Write-Host "============================================"
Write-Host "  Discovery Complete!"
Write-Host "============================================"

Stop-Transcript | Out-Null
Write-Host "Output saved to: $outFile" -ForegroundColor Green
Write-Host "Please commit: git add Test-K2Cmdlets-Results.txt && git commit -m 'K2 cmdlet discovery' && git push" -ForegroundColor Yellow
