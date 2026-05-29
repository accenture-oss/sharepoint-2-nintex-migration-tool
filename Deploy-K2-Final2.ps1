# ============================================================
#  Deploy-K2-Final2.ps1
#  
#  Use K2Studio's sourcecode.configuration pattern
#  Compile to writable directory with proper config
#
#  Run in PowerShell ISE on K2 VM
# ============================================================

$ErrorActionPreference = "Continue"
$k2Bin = "C:\Program Files\K2\Bin"
$connStr = "Integrated=True;IsPrimaryLogin=True;Authenticate=True;EncryptedPassword=False;Host=localhost;Port=5555"
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$outputFile = Join-Path $scriptDir "Deploy-K2-Final2-Results.txt"
$exportDir = Join-Path $scriptDir "k2-export\_final2"

if (-not (Test-Path $exportDir)) { New-Item -Path $exportDir -ItemType Directory -Force | Out-Null }

Start-Transcript -Path $outputFile -Force

Write-Host "============================================" -ForegroundColor White
Write-Host "  K2 FINAL2 Deploy" -ForegroundColor White
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
Write-Host "KPRX: $($kprxBytes.Length) bytes" -ForegroundColor Green

# ============================================================
# STEP 1: Show the master ConfigurationManager.config
# ============================================================
Write-Host "`n[1] Master K2 Configuration..." -ForegroundColor Yellow
$masterConfig = "C:\Program Files\K2\Configuration\ConfigurationManager.config"
if (Test-Path $masterConfig) {
    $mcContent = Get-Content $masterConfig -Raw -Encoding UTF8
    Write-Host "ConfigurationManager.config (first 3000 chars):" -ForegroundColor Cyan
    Write-Host $mcContent.Substring(0, [Math]::Min(3000, $mcContent.Length)) -ForegroundColor DarkYellow
} else {
    Write-Host "NOT FOUND! Searching..." -ForegroundColor Red
    Get-ChildItem "C:\Program Files\K2\Configuration" -ErrorAction SilentlyContinue | ForEach-Object {
        Write-Host "  $($_.Name) ($([math]::Round($_.Length/1KB))KB)" -ForegroundColor DarkGray
    }
}

