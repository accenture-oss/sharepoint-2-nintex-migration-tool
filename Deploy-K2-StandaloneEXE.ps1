# ============================================================
#  Deploy-K2-StandaloneEXE.ps1
#  
#  THE FINAL SOLUTION: Standalone EXE with its own .config
#  
#  Process.Load() needs sourcecode.configuration in the host
#  .exe.config. PowerShell ISE doesn't have it.
#  Solution: Compile K2Deployer.exe, copy a K2 .exe.config
#  next to it, invoke it.
#
#  Run in PowerShell ISE on K2 VM
# ============================================================

$ErrorActionPreference = "Continue"
$k2Bin = "C:\Program Files\K2\Bin"
$connStr = "Integrated=True;IsPrimaryLogin=True;Authenticate=True;EncryptedPassword=False;Host=localhost;Port=5555"
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$outputFile = Join-Path $scriptDir "Deploy-K2-StandaloneEXE-Results.txt"
$exportDir = Join-Path $scriptDir "k2-export\_standalone"

if (-not (Test-Path $exportDir)) { New-Item -Path $exportDir -ItemType Directory -Force | Out-Null }

Start-Transcript -Path $outputFile -Force

Write-Host "============================================" -ForegroundColor White
Write-Host "  K2 Deploy - Standalone EXE" -ForegroundColor White  
Write-Host "============================================`n" -ForegroundColor White

# ============================================================
# STEP 1: Find a K2 .exe.config to copy from
# ============================================================
Write-Host "[1] Finding K2 .exe.config source..." -ForegroundColor Yellow

$sourceConfigs = @(
    "C:\Program Files\K2\Bin\K2Studio.exe.config",
    "C:\Program Files\K2\Bin\K2 Designer.exe.config", 
    "C:\Program Files\K2\Bin\SmartObject Service Tester.exe.config",
    "C:\Program Files\K2\Bin\K2 Workspace.exe.config",
    "C:\Program Files\K2\Bin\K2Studio.exe.Config"
)
$sourceConfig = $null
foreach ($sc in $sourceConfigs) {
    if (Test-Path $sc) {
        $sourceConfig = $sc
        Write-Host "  Found: $sc" -ForegroundColor Green
        break
    }
}

# Search if not found
if (-not $sourceConfig) {
    Write-Host "  Searching for any K2 .exe.config..." -ForegroundColor Yellow
    $found = Get-ChildItem "$k2Bin" -Filter "*.exe.config" -ErrorAction SilentlyContinue | Select-Object -First 5
    foreach ($f in $found) {
        Write-Host "  Available: $($f.FullName)" -ForegroundColor Cyan
        $content = Get-Content $f.FullName -Raw -ErrorAction SilentlyContinue
        if ($content -match "sourcecode\.configuration") {
            $sourceConfig = $f.FullName
            Write-Host "    ^^^ HAS sourcecode.configuration! Using this." -ForegroundColor Green
            break
        }
    }
    # Also check Host Server
    $found2 = Get-ChildItem "C:\Program Files\K2\Host Server\Bin" -Filter "*.exe.config" -ErrorAction SilentlyContinue | Select-Object -First 5
    foreach ($f in $found2) {
        Write-Host "  Available: $($f.FullName)" -ForegroundColor Cyan
        if (-not $sourceConfig) {
            $content = Get-Content $f.FullName -Raw -ErrorAction SilentlyContinue
            if ($content -match "sourcecode\.configuration") {
                $sourceConfig = $f.FullName
                Write-Host "    ^^^ Using this." -ForegroundColor Green
            }
        }
    }
}

if (-not $sourceConfig) {
    Write-Host "  No K2 .exe.config found! Listing all .exe.config files:" -ForegroundColor Red
    Get-ChildItem "C:\Program Files\K2" -Recurse -Filter "*.exe.config" -ErrorAction SilentlyContinue | ForEach-Object {
        Write-Host "    $($_.FullName)" -ForegroundColor DarkGray
    }
}

