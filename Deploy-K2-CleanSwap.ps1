# ============================================================
#  Deploy-K2-CleanSwap.ps1
#  
#  ROOT CAUSE FOUND: The old FrameworkGeneric.Workflow file
#  was NEVER being deleted because the '+' char in the filename
#  breaks PowerShell's -like operator.
#
#  This script:
#  1. Extracts .kspx with Model.Save()
#  2. REMOVES all non-essential files (Forms, Views, SmartObjects, images)
#  3. Keeps ONLY: definition.model, properties.model, validation.model,
#     changesets.model, certificate.hash, publicKey.xml, and our NEW WF file
#  4. Builds a MINIMAL .kspx with just the workflow
#  5. Updates definition.model to ONLY reference our workflow
#
#  Run in PowerShell ISE on K2 VM
# ============================================================

$ErrorActionPreference = "Continue"
$k2Bin = "C:\Program Files\K2\Bin"
$connStr = "Integrated=True;IsPrimaryLogin=True;Authenticate=True;EncryptedPassword=False;Host=localhost;Port=5555"
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$outputFile = Join-Path $scriptDir "Deploy-K2-CleanSwap-Results.txt"
$exportDir = Join-Path $scriptDir "k2-export\_cleanswap"

if (-not (Test-Path $exportDir)) { New-Item -Path $exportDir -ItemType Directory -Force | Out-Null }

Start-Transcript -Path $outputFile -Force

Write-Host "============================================" -ForegroundColor White
Write-Host "  K2 Clean Swap Deploy" -ForegroundColor White
Write-Host "============================================`n" -ForegroundColor White

# Load assemblies
Get-ChildItem "$k2Bin\SourceCode.*.dll" | ForEach-Object {
    try { [System.Reflection.Assembly]::LoadFrom($_.FullName) | Out-Null } catch {}
}
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

# Get KPRX
Write-Host "[1] Getting KPRX..." -ForegroundColor Yellow
$mgmt = New-Object SourceCode.Workflow.Management.WorkflowManagementServer
$mgmt.CreateConnection()
$mgmt.Connection.Open($connStr)
$kprxBytes = $mgmt.GetProcessKprx(13)
$mgmt.Connection.Close()
Write-Host "  KPRX: $($kprxBytes.Length) bytes" -ForegroundColor Green

# Save template
Write-Host "`n[2] Creating template..." -ForegroundColor Yellow
$pdm = New-Object SourceCode.Deployment.Management.PackageDeploymentManager
$pdmConn = $pdm.CreateConnection()
$pdmConn.Open($connStr)

$stream = [System.IO.File]::OpenRead("C:\Program Files\K2\Setup\App Framework Core.kspx")
$s1 = "T_$(Get-Date -Format 'yyyyMMddHHmmss')"
$session = $pdm.CreateSession($s1, $stream)
$stream.Close()
$templateKspx = Join-Path $exportDir "template.kspx"
$outStream = [System.IO.File]::Create($templateKspx)
$session.Model.Save($outStream)
$outStream.Close()
$pdm.CloseSession($s1)

# Extract
Write-Host "`n[3] Extracting + cleaning..." -ForegroundColor Yellow
$extractDir = Join-Path $exportDir "extract"
if (Test-Path $extractDir) { Remove-Item $extractDir -Recurse -Force }
[System.IO.Compression.ZipFile]::ExtractToDirectory($templateKspx, $extractDir)

# List ALL files and identify them
$allFiles = Get-ChildItem $extractDir -File
Write-Host "  Total files: $($allFiles.Count)" -ForegroundColor DarkGray

# Essential files to KEEP
$keepFiles = @("definition.model", "properties.model", "validation.model", "changesets.model", "certificate.hash", "publicKey.xml")

# Delete everything EXCEPT essential files
$deleted = 0
foreach ($f in $allFiles) {
    if ($f.Name -notin $keepFiles) {
        Remove-Item $f.FullName -Force
        $deleted++
    }
}
Write-Host "  Deleted $deleted non-essential files" -ForegroundColor Green
Write-Host "  Remaining:" -ForegroundColor Yellow
Get-ChildItem $extractDir -File | ForEach-Object { Write-Host "    $($_.Name) ($([math]::Round($_.Length/1KB))KB)" -ForegroundColor DarkGray }

# Write our KPRX as the workflow file
$wfFileName = "SPDMigratedApproval.Workflow"
$wfPath = Join-Path $extractDir $wfFileName
[System.IO.File]::WriteAllBytes($wfPath, $kprxBytes)
Write-Host "  Added: $wfFileName ($([math]::Round($kprxBytes.Length/1KB))KB)" -ForegroundColor Green

