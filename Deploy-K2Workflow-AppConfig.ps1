# ============================================================
#  Deploy-K2Workflow-AppConfig.ps1
#  
#  DefaultProcess needs K2 config nodes. We create a proper  
#  app.config for powershell.exe, then use Process.Load() + Deploy()
#
#  Run in PowerShell ISE on K2 VM
# ============================================================

$ErrorActionPreference = "Continue"
$k2Bin = "C:\Program Files\K2\Bin"
$connStr = "Integrated=True;IsPrimaryLogin=True;Authenticate=True;EncryptedPassword=False;Host=localhost;Port=5555"
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$outputFile = Join-Path $scriptDir "Deploy-K2Workflow-AppConfig-Results.txt"
$exportDir = Join-Path $scriptDir "k2-export\_appconfig"

if (-not (Test-Path $exportDir)) { New-Item -Path $exportDir -ItemType Directory -Force | Out-Null }

Start-Transcript -Path $outputFile -Force

Write-Host "============================================" -ForegroundColor White
Write-Host "  K2 Deploy via Process.Load + Deploy" -ForegroundColor White
Write-Host "============================================`n" -ForegroundColor White

# ============================================================
# STEP 1: Find K2's own app.config to copy settings from
# ============================================================
Write-Host "[1] Finding K2 config files..." -ForegroundColor Yellow
$k2Configs = Get-ChildItem "C:\Program Files\K2" -Filter "*.config" -Recurse -ErrorAction SilentlyContinue | Where-Object { $_.Length -gt 100 -and $_.Name -like "*.exe.config" }
foreach ($cfg in $k2Configs | Select-Object -First 10) {
    Write-Host "  $($cfg.FullName) ($([math]::Round($cfg.Length/1KB))KB)" -ForegroundColor DarkGray
}

# Find K2 Designer or K2 Studio config (that's what Process SDK uses)
$designerConfig = Get-ChildItem "C:\Program Files\K2" -Filter "*.config" -Recurse -ErrorAction SilentlyContinue | Where-Object { $_.Name -like "*Design*" -or $_.Name -like "*Studio*" -or $_.Name -like "*Workspace*" } | Select-Object -First 5
foreach ($dc in $designerConfig) {
    Write-Host "  DESIGNER: $($dc.FullName) ($([math]::Round($dc.Length/1KB))KB)" -ForegroundColor Cyan
}

# Also check K2 Server's own config
$serverConfig = Get-ChildItem "C:\Program Files\K2" -Filter "K2HostServer.exe.config" -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
if ($serverConfig) {
    Write-Host "  SERVER: $($serverConfig.FullName)" -ForegroundColor Green
    # Read config to find the K2 sections
    $cfgContent = Get-Content $serverConfig.FullName -Raw -Encoding UTF8
    # Extract configSections
    $sectionsMatch = [regex]::Match($cfgContent, '(?s)<configSections>(.*?)</configSections>')
    if ($sectionsMatch.Success) {
        Write-Host "  Config sections (first 1000 chars):" -ForegroundColor Yellow
        Write-Host $sectionsMatch.Value.Substring(0, [Math]::Min(1000, $sectionsMatch.Value.Length)) -ForegroundColor DarkYellow
    }
}

# ============================================================
# STEP 2: Check what config the DefaultProcess actually needs
# ============================================================
Write-Host "`n[2] Checking config requirement..." -ForegroundColor Yellow

# Load assemblies
foreach ($dll in @("SourceCode.Framework.dll","SourceCode.HostClientAPI.dll","SourceCode.Workflow.Authoring.dll","SourceCode.Workflow.Design.dll","SourceCode.Workflow.Management.dll","SourceCode.Deployment.Management.dll","SourceCode.EnvironmentSettings.Client.dll","SourceCode.ComponentModel.dll")) {
    $p = Join-Path $k2Bin $dll; if (Test-Path $p) { [System.Reflection.Assembly]::LoadFrom($p) | Out-Null }
}

# Try to get the exact error message with more detail
try {
    $proc = New-Object SourceCode.Workflow.Design.DefaultProcess
} catch {
    Write-Host "  Error: $($_.Exception.Message)" -ForegroundColor Red
    if ($_.Exception.InnerException) {
        Write-Host "  Inner: $($_.Exception.InnerException.Message)" -ForegroundColor Red
        if ($_.Exception.InnerException.InnerException) {
            Write-Host "  Inner2: $($_.Exception.InnerException.InnerException.Message)" -ForegroundColor Red
        }
    }
}

# ============================================================
# STEP 3: Run Process.Load via a compiled C# exe with proper config
# ============================================================
Write-Host "`n[3] Building C# deploy tool with proper config..." -ForegroundColor Yellow

# Write C# source
$csSource = @"
using System;
using System.IO;
using SourceCode.Workflow.Design;
using SourceCode.Workflow.Authoring;
using SourceCode.Framework.Deployment;

