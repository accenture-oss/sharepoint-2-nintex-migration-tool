# ============================================================
#  Deploy-K2-AuthoringAPI.ps1
#  
#  THE REAL SOLUTION: Use SourceCode.Workflow.Authoring
#  DeploymentManager.Deploy() - sends Process to K2 Designer 
#  Server which compiles server-side. No .kspx, no .dll needed.
#
#  Also: Sanity check - deploy original unmodified .kspx
#
#  Run in PowerShell ISE on K2 VM
# ============================================================

$ErrorActionPreference = "Continue"
$k2Bin = "C:\Program Files\K2\Bin"
$k2HostBin = "C:\Program Files\K2\Host Server\Bin"
$connStr = "Integrated=True;IsPrimaryLogin=True;Authenticate=True;EncryptedPassword=False;Host=localhost;Port=5555"
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$outputFile = Join-Path $scriptDir "Deploy-K2-AuthoringAPI-Results.txt"

Start-Transcript -Path $outputFile -Force

Write-Host "============================================" -ForegroundColor White
Write-Host "  K2 Deploy - Authoring API" -ForegroundColor White
Write-Host "============================================`n" -ForegroundColor White

# Load ALL assemblies explicitly
$loadPaths = @($k2Bin, $k2HostBin)
foreach ($lp in $loadPaths) {
    if (Test-Path $lp) {
        Get-ChildItem "$lp\SourceCode.*.dll" -ErrorAction SilentlyContinue | ForEach-Object {
            try { [System.Reflection.Assembly]::LoadFrom($_.FullName) | Out-Null } catch {}
        }
    }
}

# ============================================================
# STEP 1: Find Authoring API classes
# ============================================================
Write-Host "[1] Finding Authoring API classes..." -ForegroundColor Yellow

$targetClasses = @(
    "DeploymentManager", "ProcessSerializer", "WorkflowFactory",
    "Process", "DefaultProcess", "ProcessReader", "ProcessWriter"
)
foreach ($className in $targetClasses) {
    foreach ($asm in [System.AppDomain]::CurrentDomain.GetAssemblies()) {
        try {
            $types = $asm.GetTypes() | Where-Object { $_.Name -eq $className }
            foreach ($t in $types) {
                Write-Host "  $($t.FullName) [$($asm.GetName().Name)]" -ForegroundColor Green
                # Show constructors
                foreach ($c in $t.GetConstructors()) {
                    $ps = ($c.GetParameters() | ForEach-Object { "$($_.ParameterType.Name) $($_.Name)" }) -join ", "
                    Write-Host "    ctor($ps)" -ForegroundColor DarkCyan
                }
                # Show key methods
                foreach ($m in $t.GetMethods() | Where-Object { 
                    $_.DeclaringType.FullName -eq $t.FullName -and 
                    ($_.Name -like "Deploy*" -or $_.Name -like "Deserial*" -or 
                     $_.Name -like "Read*" -or $_.Name -like "Load*" -or $_.Name -like "Save*" -or
                     $_.Name -like "Create*" -or $_.Name -like "Open*")
                }) {
                    $ps = ($m.GetParameters() | ForEach-Object { "$($_.ParameterType.Name) $($_.Name)" }) -join ", "
                    Write-Host "    $($m.ReturnType.Name) $($m.Name)($ps)" -ForegroundColor DarkCyan
                }
            }
        } catch {}
    }
}

# Also search for any type with "Deploy" in Authoring namespace
Write-Host "`n  All Authoring types with Deploy/Serialize:" -ForegroundColor Yellow
foreach ($asm in [System.AppDomain]::CurrentDomain.GetAssemblies()) {
    if ($asm.GetName().Name -like "*Authoring*" -or $asm.GetName().Name -like "*Design*") {
        try {
            foreach ($t in $asm.GetTypes()) {
                if ($t.Name -like "*Deploy*" -or $t.Name -like "*Serial*" -or $t.Name -like "*Factory*") {
                    Write-Host "    $($t.FullName)" -ForegroundColor Cyan
                }
            }
        } catch {}
    }
}

# ============================================================
# STEP 2: Get KPRX and try to deserialize
# ============================================================
Write-Host "`n[2] Loading KPRX..." -ForegroundColor Yellow

$mgmt = New-Object SourceCode.Workflow.Management.WorkflowManagementServer
$mgmt.CreateConnection()
$mgmt.Connection.Open($connStr)
$kprxBytes = $mgmt.GetProcessKprx(13) 
$mgmt.Connection.Close()
$kprxXml = [System.Text.Encoding]::UTF8.GetString($kprxBytes)
if ($kprxXml[0] -eq [char]0xFEFF) { $kprxXml = $kprxXml.Substring(1) }
Write-Host "  KPRX: $($kprxBytes.Length) bytes" -ForegroundColor Green
Write-Host "  Root: $($kprxXml.Substring(0, [Math]::Min(200, $kprxXml.Length)))" -ForegroundColor DarkGray

# The KPRX says: Type="SourceCode.Workflow.Design.DefaultProcess" 
#                Assembly="SourceCode.Workflow.Authoring, Version=4.0.0.0"
# So we can try XmlSerializer with that type

