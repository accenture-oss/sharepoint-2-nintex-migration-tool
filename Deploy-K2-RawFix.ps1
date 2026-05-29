# ============================================================
#  Deploy-K2-RawFix.ps1
#  
#  BREAKTHROUGH: Deploy-Package with ConfigFile WORKS!
#  K2 recognized the process but got I/O error = KPRX corrupted
#  by XmlWriter (encoding/BOM changes).
#
#  FIX: Use RAW string replacement (no XML parsing) to fill
#  identity, preserving original KPRX byte structure.
#
#  Run in PowerShell ISE on K2 VM
# ============================================================

$ErrorActionPreference = "Continue"
$k2Bin = "C:\Program Files\K2\Bin"
$connStr = "Integrated=True;IsPrimaryLogin=True;Authenticate=True;EncryptedPassword=False;Host=localhost;Port=5555"
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$outputFile = Join-Path $scriptDir "Deploy-K2-RawFix-Results.txt"
$exportDir = Join-Path $scriptDir "k2-export\_rawfix"

if (-not (Test-Path $exportDir)) { New-Item -Path $exportDir -ItemType Directory -Force | Out-Null }

Start-Transcript -Path $outputFile -Force

Write-Host "============================================" -ForegroundColor White
Write-Host "  K2 Deploy - Raw KPRX Fix" -ForegroundColor White
Write-Host "============================================`n" -ForegroundColor White

Get-ChildItem "$k2Bin\SourceCode.*.dll" | ForEach-Object {
    try { [System.Reflection.Assembly]::LoadFrom($_.FullName) | Out-Null } catch {}
}
Add-Type -AssemblyName System.IO.Compression
Add-PSSnapin SourceCode.Deployment.PowerShell -ErrorAction SilentlyContinue

# Get KPRX as raw bytes
$mgmt = New-Object SourceCode.Workflow.Management.WorkflowManagementServer
$mgmt.CreateConnection()
$mgmt.Connection.Open($connStr)
$kprxBytes = $mgmt.GetProcessKprx(13)
$mgmt.Connection.Close()
Write-Host "KPRX: $($kprxBytes.Length) bytes" -ForegroundColor Green

# Convert to string for replacement (preserving encoding)
$kprxStr = [System.Text.Encoding]::UTF8.GetString($kprxBytes)

# ============================================================
# STEP 1: RAW string replacement - fill identity elements
# Do NOT parse as XML - that corrupts the binary structure!
# ============================================================
Write-Host "`n[1] Raw identity replacement..." -ForegroundColor Yellow

$newGuid = [System.Guid]::NewGuid().ToString()
$newName = "SPD_Migrated_Approval"
$newDisplayName = "SPD Migrated Approval Workflow"
$newCategoryPath = "SPD Migration"

# The KPRX has elements like: <Guid>ea967...</Guid>, <Name>DisplayName</Name> etc
# But these might be child elements of Activities, not the Process root.
# We need to target the Process-level children specifically.

# Find the FIRST <Guid> after <Process - that's the process GUID
# Use regex to target the Process-level <Guid> element (appears after root attributes)
# From the KPRX structure: Process > { Dependencies, References, ExecutionLayers, Lines, 
#   Activities, StartActivity, XmlFields, Views, Guid, Name, DisplayName, ... }

# Strategy: Replace the FIRST occurrence of each after </Views>
# But simpler: just replace the KNOWN values we saw in the output

# The output showed:
# <Guid>ea9679868285487480c22d0a748a376e6</Guid> 
# So let's find and show the Guid/Name/DisplayName/CategoryPath context
$guidMatch = [regex]::Match($kprxStr, '<Guid>([^<]*)</Guid>')
Write-Host "  Current Guid: $($guidMatch.Groups[1].Value)" -ForegroundColor DarkGray

$nameMatch = [regex]::Match($kprxStr, '</Views>\s*<Guid>[^<]*</Guid>\s*<Name>([^<]*)</Name>')
if (-not $nameMatch.Success) {
    $nameMatch = [regex]::Match($kprxStr, '<Name>([^<]*)</Name>')
}
Write-Host "  Current Name: $($nameMatch.Groups[1].Value)" -ForegroundColor DarkGray

