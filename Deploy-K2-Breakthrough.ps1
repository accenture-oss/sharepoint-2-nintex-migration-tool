# ============================================================
#  Deploy-K2-Breakthrough.ps1
#  
#  THREE CRITICAL INSIGHTS (from Claude):
#  1. ProcessSerializer - dedicated class for KPRX deserialization
#  2. DeploymentManager (Authoring namespace) - uses port 5252
#  3. <DeployToCategory> must be 1, not 0
#
#  Also: Write-DeploymentConfig + Deploy-Package with -ConfigFile
#
#  Run in PowerShell ISE on K2 VM
# ============================================================

$ErrorActionPreference = "Continue"
$k2Bin = "C:\Program Files\K2\Bin"
$connStr = "Integrated=True;IsPrimaryLogin=True;Authenticate=True;EncryptedPassword=False;Host=localhost;Port=5555"
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$outputFile = Join-Path $scriptDir "Deploy-K2-Breakthrough-Results.txt"
$exportDir = Join-Path $scriptDir "k2-export\_breakthrough"

if (-not (Test-Path $exportDir)) { New-Item -Path $exportDir -ItemType Directory -Force | Out-Null }

Start-Transcript -Path $outputFile -Force

Write-Host "============================================" -ForegroundColor White
Write-Host "  K2 Deploy - BREAKTHROUGH" -ForegroundColor White
Write-Host "============================================`n" -ForegroundColor White

# Load ALL assemblies
Get-ChildItem "$k2Bin\SourceCode.*.dll" | ForEach-Object {
    try { [System.Reflection.Assembly]::LoadFrom($_.FullName) | Out-Null } catch {}
}

# Get KPRX
$mgmt = New-Object SourceCode.Workflow.Management.WorkflowManagementServer
$mgmt.CreateConnection()
$mgmt.Connection.Open($connStr)
$kprxBytes = $mgmt.GetProcessKprx(13) # TestKprxWF
$kprxXml = [System.Text.Encoding]::UTF8.GetString($kprxBytes)
if ($kprxXml[0] -eq [char]0xFEFF) { $kprxXml = $kprxXml.Substring(1) }
$mgmt.Connection.Close()
Write-Host "KPRX: $($kprxBytes.Length) bytes" -ForegroundColor Green

# ============================================================
# INSIGHT 1: Check <DeployToCategory> in the KPRX
# ============================================================
Write-Host "`n[1] Checking DeployToCategory..." -ForegroundColor Yellow

$xml = [xml]$kprxXml
$root = $xml.DocumentElement

# Search for DeployToCategory element or attribute
$dtcNodes = $root.SelectNodes("//*[local-name()='DeployToCategory']")
Write-Host "  <DeployToCategory> elements: $($dtcNodes.Count)" -ForegroundColor Cyan
foreach ($d in $dtcNodes) {
    Write-Host "    Value: [$($d.InnerText)] OuterXML: $($d.OuterXml)" -ForegroundColor DarkYellow
}

# Also check as attribute
$dtcAttrs = $root.SelectNodes("//*[@DeployToCategory]")
Write-Host "  DeployToCategory attributes: $($dtcAttrs.Count)" -ForegroundColor Cyan
foreach ($d in $dtcAttrs) {
    Write-Host "    $($d.LocalName) DeployToCategory=$($d.GetAttribute('DeployToCategory'))" -ForegroundColor DarkYellow
}

# Search the raw XML for DeployToCategory
$dtcMatches = [regex]::Matches($kprxXml, 'DeployToCategory[^<]*')
Write-Host "  Raw matches:" -ForegroundColor Yellow
foreach ($m in $dtcMatches) {
    Write-Host "    [$($m.Value)]" -ForegroundColor DarkGreen
}

