# ============================================================
#  Test-K2DeployE2E.ps1
#  End-to-end unit test for K2 workflow deployment
#  Run directly in PowerShell ISE on the K2 VM
# ============================================================

$ErrorActionPreference = "Continue"
$k2Bin = "C:\Program Files\K2\Bin"
$K2Server = "localhost"
$K2Port = 5555
$connStr = "Integrated=True;IsPrimaryLogin=True;Authenticate=True;EncryptedPassword=False;Host=$K2Server;Port=$K2Port"
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$outputFile = Join-Path $scriptDir "Test-K2DeployE2E-Results.txt"

Start-Transcript -Path $outputFile -Force

Write-Host "============================================" -ForegroundColor White
Write-Host "  K2 Workflow Deploy - End-to-End Test" -ForegroundColor White
Write-Host "  $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -ForegroundColor White
Write-Host "============================================`n" -ForegroundColor White

# ============================================================
# TEST 1: Load ALL K2 assemblies
# ============================================================
Write-Host "[TEST 1] Loading K2 assemblies..." -ForegroundColor Yellow
$loadedAssemblies = @()
$dllList = @(
    "SourceCode.Framework.dll",
    "SourceCode.HostClientAPI.dll",
    "SourceCode.Workflow.Authoring.dll",
    "SourceCode.Workflow.Design.dll",
    "SourceCode.Workflow.Management.dll",
    "SourceCode.Workflow.Client.dll",
    "SourceCode.Deployment.Management.dll",
    "SourceCode.EnvironmentSettings.Client.dll"
)
foreach ($dll in $dllList) {
    $p = Join-Path $k2Bin $dll
    if (Test-Path $p) {
        try {
            $asm = [System.Reflection.Assembly]::LoadFrom($p)
            $loadedAssemblies += $asm
            Write-Host "  OK: $dll ($($asm.GetExportedTypes().Count) types)" -ForegroundColor Green
        } catch {
            Write-Host "  FAIL: $dll - $($_.Exception.Message)" -ForegroundColor Red
        }
    } else {
        Write-Host "  MISSING: $dll" -ForegroundColor DarkYellow
    }
}
Write-Host "  Total: $($loadedAssemblies.Count) assemblies loaded`n" -ForegroundColor Cyan

# ============================================================
# TEST 2: Find ALL Process-related types
# ============================================================
Write-Host "[TEST 2] Scanning for Process/Workflow types..." -ForegroundColor Yellow
$processTypes = @()
foreach ($asm in $loadedAssemblies) {
    try {
        $types = $asm.GetExportedTypes() | Where-Object {
            ($_.Name -eq "Process" -or
             $_.Name -eq "ProcessInstance" -or
             $_.Name -match "^ProcessDef" -or
             $_.Name -eq "Workflow" -or
             $_.Name -eq "WorkflowDefinition" -or
             ($_.Name -match "Process" -and $_.Namespace -match "Design|Author|Client" -and -not $_.Name.Contains("Exception") -and -not $_.Name.Contains("EventArgs")))
        }
        foreach ($t in $types) {
            $processTypes += $t
            Write-Host "`n  TYPE: $($t.FullName) [Abstract=$($t.IsAbstract), Interface=$($t.IsInterface)]" -ForegroundColor Cyan

            # Constructors
            foreach ($ctor in $t.GetConstructors()) {
                $ps = ($ctor.GetParameters() | ForEach-Object { "$($_.ParameterType.Name) $($_.Name)" }) -join ", "
                Write-Host "    CTOR($ps)" -ForegroundColor DarkGray
            }

            # Key methods (Save, Deploy, Export, etc.)
            $methods = $t.GetMethods() | Where-Object {
                $_.DeclaringType.FullName -eq $t.FullName -and
                $_.Name -match "^(Save|Deploy|Export|Compile|Publish|Create|GetXml|Serialize|Upload|Import|Register|Build|Generate)"
            } | Sort-Object Name
            foreach ($m in $methods) {
                $ps = ($m.GetParameters() | ForEach-Object { "$($_.ParameterType.Name) $($_.Name)" }) -join ", "
                Write-Host "    METHOD: $($m.ReturnType.Name) $($m.Name)($ps)" -ForegroundColor Green
            }

            # Key properties
            $props = $t.GetProperties() | Where-Object {
                $_.Name -match "^(Name|DisplayName|Activities|Lines|DataFields|Description|Category|Folder|Version|FullName|ProcID|Connection)$"
            }
            foreach ($p in $props) {
                Write-Host "    PROP: $($p.PropertyType.Name) $($p.Name) [Get=$($p.CanRead), Set=$($p.CanWrite)]" -ForegroundColor DarkCyan
            }
        }
    } catch {}
}
Write-Host "`n  Found $($processTypes.Count) process-related types`n" -ForegroundColor Cyan

