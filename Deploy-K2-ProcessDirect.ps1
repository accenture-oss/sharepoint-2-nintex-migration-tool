# ============================================================
#  Deploy-K2-ProcessDirect.ps1
#  
#  FIX: PSObject wrapping issue with Invoke(). 
#  Use direct .NET call instead of reflection.
#  Also: No ServerName/Port on Process - it needs a Project
#  context or direct Deploy() uses internal connection.
#
#  Run in PowerShell ISE on K2 VM
# ============================================================

$ErrorActionPreference = "Continue"
$k2Bin = "C:\Program Files\K2\Bin"
$k2HostBin = "C:\Program Files\K2\Host Server\Bin"
$connStr = "Integrated=True;IsPrimaryLogin=True;Authenticate=True;EncryptedPassword=False;Host=localhost;Port=5555"
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$outputFile = Join-Path $scriptDir "Deploy-K2-ProcessDirect-Results.txt"
$exportDir = Join-Path $scriptDir "k2-export\_procdirect"

if (-not (Test-Path $exportDir)) { New-Item -Path $exportDir -ItemType Directory -Force | Out-Null }

Start-Transcript -Path $outputFile -Force

Write-Host "============================================" -ForegroundColor White
Write-Host "  K2 Deploy - Process Direct Call" -ForegroundColor White  
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
[System.IO.File]::WriteAllText($kprxFile, $kprxStr, (New-Object System.Text.UTF8Encoding $false))
Write-Host "  KPRX saved: $kprxFile" -ForegroundColor Green

# ============================================================
# STEP 2: Use inline C# to call Process.Load() and Deploy()
# C# avoids the PSObject wrapping issue entirely
# ============================================================
Write-Host "`n[2] Compiling C# deployer..." -ForegroundColor Yellow

$csharpCode = @"
using System;
using System.IO;
using SourceCode.Workflow.Authoring;

public class K2Deployer
{
    public static string LoadAndDeploy(string kprxFile)
    {
        string result = "";
        try
        {
            result += "Loading: " + kprxFile + "\n";
            Process process = Process.Load(kprxFile);
            result += "LOADED! Type=" + process.GetType().FullName + "\n";
            result += "Name=" + process.Name + "\n";
            result += "DisplayName=" + process.DisplayName + "\n";
            result += "CategoryPath=" + process.CategoryPath + "\n";
            result += "Guid=" + process.Guid + "\n";
            result += "DeployToCategory=" + process.DeployToCategory + "\n";
            result += "FullName=" + process.FullName + "\n";
            result += "FolderPath=" + process.FolderPath + "\n";
            
            // Ensure DeployToCategory is set
            process.DeployToCategory = true;
            
            // Try Compile first
            result += "\nCompiling...\n";
            try
            {
                var compileResult = process.Compile();
                result += "Compile returned: " + compileResult + "\n";
                if (compileResult != null)
                {
                    result += "CompileResult type: " + compileResult.GetType().FullName + "\n";
                    foreach (var prop in compileResult.GetType().GetProperties())
                    {
                        try { result += "  " + prop.Name + " = " + prop.GetValue(compileResult) + "\n"; } catch {}
                    }
                }
            }
            catch (Exception ex)
            {
                result += "Compile error: " + ex.Message + "\n";
                if (ex.InnerException != null)
                    result += "Compile inner: " + ex.InnerException.Message + "\n";
            }
            
            // Try Deploy()
            result += "\nDeploying...\n";
            try
            {
                var deployResult = process.Deploy();
                result += "*** DEPLOY RETURNED! ***\n";
                if (deployResult != null)
                {
                    result += "DeployResult type: " + deployResult.GetType().FullName + "\n";
                    foreach (var prop in deployResult.GetType().GetProperties())
                    {
                        try { result += "  " + prop.Name + " = " + prop.GetValue(deployResult) + "\n"; } catch {}
                    }
                }
            }
            catch (Exception ex)
            {
                result += "Deploy error: " + ex.Message + "\n";
                if (ex.InnerException != null)
                {
                    result += "Deploy inner: " + ex.InnerException.Message + "\n";
                    if (ex.InnerException.InnerException != null)
                        result += "Deploy inner2: " + ex.InnerException.InnerException.Message + "\n";
                }
            }
            
            // Try Deploy(DeploymentPackage)
            result += "\nTrying Deploy(package)...\n";
            try
            {
                var pkg = process.CreateDeploymentPackage();
                result += "Package created: " + pkg.GetType().FullName + "\n";
                foreach (var prop in pkg.GetType().GetProperties())
                {
                    try { result += "  pkg." + prop.Name + " = " + prop.GetValue(pkg) + "\n"; } catch {}
                }
                
                var deployResult2 = process.Deploy(pkg);
                result += "*** DEPLOY(pkg) RETURNED! ***\n";
                if (deployResult2 != null)
                {
                    foreach (var prop in deployResult2.GetType().GetProperties())
                    {
                        try { result += "  " + prop.Name + " = " + prop.GetValue(deployResult2) + "\n"; } catch {}
                    }
                }
            }
            catch (Exception ex)
            {
                result += "Deploy(pkg) error: " + ex.Message + "\n";
                if (ex.InnerException != null)
                    result += "Deploy(pkg) inner: " + ex.InnerException.Message + "\n";
            }
        }
        catch (Exception ex)
        {
            result += "FATAL: " + ex.ToString() + "\n";
        }
        return result;
    }
}
"@

# Find the Authoring assembly path for reference
$authoringDll = Get-ChildItem "$k2Bin\SourceCode.Workflow.Authoring.dll" -ErrorAction SilentlyContinue
if (-not $authoringDll) {
    $authoringDll = Get-ChildItem "$k2HostBin\SourceCode.Workflow.Authoring.dll" -ErrorAction SilentlyContinue
}
Write-Host "  Authoring DLL: $($authoringDll.FullName)" -ForegroundColor Green

# Get all referenced assemblies
$refDlls = @($authoringDll.FullName)
# Add dependencies
Get-ChildItem "$k2Bin\SourceCode.Workflow.Design*.dll" -ErrorAction SilentlyContinue | ForEach-Object { $refDlls += $_.FullName }
Get-ChildItem "$k2Bin\SourceCode.Framework*.dll" -ErrorAction SilentlyContinue | ForEach-Object { $refDlls += $_.FullName }
Get-ChildItem "$k2Bin\SourceCode.Hosting*.dll" -ErrorAction SilentlyContinue | ForEach-Object { $refDlls += $_.FullName }

try {
    Add-Type -TypeDefinition $csharpCode -ReferencedAssemblies $refDlls -ErrorAction Stop
    Write-Host "  Compiled!" -ForegroundColor Green
} catch {
    Write-Host "  Compile error: $($_.Exception.Message)" -ForegroundColor Red
    # Try with just the authoring DLL
    try {
        Add-Type -TypeDefinition $csharpCode -ReferencedAssemblies @($authoringDll.FullName) -ErrorAction Stop
        Write-Host "  Compiled (authoring only)!" -ForegroundColor Green
    } catch {
        Write-Host "  Still failed: $($_.Exception.Message)" -ForegroundColor Red
    }
}

# ============================================================
# STEP 3: Execute!
# ============================================================
Write-Host "`n[3] Executing Load + Deploy..." -ForegroundColor Yellow

try {
    $result = [K2Deployer]::LoadAndDeploy([string]$kprxFile)
    Write-Host $result -ForegroundColor Cyan
} catch {
    Write-Host "  Execution error: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "  $($_.Exception.ToString())" -ForegroundColor DarkRed
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
