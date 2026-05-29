# ============================================================
#  Deploy-K2-Debug.ps1
#  
#  DIAGNOSTIC: List every file after extraction, find the EXACT
#  FrameworkGeneric filename, confirm it can be deleted, then
#  verify the WF KPRX file is the ONLY workflow file in the package.
#
#  Run in PowerShell ISE on K2 VM
# ============================================================

$ErrorActionPreference = "Continue"
$k2Bin = "C:\Program Files\K2\Bin"
$connStr = "Integrated=True;IsPrimaryLogin=True;Authenticate=True;EncryptedPassword=False;Host=localhost;Port=5555"
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$outputFile = Join-Path $scriptDir "Deploy-K2-Debug-Results.txt"
$exportDir = Join-Path $scriptDir "k2-export\_debug"

if (-not (Test-Path $exportDir)) { New-Item -Path $exportDir -ItemType Directory -Force | Out-Null }

Start-Transcript -Path $outputFile -Force

Write-Host "============================================" -ForegroundColor White
Write-Host "  K2 Deploy DEBUG" -ForegroundColor White
Write-Host "============================================`n" -ForegroundColor White

# Load assemblies
Get-ChildItem "$k2Bin\SourceCode.*.dll" | ForEach-Object {
    try { [System.Reflection.Assembly]::LoadFrom($_.FullName) | Out-Null } catch {}
}
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

# Get KPRX
$mgmt = New-Object SourceCode.Workflow.Management.WorkflowManagementServer
$mgmt.CreateConnection()
$mgmt.Connection.Open($connStr)
$kprxBytes = $mgmt.GetProcessKprx(13)
$mgmt.Connection.Close()

# Save template
$pdm = New-Object SourceCode.Deployment.Management.PackageDeploymentManager
$pdmConn = $pdm.CreateConnection()
$pdmConn.Open($connStr)
$stream = [System.IO.File]::OpenRead("C:\Program Files\K2\Setup\App Framework Core.kspx")
$s1 = "D_$(Get-Date -Format 'yyyyMMddHHmmss')"
$session = $pdm.CreateSession($s1, $stream)
$stream.Close()
$templateKspx = Join-Path $exportDir "template.kspx"
$outStream = [System.IO.File]::Create($templateKspx)
$session.Model.Save($outStream)
$outStream.Close()
$pdm.CloseSession($s1)

# Extract using .NET ZipArchive to list exact entries
Write-Host "[1] ZIP entries (exact names from archive):" -ForegroundColor Yellow
$archive = [System.IO.Compression.ZipFile]::OpenRead($templateKspx)
$wfEntry = $null
foreach ($entry in $archive.Entries) {
    $isWf = $false
    if ($entry.Name -match "Workflow" -or $entry.Name -match "FrameworkGeneric") {
        $isWf = $true
        if ($entry.Name -match "FrameworkGeneric") { $wfEntry = $entry.Name }
    }
    if ($isWf) {
        Write-Host "  ** $($entry.Name) ($($entry.Length) bytes) **" -ForegroundColor Green
    }
}
$archive.Dispose()
Write-Host "  WF entry name: [$wfEntry]" -ForegroundColor Cyan

# Extract to directory 
$extractDir = Join-Path $exportDir "extract"
if (Test-Path $extractDir) { Remove-Item $extractDir -Recurse -Force }
[System.IO.Compression.ZipFile]::ExtractToDirectory($templateKspx, $extractDir)

# List files using .NET to avoid PowerShell weirdness
Write-Host "`n[2] Files on disk after extraction:" -ForegroundColor Yellow
$dirInfo = [System.IO.DirectoryInfo]::new($extractDir)
$foundFG = $false
foreach ($f in $dirInfo.GetFiles()) {
    if ($f.Name.Contains("FrameworkGeneric") -or $f.Name.Contains("Workflow")) {
        Write-Host "  ** $($f.Name) ($($f.Length) bytes) **" -ForegroundColor Cyan
        if ($f.Name.Contains("FrameworkGeneric")) { $foundFG = $true }
    }
}
Write-Host "  Found FrameworkGeneric on disk: $foundFG" -ForegroundColor $(if($foundFG){"Green"}else{"Red"})

# Try to find it with .NET directly
Write-Host "`n[3] Trying to find and delete FrameworkGeneric file:" -ForegroundColor Yellow
$fgFiles = [System.IO.Directory]::GetFiles($extractDir, "*FrameworkGeneric*")
Write-Host "  GetFiles(*FrameworkGeneric*): $($fgFiles.Count) matches" -ForegroundColor Cyan
foreach ($fgf in $fgFiles) {
    Write-Host "  Found: $fgf" -ForegroundColor Green
    [System.IO.File]::Delete($fgf)
    Write-Host "  Deleted!" -ForegroundColor Green
}

# If nothing found, list ALL files with length > 100KB (workflow files are large)
if ($fgFiles.Count -eq 0) {
    Write-Host "`n  Large files (>100KB):" -ForegroundColor Yellow
    foreach ($f in $dirInfo.GetFiles()) {
        if ($f.Length -gt 100000) {
            Write-Host "    $($f.Name) ($([math]::Round($f.Length/1KB))KB)" -ForegroundColor DarkYellow
        }
    }
}

