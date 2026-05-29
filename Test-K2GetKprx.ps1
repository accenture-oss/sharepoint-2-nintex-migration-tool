# ============================================================
#  Test-K2GetKprx.ps1
#  Extract KPRX from existing processes + build custom .kspx
#  Run in PowerShell ISE on K2 VM
# ============================================================

$ErrorActionPreference = "Continue"
$k2Bin = "C:\Program Files\K2\Bin"
$K2Server = "localhost"
$K2Port = 5555
$connStr = "Integrated=True;IsPrimaryLogin=True;Authenticate=True;EncryptedPassword=False;Host=$K2Server;Port=$K2Port"
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$outputFile = Join-Path $scriptDir "Test-K2GetKprx-Results.txt"
$exportDir = Join-Path $scriptDir "k2-export\_kprx_study"

if (-not (Test-Path $exportDir)) { New-Item -Path $exportDir -ItemType Directory -Force | Out-Null }

Start-Transcript -Path $outputFile -Force

Write-Host "============================================" -ForegroundColor White
Write-Host "  K2 KPRX Format Study + Deploy Test" -ForegroundColor White
Write-Host "============================================`n" -ForegroundColor White

# Load assemblies
foreach ($dll in @("SourceCode.Framework.dll","SourceCode.HostClientAPI.dll","SourceCode.Workflow.Management.dll")) {
    $p = Join-Path $k2Bin $dll
    if (Test-Path $p) { [System.Reflection.Assembly]::LoadFrom($p) | Out-Null }
}

# ============================================================
# STEP 1: Connect + get process list
# ============================================================
Write-Host "[STEP 1] Connecting to K2 Management Server..." -ForegroundColor Yellow
$mgmt = New-Object SourceCode.Workflow.Management.WorkflowManagementServer
$mgmt.CreateConnection()
$mgmt.Connection.Open($connStr)
Write-Host "  Connected!" -ForegroundColor Green

$procSets = $mgmt.GetProcSets()
Write-Host "  $($procSets.Count) processes:`n" -ForegroundColor Cyan
foreach ($ps in $procSets) {
    $versions = $mgmt.GetProcessVersions($ps.ProcSetID)
    foreach ($v in $versions) {
        Write-Host "  ProcSetID=$($ps.ProcSetID) ProcID=$($v.ProcID) V$($v.VersionNumber) [$($v.VersionStatus)] $($ps.FullName)" -ForegroundColor DarkGray
    }
}

# ============================================================
# STEP 2: Extract KPRX from simplest process (TestKprxWF or DocApproval)
# ============================================================
Write-Host "`n[STEP 2] Extracting KPRX from existing processes..." -ForegroundColor Yellow

# Try to get KPRX from each process
foreach ($ps in $procSets) {
    try {
        $versions = $mgmt.GetProcessVersions($ps.ProcSetID)
        foreach ($v in $versions) {
            $safeName = $ps.FullName -replace '[\\\/\:\*\?\"\<\>\|]', '_'
            
            # Get KPRX bytes
            try {
                $kprxBytes = $mgmt.GetProcessKprx($v.ProcID)
                if ($kprxBytes -and $kprxBytes.Length -gt 0) {
                    $kprxFile = Join-Path $exportDir "$safeName.kprx"
                    [System.IO.File]::WriteAllBytes($kprxFile, $kprxBytes)
                    Write-Host "  KPRX: $($ps.FullName) -> $($kprxBytes.Length) bytes" -ForegroundColor Green
                    
                    # Show first 500 chars of KPRX content (it's likely XML)
                    $kprxText = [System.Text.Encoding]::UTF8.GetString($kprxBytes, 0, [Math]::Min($kprxBytes.Length, 2000))
                    Write-Host "  --- KPRX START (first 2000 chars) ---" -ForegroundColor DarkCyan
                    Write-Host $kprxText -ForegroundColor DarkGray
                    Write-Host "  --- KPRX END ---`n" -ForegroundColor DarkCyan
                }
            } catch {
                Write-Host "  KPRX failed for $($ps.FullName): $($_.Exception.Message)" -ForegroundColor DarkYellow
            }

            # Also get Source bytes
            try {
                $srcBytes = $mgmt.GetProcessSource($v.ProcID)
                if ($srcBytes -and $srcBytes.Length -gt 0) {
                    $srcFile = Join-Path $exportDir "$safeName.source.xml"
                    [System.IO.File]::WriteAllBytes($srcFile, $srcBytes)
                    Write-Host "  SOURCE: $($ps.FullName) -> $($srcBytes.Length) bytes" -ForegroundColor Green
                }
            } catch {
                Write-Host "  Source failed: $($_.Exception.Message)" -ForegroundColor DarkYellow
            }

            # Get process details
            try {
                $proc = $mgmt.GetProcess($v.ProcID)
                $activities = $mgmt.GetProcActivities($v.ProcID)
                $dataFields = $mgmt.GetProcessDataFields($v.ProcID)
                Write-Host "  DETAILS: Activities=$($activities.Count), DataFields=$($dataFields.Count)" -ForegroundColor Cyan
                foreach ($act in $activities) {
                    Write-Host "    Activity: $($act.Name) [ID=$($act.ID)]" -ForegroundColor DarkGray
                }
                foreach ($df in $dataFields) {
                    Write-Host "    DataField: $($df.Name) = $($df.Value) [$($df.Type)]" -ForegroundColor DarkGray
                }
            } catch {
                Write-Host "  Details failed: $($_.Exception.Message)" -ForegroundColor DarkYellow
            }

            break  # only first version
        }
    } catch {}
}