# Show the area around </Views> to understand the structure
$viewsIdx = $kprxStr.IndexOf('</Views>')
if ($viewsIdx -gt 0) {
    $contextStart = $viewsIdx
    $contextEnd = [Math]::Min($viewsIdx + 500, $kprxStr.Length)
    $context = $kprxStr.Substring($contextStart, $contextEnd - $contextStart)
    Write-Host "`n  Context after </Views>:" -ForegroundColor Yellow
    Write-Host "  $context" -ForegroundColor DarkYellow
}

# Replace the identity section after </Views>
# We know the structure: </Views><Guid>X</Guid><Name>X</Name><DisplayName>X</DisplayName>...
$modStr = $kprxStr

# Use regex to replace the FIRST matching Guid/Name/etc after </Views>
$modStr = [regex]::Replace($modStr, 
    '(</Views>\s*)<Guid>[^<]*</Guid>',
    "`$1<Guid>$newGuid</Guid>", 
    [System.Text.RegularExpressions.RegexOptions]::None)

$modStr = [regex]::Replace($modStr,
    '(</Views>\s*<Guid>[^<]*</Guid>\s*)<Name>[^<]*</Name>',
    "`$1<Name>$newName</Name>",
    [System.Text.RegularExpressions.RegexOptions]::None)

$modStr = [regex]::Replace($modStr,
    '(</Views>\s*<Guid>[^<]*</Guid>\s*<Name>[^<]*</Name>\s*)<DisplayName>[^<]*</DisplayName>',
    "`$1<DisplayName>$newDisplayName</DisplayName>",
    [System.Text.RegularExpressions.RegexOptions]::None)

# CategoryPath
$modStr = [regex]::Replace($modStr,
    '<CategoryPath>[^<]*</CategoryPath>',
    "<CategoryPath>$newCategoryPath</CategoryPath>")

Write-Host "`n  After replacement context:" -ForegroundColor Yellow
$viewsIdx2 = $modStr.IndexOf('</Views>')
if ($viewsIdx2 -gt 0) {
    $ctx2 = $modStr.Substring($viewsIdx2, [Math]::Min(500, $modStr.Length - $viewsIdx2))
    Write-Host "  $ctx2" -ForegroundColor Green
}

# Convert back to bytes EXACTLY as UTF-8 (no BOM)
$modBytes = [System.Text.Encoding]::UTF8.GetBytes($modStr)
Write-Host "`n  Modified KPRX: $($modBytes.Length) bytes (original: $($kprxBytes.Length))" -ForegroundColor Green

# ============================================================
# STEP 2: Build .kspx with manual extract (skip old WF file)
# ============================================================
Write-Host "`n[2] Building .kspx..." -ForegroundColor Yellow

$pdm = New-Object SourceCode.Deployment.Management.PackageDeploymentManager
$pdmConn = $pdm.CreateConnection()
$pdmConn.Open($connStr)
$stream = [System.IO.File]::OpenRead("C:\Program Files\K2\Setup\App Framework Core.kspx")
$s1 = "RF_$(Get-Date -Format 'yyyyMMddHHmmss')"
$session = $pdm.CreateSession($s1, $stream)
$stream.Close()
$templateKspx = Join-Path $exportDir "template.kspx"
$outStream = [System.IO.File]::Create($templateKspx)
$session.Model.Save($outStream)
$outStream.Close()
$pdm.CloseSession($s1)

$extractDir = Join-Path $exportDir "extract"
if (Test-Path $extractDir) { Remove-Item $extractDir -Recurse -Force }
New-Item $extractDir -ItemType Directory -Force | Out-Null

$archive = [System.IO.Compression.ZipFile]::OpenRead($templateKspx)
$oldWfName = $null
foreach ($entry in $archive.Entries) {
    if ($entry.Name -match "FrameworkGeneric") {
        $oldWfName = $entry.Name
        continue
    }
    $es = $entry.Open()
    $fs = [System.IO.File]::Create((Join-Path $extractDir $entry.Name))
    $es.CopyTo($fs)
    $fs.Close()
    $es.Close()
}
$archive.Dispose()

