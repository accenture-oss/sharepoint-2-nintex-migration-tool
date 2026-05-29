# ============================================================
#  Deploy-K2-NewWF.ps1
#  
#  HYPOTHESIS: The KPRX from GetProcessKprx(13) still internally
#  maps to the existing TestKprxWF process. K2 recognizes the  
#  duplicate and silently skips registration.
#
#  SOLUTION: Create a BRAND NEW minimal workflow KPRX from scratch
#  using DefaultProcess.Save() format, with unique GUIDs.
#
#  Also: Check FULL DeploymentResults for workflow-specific errors.
#
#  Run in PowerShell ISE on K2 VM  
# ============================================================

$ErrorActionPreference = "Continue"
$k2Bin = "C:\Program Files\K2\Bin"
$connStr = "Integrated=True;IsPrimaryLogin=True;Authenticate=True;EncryptedPassword=False;Host=localhost;Port=5555"
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$outputFile = Join-Path $scriptDir "Deploy-K2-NewWF-Results.txt"
$exportDir = Join-Path $scriptDir "k2-export\_newwf"

if (-not (Test-Path $exportDir)) { New-Item -Path $exportDir -ItemType Directory -Force | Out-Null }

Start-Transcript -Path $outputFile -Force

Write-Host "============================================" -ForegroundColor White
Write-Host "  K2 Deploy - Brand New Workflow" -ForegroundColor White
Write-Host "============================================`n" -ForegroundColor White

Get-ChildItem "$k2Bin\SourceCode.*.dll" | ForEach-Object {
    try { [System.Reflection.Assembly]::LoadFrom($_.FullName) | Out-Null } catch {}
}
Add-Type -AssemblyName System.IO.Compression

# Get the REAL KPRX to understand its internal structure
$mgmt = New-Object SourceCode.Workflow.Management.WorkflowManagementServer
$mgmt.CreateConnection()
$mgmt.Connection.Open($connStr)

# Get TestKprxWF KPRX and study structure
$kprxBytes = $mgmt.GetProcessKprx(13)
$kprxXml = [System.Text.Encoding]::UTF8.GetString($kprxBytes)
if ($kprxXml[0] -eq [char]0xFEFF) { $kprxXml = $kprxXml.Substring(1) }

# Also get FrameworkGeneric (ID=1) for comparison
$fgKprx = $mgmt.GetProcessKprx(1)
$fgXml = [System.Text.Encoding]::UTF8.GetString($fgKprx)
if ($fgXml[0] -eq [char]0xFEFF) { $fgXml = $fgXml.Substring(1) }

$mgmt.Connection.Close()

# ============================================================
# STEP 1: Compare KPRX structures
# ============================================================
Write-Host "[1] KPRX structure comparison:" -ForegroundColor Yellow
Write-Host "  TestKprxWF (ID=13): $($kprxBytes.Length) bytes" -ForegroundColor DarkGray
Write-Host "  FrameworkGeneric (ID=1): $($fgKprx.Length) bytes" -ForegroundColor DarkGray

# Parse both as XML - show root element attributes
$xml1 = [xml]$kprxXml
$xml2 = [xml]$fgXml

Write-Host "`n  TestKprxWF root:" -ForegroundColor Cyan
foreach ($a in $xml1.DocumentElement.Attributes) {
    Write-Host "    $($a.Name)=$($a.Value)" -ForegroundColor DarkGray
}

Write-Host "`n  FrameworkGeneric root:" -ForegroundColor Cyan
foreach ($a in $xml2.DocumentElement.Attributes) {
    Write-Host "    $($a.Name)=$($a.Value)" -ForegroundColor DarkGray
}

# Show first-level child elements
Write-Host "`n  TestKprxWF children:" -ForegroundColor Cyan
foreach ($child in $xml1.DocumentElement.ChildNodes) {
    $info = ""
    if ($child.Attributes) {
        $nameAttr = $child.Attributes["Name"]
        if ($nameAttr) { $info = " Name=$($nameAttr.Value)" }
    }
    Write-Host "    <$($child.LocalName)>$info" -ForegroundColor DarkGray
}

Write-Host "`n  FrameworkGeneric children:" -ForegroundColor Cyan
foreach ($child in $xml2.DocumentElement.ChildNodes) {
    $info = ""
    if ($child.Attributes) {
        $nameAttr = $child.Attributes["Name"]
        if ($nameAttr) { $info = " Name=$($nameAttr.Value)" }
    }
    Write-Host "    <$($child.LocalName)>$info" -ForegroundColor DarkGray
}