# ============================================================
# TEST 3: Find ALL Deployment types
# ============================================================
Write-Host "[TEST 3] Scanning for Deployment types..." -ForegroundColor Yellow
foreach ($asm in $loadedAssemblies) {
    try {
        $types = $asm.GetExportedTypes() | Where-Object {
            ($_.Name -match "Deploy|Package") -and
            -not $_.IsInterface -and
            -not $_.Name.Contains("EventArgs") -and
            -not $_.Name.Contains("Exception") -and
            -not $_.Name.Contains("Attribute")
        }
        foreach ($t in $types) {
            Write-Host "`n  TYPE: $($t.FullName) [Abstract=$($t.IsAbstract)]" -ForegroundColor Cyan
            foreach ($ctor in $t.GetConstructors()) {
                $ps = ($ctor.GetParameters() | ForEach-Object { "$($_.ParameterType.Name) $($_.Name)" }) -join ", "
                Write-Host "    CTOR($ps)" -ForegroundColor DarkGray
            }
            $methods = $t.GetMethods() | Where-Object {
                $_.DeclaringType.FullName -eq $t.FullName
            } | Sort-Object Name
            foreach ($m in $methods) {
                $ps = ($m.GetParameters() | ForEach-Object { "$($_.ParameterType.Name) $($_.Name)" }) -join ", "
                Write-Host "    $($m.ReturnType.Name) $($m.Name)($ps)" -ForegroundColor DarkGray
            }
        }
    } catch {}
}

# ============================================================
# TEST 4: Management Server - upload/create methods
# ============================================================
Write-Host "`n`n[TEST 4] Management Server methods..." -ForegroundColor Yellow
try {
    $mgmt = New-Object SourceCode.Workflow.Management.WorkflowManagementServer
    $mgmt.CreateConnection()
    $mgmt.Connection.Open($connStr)
    Write-Host "  Connected to K2 Management Server" -ForegroundColor Green

    $procSets = $mgmt.GetProcSets()
    Write-Host "  $($procSets.Count) existing processes:" -ForegroundColor Cyan
    foreach ($ps in $procSets) {
        Write-Host "    [$($ps.ProcSetID)] $($ps.FullName)" -ForegroundColor DarkGray
    }

    Write-Host "`n  Upload/Import/Deploy methods:" -ForegroundColor Cyan
    $mgmtType = $mgmt.GetType()
    $mgmtType.GetMethods() | Where-Object {
        $_.DeclaringType.FullName -like "SourceCode.*" -and
        $_.Name -match "Upload|Import|Deploy|SaveProc|SetProc|AddProc|Create|Register|GetProc|SaveVersion"
    } | Sort-Object Name -Unique | ForEach-Object {
        $ps = ($_.GetParameters() | ForEach-Object { "$($_.ParameterType.Name) $($_.Name)" }) -join ", "
        Write-Host "    $($_.ReturnType.Name) $($_.Name)($ps)" -ForegroundColor Green
    }

    $mgmt.Connection.Close()
} catch {
    Write-Host "  FAILED: $($_.Exception.Message)" -ForegroundColor Red
}