# ============================================================
# STEP 4: Build MINIMAL definition.model
# ============================================================
Write-Host "`n[4] Building minimal definition.model..." -ForegroundColor Yellow

$newGuid = [System.Guid]::NewGuid().ToString()
$processName = "SPD Migrated Approval"
$folderName = "SPD Migration"
$encodedProcName = [System.Uri]::EscapeDataString($processName).Replace("%20", "+")

# Build a minimal definition.model based on the REAL schema we extracted
$defModel = @"
<?xml version="1.0" encoding="utf-8"?>
<model id="1" name="SPD Migration Package" itemtype="2" apiver="9" ns="" excl="False" desc="Auto-migrated from SharePoint Designer" nextid="100" minorApiVer="5">
  <set id="2" name="Members" itemtype="4" apiver="9" readonly="False" count="4" xmlns="urn:SourceCode/ComponentModel">
    <ct id="3" name="$folderName" itemtype="10" apiver="9" ns="urn:SourceCode/Categories?$($folderName.Replace(' ','_'))#Path.%2Froot%2FSPD+Migration%2F" excl="False" displayname="$folderName" scope="0" hostversion="5.16.1000.0" flags="4">
      <tref id="4" name="Category" itemtype="9" apiver="9" required="True" ns="urn:SourceCode/Category" displayname="Category" scope="0" dataType="1" flags="0">
        <null />
        <null />
      </tref>
      <null xmlns="" />
      <set id="5" name="Members" itemtype="4" readonly="False" count="2" xmlns="">
        <prop id="6" name="Id" itemtype="13" ns="urn:SourceCode/Categories?$($folderName.Replace(' ','_'))#Path.%2Froot%2FSPD+Migration%2F" excl="False" displayname="Id" scope="0" unique="True" modAttr="1">
          <tref id="7" name="Int32" itemtype="9" required="True" ns="urn:SourceCode/ComponentModel" displayname="Int32" scope="0" dataType="9" flags="0">
            <null />
            <null />
          </tref>
          <valueref id="9" name="Value" itemtype="6" required="True" type="9" value="200" />
          <null />
          <set id="8" name="References" itemtype="4" readonly="False" count="0" />
        </prop>
        <prop id="10" name="Description" itemtype="13" ns="urn:SourceCode/Categories?$($folderName.Replace(' ','_'))#Path.%2Froot%2FSPD+Migration%2F" excl="False" displayname="Description" scope="0" unique="False" modAttr="3">
          <tref id="11" name="String" itemtype="9" required="True" ns="urn:SourceCode/ComponentModel" displayname="String" scope="0" dataType="18" flags="0">
            <null />
            <null />
          </tref>
          <valueref id="13" name="Value" itemtype="6" required="True" type="18" value="" />
          <null />
          <set id="12" name="References" itemtype="4" readonly="False" count="0" />
        </prop>
      </set>
      <set id="14" name="References" itemtype="4" readonly="False" count="1" xmlns="">
        <tref id="15" name="$folderName\$processName" itemtype="9" required="True" ns="urn:SourceCode/Workflows" displayname="$processName" scope="0" dataType="1" flags="0">
          <null />
          <tref id="16" name="Process" itemtype="9" required="True" ns="urn:SourceCode/Workflow" displayname="Process" scope="0" dataType="1" flags="0">
            <null />
            <tref id="17" name="Object" itemtype="9" required="True" ns="urn:SourceCode/ComponentModel" displayname="Object" scope="0" dataType="1" flags="0">
              <null />
              <null />
            </tref>
          </tref>
        </tref>
      </set>
    </ct>
    <ct id="20" name="$folderName\$processName" itemtype="10" ns="urn:SourceCode/Workflows" excl="False" displayname="$processName" scope="0" hostversion="5.16.1000.0" flags="4">
      <tref id="21" name="Process" itemtype="9" required="True" ns="urn:SourceCode/Workflow" displayname="Process" scope="0" dataType="1" flags="0">
        <null />
        <tref id="22" name="Object" itemtype="9" required="True" ns="urn:SourceCode/ComponentModel" displayname="Object" scope="0" dataType="1" flags="0">
          <null />
          <null />
        </tref>
      </tref>
      <fileitem id="23" name="Definition" itemtype="12" file="$wfFileName" />
      <set id="24" name="Members" itemtype="4" readonly="False" count="0" />
      <set id="25" name="References" itemtype="4" readonly="False" count="0" />
    </ct>
    <ct id="30" name="root" itemtype="10" ns="urn:SourceCode/Categories?root#Path.%2F" excl="False" displayname="root" scope="0" hostversion="5.16.1000.0" flags="4">
      <tref id="31" name="Category" itemtype="9" apiver="9" required="True" ns="urn:SourceCode/Category" displayname="Category" scope="0" dataType="1" flags="0">
        <null />
        <null />
      </tref>
      <null xmlns="" />
      <set id="32" name="Members" itemtype="4" readonly="False" count="2" xmlns="">
        <prop id="33" name="Id" itemtype="13" ns="urn:SourceCode/Categories?root#Path.%2F" excl="False" displayname="Id" scope="0" unique="True" modAttr="1">
          <tref id="34" name="Int32" itemtype="9" required="True" ns="urn:SourceCode/ComponentModel" displayname="Int32" scope="0" dataType="9" flags="0">
            <null />
            <null />
          </tref>
          <valueref id="36" name="Value" itemtype="6" required="True" type="9" value="1" />
          <null />
          <set id="35" name="References" itemtype="4" readonly="False" count="0" />
        </prop>
        <prop id="37" name="Description" itemtype="13" ns="urn:SourceCode/Categories?root#Path.%2F" excl="False" displayname="Description" scope="0" unique="False" modAttr="3">
          <tref id="38" name="String" itemtype="9" required="True" ns="urn:SourceCode/ComponentModel" displayname="String" scope="0" dataType="18" flags="0">
            <null />
            <null />
          </tref>
          <valueref id="40" name="Value" itemtype="6" required="True" type="18" value="" />
          <null />
          <set id="39" name="References" itemtype="4" readonly="False" count="0" />
        </prop>
      </set>
      <set id="41" name="References" itemtype="4" readonly="False" count="0" xmlns="" />
    </ct>
  </set>