# ============================================================
# STEP 2: Compile K2Deployer.exe
# ============================================================
Write-Host "`n[2] Compiling K2Deployer.exe..." -ForegroundColor Yellow

$csFile = Join-Path $scriptDir "K2Deployer.cs"
$exeFile = Join-Path $exportDir "K2Deployer.exe"
$configFile = Join-Path $exportDir "K2Deployer.exe.config"

# Find csc.exe
$csc = Get-ChildItem "C:\Windows\Microsoft.NET\Framework64\v4.*\csc.exe" -ErrorAction SilentlyContinue | Select-Object -Last 1
if (-not $csc) { $csc = Get-ChildItem "C:\Windows\Microsoft.NET\Framework\v4.*\csc.exe" -ErrorAction SilentlyContinue | Select-Object -Last 1 }
Write-Host "  csc.exe: $($csc.FullName)" -ForegroundColor Green

# Compile with ALL K2 references + Microsoft.Build.Framework
$refArgs = @()
Get-ChildItem "$k2Bin\SourceCode.*.dll" -ErrorAction SilentlyContinue | ForEach-Object {
    $refArgs += "/reference:`"$($_.FullName)`""
}
# Add Microsoft.Build.Framework + Utilities for IBuildEngine/TaskItem
$fwkDir = Split-Path $csc.FullName
foreach ($msBuildDll in @("Microsoft.Build.Framework.dll", "Microsoft.Build.Utilities.v4.0.dll")) {
    $dllPath = Join-Path $fwkDir $msBuildDll
    if (Test-Path $dllPath) { $refArgs += "/reference:`"$dllPath`"" }
}
Write-Host "  References: $($refArgs.Count) DLLs" -ForegroundColor DarkGray