# If found and = 0, change to 1
if ($kprxXml.Contains("DeployToCategory")) {
    $modXml = $kprxXml.Replace(">False<", ">True<").Replace(">0<", ">1<")
    # Also handle attribute form
    $modXml = $modXml.Replace('DeployToCategory="False"', 'DeployToCategory="True"')
    $modXml = $modXml.Replace('DeployToCategory="0"', 'DeployToCategory="1"')
    Write-Host "  Fixed DeployToCategory!" -ForegroundColor Green
} else {
    Write-Host "  NOT FOUND - searching broader..." -ForegroundColor Red
    $modXml = $kprxXml
}

# Also show the <Process> root element and first-level children (as Claude requested)
Write-Host "`n  KPRX root + children:" -ForegroundColor Yellow
Write-Host "  <$($root.LocalName)" -ForegroundColor DarkGray
foreach ($a in $root.Attributes) {
    Write-Host "    $($a.Name)=`"$($a.Value)`"" -ForegroundColor DarkGray
}
Write-Host "  >" -ForegroundColor DarkGray
foreach ($child in $root.ChildNodes) {
    $attrs = ""
    if ($child.Attributes) {
        foreach ($a in $child.Attributes | Select-Object -First 3) { $attrs += " $($a.Name)=`"$($a.Value)`"" }
    }
    Write-Host "    <$($child.LocalName)$attrs />" -ForegroundColor DarkCyan
}

# ============================================================
# INSIGHT 2: Find ProcessSerializer
# ============================================================
Write-Host "`n[2] Looking for ProcessSerializer..." -ForegroundColor Yellow

# Search all loaded assemblies for ProcessSerializer
$allTypes = @()
foreach ($asm in [System.AppDomain]::CurrentDomain.GetAssemblies()) {
    try {
        $types = $asm.GetTypes() | Where-Object { $_.Name -like "*ProcessSerial*" -or $_.Name -like "*WorkflowFactory*" -or ($_.Name -like "*DeploymentManager*" -and $_.Namespace -like "*Authoring*") }
        foreach ($t in $types) {
            Write-Host "  FOUND: $($t.FullName) in $($asm.GetName().Name)" -ForegroundColor Green
            $allTypes += $t
        }
    } catch {}
}

# Also search for DeploymentManager specifically
foreach ($asm in [System.AppDomain]::CurrentDomain.GetAssemblies()) {
    try {
        $dms = $asm.GetTypes() | Where-Object { $_.Name -eq "DeploymentManager" }
        foreach ($dm in $dms) {
            Write-Host "  DeploymentManager: $($dm.FullName) in $($asm.GetName().Name)" -ForegroundColor Cyan
            # List methods
            foreach ($m in $dm.GetMethods() | Where-Object { $_.DeclaringType.FullName -eq $dm.FullName }) {
                $ps = ($m.GetParameters() | ForEach-Object { "$($_.ParameterType.Name) $($_.Name)" }) -join ", "
                Write-Host "    $($m.ReturnType.Name) $($m.Name)($ps)" -ForegroundColor DarkCyan
            }
        }
    } catch {}
}

# ============================================================
# INSIGHT 3: Write-DeploymentConfig + Deploy-Package with config
# ============================================================
Write-Host "`n[3] Checking P&D cmdlets..." -ForegroundColor Yellow

# Check if snap-in is loaded
$snapins = Get-PSSnapin -Registered 2>$null
foreach ($s in $snapins) {
    if ($s.Name -like "*SourceCode*" -or $s.Name -like "*K2*") {
        Write-Host "  Registered: $($s.Name)" -ForegroundColor Green
    }
}

# Add snap-in if needed
try {
    Add-PSSnapin SourceCode.Deployment.PowerShell -ErrorAction Stop
    Write-Host "  Snap-in loaded!" -ForegroundColor Green
} catch {
    Write-Host "  Snap-in load: $($_.Exception.Message)" -ForegroundColor DarkGray
}

# List ALL K2 deployment cmdlets
$k2Cmds = Get-Command -Module SourceCode* -ErrorAction SilentlyContinue
if (-not $k2Cmds) {
    $k2Cmds = Get-Command *Deploy* -ErrorAction SilentlyContinue | Where-Object { $_.Source -like "*SourceCode*" -or $_.ModuleName -like "*SourceCode*" }
}
foreach ($cmd in $k2Cmds) {
    Write-Host "  CMD: $($cmd.Name)" -ForegroundColor DarkCyan
}

