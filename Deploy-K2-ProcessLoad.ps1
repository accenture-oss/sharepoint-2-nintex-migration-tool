# ============================================================
#  Deploy-K2-ProcessLoad.ps1
#  
#  DISCOVERY: Process class HAS built-in Deploy() and Load()!
#    Process.Load(fileName) - loads KPRX
#    Process.Deploy() - compiles and deploys server-side!
#
#  No DeploymentManager needed. No .kspx needed.
#
#  Run in PowerShell ISE on K2 VM
# ============================================================

$ErrorActionPreference = "Continue"
$k2Bin = "C:\Program Files\K2\Bin"
$k2HostBin = "C:\Program Files\K2\Host Server\Bin"
$connStr = "Integrated=True;IsPrimaryLogin=True;Authenticate=True;EncryptedPassword=False;Host=localhost;Port=5555"
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$outputFile = Join-Path $scriptDir "Deploy-K2-ProcessLoad-Results.txt"
$exportDir = Join-Path $scriptDir "k2-export\_procload"

if (-not (Test-Path $exportDir)) { New-Item -Path $exportDir -ItemType Directory -Force | Out-Null }

Start-Transcript -Path $outputFile -Force

Write-Host "============================================" -ForegroundColor White
Write-Host "  K2 Deploy - Process.Load() + Deploy()" -ForegroundColor White  
Write-Host "============================================`n" -ForegroundColor White

# Load assemblies
foreach ($lp in @($k2Bin, $k2HostBin)) {
    if (Test-Path $lp) {
        Get-ChildItem "$lp\SourceCode.*.dll" -ErrorAction SilentlyContinue | ForEach-Object {
            try { [System.Reflection.Assembly]::LoadFrom($_.FullName) | Out-Null } catch {}
        }
    }
}

# ============================================================
# STEP 1: Save KPRX to file
# ============================================================
Write-Host "[1] Getting KPRX..." -ForegroundColor Yellow
$mgmt = New-Object SourceCode.Workflow.Management.WorkflowManagementServer
$mgmt.CreateConnection()
$mgmt.Connection.Open($connStr)
$kprxBytes = $mgmt.GetProcessKprx(13)
$mgmt.Connection.Close()

# Modify identity
$kprxStr = [System.Text.Encoding]::UTF8.GetString($kprxBytes)
$newGuid = [System.Guid]::NewGuid().ToString("N")
$kprxStr = $kprxStr.Replace("<Guid>65aaa9ae4e5b4d8b839d9edf44eea93a</Guid>", "<Guid>$newGuid</Guid>")
$kprxStr = $kprxStr.Replace("<Name>TestKprxWF</Name>", "<Name>SPDMigratedApproval</Name>")
$kprxStr = $kprxStr.Replace("<DisplayName>TestKprxWF</DisplayName>", "<DisplayName>SPD Migrated Approval</DisplayName>")
$kprxStr = $kprxStr.Replace("<CategoryPath>Workflow</CategoryPath>", "<CategoryPath>SPD Migration</CategoryPath>")
$kprxStr = $kprxStr.Replace("<ExtenderNamespace>65aaa9ae4e5b4d8b839d9edf44eea93a</ExtenderNamespace>", "<ExtenderNamespace>$newGuid</ExtenderNamespace>")

$kprxFile = Join-Path $exportDir "SPDMigratedApproval.kprx"
[System.IO.File]::WriteAllText($kprxFile, $kprxStr, [System.Text.Encoding]::UTF8)
Write-Host "  KPRX saved: $kprxFile ($([math]::Round((Get-Item $kprxFile).Length/1KB))KB)" -ForegroundColor Green

# ============================================================
# STEP 2: Explore Process class fully
# ============================================================
Write-Host "`n[2] Process class analysis..." -ForegroundColor Yellow
$procType = [System.AppDomain]::CurrentDomain.GetAssemblies() | ForEach-Object {
    try { $_.GetType("SourceCode.Workflow.Authoring.Process") } catch {}
} | Where-Object { $_ } | Select-Object -First 1

Write-Host "  Type: $($procType.FullName)" -ForegroundColor Green

# Properties related to connection/server
Write-Host "`n  Connection-related properties:" -ForegroundColor Yellow
foreach ($prop in $procType.GetProperties()) {
    if ($prop.Name -match "Server|Host|Port|Connection|Url|Deploy|Category") {
        $canSet = if ($prop.CanWrite) { "SET" } else { "GET" }
        Write-Host "    $($prop.PropertyType.Name) $($prop.Name) [$canSet]" -ForegroundColor DarkCyan
    }
}

# ALL public methods (not inherited from Object)
Write-Host "`n  All methods:" -ForegroundColor Yellow
foreach ($m in $procType.GetMethods() | Where-Object { $_.DeclaringType.Namespace -like "*SourceCode*" }) {
    $ps = ($m.GetParameters() | ForEach-Object { "$($_.ParameterType.Name) $($_.Name)" }) -join ", "
    Write-Host "    $($m.ReturnType.Name) $($m.Name)($ps)" -ForegroundColor DarkCyan
}

# ============================================================
# STEP 3: Process.Load(fileName) 
# ============================================================
Write-Host "`n[3] Loading KPRX with Process.Load()..." -ForegroundColor Yellow