# ============================================================
# STEP 3: Try to deploy using Deploy-Package cmdlet with existing .kspx
# ============================================================
Write-Host "`n[STEP 3] Verifying Deploy-Package cmdlet..." -ForegroundColor Yellow
try {
    Add-PSSnapin SourceCode.Deployment.PowerShell -ErrorAction Stop
    $dpCmd = Get-Command "Deploy-Package" -ErrorAction Stop
    Write-Host "  Deploy-Package cmdlet found!" -ForegroundColor Green

    # Also check if there's a way to deploy a .kprx directly (not .kspx)
    $helpText = Get-Help Deploy-Package -Full 2>&1
    Write-Host "  Deploy-Package synopsis: $($helpText.synopsis)" -ForegroundColor DarkGray
    if ($helpText.description) {
        Write-Host "  Description: $($helpText.description.text)" -ForegroundColor DarkGray
    }
} catch {
    Write-Host "  Deploy-Package: $($_.Exception.Message)" -ForegroundColor Red
}

# ============================================================
# STEP 4: Try New-Package to create .kspx from config
# ============================================================
Write-Host "`n[STEP 4] Testing New-Package with Write-PackageConfig output..." -ForegroundColor Yellow

# First, create a minimal package config XML for a simple workflow
$testConfigXml = @"
<?xml version="1.0" encoding="utf-8"?>
<c xmlns="http://schemas.k2.com/Package">
  <p validate="true">
    <exs />
    <incs>
      <i n="TestKprxWF" ns="urn:SourceCode/Workflow" includeDependencies="false" />
    </incs>
    <rem />
    <vars />
  </p>
</c>
"@

$testConfigFile = Join-Path $exportDir "test_package_config.xml"
$testConfigXml | Out-File $testConfigFile -Encoding UTF8
Write-Host "  Config file: $testConfigFile" -ForegroundColor DarkGray

$testKspxFile = Join-Path $exportDir "test_package.kspx"
try {
    New-Package -FileName $testKspxFile -InputFileName $testConfigFile -Description "Test package for SPD migration" -ConnectionString $connStr
    Write-Host "  New-Package SUCCESS! File: $testKspxFile ($([math]::Round((Get-Item $testKspxFile).Length/1KB))KB)" -ForegroundColor Green

    # Now try to deploy this generated package
    Write-Host "  Deploying generated package..." -ForegroundColor Cyan
    Deploy-Package -FileName $testKspxFile -K2Host $K2Server -Port $K2Port -Integrated $true -IsPrimaryLogin $true -NoAnalyze
    Write-Host "  DEPLOY SUCCESS!" -ForegroundColor Green
} catch {
    Write-Host "  New-Package/Deploy failed: $($_.Exception.Message)" -ForegroundColor Red
    if ($_.Exception.InnerException) {
        Write-Host "  Inner: $($_.Exception.InnerException.Message)" -ForegroundColor DarkRed
    }
}

$mgmt.Connection.Close()

Write-Host "`n============================================" -ForegroundColor White
Write-Host "  KPRX Study Complete!" -ForegroundColor White
Write-Host "============================================" -ForegroundColor White

Stop-Transcript
