# ============================================================
#  Deploy-K2-ManualExtract.ps1
#  
#  ROOT CAUSE: ZipFile.ExtractToDirectory silently skips the
#  FrameworkGeneric file due to the + character in its name.
#  The definition.model uses <fileitem> not file= for the KPRX link.
#
#  FIX: Use ZipArchive to manually extract entries one by one,
#  and find/replace the <fileitem> element.
#
#  Run in PowerShell ISE on K2 VM
# ============================================================

$ErrorActionPreference = "Continue"
$k2Bin = "C:\Program Files\K2\Bin"
$connStr = "Integrated=True;IsPrimaryLogin=True;Authenticate=True;EncryptedPassword=False;Host=localhost;Port=5555"
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$outputFile = Join-Path $scriptDir "Deploy-K2-ManualExtract-Results.txt"
$exportDir = Join-Path $scriptDir "k2-export\_manual"

if (-not (Test-Path $exportDir)) { New-Item -Path $exportDir -ItemType Directory -Force | Out-Null }

Start-Transcript -Path $outputFile -Force

Write-Host "============================================" -ForegroundColor White
Write-Host "  K2 Deploy - Manual ZIP Extract" -ForegroundColor White
Write-Host "============================================`n" -ForegroundColor White

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
Write-Host "KPRX: $($kprxBytes.Length) bytes" -ForegroundColor Green

# Save template
$pdm = New-Object SourceCode.Deployment.Management.PackageDeploymentManager
$pdmConn = $pdm.CreateConnection()
$pdmConn.Open($connStr)
$stream = [System.IO.File]::OpenRead("C:\Program Files\K2\Setup\App Framework Core.kspx")
$s1 = "M_$(Get-Date -Format 'yyyyMMddHHmmss')"
$session = $pdm.CreateSession($s1, $stream)
$stream.Close()
$templateKspx = Join-Path $exportDir "template.kspx"
$outStream = [System.IO.File]::Create($templateKspx)
$session.Model.Save($outStream)
$outStream.Close()
$pdm.CloseSession($s1)

# ============================================================
# STEP 1: Manual extraction - entry by entry
# ============================================================
Write-Host "`n[1] Manual ZIP extraction..." -ForegroundColor Yellow
$extractDir = Join-Path $exportDir "extract"
if (Test-Path $extractDir) { Remove-Item $extractDir -Recurse -Force }
New-Item $extractDir -ItemType Directory -Force | Out-Null

$archive = [System.IO.Compression.ZipFile]::OpenRead($templateKspx)
$oldWfEntryName = $null
foreach ($entry in $archive.Entries) {
    $destPath = Join-Path $extractDir $entry.Name
    
    # Skip the old WF file - we'll replace it
    if ($entry.Name -match "FrameworkGeneric") {
        $oldWfEntryName = $entry.Name
        Write-Host "  SKIP WF: $($entry.Name) ($($entry.Length) bytes)" -ForegroundColor Yellow
        continue
    }
    
    # Extract using stream copy (avoids filename issues)
    $entryStream = $entry.Open()
    $fileStream = [System.IO.File]::Create($destPath)
    $entryStream.CopyTo($fileStream)
    $fileStream.Close()
    $entryStream.Close()
}
$archive.Dispose()
Write-Host "  Old WF entry: $oldWfEntryName" -ForegroundColor Cyan

# Write our KPRX
$newWfName = "SPDMigratedApproval.Workflow"
[System.IO.File]::WriteAllBytes((Join-Path $extractDir $newWfName), $kprxBytes)
Write-Host "  Wrote: $newWfName ($([math]::Round($kprxBytes.Length/1KB))KB)" -ForegroundColor Green

# Verify on disk
Write-Host "`n  Files with 'Workflow' or 'FrameworkGeneric':" -ForegroundColor Yellow
foreach ($f in [System.IO.Directory]::GetFiles($extractDir)) {
    $fn = [System.IO.Path]::GetFileName($f)
    if ($fn -match "Workflow" -or $fn -match "FrameworkGeneric") {
        Write-Host "    $fn ($([math]::Round((Get-Item -LiteralPath $f).Length/1KB))KB)" -ForegroundColor Green
    }
}

# ============================================================
# STEP 2: Find <fileitem> in definition.model
# ============================================================
Write-Host "`n[2] Analyzing definition.model..." -ForegroundColor Yellow
$defPath = Join-Path $extractDir "definition.model"
$defContent = [System.IO.File]::ReadAllText($defPath, [System.Text.Encoding]::UTF8)

# Find ALL fileitem elements
$fileItems = [regex]::Matches($defContent, '<fileitem[^>]*>')
Write-Host "  <fileitem> elements: $($fileItems.Count)" -ForegroundColor Cyan
foreach ($fi in $fileItems) {
    Write-Host "    $($fi.Value)" -ForegroundColor Green
}

# Find all references to FrameworkGeneric in the model
$fgRefs = [regex]::Matches($defContent, '[^"<>]*FrameworkGeneric[^"<>]*')
Write-Host "`n  FrameworkGeneric references: $($fgRefs.Count)" -ForegroundColor Cyan
$uniqueRefs = $fgRefs | ForEach-Object { $_.Value.Trim() } | Sort-Object -Unique
foreach ($ref in $uniqueRefs) {
    Write-Host "    [$ref]" -ForegroundColor DarkYellow
}

