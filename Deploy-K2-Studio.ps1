# ============================================================
#  Deploy-K2-Studio.ps1
#  
#  TWO APPROACHES:
#  A: Copy K2Studio.exe.config for our K2Deployer.exe
#  B: Use DeployPackage.exe directly (K2's own deployment CLI)
#
#  Run in PowerShell ISE on K2 VM
# ============================================================

$ErrorActionPreference = "Continue"
$k2Bin = "C:\Program Files\K2\Bin"
$connStr = "Integrated=True;IsPrimaryLogin=True;Authenticate=True;EncryptedPassword=False;Host=localhost;Port=5555"
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$outputFile = Join-Path $scriptDir "Deploy-K2-Studio-Results.txt"
$exportDir = Join-Path $scriptDir "k2-export\_studio"

if (-not (Test-Path $exportDir)) { New-Item -Path $exportDir -ItemType Directory -Force | Out-Null }

Start-Transcript -Path $outputFile -Force

Write-Host "============================================" -ForegroundColor White
Write-Host "  K2 Deploy via K2Studio Config + CLI Tools" -ForegroundColor White
Write-Host "============================================`n" -ForegroundColor White

# Load assemblies for KPRX extraction
foreach ($dll in @("SourceCode.Framework.dll","SourceCode.HostClientAPI.dll","SourceCode.Workflow.Management.dll")) {
    $p = Join-Path $k2Bin $dll; if (Test-Path $p) { [System.Reflection.Assembly]::LoadFrom($p) | Out-Null }
}

# Get KPRX
$mgmt = New-Object SourceCode.Workflow.Management.WorkflowManagementServer
$mgmt.CreateConnection()
$mgmt.Connection.Open($connStr)
$kprxBytes = $mgmt.GetProcessKprx(13)
$kprxFile = Join-Path $exportDir "TestKprxWF.kprx"
[System.IO.File]::WriteAllBytes($kprxFile, $kprxBytes)
$mgmt.Connection.Close()
Write-Host "KPRX saved: $($kprxBytes.Length) bytes" -ForegroundColor Green

# ============================================================
# APPROACH A: Show K2Studio.exe.config contents
# ============================================================
Write-Host "`n=== APPROACH A: K2Studio Config ===" -ForegroundColor Cyan

$k2StudioConfig = "C:\Program Files\K2\K2Studio\K2Studio.exe.config"
if (Test-Path $k2StudioConfig) {
    $configContent = Get-Content $k2StudioConfig -Raw -Encoding UTF8
    Write-Host "K2Studio.exe.config contents:" -ForegroundColor Yellow
    Write-Host $configContent -ForegroundColor DarkYellow
} else {
    Write-Host "K2Studio.exe.config not found!" -ForegroundColor Red
}

# Also show SourceCode.Workflow.Design.dll.config
$designConfig = "C:\Program Files\K2\Bin\SourceCode.Workflow.Design.dll.config"
if (Test-Path $designConfig) {
    $designContent = Get-Content $designConfig -Raw -Encoding UTF8
    Write-Host "`nSourceCode.Workflow.Design.dll.config:" -ForegroundColor Yellow
    Write-Host $designContent -ForegroundColor DarkYellow
}

# K2StudioConfigurationManager.config
$studioMgrConfig = "C:\Program Files\K2\K2Studio\K2StudioConfigurationManager.config"
if (Test-Path $studioMgrConfig) {
    $mgrContent = Get-Content $studioMgrConfig -Raw -Encoding UTF8
    Write-Host "`nK2StudioConfigurationManager.config:" -ForegroundColor Yellow
    Write-Host $mgrContent -ForegroundColor DarkYellow
}

# ============================================================
# APPROACH B: Use DeployPackage.exe CLI
# ============================================================
Write-Host "`n=== APPROACH B: DeployPackage.exe CLI ===" -ForegroundColor Cyan

$deployPkgExe = "C:\Program Files\K2\Setup\DeployPackage.exe"
$deployPkgConfig = "C:\Program Files\K2\Setup\DeployPackage.exe.config"

