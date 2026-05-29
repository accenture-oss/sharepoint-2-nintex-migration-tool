# ============================================================
#  Deploy-K2Workflow-FINAL.ps1
#  
#  THE DEFINITIVE APPROACH: Use the Process SDK directly
#  
#  SourceCode.Workflow.Authoring.Process has:
#    - Deploy() -> DeploymentResults 
#    - CreateDeploymentPackage() -> DeploymentPackage
#    - Save(fileName) -> writes KPRX to file
#  
#  SourceCode.Framework.Deployment.DeploymentPackage has:
#    - Execute() -> DeploymentResults
#    - WorkflowManagementConnectionString (setter)
#
#  Strategy: Deserialize KPRX XML -> DefaultProcess -> Deploy()
#  OR: DefaultProcess -> CreateDeploymentPackage() -> Execute()
#
#  Run in PowerShell ISE on K2 VM
# ============================================================

$ErrorActionPreference = "Continue"
$k2Bin = "C:\Program Files\K2\Bin"
$connStr = "Integrated=True;IsPrimaryLogin=True;Authenticate=True;EncryptedPassword=False;Host=localhost;Port=5555"
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$outputFile = Join-Path $scriptDir "Deploy-K2Workflow-FINAL-Results.txt"
$exportDir = Join-Path $scriptDir "k2-export\_final_deploy"

if (-not (Test-Path $exportDir)) { New-Item -Path $exportDir -ItemType Directory -Force | Out-Null }

Start-Transcript -Path $outputFile -Force

Write-Host "============================================" -ForegroundColor White
Write-Host "  K2 FINAL Workflow Deploy" -ForegroundColor White
Write-Host "  Strategy: Process SDK Direct Deploy" -ForegroundColor White
Write-Host "============================================`n" -ForegroundColor White

# Load ALL K2 assemblies
Write-Host "[0] Loading assemblies..." -ForegroundColor Yellow
$assemblyNames = @(
    "SourceCode.Framework.dll",
    "SourceCode.HostClientAPI.dll",
    "SourceCode.Workflow.Authoring.dll",
    "SourceCode.Workflow.Design.dll",
    "SourceCode.Workflow.Management.dll",
    "SourceCode.Workflow.Client.dll",
    "SourceCode.Deployment.Management.dll",
    "SourceCode.EnvironmentSettings.Client.dll",
    "SourceCode.ComponentModel.dll"
)
foreach ($name in $assemblyNames) {
    $p = Join-Path $k2Bin $name
    if (Test-Path $p) {
        [System.Reflection.Assembly]::LoadFrom($p) | Out-Null
        Write-Host "  Loaded: $name" -ForegroundColor DarkGray
    }
}

# ============================================================
# STEP 1: Get KPRX from existing workflow
# ============================================================
Write-Host "`n[1] Getting TestKprxWF KPRX..." -ForegroundColor Yellow
$mgmt = New-Object SourceCode.Workflow.Management.WorkflowManagementServer
$mgmt.CreateConnection()
$mgmt.Connection.Open($connStr)
$kprxBytes = $mgmt.GetProcessKprx(13) # TestKprxWF
$kprxXml = [System.Text.Encoding]::UTF8.GetString($kprxBytes)
if ($kprxXml[0] -eq [char]0xFEFF) { $kprxXml = $kprxXml.Substring(1) }
Write-Host "  KPRX: $($kprxBytes.Length) bytes" -ForegroundColor Green
$mgmt.Connection.Close()

# Save to file for reference
$kprxFile = Join-Path $exportDir "TestKprxWF.kprx"
[System.IO.File]::WriteAllBytes($kprxFile, $kprxBytes)

# ============================================================
# STEP 2: List ALL methods on Process class 
# ============================================================
Write-Host "`n[2] Process class full API..." -ForegroundColor Yellow
$processType = [SourceCode.Workflow.Design.DefaultProcess]
$processType.GetMethods() | Where-Object { $_.DeclaringType.FullName -like "SourceCode.*" } | Sort-Object Name | ForEach-Object {
    $ps = ($_.GetParameters() | ForEach-Object { "$($_.ParameterType.Name) $($_.Name)" }) -join ", "
    Write-Host "  $($_.ReturnType.Name) $($_.Name)($ps)" -ForegroundColor DarkGray
}