# Also read the definition.model to find the exact file= reference
Write-Host "`n[4] File references in definition.model:" -ForegroundColor Yellow
$defContent = [System.IO.File]::ReadAllText((Join-Path $extractDir "definition.model"), [System.Text.Encoding]::UTF8)
$fileRefs = [regex]::Matches($defContent, 'file="([^"]*)"')
foreach ($fr in $fileRefs) {
    Write-Host "  file=`"$($fr.Groups[1].Value)`"" -ForegroundColor Green
}

# Find the workflow ct entry  
$wfCtMatch = [regex]::Match($defContent, '(?s)ns="urn:SourceCode/Workflows"[^>]*>(.*?)</ct>')
if ($wfCtMatch.Success) {
    Write-Host "`n  Workflow CT block (first 500 chars):" -ForegroundColor Yellow
    Write-Host $wfCtMatch.Value.Substring(0, [Math]::Min(500, $wfCtMatch.Value.Length)) -ForegroundColor DarkYellow
}

# Now do the proper swap
Write-Host "`n[5] Performing swap..." -ForegroundColor Yellow

# Write our KPRX
$newWfName = "SPDMigratedApproval.Workflow"
$newWfPath = Join-Path $extractDir $newWfName
[System.IO.File]::WriteAllBytes($newWfPath, $kprxBytes)
Write-Host "  Wrote: $newWfName" -ForegroundColor Green

# Get the exact file= value from definition.model and replace it
if ($fileRefs.Count -gt 0) {
    $oldFileRef = $fileRefs[0].Groups[1].Value
    Write-Host "  Replacing file ref: $oldFileRef -> $newWfName" -ForegroundColor Cyan
    $defContent = $defContent.Replace($oldFileRef, $newWfName)
}

# Replace process identity
$defContent = $defContent.Replace("Framework Core\FrameworkGeneric.Workflow.Reference", "SPD Migration\SPDMigratedApproval")
$defContent = $defContent.Replace("FrameworkGeneric%2EWorkflow%2EReference", "SPDMigratedApproval")
$defContent = $defContent.Replace("Framework_Core", "SPD_Migration")
$defContent = $defContent.Replace("App Framework Core", "SPD Migration Package")

[System.IO.File]::WriteAllText((Join-Path $extractDir "definition.model"), $defContent, [System.Text.Encoding]::UTF8)

# Update properties
$propsPath = Join-Path $extractDir "properties.model" 
$pc = [System.IO.File]::ReadAllText($propsPath, [System.Text.Encoding]::UTF8)
$pc = $pc.Replace("App Framework Core", "SPD Migration Package")
[System.IO.File]::WriteAllText($propsPath, $pc, [System.Text.Encoding]::UTF8)

# Verify final state  
Write-Host "`n  Final file refs:" -ForegroundColor Yellow
$defAfter = [System.IO.File]::ReadAllText((Join-Path $extractDir "definition.model"), [System.Text.Encoding]::UTF8)
$refsAfter = [regex]::Matches($defAfter, 'file="([^"]*)"')
foreach ($fr in $refsAfter) {
    Write-Host "    file=`"$($fr.Groups[1].Value)`"" -ForegroundColor Green
}

# Package + Deploy
Write-Host "`n[6] Deploy..." -ForegroundColor Yellow
$finalKspx = Join-Path $exportDir "debug_deploy.kspx"
if (Test-Path $finalKspx) { Remove-Item $finalKspx -Force }
[System.IO.Compression.ZipFile]::CreateFromDirectory($extractDir, $finalKspx)

$deployStream = [System.IO.File]::OpenRead($finalKspx)
$s2 = "DB_$(Get-Date -Format 'yyyyMMddHHmmss')"
try {
    $session2 = $pdm.CreateSession($s2, $deployStream)
    $deployStream.Close()
    Write-Host "  Model: $($session2.Model.Name) Members: $($session2.Model.Members.Count)" -ForegroundColor Green
    
    $session2.SetOption("NoAnalyze", $true)
    $session2.Deploy()
    Start-Sleep -Seconds 5
    $count = 0; foreach ($r in $session2.DeploymentResults) { $count++ }
    Write-Host "  DEPLOYED: $count items" -ForegroundColor Green
    $pdm.CloseSession($s2)
} catch {
    try { $deployStream.Close() } catch {}
    Write-Host "  Deploy failed: $($_.Exception.Message)" -ForegroundColor Red
}

# Verify
Write-Host "`n[7] Processes:" -ForegroundColor Yellow
$mgmt2 = New-Object SourceCode.Workflow.Management.WorkflowManagementServer
$mgmt2.CreateConnection()
$mgmt2.Connection.Open($connStr)
foreach ($ps in $mgmt2.GetProcSets()) {
    $m = if ($ps.FullName -like "*SPD*" -or $ps.FullName -like "*Migrat*") { " <<< NEW!" } else { "" }
    Write-Host "  $($ps.FullName) (ID=$($ps.ProcSetID))$m" -ForegroundColor $(if($m){"Green"}else{"DarkGray"})
}
Write-Host "  Total: $($mgmt2.GetProcSets().Count)" -ForegroundColor Yellow
$mgmt2.Connection.Close()
$pdm.Dispose()

Stop-Transcript