if (Test-Path $deployPkgConfig) {
    $dpContent = Get-Content $deployPkgConfig -Raw -Encoding UTF8
    Write-Host "DeployPackage.exe.config:" -ForegroundColor Yellow
    Write-Host $dpContent -ForegroundColor DarkYellow
}

# Try running it with --help or /?
Write-Host "`nTrying DeployPackage.exe /?" -ForegroundColor Yellow
try {
    $dpResult = & $deployPkgExe "/?" 2>&1
    $dpResult | ForEach-Object { Write-Host "  $_" -ForegroundColor DarkGray }
} catch {
    Write-Host "  Error: $($_.Exception.Message)" -ForegroundColor Red
}

Write-Host "`nTrying DeployPackage.exe (no args)" -ForegroundColor Yellow
try {
    $dpResult2 = & $deployPkgExe 2>&1
    $dpResult2 | ForEach-Object { Write-Host "  $_" -ForegroundColor DarkGray }
} catch {
    Write-Host "  Error: $($_.Exception.Message)" -ForegroundColor Red
}

# ============================================================
# APPROACH C: Use AppDeployment.exe / SourceCode.AppDeployment.exe
# ============================================================
Write-Host "`n=== APPROACH C: AppDeployment CLIs ===" -ForegroundColor Cyan

$appDeployExe = "C:\Program Files\K2\Setup\AppDeployment.exe"
$srcAppDeployExe = "C:\Program Files\K2\Setup\SourceCode.AppDeployment.exe"

Write-Host "AppDeployment.exe /?" -ForegroundColor Yellow
try {
    $adResult = & $appDeployExe "/?" 2>&1
    $adResult | ForEach-Object { Write-Host "  $_" -ForegroundColor DarkGray }
} catch {
    Write-Host "  Error: $($_.Exception.Message)" -ForegroundColor Red
}

Write-Host "`nSourceCode.AppDeployment.exe /?" -ForegroundColor Yellow
try {
    $sadResult = & $srcAppDeployExe "/?" 2>&1
    $sadResult | ForEach-Object { Write-Host "  $_" -ForegroundColor DarkGray }
} catch {
    Write-Host "  Error: $($_.Exception.Message)" -ForegroundColor Red
}

# ============================================================
# APPROACH D: Copy our C# exe next to K2Studio and use its config
# ============================================================
Write-Host "`n=== APPROACH D: Compile in K2Studio dir ===" -ForegroundColor Cyan

$csSource = @'
using System;
using System.IO;
using SourceCode.Workflow.Authoring;
using SourceCode.Framework.Deployment;

class K2Deploy
{
    static void Main(string[] args)
    {
        if (args.Length < 1) { Console.WriteLine("Usage: K2Deploy.exe <kprx_file> [new_name] [folder]"); return; }
        
        string kprxFile = args[0];
        string newName = args.Length > 1 ? args[1] : "SPD_Migrated_WF";
        string folder = args.Length > 2 ? args[2] : "SPD Migration";
        string connStr = "Integrated=True;IsPrimaryLogin=True;Authenticate=True;EncryptedPassword=False;Host=localhost;Port=5555";
        
        Console.WriteLine("Loading KPRX: " + kprxFile);
        
        try
        {
            Process proc = Process.Load(kprxFile);
            Console.WriteLine("Loaded! Name=" + proc.Name + " FullName=" + proc.FullName);
            Console.WriteLine("Activities=" + proc.Activities.Count + " DataFields=" + proc.DataFields.Count);
            Console.WriteLine("Guid=" + proc.Guid);
            
            // Modify identity
            proc.Name = newName;
            proc.DisplayName = newName;
            proc.Guid = Guid.NewGuid();
            proc.Description = "Migrated from SPD";
            try { proc.ProcSetFolderName = folder; } catch {}
            try { proc.CategoryPath = folder; } catch {}
            
            Console.WriteLine("Modified: Name=" + proc.Name + " Guid=" + proc.Guid);
            
            // Deploy directly
            Console.WriteLine("Deploying...");
            DeploymentResults results = proc.Deploy();
            Console.WriteLine("Result: Successful=" + results.Successful);
            if (results.Errors != null)
                foreach (var e in results.Errors) Console.WriteLine("ERR: " + e);
            if (results.Output != null)
                foreach (var o in results.Output) Console.WriteLine("OUT: " + o);
            
            if (!results.Successful)
            {
                Console.WriteLine("Trying package deploy...");
                DeploymentPackage pkg = proc.CreateDeploymentPackage();
                pkg.WorkflowManagementConnectionString = connStr;
                DeploymentResults r2 = pkg.Execute();
                Console.WriteLine("Package result: Successful=" + r2.Successful);
                if (r2.Errors != null)
                    foreach (var e in r2.Errors) Console.WriteLine("PKG ERR: " + e);
            }
        }
        catch (Exception ex)
        {
            Console.WriteLine("FATAL: " + ex.Message);
            if (ex.InnerException != null)
            {
                Console.WriteLine("Inner: " + ex.InnerException.Message);
                if (ex.InnerException.InnerException != null)
                    Console.WriteLine("Inner2: " + ex.InnerException.InnerException.Message);
            }
        }
    }
}
'@