class K2Deployer
{
    static void Main(string[] args)
    {
        if (args.Length < 1) { Console.WriteLine("Usage: K2Deployer.exe <kprx_file> [new_name] [folder]"); return; }
        
        string kprxFile = args[0];
        string newName = args.Length > 1 ? args[1] : "SPD_Migrated_WF";
        string folder = args.Length > 2 ? args[2] : "SPD Migration";
        string connStr = "Integrated=True;IsPrimaryLogin=True;Authenticate=True;EncryptedPassword=False;Host=localhost;Port=5555";
        
        Console.WriteLine("K2 Workflow Deployer");
        Console.WriteLine("  KPRX: " + kprxFile);
        Console.WriteLine("  Name: " + newName);
        Console.WriteLine("  Folder: " + folder);
        
        try
        {
            // Load the KPRX into a Process object
            Console.WriteLine("[1] Loading KPRX...");
            Process proc = Process.Load(kprxFile);
            Console.WriteLine("  Loaded: Name=" + proc.Name + " FullName=" + proc.FullName);
            Console.WriteLine("  Activities: " + proc.Activities.Count);
            Console.WriteLine("  DataFields: " + proc.DataFields.Count);
            Console.WriteLine("  Lines: " + proc.Lines.Count);
            Console.WriteLine("  Guid: " + proc.Guid);
            Console.WriteLine("  FolderPath: " + proc.FolderPath);
            
            // Modify for migration
            Console.WriteLine("[2] Modifying for migration...");
            proc.Name = newName;
            proc.DisplayName = newName;
            proc.Description = "Migrated from SharePoint Designer";
            proc.Guid = Guid.NewGuid(); // NEW GUID = NEW PROCESS
            
            // Set folder
            try { proc.ProcSetFolderName = folder; } catch (Exception ex) { Console.WriteLine("  ProcSetFolderName: " + ex.Message); }
            try { proc.CategoryPath = folder; } catch (Exception ex) { Console.WriteLine("  CategoryPath: " + ex.Message); }
            
            Console.WriteLine("  New Name: " + proc.Name);
            Console.WriteLine("  New Guid: " + proc.Guid);
            
            // Deploy
            Console.WriteLine("[3] Deploying...");
            DeploymentResults results = proc.Deploy();
            Console.WriteLine("  Deploy Result: Successful=" + results.Successful);
            
            if (results.Errors != null && results.Errors.Count > 0)
            {
                foreach (var err in results.Errors)
                    Console.WriteLine("  ERROR: " + err);
            }
            if (results.Output != null && results.Output.Count > 0)
            {
                foreach (var line in results.Output)
                    Console.WriteLine("  OUTPUT: " + line);
            }
            
            // Also try CreateDeploymentPackage + Execute
            if (!results.Successful)
            {
                Console.WriteLine("[4] Trying CreateDeploymentPackage...");
                try
                {
                    DeploymentPackage pkg = proc.CreateDeploymentPackage();
                    pkg.WorkflowManagementConnectionString = connStr;
                    Console.WriteLine("  Package created, targets: " + pkg.Targets.Count);
                    
                    DeploymentResults pkgResults = pkg.Execute();
                    Console.WriteLine("  Package Execute: Successful=" + pkgResults.Successful);
                    if (pkgResults.Errors != null)
                        foreach (var err in pkgResults.Errors)
                            Console.WriteLine("  PKG ERROR: " + err);
                }
                catch (Exception ex)
                {
                    Console.WriteLine("  Package failed: " + ex.Message);
                }
            }
            
            Console.WriteLine("[5] DONE!");
        }
        catch (Exception ex)
        {
            Console.WriteLine("FATAL: " + ex.Message);
            if (ex.InnerException != null)
                Console.WriteLine("  Inner: " + ex.InnerException.Message);
        }
    }
}
"@

$csFile = Join-Path $exportDir "K2Deployer.cs"
[System.IO.File]::WriteAllText($csFile, $csSource)
Write-Host "  C# source written" -ForegroundColor Green

# Write app.config for the exe (copy K2 server's config sections)
$appConfig = @"
<?xml version="1.0" encoding="utf-8"?>
<configuration>
  <configSections>
    <section name="SourceCode.Workflow.Design" type="SourceCode.Workflow.Authoring.WorkflowDesignConfigurationSectionHandler, SourceCode.Workflow.Authoring, Version=4.0.0.0, Culture=neutral, PublicKeyToken=16a2c5aaaa1b130d" />
  </configSections>
  <SourceCode.Workflow.Design>
    <Extenders basedir="$k2Bin">
      <Extender type="SourceCode.Workflow.Design.DefaultProcess, SourceCode.Workflow.Design, Version=4.0.0.0, Culture=neutral, PublicKeyToken=16a2c5aaaa1b130d" />
    </Extenders>
    <DeploymentTargets>
      <Target assembly="SourceCode.Workflow.Authoring" type="SourceCode.Workflow.Authoring.ProcessDeploymentTarget" />
    </DeploymentTargets>
  </SourceCode.Workflow.Design>
  <runtime>
    <assemblyBinding xmlns="urn:schemas-microsoft-com:asm.v1">
      <probing privatePath="$k2Bin" />
    </assemblyBinding>
  </runtime>