# ============================================================
# STEP 3: Try to deserialize KPRX into DefaultProcess
# ============================================================
Write-Host "`n[3] Deserializing KPRX into DefaultProcess..." -ForegroundColor Yellow

# Method A: Try Load from file
try {
    # Check for static Load methods
    $loadMethods = $processType.GetMethods([System.Reflection.BindingFlags]::Static -bor [System.Reflection.BindingFlags]::Public) | Where-Object { $_.Name -eq "Load" -or $_.Name -eq "Open" -or $_.Name -eq "LoadFrom" }
    foreach ($lm in $loadMethods) {
        $lps = ($lm.GetParameters() | ForEach-Object { "$($_.ParameterType.Name) $($_.Name)" }) -join ", "
        Write-Host "  Static: $($lm.ReturnType.Name) $($lm.Name)($lps)" -ForegroundColor Cyan
    }
} catch {}

# Method B: Construct DefaultProcess and use XmlSerializer or direct XML load
try {
    $proc = New-Object SourceCode.Workflow.Design.DefaultProcess
    Write-Host "  DefaultProcess created: Name=$($proc.Name)" -ForegroundColor Green

    # Try to load from file using Save/Load pattern
    # The IProcess interface has Save(fileName), check for Load 
    $allMethods = $proc.GetType().GetMethods()
    $loadSaveMethods = $allMethods | Where-Object { $_.Name -like "Load*" -or $_.Name -like "Save*" -or $_.Name -like "Open*" -or $_.Name -like "Read*" -or $_.Name -like "From*" -or $_.Name -like "Import*" -or $_.Name -like "Deseriali*" }
    Write-Host "  Load/Save methods:" -ForegroundColor Yellow
    foreach ($m in $loadSaveMethods) {
        $mps = ($m.GetParameters() | ForEach-Object { "$($_.ParameterType.Name) $($_.Name)" }) -join ", "
        Write-Host "    $($m.ReturnType.Name) $($m.Name)($mps)" -ForegroundColor DarkCyan
    }
} catch {
    Write-Host "  DefaultProcess creation failed: $($_.Exception.Message)" -ForegroundColor Red
}

# Method C: Use XmlSerializer
Write-Host "`n  Trying XmlSerializer..." -ForegroundColor Yellow
try {
    $serializer = New-Object System.Xml.Serialization.XmlSerializer($processType)
    $reader = New-Object System.IO.StringReader($kprxXml)
    $deserializedProc = $serializer.Deserialize($reader)
    $reader.Close()
    Write-Host "  XmlSerializer SUCCESS! Name=$($deserializedProc.Name) FullName=$($deserializedProc.FullName)" -ForegroundColor Green
} catch {
    Write-Host "  XmlSerializer failed: $($_.Exception.Message)" -ForegroundColor Red
}

# Method D: Use XmlDocument to load and then construct the type
Write-Host "`n  Trying Process.Load from TextReader..." -ForegroundColor Yellow
try {
    # IProcess.Save(String fileName) suggests there might be a Load
    # SourceCode.Workflow.Authoring.Process has SaveAs(fileName) 
    # Check base class for static factory methods  
    $baseType = [SourceCode.Workflow.Authoring.Process]
    $staticMethods = $baseType.GetMethods([System.Reflection.BindingFlags]::Static -bor [System.Reflection.BindingFlags]::Public -bor [System.Reflection.BindingFlags]::NonPublic)
    Write-Host "  Process base static methods:" -ForegroundColor Yellow
    foreach ($sm in $staticMethods) {
        $sps = ($sm.GetParameters() | ForEach-Object { "$($_.ParameterType.Name) $($_.Name)" }) -join ", "
        Write-Host "    $($sm.ReturnType.Name) $($sm.Name)($sps) [Public=$($sm.IsPublic)]" -ForegroundColor DarkCyan
    }
    
    # Also check instance Load methods
    $instanceLoad = $baseType.GetMethods() | Where-Object { $_.Name -like "Load*" -or $_.Name -like "Open*" }
    foreach ($il in $instanceLoad) {
        $ips = ($il.GetParameters() | ForEach-Object { "$($_.ParameterType.Name) $($_.Name)" }) -join ", "
        Write-Host "    INSTANCE: $($il.ReturnType.Name) $($il.Name)($ips)" -ForegroundColor DarkYellow
    }
} catch {
    Write-Host "  Base type scan failed: $($_.Exception.Message)" -ForegroundColor Red
}