# Check for Write-DeploymentConfig
try {
    $wdc = Get-Command Write-DeploymentConfig -ErrorAction Stop
    Write-Host "  Write-DeploymentConfig found!" -ForegroundColor Green
    Write-Host "  Parameters: $(($wdc.Parameters.Keys) -join ', ')" -ForegroundColor DarkGray
} catch {
    Write-Host "  Write-DeploymentConfig: $($_.Exception.Message)" -ForegroundColor DarkGray
}

# Check for Deploy-Package parameters
try {
    $dp = Get-Command Deploy-Package -ErrorAction Stop
    Write-Host "  Deploy-Package parameters:" -ForegroundColor Yellow
    foreach ($p in $dp.Parameters.Keys) {
        Write-Host "    -$p" -ForegroundColor DarkCyan
    }
} catch {
    Write-Host "  Deploy-Package: $($_.Exception.Message)" -ForegroundColor DarkGray
}

# ============================================================
# STEP 4: Try Deploy-Package with ConfigFile  
# ============================================================
Write-Host "`n[4] Deploy-Package approach..." -ForegroundColor Yellow

# Save modified KPRX (with DeployToCategory fixed)
$modKprxFile = Join-Path $exportDir "modified.kprx"
$kprxBytesFixed = [System.Text.Encoding]::UTF8.GetBytes($modXml)
[System.IO.File]::WriteAllBytes($modKprxFile, $kprxBytesFixed)

# Try to create a deployment config
try {
    $configFile = Join-Path $exportDir "deploy.config"
    Write-DeploymentConfig -FileName $configFile -ConnectionString $connStr -ErrorAction Stop
    Write-Host "  Config written: $configFile" -ForegroundColor Green
    $configContent = Get-Content $configFile -Raw -ErrorAction SilentlyContinue
    Write-Host "  Config: $($configContent.Substring(0, [Math]::Min(500, $configContent.Length)))" -ForegroundColor DarkYellow
} catch {
    Write-Host "  Write-DeploymentConfig failed: $($_.Exception.Message)" -ForegroundColor Red
}

# Try New-Package with the KPRX, then Deploy-Package with config
try {
    $pkgFile = Join-Path $exportDir "breakthrough.kspx"
    New-Package -FileName $pkgFile -ProcessFile $modKprxFile -ErrorAction Stop
    Write-Host "  Package created: $pkgFile" -ForegroundColor Green
    
    if (Test-Path $configFile) {
        Deploy-Package -FileName $pkgFile -ConfigFile $configFile -ErrorAction Stop
        Write-Host "  DEPLOYED via Deploy-Package with config!" -ForegroundColor Green
    } else {
        Deploy-Package -FileName $pkgFile -ConnectionString $connStr -ErrorAction Stop
        Write-Host "  DEPLOYED via Deploy-Package!" -ForegroundColor Green
    }
} catch {
    Write-Host "  Package deploy error: $($_.Exception.Message)" -ForegroundColor Red
}

# ============================================================
# VERIFY
# ============================================================
Write-Host "`n[5] Processes:" -ForegroundColor Yellow
$mgmt2 = New-Object SourceCode.Workflow.Management.WorkflowManagementServer
$mgmt2.CreateConnection()
$mgmt2.Connection.Open($connStr)
foreach ($ps in $mgmt2.GetProcSets()) {
    $m = if ($ps.FullName -like "*SPD*" -or $ps.FullName -like "*Migrat*" -or $ps.ProcSetID -gt 11) { " <<< NEW!" } else { "" }
    Write-Host "  $($ps.FullName) (ID=$($ps.ProcSetID))$m" -ForegroundColor $(if($m){"Green"}else{"DarkGray"})
}
Write-Host "  Total: $($mgmt2.GetProcSets().Count)" -ForegroundColor Yellow
$mgmt2.Connection.Close()

Stop-Transcript
