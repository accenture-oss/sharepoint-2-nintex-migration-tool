# ============================================================
#  Deploy-K2-KPRX-Identity.ps1
#  
#  PROVEN PATH ONLY - no more experiments!
#  
#  We KNOW:
#  1. PDM session.Deploy() works (deployed 104 items)
#  2. KPRX is XML with process identity inside
#  3. The reason swap didn't create a NEW process is the KPRX  
#     still has the original identity
#
#  FIX: Modify the KPRX XML to change FolderName, process GUID,
#  and Name BEFORE packaging into .kspx
#
#  Run in PowerShell ISE on K2 VM
# ============================================================

$ErrorActionPreference = "Continue"
$k2Bin = "C:\Program Files\K2\Bin"
$connStr = "Integrated=True;IsPrimaryLogin=True;Authenticate=True;EncryptedPassword=False;Host=localhost;Port=5555"
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$outputFile = Join-Path $scriptDir "Deploy-K2-KPRX-Identity-Results.txt"
$exportDir = Join-Path $scriptDir "k2-export\_identity"

if (-not (Test-Path $exportDir)) { New-Item -Path $exportDir -ItemType Directory -Force | Out-Null }

Start-Transcript -Path $outputFile -Force

Write-Host "============================================" -ForegroundColor White
Write-Host "  K2 Deploy - KPRX Identity Modification" -ForegroundColor White
Write-Host "============================================`n" -ForegroundColor White

# Load assemblies
Get-ChildItem "$k2Bin\SourceCode.*.dll" | ForEach-Object {
    try { [System.Reflection.Assembly]::LoadFrom($_.FullName) | Out-Null } catch {}
}
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

# ============================================================
# STEP 1: Get KPRX and study its identity fields
# ============================================================
Write-Host "[1] Studying KPRX identity..." -ForegroundColor Yellow
$mgmt = New-Object SourceCode.Workflow.Management.WorkflowManagementServer
$mgmt.CreateConnection()
$mgmt.Connection.Open($connStr)
$kprxBytes = $mgmt.GetProcessKprx(13)
$kprxXml = [System.Text.Encoding]::UTF8.GetString($kprxBytes)
if ($kprxXml[0] -eq [char]0xFEFF) { $kprxXml = $kprxXml.Substring(1) }
$mgmt.Connection.Close()

# Parse as XML to find identity attributes
$xml = [xml]$kprxXml
$root = $xml.DocumentElement

Write-Host "  Root element: $($root.LocalName)" -ForegroundColor DarkGray
Write-Host "  Root attribs:" -ForegroundColor Yellow
foreach ($attr in $root.Attributes) {
    Write-Host "    $($attr.Name) = $($attr.Value)" -ForegroundColor DarkYellow
}

# Find Name, FolderName, Guid attributes throughout
Write-Host "`n  Key identity nodes:" -ForegroundColor Yellow
$nameAttrs = $root.SelectNodes("//*[@Name]")
Write-Host "  Nodes with Name attr: $($nameAttrs.Count)" -ForegroundColor DarkGray
# Show first few
$shown = 0
foreach ($n in $nameAttrs) {
    if ($shown -lt 5) {
        $guid = $n.GetAttribute("Guid")
        $folder = $n.GetAttribute("FolderName")
        $name = $n.GetAttribute("Name")
        if ($name -or $guid -or $folder) {
            Write-Host "    <$($n.LocalName) Name=`"$name`" Guid=`"$guid`" FolderName=`"$folder`">" -ForegroundColor DarkCyan
        }
        $shown++
    }
}

# Look for the Process root attributes specifically
$processNode = $root
Write-Host "`n  PROCESS identity:" -ForegroundColor Green
Write-Host "    Name      = $($processNode.GetAttribute('Name'))" -ForegroundColor Green
Write-Host "    Guid      = $($processNode.GetAttribute('Guid'))" -ForegroundColor Green
Write-Host "    FolderName= $($processNode.GetAttribute('FolderName'))" -ForegroundColor Green
Write-Host "    FullName  = $($processNode.GetAttribute('FullName'))" -ForegroundColor Green
Write-Host "    FileName  = $($processNode.GetAttribute('FileName'))" -ForegroundColor Green

# Search for FolderName anywhere
$folderNodes = $root.SelectNodes("//*[@FolderName]")
Write-Host "`n  All FolderName attributes:" -ForegroundColor Yellow
foreach ($fn in $folderNodes) {
    Write-Host "    <$($fn.LocalName)> FolderName=`"$($fn.GetAttribute('FolderName'))`" Name=`"$($fn.GetAttribute('Name'))`"" -ForegroundColor DarkYellow
}