# ============================================================
# STEP 2: Compile deployer to writable dir with correct config
# ============================================================
Write-Host "`n[2] Building deployer..." -ForegroundColor Yellow

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
        
        Console.WriteLine("=== K2 Workflow Deployer ===");
        Console.WriteLine("KPRX: " + kprxFile + " (" + new FileInfo(kprxFile).Length + " bytes)");
        
        try
        {
            Console.WriteLine("Loading KPRX...");
            Process proc = Process.Load(kprxFile);
            Console.WriteLine("SUCCESS: Loaded process");
            Console.WriteLine("  Name: " + proc.Name);
            Console.WriteLine("  FullName: " + proc.FullName);
            Console.WriteLine("  DisplayName: " + proc.DisplayName);
            Console.WriteLine("  Activities: " + proc.Activities.Count);
            Console.WriteLine("  DataFields: " + proc.DataFields.Count);
            Console.WriteLine("  Lines: " + proc.Lines.Count);
            Console.WriteLine("  Guid: " + proc.Guid);
            Console.WriteLine("  FolderPath: " + (proc.FolderPath ?? "null"));
            Console.WriteLine("  CategoryPath: " + (proc.CategoryPath ?? "null"));
            Console.WriteLine("  ProcSetFolderName: " + (proc.ProcSetFolderName ?? "null"));
            
            // Modify for migration
            Console.WriteLine("\nModifying process identity...");
            proc.Guid = Guid.NewGuid();
            proc.Name = newName;
            proc.DisplayName = newName;
            proc.Description = "Migrated from SharePoint Designer";
            try { proc.ProcSetFolderName = folder; } catch (Exception ex) { Console.WriteLine("  ProcSetFolderName err: " + ex.Message); }
            try { proc.CategoryPath = folder; } catch (Exception ex) { Console.WriteLine("  CategoryPath err: " + ex.Message); }
            
            Console.WriteLine("  New Name: " + proc.Name);
            Console.WriteLine("  New Guid: " + proc.Guid);
            
            // Try Deploy()
            Console.WriteLine("\nDeploying...");
            try
            {
                DeploymentResults results = proc.Deploy();
                Console.WriteLine("Deploy() Successful=" + results.Successful);
                if (results.Errors != null && results.Errors.Count > 0)
                    foreach (var e in results.Errors) Console.WriteLine("  ERROR: " + e);
                if (results.Output != null && results.Output.Count > 0)
                    foreach (var o in results.Output) Console.WriteLine("  OUTPUT: " + o);
                    
                if (results.Successful)
                {
                    Console.WriteLine("\n*** DEPLOYMENT SUCCESSFUL! ***");
                    return;
                }
            }
            catch (Exception ex)
            {
                Console.WriteLine("Deploy() failed: " + ex.Message);
                if (ex.InnerException != null) Console.WriteLine("  Inner: " + ex.InnerException.Message);
            }
            
            // Try CreateDeploymentPackage + Execute
            Console.WriteLine("\nTrying CreateDeploymentPackage...");
            try
            {
                DeploymentPackage pkg = proc.CreateDeploymentPackage();
                pkg.WorkflowManagementConnectionString = connStr;
                Console.WriteLine("Package created, targets=" + pkg.Targets.Count);
                
                // Save package for inspection
                try
                {
                    string pkgDir = Path.GetDirectoryName(kprxFile);
                    pkg.Save(pkgDir, "migrated_package");
                    Console.WriteLine("Package saved to: " + pkgDir);
                }
                catch (Exception ex) { Console.WriteLine("Package save: " + ex.Message); }
                
                DeploymentResults r2 = pkg.Execute();
                Console.WriteLine("Package Execute: Successful=" + r2.Successful);
                if (r2.Errors != null && r2.Errors.Count > 0)
                    foreach (var e in r2.Errors) Console.WriteLine("  PKG ERROR: " + e);
                if (r2.Output != null && r2.Output.Count > 0)
                    foreach (var o in r2.Output) Console.WriteLine("  PKG OUTPUT: " + o);
                    
                if (r2.Successful) Console.WriteLine("\n*** PACKAGE DEPLOYMENT SUCCESSFUL! ***");
            }
            catch (Exception ex)
            {
                Console.WriteLine("Package deploy failed: " + ex.Message);
                if (ex.InnerException != null) Console.WriteLine("  Inner: " + ex.InnerException.Message);
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

$csFile = Join-Path $exportDir "K2Deploy.cs"
[System.IO.File]::WriteAllText($csFile, $csSource)

# Write the CORRECT app.config matching K2Studio's pattern
$appConfig = @"
<?xml version="1.0" encoding="utf-8"?>
<configuration>
  <configSections>
    <section name="sourcecode.configuration" type="SourceCode.Configuration.ConfigurationManager, SourceCode.Framework, Version=4.0.0.0, Culture=neutral, PublicKeyToken=16a2c5aaaa1b130d" />
  </configSections>
  <startup useLegacyV2RuntimeActivationPolicy="true">
    <supportedRuntime version="v4.0" />
  </startup>
  <appSettings>
    <add key="HighestSupportedTargetFramework" value="4.5" />
    <add key="DefaultTargetFramework" value="4.0" />
  </appSettings>
  <sourcecode.configuration managerConfigFile="C:\Program Files\K2\Configuration\ConfigurationManager.config" productPath="C:\Program Files\K2\Bin" templateConfigFile="" />
  <connectionStrings>
    <add name="HostServer" connectionString="Integrated=True;IsPrimaryLogin=True;Authenticate=True;EncryptedPassword=False;Host=NINTEX-SP-POC;Port=5555" providerName="K2FIVE" />
  </connectionStrings>
</configuration>
"@

$configFile = Join-Path $exportDir "K2Deploy.exe.config"
[System.IO.File]::WriteAllText($configFile, $appConfig)
Write-Host "Config written (matching K2Studio pattern)" -ForegroundColor Green

# Compile
$cscPath = "C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe"
$exeFile = Join-Path $exportDir "K2Deploy.exe"
$refs = @("$k2Bin\SourceCode.Framework.dll","$k2Bin\SourceCode.Workflow.Authoring.dll","$k2Bin\SourceCode.Workflow.Design.dll","$k2Bin\SourceCode.HostClientAPI.dll")
$refStr = ($refs | ForEach-Object { "/r:`"$_`"" }) -join " "
$compCmd = "& `"$cscPath`" /target:exe /platform:x64 /out:`"$exeFile`" $refStr `"$csFile`" 2>&1"
Write-Host "Compiling..." -ForegroundColor Yellow
$compResult = Invoke-Expression $compCmd
$compResult | ForEach-Object { Write-Host "  $_" -ForegroundColor DarkGray }

if (Test-Path $exeFile) {
    Write-Host "Compiled: $exeFile" -ForegroundColor Green
    
    # Run it!
    Write-Host "`n[3] Running K2Deploy.exe..." -ForegroundColor Yellow
    $result = & $exeFile $kprxFile "SPD_Migrated_Test" "SPD Migration" 2>&1
    $result | ForEach-Object { 
        $color = "DarkGray"
        if ("$_" -like "*FATAL*" -or "$$_" -like "*ERROR*" -or "$_" -like "*failed*") { $color = "Red" }
        elseif ("$_" -like "*SUCCESS*" -or "$_" -like "*Successful=True*") { $color = "Green" }
        elseif ("$_" -like "*Loaded*" -or "$_" -like "*Activities*") { $color = "Cyan" }
        Write-Host "  $_" -ForegroundColor $color
    }
}

# ============================================================
# VERIFICATION
# ============================================================
Write-Host "`n[4] Verifying..." -ForegroundColor Yellow
$mgmt2 = New-Object SourceCode.Workflow.Management.WorkflowManagementServer
$mgmt2.CreateConnection()
$mgmt2.Connection.Open($connStr)
foreach ($ps in $mgmt2.GetProcSets()) {
    $marker = ""
    if ($ps.FullName -like "*SPD*" -or $ps.FullName -like "*Migrat*") { $marker = " <<<< NEW!" }
    Write-Host "  $($ps.FullName) (ID=$($ps.ProcSetID))$marker" -ForegroundColor $(if($marker){"Green"}else{"DarkGray"})
}
$mgmt2.Connection.Close()

Write-Host "`n============================================" -ForegroundColor White
Write-Host "  FINAL2 Deploy Complete!" -ForegroundColor White
Write-Host "============================================" -ForegroundColor White

Stop-Transcript