# ============================================================
# TEST 5: K2 PowerShell snap-in cmdlets
# ============================================================
Write-Host "`n[TEST 5] K2 PowerShell Snap-in..." -ForegroundColor Yellow
try {
    Add-PSSnapin SourceCode.Deployment.PowerShell -ErrorAction Stop
    Write-Host "  Snap-in loaded" -ForegroundColor Green

    $k2Cmds = Get-Command -Module SourceCode.Deployment.PowerShell -ErrorAction SilentlyContinue
    if (-not $k2Cmds) {
        # Try PSSnapin instead of Module
        $k2Cmds = Get-Command -PSSnapin SourceCode.Deployment.PowerShell -ErrorAction SilentlyContinue
    }
    if ($k2Cmds) {
        foreach ($cmd in $k2Cmds) {
            Write-Host "  CMD: $($cmd.Name)" -ForegroundColor Cyan
            try {
                $params = (Get-Command $cmd.Name).Parameters
                foreach ($pKey in $params.Keys) {
                    $param = $params[$pKey]
                    Write-Host "    -$pKey [$($param.ParameterType.Name)]" -ForegroundColor DarkGray
                }
            } catch {}
        }
    } else {
        Write-Host "  No cmdlets found via Get-Command" -ForegroundColor Yellow
        # Manual probe
        Write-Host "  Testing Send-Deploy-Package directly..." -ForegroundColor Yellow
        try {
            $sendCmd = Get-Command "Send-Deploy-Package" -ErrorAction Stop
            Write-Host "  FOUND: $($sendCmd.Name) from $($sendCmd.Source)" -ForegroundColor Green
        } catch {
            Write-Host "  NOT FOUND: $($_.Exception.Message)" -ForegroundColor Red
        }
    }
} catch {
    Write-Host "  Snap-in failed: $($_.Exception.Message)" -ForegroundColor Red
}

# ============================================================
# TEST 6: Try to deploy using Send-Deploy-Package with REAL K2 .kspx
# ============================================================
Write-Host "`n[TEST 6] Deploy existing K2 .kspx from Setup folder..." -ForegroundColor Yellow
$setupDir = "C:\Program Files\K2\Setup"
$existingKspx = Get-ChildItem $setupDir -Filter "*.kspx" -ErrorAction SilentlyContinue | Select-Object -First 1
if ($existingKspx) {
    Write-Host "  Found: $($existingKspx.Name) ($([math]::Round($existingKspx.Length/1KB))KB)" -ForegroundColor Cyan

    # Copy to writable location
    $testDir = Join-Path $scriptDir "k2-export\_deploy_test"
    if (-not (Test-Path $testDir)) { New-Item -Path $testDir -ItemType Directory -Force | Out-Null }
    $testKspx = Join-Path $testDir $existingKspx.Name
    Copy-Item $existingKspx.FullName $testKspx -Force
    Write-Host "  Copied to: $testKspx" -ForegroundColor DarkGray

    try {
        Write-Host "  Deploying $($existingKspx.Name)..." -ForegroundColor Cyan
        Send-Deploy-Package -FileName $testKspx -K2Host $K2Server -Port $K2Port -Integrated $true -IsPrimaryLogin $true -NoAnalyze
        Write-Host "  DEPLOY SUCCESS!" -ForegroundColor Green
    } catch {
        Write-Host "  Deploy failed: $($_.Exception.Message)" -ForegroundColor Red
        if ($_.Exception.InnerException) {
            Write-Host "  Inner: $($_.Exception.InnerException.Message)" -ForegroundColor DarkRed
        }
    }
} else {
    Write-Host "  No .kspx files found in $setupDir" -ForegroundColor Yellow
}

# ============================================================
# TEST 7: Try ProcessInstance creation (proves API connectivity)
# ============================================================
Write-Host "`n[TEST 7] Process Instance API test..." -ForegroundColor Yellow
try {
    # Use Workflow Client to check connectivity
    $clientType = $loadedAssemblies | ForEach-Object { $_.GetExportedTypes() } | Where-Object { $_.FullName -eq "SourceCode.Workflow.Client.Connection" } | Select-Object -First 1
    if ($clientType) {
        Write-Host "  Found: $($clientType.FullName)" -ForegroundColor Cyan
        $clientConn = New-Object SourceCode.Workflow.Client.Connection
        $clientConn.Open($K2Server, $connStr)
        Write-Host "  Client connected!" -ForegroundColor Green

        # List available processes
        $procList = $clientConn.GetProcessInstances()
        Write-Host "  $($procList.Count) running process instances" -ForegroundColor Cyan

        $clientConn.Close()
    }
} catch {
    Write-Host "  Client test: $($_.Exception.Message)" -ForegroundColor Yellow
}

Write-Host "`n============================================" -ForegroundColor White
Write-Host "  E2E Test Complete!" -ForegroundColor White
Write-Host "  Results: $outputFile" -ForegroundColor White
Write-Host "============================================" -ForegroundColor White

Stop-Transcript