# Try 1: XmlSerializer with Process type
Write-Host "`n  Trying XmlSerializer deserialization..." -ForegroundColor Yellow
$processType = $null
foreach ($asm in [System.AppDomain]::CurrentDomain.GetAssemblies()) {
    try {
        $pt = $asm.GetType("SourceCode.Workflow.Design.DefaultProcess")
        if ($pt) { $processType = $pt; Write-Host "    Found: $($pt.FullName) in $($asm.GetName().Name)" -ForegroundColor Green }
    } catch {}
}
if (-not $processType) {
    # Try broader search
    foreach ($asm in [System.AppDomain]::CurrentDomain.GetAssemblies()) {
        try {
            $pt = $asm.GetTypes() | Where-Object { $_.Name -eq "DefaultProcess" } | Select-Object -First 1
            if ($pt) { $processType = $pt; Write-Host "    Found (broad): $($pt.FullName) in $($asm.GetName().Name)" -ForegroundColor Green }
        } catch {}
    }
}

if ($processType) {
    Write-Host "    ProcessType: $($processType.FullName)" -ForegroundColor Green
    Write-Host "    Base: $($processType.BaseType.FullName)" -ForegroundColor DarkGray
    
    try {
        $serializer = New-Object System.Xml.Serialization.XmlSerializer($processType)
        $reader = New-Object System.IO.StringReader($kprxXml)
        $process = $serializer.Deserialize($reader)
        $reader.Close()
        Write-Host "    *** DESERIALIZED! ***" -ForegroundColor Green
        Write-Host "    Type: $($process.GetType().FullName)" -ForegroundColor Cyan
        
        # Show process properties
        foreach ($prop in $process.GetType().GetProperties() | Where-Object {
            $_.Name -in @("Name","DisplayName","Guid","CategoryPath","ServerName","Description")
        }) {
            $val = try { $prop.GetValue($process) } catch { "ERR" }
            Write-Host "    $($prop.Name) = $val" -ForegroundColor DarkCyan
        }
    } catch {
        Write-Host "    XmlSerializer failed: $($_.Exception.Message)" -ForegroundColor Red
        if ($_.Exception.InnerException) {
            Write-Host "    Inner: $($_.Exception.InnerException.Message)" -ForegroundColor DarkRed
        }
    }
}

# ============================================================
# STEP 3: Try DeploymentManager.Deploy
# ============================================================
Write-Host "`n[3] Trying DeploymentManager..." -ForegroundColor Yellow

$dmType = $null
foreach ($asm in [System.AppDomain]::CurrentDomain.GetAssemblies()) {
    try {
        $dms = $asm.GetTypes() | Where-Object { $_.Name -eq "DeploymentManager" -and $_.Namespace -like "*Authoring*" }
        foreach ($dm in $dms) { $dmType = $dm }
    } catch {}
}

if ($dmType) {
    Write-Host "  Found: $($dmType.FullName)" -ForegroundColor Green
    
    # List ALL methods
    foreach ($m in $dmType.GetMethods()) {
        if ($m.DeclaringType.FullName -eq $dmType.FullName) {
            $ps = ($m.GetParameters() | ForEach-Object { "$($_.ParameterType.Name) $($_.Name)" }) -join ", "
            Write-Host "    $($m.ReturnType.Name) $($m.Name)($ps)" -ForegroundColor DarkCyan
        }
    }
    
    # Try to deploy if we have a process object
    if ($process) {
        Write-Host "`n  Deploying via DeploymentManager..." -ForegroundColor Yellow
        try {
            $dm = [System.Activator]::CreateInstance($dmType)
            # Try Deploy(Process, host, port)
            $deployMethod = $dmType.GetMethod("Deploy")
            if ($deployMethod) {
                $ps = ($deployMethod.GetParameters() | ForEach-Object { "$($_.ParameterType.Name) $($_.Name)" }) -join ", "
                Write-Host "    Deploy signature: $ps" -ForegroundColor Cyan
                $deployMethod.Invoke($dm, @($process, "localhost", 5555))
                Write-Host "    *** DEPLOY SUCCEEDED! ***" -ForegroundColor Green
            }
        } catch {
            Write-Host "    Deploy error: $($_.Exception.Message)" -ForegroundColor Red
            if ($_.Exception.InnerException) {
                Write-Host "    Inner: $($_.Exception.InnerException.Message)" -ForegroundColor DarkRed
                if ($_.Exception.InnerException.InnerException) {
                    Write-Host "    Inner2: $($_.Exception.InnerException.InnerException.Message)" -ForegroundColor DarkRed
                }
            }
        }
    }
} else {
    Write-Host "  DeploymentManager NOT FOUND in Authoring namespace" -ForegroundColor Red
    
    # Search ALL DeploymentManager types anywhere
    Write-Host "  All DeploymentManager types:" -ForegroundColor Yellow
    foreach ($asm in [System.AppDomain]::CurrentDomain.GetAssemblies()) {
        try {
            $dms = $asm.GetTypes() | Where-Object { $_.Name -like "*DeploymentManager*" }
            foreach ($dm in $dms) {
                Write-Host "    $($dm.FullName) [$($asm.GetName().Name)]" -ForegroundColor DarkCyan
            }
        } catch {}
    }
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