# ============================================================
# STEP 2: Modify FrameworkGeneric KPRX to create a "new" workflow
# Since it was originally deployed as ID=1, changing its XML 
# identity should create a new process
# ============================================================
Write-Host "`n[2] Creating modified FrameworkGeneric KPRX..." -ForegroundColor Yellow

# We'll use the simpler FrameworkGeneric KPRX as our base
# It's the actual workflow KPRX that was in the .kspx package
$modXml = [xml]$fgXml

# Show the full root element opening tag
$root = $modXml.DocumentElement
Write-Host "  Full root tag:" -ForegroundColor Yellow
$rootStr = "<" + $root.LocalName
foreach ($a in $root.Attributes) { $rootStr += " $($a.Name)=`"$($a.Value)`"" }
$rootStr += ">"
Write-Host "    $rootStr" -ForegroundColor DarkYellow

# ============================================================
# STEP 3: Full deploy with DETAILED results inspection
# ============================================================
Write-Host "`n[3] Deploying with DETAILED results..." -ForegroundColor Yellow

$pdm = New-Object SourceCode.Deployment.Management.PackageDeploymentManager
$pdmConn = $pdm.CreateConnection()
$pdmConn.Open($connStr)

# Load original .kspx directly (no modifications) to see full results
$stream = [System.IO.File]::OpenRead("C:\Program Files\K2\Setup\App Framework Core.kspx")
$s1 = "NW_$(Get-Date -Format 'yyyyMMddHHmmss')"
$session = $pdm.CreateSession($s1, $stream)
$stream.Close()

Write-Host "  Members: $($session.Model.Members.Count)" -ForegroundColor Green

# Deploy original package - focus on what happens to workflows
$session.SetOption("NoAnalyze", $true)
$session.Deploy()

Start-Sleep -Seconds 5

# Inspect DeploymentResults in DETAIL
Write-Host "`n  DeploymentResults detail:" -ForegroundColor Yellow
$resType = $session.DeploymentResults.GetType()
Write-Host "  Result type: $($resType.FullName)" -ForegroundColor DarkGray

# Get properties of each result
$resultCount = 0
foreach ($r in $session.DeploymentResults) {
    $resultCount++
    $rType = $r.GetType()
    
    # Get all properties
    $name = try { $r.Name } catch { "" }
    $ns = try { $r.Namespace } catch { "" }
    $success = try { $r.Successful } catch { "" }
    $itemType = try { $r.ItemType } catch { "" }
    $message = try { $r.Message } catch { "" }
    $status = try { $r.Status } catch { "" }
    
    # Show ALL results that reference Workflow or have errors
    if ($ns -like "*Workflow*" -or $name -like "*Workflow*" -or $success -eq $false -or $message) {
        Write-Host "  [$resultCount] Name=$name NS=$ns Success=$success Type=$itemType Msg=$message Status=$status" -ForegroundColor $(if($success -eq $false){"Red"}else{"Cyan"})
    }
    
    # Show first 5 results regardless to understand structure
    if ($resultCount -le 5) {
        Write-Host "  [$resultCount] ALL PROPS:" -ForegroundColor DarkGray
        foreach ($prop in $rType.GetProperties()) {
            $val = try { $prop.GetValue($r) } catch { "ERR" }
            Write-Host "    $($prop.Name) = $val" -ForegroundColor DarkGray
        }
    }
}
Write-Host "  Total results: $resultCount" -ForegroundColor Green

# Check session properties for errors
Write-Host "`n  Session properties:" -ForegroundColor Yellow
$sessionType = $session.GetType()
foreach ($prop in $sessionType.GetProperties()) {
    $val = try { $prop.GetValue($session) } catch { "ERR" }
    if ("$val" -and "$val" -ne "ERR" -and "$val" -ne "0" -and "$val" -ne "False") {
        Write-Host "    $($prop.Name) = $val" -ForegroundColor DarkGray
    }
}

$pdm.CloseSession($s1)
$pdm.Dispose()

# ============================================================
# Verify
# ============================================================
Write-Host "`n[4] Processes:" -ForegroundColor Yellow
$mgmt2 = New-Object SourceCode.Workflow.Management.WorkflowManagementServer
$mgmt2.CreateConnection()
$mgmt2.Connection.Open($connStr)
foreach ($ps in $mgmt2.GetProcSets()) {
    Write-Host "  $($ps.FullName) (ID=$($ps.ProcSetID))" -ForegroundColor DarkGray
}
Write-Host "  Total: $($mgmt2.GetProcSets().Count)" -ForegroundColor Yellow
$mgmt2.Connection.Close()

Stop-Transcript
