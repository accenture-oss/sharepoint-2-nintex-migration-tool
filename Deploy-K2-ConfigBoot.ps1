# ============================================================
#  Deploy-K2-ConfigBoot.ps1
#  
#  Process.Load() needs SourceCode.Configuration bootstrapped.
#  Process..ctor() -> EnsureRequiredReferences() -> ConfigurationManager
#  
#  Solution: Initialize the K2 config system before calling Load.
#  K2Studio does this via its .exe.config which has:
#    <sourcecode.configuration managerConfigFile="path\to\ConfigurationManager.config" />
#
#  We'll find and initialize it, then Load + Deploy.
#
#  Run in PowerShell ISE on K2 VM
# ============================================================

$ErrorActionPreference = "Continue"
$k2Bin = "C:\Program Files\K2\Bin"
$k2HostBin = "C:\Program Files\K2\Host Server\Bin"
$connStr = "Integrated=True;IsPrimaryLogin=True;Authenticate=True;EncryptedPassword=False;Host=localhost;Port=5555"
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$outputFile = Join-Path $scriptDir "Deploy-K2-ConfigBoot-Results.txt"
$exportDir = Join-Path $scriptDir "k2-export\_cfgboot"

if (-not (Test-Path $exportDir)) { New-Item -Path $exportDir -ItemType Directory -Force | Out-Null }

Start-Transcript -Path $outputFile -Force

Write-Host "============================================" -ForegroundColor White
Write-Host "  K2 Deploy - Config Bootstrap + Deploy" -ForegroundColor White  
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
# STEP 1: Find K2 configuration files
# ============================================================
Write-Host "[1] Finding K2 config files..." -ForegroundColor Yellow

# Search for ConfigurationManager.config and K2Studio.exe.config
$configSearchPaths = @(
    "C:\Program Files\K2",
    "C:\Program Files (x86)\K2 blackpearl",
    "C:\ProgramData\SourceCode",
    "C:\ProgramData\K2"
)
$cfgMgrConfig = $null
$k2StudioConfig = $null

foreach ($sp in $configSearchPaths) {
    if (Test-Path $sp) {
        # Find ConfigurationManager.config
        $cfgs = Get-ChildItem $sp -Recurse -Filter "ConfigurationManager.config" -ErrorAction SilentlyContinue
        foreach ($c in $cfgs) {
            Write-Host "  ConfigMgr: $($c.FullName)" -ForegroundColor Green
            if (-not $cfgMgrConfig) { $cfgMgrConfig = $c.FullName }
        }
        # Find K2Studio*.config
        $k2cfgs = Get-ChildItem $sp -Recurse -Filter "K2Studio*.config" -ErrorAction SilentlyContinue
        foreach ($c in $k2cfgs) {
            Write-Host "  K2Studio: $($c.FullName)" -ForegroundColor Green
            if (-not $k2StudioConfig) { $k2StudioConfig = $c.FullName }
        }
        # Find any .exe.config that has sourcecode.configuration
        $exeCfgs = Get-ChildItem $sp -Recurse -Filter "*.exe.config" -ErrorAction SilentlyContinue
        foreach ($c in $exeCfgs) {
            $content = Get-Content $c.FullName -Raw -ErrorAction SilentlyContinue
            if ($content -and $content -match "sourcecode.configuration") {
                Write-Host "  SourceCode config: $($c.FullName)" -ForegroundColor Cyan
                if (-not $k2StudioConfig) { $k2StudioConfig = $c.FullName }
            }
        }
    }
}

# Also search on C: root for K2 config  
$rootCfgs = Get-ChildItem "C:\" -Filter "ConfigurationManager.config" -Depth 5 -ErrorAction SilentlyContinue
foreach ($c in $rootCfgs) {
    Write-Host "  Root ConfigMgr: $($c.FullName)" -ForegroundColor Green
    if (-not $cfgMgrConfig) { $cfgMgrConfig = $c.FullName }
}

# ============================================================
# STEP 2: Try to initialize SourceCode.Configuration
# ============================================================
Write-Host "`n[2] Initializing SourceCode.Configuration..." -ForegroundColor Yellow