# Write modified KPRX as raw bytes
$newWfName = "SPDMigratedApproval.Workflow"
[System.IO.File]::WriteAllBytes((Join-Path $extractDir $newWfName), $modBytes)
Write-Host "  Skipped: $oldWfName" -ForegroundColor Green
Write-Host "  Added: $newWfName ($([math]::Round($modBytes.Length/1KB))KB)" -ForegroundColor Green

# Update definition.model
$defPath = Join-Path $extractDir "definition.model"
$defContent = [System.IO.File]::ReadAllText($defPath, [System.Text.Encoding]::UTF8)
if ($oldWfName) { $defContent = $defContent.Replace($oldWfName, $newWfName) }
$defContent = $defContent.Replace("Framework Core\FrameworkGeneric.Workflow.Reference", "$newCategoryPath\$newName")
$defContent = $defContent.Replace("FrameworkGeneric%2EWorkflow%2EReference", $newName)
$defContent = $defContent.Replace("FrameworkGeneric.Workflow.Reference", $newName)
$defContent = $defContent.Replace("Framework_Core", $newCategoryPath.Replace(" ","_"))
$defContent = $defContent.Replace("Framework Core", $newCategoryPath)
$defContent = $defContent.Replace("App Framework Core", "SPD Migration Package")
[System.IO.File]::WriteAllText($defPath, $defContent, [System.Text.Encoding]::UTF8)

$pp = Join-Path $extractDir "properties.model"
$pc = [System.IO.File]::ReadAllText($pp, [System.Text.Encoding]::UTF8)
$pc = $pc.Replace("App Framework Core", "SPD Migration Package")
[System.IO.File]::WriteAllText($pp, $pc, [System.Text.Encoding]::UTF8)

# Repack
$finalKspx = Join-Path $exportDir "rawfix_deploy.kspx"
if (Test-Path $finalKspx) { Remove-Item $finalKspx -Force }
$outZip = [System.IO.Compression.ZipFile]::Open($finalKspx, [System.IO.Compression.ZipArchiveMode]::Create)
foreach ($f in [System.IO.Directory]::GetFiles($extractDir)) {
    $fn = [System.IO.Path]::GetFileName($f)
    $e = $outZip.CreateEntry($fn)
    $es = $e.Open(); $fs = [System.IO.File]::OpenRead($f); $fs.CopyTo($es); $fs.Close(); $es.Close()
}
$outZip.Dispose()
Write-Host "  Package: $([math]::Round((Get-Item $finalKspx).Length/1KB))KB" -ForegroundColor Green

# ============================================================
# STEP 3: Write-DeploymentConfig + Deploy-Package
# ============================================================
Write-Host "`n[3] Write-DeploymentConfig + Deploy-Package..." -ForegroundColor Yellow
$deployConfigXml = Join-Path $exportDir "deploy_config.xml"
try {
    Write-DeploymentConfig -InputFile $finalKspx -OutputFile $deployConfigXml -ErrorAction Stop
    Write-Host "  Config generated!" -ForegroundColor Green
    
    Deploy-Package -FileName $finalKspx -ConfigFile $deployConfigXml -ConnectionString $connStr -ErrorAction Stop
    Write-Host "  *** Deploy-Package SUCCEEDED! ***" -ForegroundColor Green
} catch {
    Write-Host "  Error: $($_.Exception.Message)" -ForegroundColor Red
}

# ============================================================
# STEP 4: Also try Deploy-Package direct (fix -Integrated:$true)
# ============================================================
Write-Host "`n[4] Direct Deploy-Package..." -ForegroundColor Yellow
try {
    Deploy-Package -FileName $finalKspx -NoAnalyze -K2Host "localhost" -Port 5555 -Integrated:$true -IsPrimaryLogin:$true -ErrorAction Stop
    Write-Host "  *** Direct Deploy-Package SUCCEEDED! ***" -ForegroundColor Green
} catch {
    Write-Host "  Error: $($_.Exception.Message)" -ForegroundColor Red
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
$pdm.Dispose()

Stop-Transcript