# Method E: Check IProcess for Load
Write-Host "`n  Checking IProcess interface..." -ForegroundColor Yellow
try {
    $iprocType = [SourceCode.Workflow.Authoring.IProcess]
    $iprocType.GetMethods() | ForEach-Object {
        $ips = ($_.GetParameters() | ForEach-Object { "$($_.ParameterType.Name) $($_.Name)" }) -join ", "
        Write-Host "    IProcess: $($_.ReturnType.Name) $($_.Name)($ips)" -ForegroundColor DarkCyan
    }
} catch {}

# ============================================================
# STEP 4: Try DeploymentPackage approach
# ============================================================
Write-Host "`n[4] DeploymentPackage approach..." -ForegroundColor Yellow
try {
    $pkg = New-Object SourceCode.Framework.Deployment.DeploymentPackage
    Write-Host "  DeploymentPackage created" -ForegroundColor Green
    
    # Set connection strings  
    $pkg.WorkflowManagementConnectionString = $connStr
    Write-Host "  WorkflowManagementConnectionString set" -ForegroundColor Green
    
    # Try SmartObjectConnectionString too
    try { $pkg.SmartObjectConnectionString = $connStr } catch {}
    
    # List all properties
    $pkg.GetType().GetProperties() | ForEach-Object {
        $val = try { $_.GetValue($pkg) } catch { "ERR" }
        Write-Host "  PKG: $($_.Name) = $val" -ForegroundColor DarkGray
    }
    
    # Check if we can add a process/deploy target
    $targets = $pkg.Targets
    Write-Host "  Targets count: $($targets.Count)" -ForegroundColor DarkGray
    
    # Try CreateDeploymentPackage from Process
    $proc2 = New-Object SourceCode.Workflow.Design.DefaultProcess
    $proc2.Name = "SPD_Migrated_Test"
    
    Write-Host "  Trying proc.CreateDeploymentPackage()..." -ForegroundColor Yellow
    try {
        $createdPkg = $proc2.CreateDeploymentPackage()
        Write-Host "  CreateDeploymentPackage SUCCESS!" -ForegroundColor Green
        $createdPkg.GetType().GetProperties() | ForEach-Object {
            $val = try { $_.GetValue($createdPkg) } catch { "ERR" }
            Write-Host "    $($_.Name) = $val" -ForegroundColor DarkYellow
        }
    } catch {
        Write-Host "  CreateDeploymentPackage failed: $($_.Exception.Message)" -ForegroundColor Red
    }
    
    # Try proc.Deploy() directly
    Write-Host "  Trying proc.Deploy()..." -ForegroundColor Yellow
    try {
        $deployResult = $proc2.Deploy()
        Write-Host "  Deploy SUCCESS! Result=$($deployResult.Successful)" -ForegroundColor Green
        if ($deployResult.Errors -and $deployResult.Errors.Count -gt 0) {
            foreach ($err in $deployResult.Errors) { Write-Host "    Error: $err" -ForegroundColor Red }
        }
        if ($deployResult.Output -and $deployResult.Output.Count -gt 0) {
            foreach ($out in $deployResult.Output) { Write-Host "    Output: $out" -ForegroundColor DarkYellow }
        }
    } catch {
        Write-Host "  Deploy failed: $($_.Exception.Message)" -ForegroundColor Red
        if ($_.Exception.InnerException) { Write-Host "  Inner: $($_.Exception.InnerException.Message)" -ForegroundColor DarkRed }
    }
} catch {
    Write-Host "  DeploymentPackage failed: $($_.Exception.Message)" -ForegroundColor Red
}