# Look for ProcSetFolderName
$psfn = $root.SelectNodes("//*[@ProcSetFolderName]")
foreach ($p in $psfn) {
    Write-Host "    <$($p.LocalName)> ProcSetFolderName=`"$($p.GetAttribute('ProcSetFolderName'))`"" -ForegroundColor DarkYellow
}

# ============================================================
# STEP 2: Modify KPRX identity
# ============================================================
Write-Host "`n[2] Modifying KPRX identity..." -ForegroundColor Yellow

$newGuid = [System.Guid]::NewGuid().ToString()
$newName = "SPD_Migrated_Approval"
$newFolder = "SPD Migration"
$newDisplayName = "SPD Migrated Approval Workflow"

# Get old values
$oldName = $processNode.GetAttribute("Name")
$oldGuid = $processNode.GetAttribute("Guid")
$oldFolder = $processNode.GetAttribute("FolderName") 
$oldFullName = $processNode.GetAttribute("FullName")

Write-Host "  Old: Name=$oldName Guid=$oldGuid Folder=$oldFolder" -ForegroundColor DarkGray

# Set new identity on Process root
if ($oldName) { $processNode.SetAttribute("Name", $newName) }
if ($oldGuid) { $processNode.SetAttribute("Guid", $newGuid) }
if ($oldFolder) { $processNode.SetAttribute("FolderName", $newFolder) }
if ($oldFullName) { $processNode.SetAttribute("FullName", "$newFolder\$newName") }

# Also look for DisplayName
$oldDisplayName = $processNode.GetAttribute("DisplayName")
if ($oldDisplayName) { $processNode.SetAttribute("DisplayName", $newDisplayName) }

# Update FileName if present
$oldFileName = $processNode.GetAttribute("FileName")
if ($oldFileName) { $processNode.SetAttribute("FileName", "$newName.kprx") }

Write-Host "  New: Name=$newName Guid=$newGuid Folder=$newFolder" -ForegroundColor Green

# Save modified KPRX
$modKprxFile = Join-Path $exportDir "modified.kprx"
$settings = New-Object System.Xml.XmlWriterSettings
$settings.Indent = $true
$settings.Encoding = [System.Text.Encoding]::UTF8
$writer = [System.Xml.XmlWriter]::Create($modKprxFile, $settings)
$xml.Save($writer)
$writer.Close()
$modKprxBytes = [System.IO.File]::ReadAllBytes($modKprxFile)
Write-Host "  Modified KPRX: $($modKprxBytes.Length) bytes" -ForegroundColor Green

# ============================================================
# STEP 3: Load template .kspx from PDM + save
# ============================================================
Write-Host "`n[3] Creating .kspx template..." -ForegroundColor Yellow
$pdm = New-Object SourceCode.Deployment.Management.PackageDeploymentManager
$pdmConn = $pdm.CreateConnection()
$pdmConn.Open($connStr)

$kspxPath = "C:\Program Files\K2\Setup\App Framework Core.kspx"
$stream = [System.IO.File]::OpenRead($kspxPath)
$s1 = "Tmpl_$(Get-Date -Format 'yyyyMMddHHmmss')"
$session = $pdm.CreateSession($s1, $stream)
$stream.Close()

$templateKspx = Join-Path $exportDir "template.kspx"
$outStream = [System.IO.File]::Create($templateKspx)
$session.Model.Save($outStream)
$outStream.Close()
$pdm.CloseSession($s1)
Write-Host "  Template: $([math]::Round((Get-Item $templateKspx).Length/1KB))KB" -ForegroundColor Green

# ============================================================
# STEP 4: Extract, replace WF file + update definition.model
# ============================================================
Write-Host "`n[4] Modifying .kspx package..." -ForegroundColor Yellow
$extractDir = Join-Path $exportDir "extract"
if (Test-Path $extractDir) { Remove-Item $extractDir -Recurse -Force }
[System.IO.Compression.ZipFile]::ExtractToDirectory($templateKspx, $extractDir)

# Find old workflow file
$oldWfFile = Get-ChildItem $extractDir -File | Where-Object { $_.Name -like "FrameworkGeneric*" }
$oldWfFileName = if ($oldWfFile) { $oldWfFile.Name } else { "" }
Write-Host "  Old WF file: $oldWfFileName" -ForegroundColor DarkGray

# New workflow filename (K2 pattern: Name_Hash.DisplayPart)
$hash = [Convert]::ToBase64String([System.Security.Cryptography.SHA1]::Create().ComputeHash($modKprxBytes)).Replace("/","_").Replace("+","-")
$newWfFileName = "$($newName)_$($hash.Substring(0,20)).$newFolder"
Write-Host "  New WF file: $newWfFileName" -ForegroundColor Green

# Update definition.model
$defModelPath = Join-Path $extractDir "definition.model"
$defBytes = [System.IO.File]::ReadAllBytes($defModelPath)
$defContent = [System.Text.Encoding]::UTF8.GetString($defBytes)

# Replace ALL references
if ($oldWfFileName) {
    $defContent = $defContent.Replace($oldWfFileName, $newWfFileName)
    Write-Host "  Replaced file ref: $oldWfFileName -> $newWfFileName" -ForegroundColor Green
}

# Replace workflow name references  
$defContent = $defContent.Replace("Framework Core\FrameworkGeneric.Workflow.Reference", "$newFolder\$newName")
$defContent = $defContent.Replace("FrameworkGeneric%2EWorkflow%2EReference", [System.Uri]::EscapeDataString($newName))
$defContent = $defContent.Replace("Framework_Core", $newFolder.Replace(" ","_"))
$defContent = $defContent.Replace("App Framework Core", "SPD Migration Package")

[System.IO.File]::WriteAllBytes($defModelPath, [System.Text.Encoding]::UTF8.GetBytes($defContent))

# Replace workflow file
if ($oldWfFile -and (Test-Path $oldWfFile.FullName)) { Remove-Item $oldWfFile.FullName -Force }
$newWfPath = Join-Path $extractDir $newWfFileName
[System.IO.File]::WriteAllBytes($newWfPath, $modKprxBytes)
Write-Host "  Wrote modified KPRX as: $newWfFileName" -ForegroundColor Green

# Update properties.model
$propsPath = Join-Path $extractDir "properties.model"
if (Test-Path $propsPath) {
    $pc = [System.IO.File]::ReadAllText($propsPath, [System.Text.Encoding]::UTF8)
    $pc = $pc.Replace("App Framework Core", "SPD Migration Package")
    [System.IO.File]::WriteAllText($propsPath, $pc, [System.Text.Encoding]::UTF8)
}

# ============================================================
# STEP 5: Re-package + Deploy
# ============================================================
Write-Host "`n[5] Packaging + Deploying..." -ForegroundColor Yellow
$finalKspx = Join-Path $exportDir "SPD_Migration_Identity.kspx"
if (Test-Path $finalKspx) { Remove-Item $finalKspx -Force }
[System.IO.Compression.ZipFile]::CreateFromDirectory($extractDir, $finalKspx)
Write-Host "  Package: $([math]::Round((Get-Item $finalKspx).Length/1KB))KB" -ForegroundColor Green

$deployStream = [System.IO.File]::OpenRead($finalKspx)
$s2 = "Deploy_ID_$(Get-Date -Format 'yyyyMMddHHmmss')"
try {
    $session2 = $pdm.CreateSession($s2, $deployStream)
    $deployStream.Close()
    Write-Host "  Model: $($session2.Model.Name) Members: $($session2.Model.Members.Count)" -ForegroundColor Green
    
    # Show workflow members
    foreach ($m in $session2.Model.Members) {
        $ns = try { $m.Namespace } catch { "" }
        if ($ns -like "*Workflow*") {
            Write-Host "  WF: $($m.Name) ns=$ns" -ForegroundColor Cyan
        }
    }
    
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

# ============================================================
# STEP 6: Verify
# ============================================================
Write-Host "`n[6] Verifying on K2 server..." -ForegroundColor Yellow
$mgmt2 = New-Object SourceCode.Workflow.Management.WorkflowManagementServer
$mgmt2.CreateConnection()
$mgmt2.Connection.Open($connStr)
foreach ($ps in $mgmt2.GetProcSets()) {
    $marker = ""
    if ($ps.FullName -like "*SPD*" -or $ps.FullName -like "*Migrat*") { $marker = " <<< NEW!" }
    Write-Host "  $($ps.FullName) (ID=$($ps.ProcSetID))$marker" -ForegroundColor $(if($marker){"Green"}else{"DarkGray"})
}
Write-Host "  Total: $($mgmt2.GetProcSets().Count) processes" -ForegroundColor Yellow
$mgmt2.Connection.Close()
$pdm.Dispose()

Write-Host "`n============================================" -ForegroundColor White
Write-Host "  Deploy Complete!" -ForegroundColor White
Write-Host "============================================" -ForegroundColor White

Stop-Transcript