# Compile into K2Studio directory (it has proper config)
$k2StudioDir = "C:\Program Files\K2\K2Studio"
$csFile = Join-Path $exportDir "K2Deploy.cs"
[System.IO.File]::WriteAllText($csFile, $csSource)

$cscPath = "C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe"
$exeOut = Join-Path $k2StudioDir "K2Deploy.exe"
$refs = @("$k2Bin\SourceCode.Framework.dll","$k2Bin\SourceCode.Workflow.Authoring.dll","$k2Bin\SourceCode.Workflow.Design.dll","$k2Bin\SourceCode.HostClientAPI.dll")
$refStr = ($refs | ForEach-Object { "/r:`"$_`"" }) -join " "

Write-Host "Compiling to K2Studio dir..." -ForegroundColor Yellow
$compCmd = "& `"$cscPath`" /target:exe /out:`"$exeOut`" $refStr `"$csFile`" 2>&1"
$compResult = Invoke-Expression $compCmd
$compResult | ForEach-Object { Write-Host "  $_" -ForegroundColor DarkGray }

if (Test-Path $exeOut) {
    Write-Host "Compiled! Running from K2Studio dir..." -ForegroundColor Green
    
    # K2Studio.exe.config should be picked up by K2Deploy.exe via probing
    # But we need K2Deploy.exe.config - copy from K2Studio
    Copy-Item $k2StudioConfig (Join-Path $k2StudioDir "K2Deploy.exe.config") -Force
    Write-Host "Copied K2Studio config as K2Deploy.exe.config" -ForegroundColor Green
    
    $result = & $exeOut $kprxFile "SPD_Migrated_Test" "SPD Migration" 2>&1
    $result | ForEach-Object { Write-Host "  $_" -ForegroundColor $(if("$_" -like "*FATAL*" -or "$_" -like "*ERR*"){"Red"}elseif("$_" -like "*Successful=True*"){"Green"}else{"DarkGray"}) }
    
    # Clean up
    Remove-Item $exeOut -Force -ErrorAction SilentlyContinue
    Remove-Item (Join-Path $k2StudioDir "K2Deploy.exe.config") -Force -ErrorAction SilentlyContinue
}

# ============================================================
# VERIFICATION
# ============================================================
Write-Host "`n=== VERIFICATION ===" -ForegroundColor Cyan
$mgmt2 = New-Object SourceCode.Workflow.Management.WorkflowManagementServer
$mgmt2.CreateConnection()
$mgmt2.Connection.Open($connStr)
foreach ($ps in $mgmt2.GetProcSets()) {
    $marker = if ($ps.FullName -like "*SPD*" -or $ps.FullName -like "*Migrat*") { " <<<< NEW!" } else { "" }
    Write-Host "  $($ps.FullName) (ID=$($ps.ProcSetID))$marker" -ForegroundColor $(if($marker){"Green"}else{"DarkGray"})
}
$mgmt2.Connection.Close()

Write-Host "`n============================================" -ForegroundColor White
Write-Host "  K2 Studio Deploy Complete!" -ForegroundColor White
Write-Host "============================================" -ForegroundColor White

Stop-Transcript