</configuration>
"@

$configFile = Join-Path $exportDir "K2Deployer.exe.config"
[System.IO.File]::WriteAllText($configFile, $appConfig)
Write-Host "  App.config written" -ForegroundColor Green

# Compile with csc.exe
$cscPath = "C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe"
$exeFile = Join-Path $exportDir "K2Deployer.exe"
$refs = @(
    (Join-Path $k2Bin "SourceCode.Framework.dll"),
    (Join-Path $k2Bin "SourceCode.Workflow.Authoring.dll"),
    (Join-Path $k2Bin "SourceCode.Workflow.Design.dll"),
    (Join-Path $k2Bin "SourceCode.HostClientAPI.dll")
)
$refArgs = ($refs | ForEach-Object { "/r:`"$_`"" }) -join " "

$compileCmd = "& `"$cscPath`" /target:exe /out:`"$exeFile`" $refArgs `"$csFile`" 2>&1"
Write-Host "  Compiling..." -ForegroundColor Yellow
$compileResult = Invoke-Expression $compileCmd
$compileResult | ForEach-Object { Write-Host "  $_" -ForegroundColor DarkGray }

if (Test-Path $exeFile) {
    Write-Host "  Compiled: $exeFile" -ForegroundColor Green
    
    # Get the KPRX file
    $mgmt = New-Object SourceCode.Workflow.Management.WorkflowManagementServer
    $mgmt.CreateConnection()
    $mgmt.Connection.Open($connStr)
    $kprxBytes = $mgmt.GetProcessKprx(13)
    $kprxFile = Join-Path $exportDir "TestKprxWF.kprx"
    [System.IO.File]::WriteAllBytes($kprxFile, $kprxBytes)
    $mgmt.Connection.Close()
    Write-Host "  KPRX saved: $kprxFile ($($kprxBytes.Length) bytes)" -ForegroundColor Green
    
    # Run the deployer
    Write-Host "`n[4] Running K2Deployer.exe..." -ForegroundColor Yellow
    $deployResult = & $exeFile $kprxFile "SPD_Migrated_Test" "SPD Migration" 2>&1
    $deployResult | ForEach-Object { Write-Host "  $_" -ForegroundColor $(if("$_" -like "*ERROR*" -or "$_" -like "*FATAL*"){"Red"}elseif("$_" -like "*SUCCESS*" -or "$_" -like "*DONE*"){"Green"}else{"DarkGray"}) }
} else {
    Write-Host "  Compilation failed!" -ForegroundColor Red
}

# ============================================================ 
# STEP 4b: Also try the K2 SmartForms WorkflowDesigner approach
# Check if there's a K2 exe we can use directly
# ============================================================
Write-Host "`n[5] Checking K2 tools..." -ForegroundColor Yellow
$k2Exes = Get-ChildItem "C:\Program Files\K2" -Filter "*.exe" -Recurse -ErrorAction SilentlyContinue | Where-Object { $_.Name -like "*Deploy*" -or $_.Name -like "*Design*" -or $_.Name -like "*Import*" -or $_.Name -like "*Package*" } | Select-Object -First 10
foreach ($exe in $k2Exes) {
    Write-Host "  $($exe.FullName)" -ForegroundColor Cyan
}

# Also check if K2 has a command-line deployment tool
$k2Tools = Get-ChildItem "C:\Program Files\K2" -Filter "*.exe" -Recurse -ErrorAction SilentlyContinue | Select-Object -First 30
foreach ($tool in $k2Tools) {
    Write-Host "  TOOL: $($tool.Name) ($([math]::Round($tool.Length/1KB))KB)" -ForegroundColor DarkGray
}

# ============================================================
# VERIFICATION
# ============================================================
Write-Host "`n[6] Verifying processes..." -ForegroundColor Yellow
$mgmt2 = New-Object SourceCode.Workflow.Management.WorkflowManagementServer
$mgmt2.CreateConnection()
$mgmt2.Connection.Open($connStr)
$procSets = $mgmt2.GetProcSets()
foreach ($ps in $procSets) {
    $marker = ""
    if ($ps.FullName -like "*SPD*" -or $ps.FullName -like "*Migrat*") { $marker = " <<<< NEW!" }
    Write-Host "  $($ps.FullName) (ID=$($ps.ProcSetID))$marker" -ForegroundColor $(if($marker){"Green"}else{"DarkGray"})
}
$mgmt2.Connection.Close()

Write-Host "`n============================================" -ForegroundColor White
Write-Host "  Deploy Complete!" -ForegroundColor White
Write-Host "============================================" -ForegroundColor White

Stop-Transcript