$scConfigType = [System.AppDomain]::CurrentDomain.GetAssemblies() | ForEach-Object {
    try { $_.GetType("SourceCode.Configuration.ConfigurationManager") } catch {}
} | Where-Object { $_ } | Select-Object -First 1

if ($scConfigType) {
    Write-Host "  Found: $($scConfigType.FullName)" -ForegroundColor Green
    
    # List all static methods
    foreach ($m in $scConfigType.GetMethods([System.Reflection.BindingFlags]::Static -bor [System.Reflection.BindingFlags]::Public)) {
        $ps = ($m.GetParameters() | ForEach-Object { "$($_.ParameterType.Name) $($_.Name)" }) -join ", "
        Write-Host "    static $($m.ReturnType.Name) $($m.Name)($ps)" -ForegroundColor DarkCyan
    }
    # Static properties
    foreach ($p in $scConfigType.GetProperties([System.Reflection.BindingFlags]::Static -bor [System.Reflection.BindingFlags]::Public)) {
        Write-Host "    static $($p.PropertyType.Name) $($p.Name)" -ForegroundColor DarkCyan
    }
    
    # Try Initialize with the config file
    if ($cfgMgrConfig) {
        Write-Host "`n  Initializing with: $cfgMgrConfig" -ForegroundColor Yellow
        try {
            $initMethod = $scConfigType.GetMethod("Initialize", [Type[]]@([string]))
            if ($initMethod) {
                $initMethod.Invoke($null, @([string]$cfgMgrConfig))
                Write-Host "  *** INITIALIZED! ***" -ForegroundColor Green
            } else {
                Write-Host "  No Initialize(string) method" -ForegroundColor Red
            }
        } catch {
            Write-Host "  Init error: $($_.Exception.Message)" -ForegroundColor Red
            if ($_.Exception.InnerException) {
                Write-Host "  Inner: $($_.Exception.InnerException.Message)" -ForegroundColor DarkRed
            }
        }
    }
    
    # If no ConfigurationManager.config found, try creating one
    if (-not $cfgMgrConfig) {
        Write-Host "`n  No ConfigurationManager.config found. Creating minimal one..." -ForegroundColor Yellow
        $minConfig = Join-Path $exportDir "ConfigurationManager.config"
        $configXml = @"
<?xml version="1.0" encoding="utf-8"?>
<configuration>
  <appSettings>
    <add key="ServerName" value="localhost" />
    <add key="Port" value="5555" />
  </appSettings>
</configuration>
"@
        [System.IO.File]::WriteAllText($minConfig, $configXml)
        
        # Try Initialize methods
        $methods = $scConfigType.GetMethods([System.Reflection.BindingFlags]::Static -bor [System.Reflection.BindingFlags]::Public) |
            Where-Object { $_.Name -like "*Init*" -or $_.Name -like "*Load*" -or $_.Name -like "*Set*" -or $_.Name -like "*Config*" }
        foreach ($m in $methods) {
            $ps = ($m.GetParameters() | ForEach-Object { "$($_.ParameterType.Name) $($_.Name)" }) -join ", "
            Write-Host "    Trying: $($m.Name)($ps)" -ForegroundColor Yellow
        }
    }
}

# ============================================================
# STEP 3: Compile and run C# with config bootstrap
# ============================================================
Write-Host "`n[3] C# deployer with config..." -ForegroundColor Yellow

$cfgPath = if ($cfgMgrConfig) { $cfgMgrConfig } else { "" }

$csharpCode = @"
using System;
using System.IO;
using System.Reflection;