# ============================================================
# STEP 3: Replace in definition.model
# ============================================================
Write-Host "`n[3] Replacing in definition.model..." -ForegroundColor Yellow

# Replace the fileitem file reference
if ($oldWfEntryName) {
    $before = $defContent.Contains($oldWfEntryName)
    $defContent = $defContent.Replace($oldWfEntryName, $newWfName)
    $after = $defContent.Contains($newWfName)
    Write-Host "  fileitem ref: before=$before after=$after" -ForegroundColor $(if($after){"Green"}else{"Red"})
}

# Replace process name
$defContent = $defContent.Replace("Framework Core\FrameworkGeneric.Workflow.Reference", "SPD Migration\SPDMigratedApproval")
$defContent = $defContent.Replace("FrameworkGeneric%2EWorkflow%2EReference", "SPDMigratedApproval")
$defContent = $defContent.Replace("FrameworkGeneric.Workflow.Reference", "SPDMigratedApproval")
$defContent = $defContent.Replace("Framework_Core", "SPD_Migration")
$defContent = $defContent.Replace("Framework Core", "SPD Migration")  
$defContent = $defContent.Replace("App Framework Core", "SPD Migration Package")

# Verify fileitem after replacement
$fileItemsAfter = [regex]::Matches($defContent, '<fileitem[^>]*>')
Write-Host "  <fileitem> elements after: $($fileItemsAfter.Count)" -ForegroundColor Cyan
foreach ($fi in $fileItemsAfter) {
    Write-Host "    $($fi.Value)" -ForegroundColor Green
}

# Verify no FrameworkGeneric references remain
$fgRefsAfter = [regex]::Matches($defContent, 'FrameworkGeneric')
Write-Host "  Remaining FrameworkGeneric refs: $($fgRefsAfter.Count)" -ForegroundColor $(if($fgRefsAfter.Count -eq 0){"Green"}else{"Red"})

[System.IO.File]::WriteAllText($defPath, $defContent, [System.Text.Encoding]::UTF8)

# Update properties
$propsPath = Join-Path $extractDir "properties.model"
$pc = [System.IO.File]::ReadAllText($propsPath, [System.Text.Encoding]::UTF8)
$pc = $pc.Replace("App Framework Core", "SPD Migration Package")
[System.IO.File]::WriteAllText($propsPath, $pc, [System.Text.Encoding]::UTF8)

# ============================================================
# STEP 4: Repackage using ZipArchive (not ZipFile)
# ============================================================
Write-Host "`n[4] Repackaging..." -ForegroundColor Yellow
$finalKspx = Join-Path $exportDir "manual_deploy.kspx"
if (Test-Path $finalKspx) { Remove-Item $finalKspx -Force }

$outArchive = [System.IO.Compression.ZipFile]::Open($finalKspx, [System.IO.Compression.ZipArchiveMode]::Create)
foreach ($f in [System.IO.Directory]::GetFiles($extractDir)) {
    $fn = [System.IO.Path]::GetFileName($f)
    $entry = $outArchive.CreateEntry($fn)
    $es = $entry.Open()
    $fs = [System.IO.File]::OpenRead($f)
    $fs.CopyTo($es)
    $fs.Close()
    $es.Close()
}
$outArchive.Dispose()
Write-Host "  Package: $([math]::Round((Get-Item $finalKspx).Length/1KB))KB" -ForegroundColor Green

# ============================================================
# STEP 5: Deploy
# ============================================================
Write-Host "`n[5] Deploying..." -ForegroundColor Yellow
$deployStream = [System.IO.File]::OpenRead($finalKspx)
$s2 = "ME_$(Get-Date -Format 'yyyyMMddHHmmss')"
try {
    $session2 = $pdm.CreateSession($s2, $deployStream)
    $deployStream.Close()
    Write-Host "  Model: $($session2.Model.Name) Members: $($session2.Model.Members.Count)" -ForegroundColor Green
    
    foreach ($m in $session2.Model.Members) {
        $ns = try { $m.Namespace } catch { "" }
        if ($ns -like "*Workflow*" -or $m.Name -like "*SPD*" -or $m.Name -like "*Migrat*") {
            Write-Host "  ** $($m.Name) ns=$ns **" -ForegroundColor Cyan
        }
    }
    
    $session2.SetOption("NoAnalyze", $true)
    $session2.Deploy()
    Start-Sleep -Seconds 5
    $count = 0; foreach ($r in $session2.DeploymentResults) { $count++ }
    Write-Host "`n  DEPLOYED: $count items" -ForegroundColor Green
    $pdm.CloseSession($s2)
} catch {
    try { $deployStream.Close() } catch {}
    Write-Host "  Deploy failed: $($_.Exception.Message)" -ForegroundColor Red
    if ($_.Exception.InnerException) { Write-Host "  Inner: $($_.Exception.InnerException.Message)" -ForegroundColor DarkRed }
}

# ============================================================
# STEP 6: Verify
# ============================================================
Write-Host "`n[6] Processes:" -ForegroundColor Yellow
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