# ============================================================
# STEP 5: SaveAs the KPRX to temp, try Load + Deploy
# ============================================================
Write-Host "`n[5] SaveAs + Load pattern..." -ForegroundColor Yellow
try {
    $proc3 = New-Object SourceCode.Workflow.Design.DefaultProcess
    $proc3.Name = "SPD_Migrated_WF"
    
    # Save the empty process to see format
    $emptyFile = Join-Path $exportDir "empty_process.kprx"
    try {
        $proc3.Save($emptyFile)
        Write-Host "  Saved empty process to: $emptyFile" -ForegroundColor Green
        $emptyContent = Get-Content $emptyFile -Raw -Encoding UTF8
        Write-Host "  Empty KPRX (first 500 chars): $($emptyContent.Substring(0, [Math]::Min(500, $emptyContent.Length)))" -ForegroundColor DarkYellow
    } catch {
        Write-Host "  Save failed: $($_.Exception.Message)" -ForegroundColor Red
    }
    
    # Try SaveAs with TextWriter 
    try {
        $sw = New-Object System.IO.StreamWriter((Join-Path $exportDir "empty_process2.kprx"))
        $proc3.Save($sw)
        $sw.Close()
        Write-Host "  Save(TextWriter) succeeded" -ForegroundColor Green
        $content2 = Get-Content (Join-Path $exportDir "empty_process2.kprx") -Raw -Encoding UTF8
        Write-Host "  Content: $($content2.Substring(0, [Math]::Min(300, $content2.Length)))" -ForegroundColor DarkYellow
    } catch {
        try { $sw.Close() } catch {}
        Write-Host "  Save(TextWriter) failed: $($_.Exception.Message)" -ForegroundColor Red
    }
} catch {
    Write-Host "  SaveAs pattern failed: $($_.Exception.Message)" -ForegroundColor Red
}

# ============================================================
# STEP 6: WorkflowManagementServer - find ALL write methods
# ============================================================
Write-Host "`n[6] WorkflowManagementServer write methods..." -ForegroundColor Yellow
$wmsType = [SourceCode.Workflow.Management.WorkflowManagementServer]
$wmsType.GetMethods() | Where-Object { 
    $_.DeclaringType.FullName -like "SourceCode*" -and 
    ($_.Name -like "Set*" -or $_.Name -like "Create*" -or $_.Name -like "Add*" -or $_.Name -like "Register*" -or $_.Name -like "Upload*" -or $_.Name -like "Save*" -or $_.Name -like "Deploy*" -or $_.Name -like "Update*" -or $_.Name -like "New*")
} | Sort-Object Name | ForEach-Object {
    $ps = ($_.GetParameters() | ForEach-Object { "$($_.ParameterType.Name) $($_.Name)" }) -join ", "
    Write-Host "  $($_.ReturnType.Name) $($_.Name)($ps)" -ForegroundColor Cyan
}

# Check for SetProcessKprx specifically
Write-Host "`n  All methods containing 'Kprx' or 'Process' or 'ProcSet':" -ForegroundColor Yellow
$wmsType.GetMethods() | Where-Object { 
    $_.DeclaringType.FullName -like "SourceCode*" -and 
    ($_.Name -like "*Kprx*" -or $_.Name -like "*Process*" -or $_.Name -like "*ProcSet*" -or $_.Name -like "*Proc*")
} | Sort-Object Name | ForEach-Object {
    $ps = ($_.GetParameters() | ForEach-Object { "$($_.ParameterType.Name) $($_.Name)" }) -join ", "
    Write-Host "  $($_.ReturnType.Name) $($_.Name)($ps)" -ForegroundColor DarkCyan
}

# ============================================================
# STEP 7: If SetProcessKprx exists, try it!
# ============================================================
Write-Host "`n[7] Attempting direct WMS deploy..." -ForegroundColor Yellow
$mgmt2 = New-Object SourceCode.Workflow.Management.WorkflowManagementServer
$mgmt2.CreateConnection()
$mgmt2.Connection.Open($connStr)

# Try SetProcessKprx
try {
    $method = $wmsType.GetMethod("SetProcessKprx")
    if ($method) {
        $ps = ($method.GetParameters() | ForEach-Object { "$($_.ParameterType.Name) $($_.Name)" }) -join ", "
        Write-Host "  Found SetProcessKprx($ps)!" -ForegroundColor Green
        # Try calling it with our KPRX
    }
} catch {}

# Try CreateProcessSet / CreateProcess
try {
    $createMethods = $wmsType.GetMethods() | Where-Object { $_.Name -like "Create*" }
    foreach ($cm in $createMethods) {
        $cps = ($cm.GetParameters() | ForEach-Object { "$($_.ParameterType.Name) $($_.Name)" }) -join ", "
        Write-Host "  Found: $($cm.ReturnType.Name) $($cm.Name)($cps)" -ForegroundColor Green
    }
} catch {}

$mgmt2.Connection.Close()

Write-Host "`n============================================" -ForegroundColor White
Write-Host "  FINAL Deploy Test Complete!" -ForegroundColor White
Write-Host "============================================" -ForegroundColor White

Stop-Transcript