</model>
"@

$defModelPath = Join-Path $extractDir "definition.model"
[System.IO.File]::WriteAllText($defModelPath, $defModel, [System.Text.Encoding]::UTF8)
Write-Host "  Wrote minimal definition.model ($([math]::Round($defModel.Length/1KB))KB)" -ForegroundColor Green

# Update properties.model
$propsModel = @"
<?xml version="1.0" encoding="utf-8"?>
<properties name="SPD Migration Package" />
"@
[System.IO.File]::WriteAllText((Join-Path $extractDir "properties.model"), $propsModel, [System.Text.Encoding]::UTF8)

# Show final contents
Write-Host "`n  Final package contents:" -ForegroundColor Yellow
Get-ChildItem $extractDir -File | ForEach-Object { Write-Host "    $($_.Name) ($([math]::Round($_.Length/1KB))KB)" -ForegroundColor DarkGray }

# ============================================================
# STEP 5: Package + Deploy
# ============================================================
Write-Host "`n[5] Packaging + Deploying..." -ForegroundColor Yellow
$finalKspx = Join-Path $exportDir "SPD_CleanSwap.kspx"
if (Test-Path $finalKspx) { Remove-Item $finalKspx -Force }
[System.IO.Compression.ZipFile]::CreateFromDirectory($extractDir, $finalKspx)
Write-Host "  Package: $([math]::Round((Get-Item $finalKspx).Length/1KB))KB" -ForegroundColor Green

$deployStream = [System.IO.File]::OpenRead($finalKspx)
$s2 = "CS_$(Get-Date -Format 'yyyyMMddHHmmss')"
try {
    $session2 = $pdm.CreateSession($s2, $deployStream)
    $deployStream.Close()
    Write-Host "  Model: $($session2.Model.Name) Members: $($session2.Model.Members.Count)" -ForegroundColor Green
    
    foreach ($m in $session2.Model.Members) {
        $ns = try { $m.Namespace } catch { "" }
        Write-Host "    [$($m.ItemType)] $($m.Name) ns=$ns" -ForegroundColor DarkCyan
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
Write-Host "`n[6] Verifying..." -ForegroundColor Yellow
$mgmt2 = New-Object SourceCode.Workflow.Management.WorkflowManagementServer
$mgmt2.CreateConnection()
$mgmt2.Connection.Open($connStr)
$allProcs = $mgmt2.GetProcSets()
foreach ($ps in $allProcs) {
    $marker = ""
    if ($ps.FullName -like "*SPD*" -or $ps.FullName -like "*Migrat*") { $marker = " <<< NEW!" }
    Write-Host "  $($ps.FullName) (ID=$($ps.ProcSetID))$marker" -ForegroundColor $(if($marker){"Green"}else{"DarkGray"})
}
Write-Host "  Total: $($allProcs.Count) processes" -ForegroundColor Yellow
$mgmt2.Connection.Close()
$pdm.Dispose()

Write-Host "`n============================================" -ForegroundColor White
Write-Host "  Clean Swap Deploy Complete!" -ForegroundColor White
Write-Host "============================================" -ForegroundColor White

Stop-Transcript