if (Test-Path $exeFile) { Remove-Item $exeFile -Force }
# Add System.IO.Compression for ZIP creation
$compressionDll = [System.IO.Path]::Combine([System.Runtime.InteropServices.RuntimeEnvironment]::GetRuntimeDirectory(), "System.IO.Compression.dll")
$compressionFsDll = [System.IO.Path]::Combine([System.Runtime.InteropServices.RuntimeEnvironment]::GetRuntimeDirectory(), "System.IO.Compression.FileSystem.dll")
if (Test-Path $compressionDll) { $refArgs += "/reference:`"$compressionDll`"" }
if (Test-Path $compressionFsDll) { $refArgs += "/reference:`"$compressionFsDll`"" }
$allArgs = @("/target:exe", "/out:`"$exeFile`"", "/nologo") + $refArgs + @("`"$csFile`"")
$compileResult = & $csc.FullName $allArgs 2>&1
$compileResult | ForEach-Object { Write-Host "  $_" -ForegroundColor $(if ($_ -match "error") {"Red"} else {"DarkGray"}) }

if (Test-Path $exeFile) {
    Write-Host "  EXE compiled: $exeFile" -ForegroundColor Green
} else {
    Write-Host "  COMPILE FAILED" -ForegroundColor Red
    Stop-Transcript
    return
}

# ============================================================
# STEP 3: Copy/create .exe.config
# ============================================================
Write-Host "`n[3] Setting up .exe.config..." -ForegroundColor Yellow

if ($sourceConfig) {
    Copy-Item $sourceConfig $configFile -Force
    Write-Host "  Copied: $sourceConfig -> $configFile" -ForegroundColor Green
} else {
    # Create a minimal config based on K2 patterns
    Write-Host "  Creating minimal config..." -ForegroundColor Yellow
    $minConfig = @"
<?xml version="1.0" encoding="utf-8"?>
<configuration>
  <configSections>
    <section name="sourcecode.configuration" type="SourceCode.Configuration.ConfigurationHandler, SourceCode.Configuration" />
  </configSections>
  <sourcecode.configuration managerConfigFile="C:\Program Files\K2\Host Server\Bin\ConfigurationManager.config" />
  <runtime>
    <assemblyBinding xmlns="urn:schemas-microsoft-com:asm.v1">
      <probing privatePath="C:\Program Files\K2\Bin" />
    </assemblyBinding>
  </runtime>
</configuration>
"@
    [System.IO.File]::WriteAllText($configFile, $minConfig)
    Write-Host "  Created minimal config" -ForegroundColor Yellow
}

# Show config content (first 500 chars)
$cfgContent = Get-Content $configFile -Raw
Write-Host "  Config (first 500): $($cfgContent.Substring(0, [Math]::Min(500, $cfgContent.Length)))" -ForegroundColor DarkYellow

# ============================================================
# STEP 4: Prepare KPRX
# ============================================================
Write-Host "`n[4] Preparing KPRX..." -ForegroundColor Yellow

# Load assemblies for management API
Get-ChildItem "$k2Bin\SourceCode.*.dll" | ForEach-Object {
    try { [System.Reflection.Assembly]::LoadFrom($_.FullName) | Out-Null } catch {}
}

$mgmt = New-Object SourceCode.Workflow.Management.WorkflowManagementServer
$mgmt.CreateConnection() | Out-Null
$mgmt.Connection.Open($connStr) | Out-Null
$kprxBytes = $mgmt.GetProcessKprx(13)
$mgmt.Connection.Close()

$kprxStr = [System.Text.Encoding]::UTF8.GetString($kprxBytes)
$newGuid = [System.Guid]::NewGuid().ToString("N")
$kprxStr = $kprxStr.Replace("<Guid>65aaa9ae4e5b4d8b839d9edf44eea93a</Guid>", "<Guid>$newGuid</Guid>")
$kprxStr = $kprxStr.Replace("<Name>TestKprxWF</Name>", "<Name>SPDMigratedApproval</Name>")
$kprxStr = $kprxStr.Replace("<DisplayName>TestKprxWF</DisplayName>", "<DisplayName>SPD Migrated Approval</DisplayName>")
$kprxStr = $kprxStr.Replace("<CategoryPath>Workflow</CategoryPath>", "<CategoryPath>SPD Migration</CategoryPath>")
$kprxStr = $kprxStr.Replace("<ExtenderNamespace>65aaa9ae4e5b4d8b839d9edf44eea93a</ExtenderNamespace>", "<ExtenderNamespace>$newGuid</ExtenderNamespace>")
$kprxFile = Join-Path $exportDir "SPDMigratedApproval.kprx"
[System.IO.File]::WriteAllText($kprxFile, $kprxStr, (New-Object System.Text.UTF8Encoding $false))
Write-Host "  KPRX: $kprxFile" -ForegroundColor Green

# ============================================================
# STEP 5: Execute K2Deployer.exe (Load + Compile + Export)
# ============================================================
Write-Host "`n[5] Executing K2Deployer.exe..." -ForegroundColor Yellow

Write-Host "  Command: $exeFile `"$kprxFile`" `"$exportDir`"" -ForegroundColor DarkGray

$deployOutput = & "$exeFile" "$kprxFile" "$exportDir" 2>&1
foreach ($line in $deployOutput) {
    $color = "White"
    if ($line -match "SUCCESS|LOADED|COMPLETE|DONE|\*\*\*") { $color = "Green" }
    elseif ($line -match "FATAL|error CS") { $color = "Red" }
    elseif ($line -match "KSPX_ZIP=") { $color = "Green" }
    elseif ($line -match "^\s+\w+\s*[:=]") { $color = "Cyan" }
    Write-Host "  $line" -ForegroundColor $color
}

# ============================================================
# STEP 6: Deploy the ZIP .kspx via Deploy-Package
# ============================================================
$zipKspx = Join-Path $exportDir "SPDMigratedApproval.kspx"
if (Test-Path $zipKspx) {
    Write-Host "`n[6] Deploying ZIP .kspx via Deploy-Package..." -ForegroundColor Yellow
    Write-Host "  Package: $zipKspx ($($(Get-Item $zipKspx).Length) bytes)" -ForegroundColor Green
    
    try {
        # First discover actual parameter names
        Write-Host "  Deploy-Package parameters:" -ForegroundColor Cyan
        $cmd = Get-Command Deploy-Package -ErrorAction SilentlyContinue
        if ($cmd) {
            foreach ($p in $cmd.Parameters.Keys) {
                Write-Host "    -$p" -ForegroundColor DarkCyan
            }
        }
        
        # Try with discovered params — common K2 names
        $deployed = $false
        $attempts = @(
            { Deploy-Package -FilePath $zipKspx -ConnectionString $connStr -ErrorAction Stop },
            { Deploy-Package -Path $zipKspx -ConnectionString $connStr -ErrorAction Stop },
            { Deploy-Package $zipKspx -ConnectionString $connStr -ErrorAction Stop },
            { Deploy-Package -PackagePath $zipKspx -ConnectionString $connStr -ErrorAction Stop }
        )
        
        foreach ($attempt in $attempts) {
            try {
                & $attempt
                $deployed = $true
                Write-Host "  Deploy-Package: SUCCESS!" -ForegroundColor Green
                break
            } catch {
                if ($_.Exception.Message -notmatch "parameter") {
                    # Real error, not parameter name issue
                    Write-Host "  Deploy-Package error: $($_.Exception.Message)" -ForegroundColor Red
                    break
                }
            }
        }
        
        if (-not $deployed) {
            throw "All parameter combinations failed"
        }
    } catch {
        Write-Host "  Deploy-Package error: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host "  Trying alternative: direct K2 management API..." -ForegroundColor Yellow
        
        # Fallback: explore WorkflowManagementServer methods
        try {
            $mgmt = New-Object SourceCode.Workflow.Management.WorkflowManagementServer
            $mgmt.CreateConnection() | Out-Null
            $mgmt.Connection.Open($connStr) | Out-Null
            
            $methods = $mgmt.GetType().GetMethods() | Where-Object { $_.Name -match "Import|Deploy|Upload|Register|Create" } | Select-Object Name, @{n='Params';e={($_.GetParameters() | ForEach-Object {"$($_.ParameterType.Name) $($_.Name)"}) -join ", "}}
            Write-Host "  Available methods:" -ForegroundColor Cyan
            foreach ($m in $methods) {
                Write-Host "    $($m.Name)($($m.Params))" -ForegroundColor DarkCyan
            }
            $mgmt.Connection.Close()
        } catch {
            Write-Host "  Fallback also failed: $($_.Exception.Message)" -ForegroundColor Red
        }
    }
} else {
    Write-Host "`n[6] No ZIP .kspx found at $zipKspx" -ForegroundColor Red
}

# ============================================================
# VERIFY - Show ALL processes
# ============================================================
Write-Host "`n[7] Verifying deployed processes:" -ForegroundColor Yellow
$mgmt2 = New-Object SourceCode.Workflow.Management.WorkflowManagementServer
$mgmt2.CreateConnection() | Out-Null
$mgmt2.Connection.Open($connStr) | Out-Null
$procSets = $mgmt2.GetProcSets()
foreach ($ps in $procSets) {
    $isNew = $ps.ProcSetID -gt 11
    $isSPD = $ps.FullName -match "SPD|Migrated"
    $marker = ""
    if ($isNew) { $marker = " <<< NEW!" }
    if ($isSPD) { $marker = " <<< SPD MIGRATED!" }
    $color = if ($isNew -or $isSPD) { "Green" } else { "DarkGray" }
    Write-Host "  $($ps.FullName) (ID=$($ps.ProcSetID))$marker" -ForegroundColor $color
}
Write-Host "  Total: $($procSets.Count)" -ForegroundColor Yellow
$mgmt2.Connection.Close()

Stop-Transcript