try {
    $loadMethod = $procType.GetMethod("Load", [Type[]]@([string]))
    Write-Host "  Load method: $($loadMethod.ReturnType.Name) Load($($loadMethod.GetParameters()[0].ParameterType.Name))" -ForegroundColor Green
    
    $process = $loadMethod.Invoke($null, @($kprxFile))  # Static method?
    if (-not $process) {
        # Try instance method
        Write-Host "  Static returned null, trying instance..." -ForegroundColor Yellow
        $proc = [System.Activator]::CreateInstance($procType)
        $process = $loadMethod.Invoke($proc, @($kprxFile))
    }
    
    if ($process) {
        Write-Host "  *** LOADED! ***" -ForegroundColor Green
        Write-Host "  Type: $($process.GetType().FullName)" -ForegroundColor Cyan
        
        # Show properties
        foreach ($prop in $process.GetType().GetProperties()) {
            $val = try { $prop.GetValue($process) } catch { $null }
            if ($val -and "$val" -ne "" -and "$val" -ne "0" -and "$val" -ne "False") {
                if ($prop.Name -match "Name|Guid|Category|Server|Host|Port|Display|Deploy|Folder") {
                    Write-Host "    $($prop.Name) = $val" -ForegroundColor Green
                }
            }
        }
    }
} catch {
    Write-Host "  Load error: $($_.Exception.Message)" -ForegroundColor Red
    if ($_.Exception.InnerException) {
        Write-Host "  Inner: $($_.Exception.InnerException.Message)" -ForegroundColor DarkRed
        if ($_.Exception.InnerException.InnerException) {
            Write-Host "  Inner2: $($_.Exception.InnerException.InnerException.Message)" -ForegroundColor DarkRed
        }
    }
}

# ============================================================
# STEP 4: Set server connection and Deploy()
# ============================================================
Write-Host "`n[4] Setting server + Deploy()..." -ForegroundColor Yellow

if ($process) {
    # Set server connection properties
    try { $process.ServerName = "localhost" } catch { Write-Host "  ServerName err: $_" -ForegroundColor DarkRed }
    try { $process.Port = 5555 } catch { Write-Host "  Port err: $_" -ForegroundColor DarkRed }
    
    # Check for ConnectionString or similar
    foreach ($prop in $process.GetType().GetProperties() | Where-Object { $_.CanWrite }) {
        if ($prop.Name -match "Server|Host|Connection") {
            Write-Host "  Writable: $($prop.Name) ($($prop.PropertyType.Name))" -ForegroundColor DarkCyan
        }
    }
    
    # Try Deploy()
    Write-Host "`n  Calling Deploy()..." -ForegroundColor Yellow
    try {
        $deployResult = $process.Deploy()
        Write-Host "  *** DEPLOY RETURNED! ***" -ForegroundColor Green
        Write-Host "  Result type: $($deployResult.GetType().FullName)" -ForegroundColor Cyan
        
        # Show results
        foreach ($prop in $deployResult.GetType().GetProperties()) {
            $val = try { $prop.GetValue($deployResult) } catch { "ERR" }
            Write-Host "    $($prop.Name) = $val" -ForegroundColor Green
        }
    } catch {
        Write-Host "  Deploy() error: $($_.Exception.Message)" -ForegroundColor Red
        if ($_.Exception.InnerException) {
            Write-Host "  Inner: $($_.Exception.InnerException.Message)" -ForegroundColor DarkRed
            if ($_.Exception.InnerException.InnerException) {
                Write-Host "  Inner2: $($_.Exception.InnerException.InnerException.Message)" -ForegroundColor DarkRed
            }
        }
        
        # Try Deploy(DeploymentPackage)
        Write-Host "`n  Trying Deploy(package)..." -ForegroundColor Yellow
        try {
            $pkg = $process.CreateDeploymentPackage()
            Write-Host "  Package created: $($pkg.GetType().FullName)" -ForegroundColor Green
            $deployResult2 = $process.Deploy($pkg)
            Write-Host "  *** DEPLOY(pkg) RETURNED! ***" -ForegroundColor Green
        } catch {
            Write-Host "  Deploy(pkg) error: $($_.Exception.Message)" -ForegroundColor Red
            if ($_.Exception.InnerException) {
                Write-Host "  Inner: $($_.Exception.InnerException.Message)" -ForegroundColor DarkRed
            }
        }
    }
}

# ============================================================
# VERIFY
# ============================================================
Write-Host "`n[5] Processes:" -ForegroundColor Yellow
$mgmt2 = New-Object SourceCode.Workflow.Management.WorkflowManagementServer
$mgmt2.CreateConnection()
$mgmt2.Connection.Open($connStr)
foreach ($ps in $mgmt2.GetProcSets()) {
    $m = if ($ps.ProcSetID -gt 11) { " <<< NEW!" } else { "" }
    Write-Host "  $($ps.FullName) (ID=$($ps.ProcSetID))$m" -ForegroundColor $(if($m){"Green"}else{"DarkGray"})
}
Write-Host "  Total: $($mgmt2.GetProcSets().Count)" -ForegroundColor Yellow
$mgmt2.Connection.Close()

Stop-Transcript