public class K2ConfigDeployer
{
    public static string Deploy(string kprxFile, string configPath)
    {
        string result = "";
        try
        {
            // Step A: Bootstrap config
            result += "Config path: " + configPath + "\n";
            
            var scConfigType = Type.GetType("SourceCode.Configuration.ConfigurationManager, SourceCode.Configuration");
            if (scConfigType == null)
            {
                // Search loaded assemblies
                foreach (var asm in AppDomain.CurrentDomain.GetAssemblies())
                {
                    var t = asm.GetType("SourceCode.Configuration.ConfigurationManager");
                    if (t != null) { scConfigType = t; break; }
                }
            }
            
            if (scConfigType != null)
            {
                result += "ConfigMgr type found\n";
                
                // List all methods
                foreach (var m in scConfigType.GetMethods(BindingFlags.Public | BindingFlags.Static))
                {
                    var parms = "";
                    foreach (var p in m.GetParameters()) parms += p.ParameterType.Name + " " + p.Name + ", ";
                    result += "  static " + m.ReturnType.Name + " " + m.Name + "(" + parms + ")\n";
                }
                
                // Try to call Initialize or equivalent
                if (!string.IsNullOrEmpty(configPath) && File.Exists(configPath))
                {
                    try
                    {
                        var initMethod = scConfigType.GetMethod("Initialize", new Type[] { typeof(string) });
                        if (initMethod != null)
                        {
                            initMethod.Invoke(null, new object[] { configPath });
                            result += "*** Config INITIALIZED ***\n";
                        }
                    }
                    catch (Exception ex) { result += "Init error: " + ex.InnerException?.Message + "\n"; }
                }
                
                // Check if already initialized
                try
                {
                    var isInitProp = scConfigType.GetProperty("IsInitialized", BindingFlags.Public | BindingFlags.Static);
                    if (isInitProp != null)
                        result += "IsInitialized = " + isInitProp.GetValue(null) + "\n";
                }
                catch {}
            }
            
            // Step B: Try Process.Load
            result += "\nLoading KPRX...\n";
            var process = SourceCode.Workflow.Authoring.Process.Load(kprxFile);
            result += "*** LOADED! ***\n";
            result += "Name=" + process.Name + "\n";
            result += "CategoryPath=" + process.CategoryPath + "\n";
            result += "DeployToCategory=" + process.DeployToCategory + "\n";
            
            // Step C: Deploy
            process.DeployToCategory = true;
            result += "\nDeploying...\n";
            var deployResult = process.Deploy();
            result += "*** DEPLOY COMPLETE! ***\n";
            if (deployResult != null)
            {
                foreach (var prop in deployResult.GetType().GetProperties())
                {
                    try { result += "  " + prop.Name + " = " + prop.GetValue(deployResult) + "\n"; } catch {}
                }
            }
        }
        catch (Exception ex)
        {
            result += "ERROR: " + ex.Message + "\n";
            if (ex.InnerException != null)
            {
                result += "INNER: " + ex.InnerException.Message + "\n";
                if (ex.InnerException.InnerException != null)
                    result += "INNER2: " + ex.InnerException.InnerException.Message + "\n";
            }
            result += "\nStack:\n" + ex.ToString().Substring(0, Math.Min(1500, ex.ToString().Length)) + "\n";
        }
        return result;
    }
}
"@

$authoringDll = "$k2Bin\SourceCode.Workflow.Authoring.dll"
$configDll = Get-ChildItem "$k2Bin\SourceCode.Configuration.dll" -ErrorAction SilentlyContinue
$refDlls = @($authoringDll)
if ($configDll) { $refDlls += $configDll.FullName }

try {
    Add-Type -TypeDefinition $csharpCode -ReferencedAssemblies $refDlls -ErrorAction Stop
    Write-Host "  Compiled!" -ForegroundColor Green
} catch {
    Write-Host "  Compile: $($_.Exception.Message)" -ForegroundColor Red
}

# Save KPRX
$mgmt = New-Object SourceCode.Workflow.Management.WorkflowManagementServer
$mgmt.CreateConnection()
$mgmt.Connection.Open($connStr)
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

# Execute
Write-Host "`n  Executing..." -ForegroundColor Yellow
try {
    $result = [K2ConfigDeployer]::Deploy([string]$kprxFile, [string]$cfgPath)
    Write-Host $result
} catch {
    Write-Host "  Error: $($_.Exception.ToString())" -ForegroundColor Red
}

# ============================================================
# VERIFY
# ============================================================
Write-Host "`n[4] Processes:" -ForegroundColor Yellow
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
