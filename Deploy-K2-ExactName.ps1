# ============================================================
#  Deploy-K2-ExactName.ps1
#  
#  ROOT CAUSE FOUND: ServicePackage.GetStream(Uri itemUri)
#  K2 reads the KPRX by its ZIP ENTRY NAME/URI from the kspx.
#  When we renamed the file, GetStream can't find it.
#
#  FIX: Write our KPRX using the EXACT SAME entry name as the 
#  original (including the + character), so GetStream resolves.
#
#  Run in PowerShell ISE on K2 VM
# ============================================================

$ErrorActionPreference = "Continue"
$k2Bin = "C:\Program Files\K2\Bin"
$connStr = "Integrated=True;IsPrimaryLogin=True;Authenticate=True;EncryptedPassword=False;Host=localhost;Port=5555"
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$outputFile = Join-Path $scriptDir "Deploy-K2-ExactName-Results.txt"
$exportDir = Join-Path $scriptDir "k2-export\_exact"

if (-not (Test-Path $exportDir)) { New-Item -Path $exportDir -ItemType Directory -Force | Out-Null }

Start-Transcript -Path $outputFile -Force

Write-Host "============================================" -ForegroundColor White
Write-Host "  K2 Deploy - Exact Entry Name" -ForegroundColor White
Write-Host "============================================`n" -ForegroundColor White

Get-ChildItem "$k2Bin\SourceCode.*.dll" | ForEach-Object {
    try { [System.Reflection.Assembly]::LoadFrom($_.FullName) | Out-Null } catch {}
}
Add-Type -AssemblyName System.IO.Compression
Add-PSSnapin SourceCode.Deployment.PowerShell -ErrorAction SilentlyContinue

# Get KPRX
$mgmt = New-Object SourceCode.Workflow.Management.WorkflowManagementServer
$mgmt.CreateConnection()
$mgmt.Connection.Open($connStr)
$kprxBytes = $mgmt.GetProcessKprx(13)
$mgmt.Connection.Close()

# Modify identity via simple .Replace()
$kprxStr = [System.Text.Encoding]::UTF8.GetString($kprxBytes)
$newGuid = [System.Guid]::NewGuid().ToString("N")
$kprxStr = $kprxStr.Replace("<Guid>65aaa9ae4e5b4d8b839d9edf44eea93a</Guid>", "<Guid>$newGuid</Guid>")
$kprxStr = $kprxStr.Replace("<Name>TestKprxWF</Name>", "<Name>SPD_Migrated_Approval</Name>")
$kprxStr = $kprxStr.Replace("<DisplayName>TestKprxWF</DisplayName>", "<DisplayName>SPD Migrated Approval</DisplayName>")
$kprxStr = $kprxStr.Replace("<CategoryPath>Workflow</CategoryPath>", "<CategoryPath>SPD Migration</CategoryPath>")
$kprxStr = $kprxStr.Replace("<ExtenderNamespace>65aaa9ae4e5b4d8b839d9edf44eea93a</ExtenderNamespace>", "<ExtenderNamespace>$newGuid</ExtenderNamespace>")
$modBytes = [System.Text.Encoding]::UTF8.GetBytes($kprxStr)
Write-Host "KPRX: $($kprxBytes.Length) -> $($modBytes.Length) bytes" -ForegroundColor Green

# ============================================================
# Build kspx by REPLACING the WF entry content (same name!)
# ============================================================
Write-Host "`n[1] Building kspx with exact entry names..." -ForegroundColor Yellow

$pdm = New-Object SourceCode.Deployment.Management.PackageDeploymentManager
$pdmConn = $pdm.CreateConnection()
$pdmConn.Open($connStr)
$stream = [System.IO.File]::OpenRead("C:\Program Files\K2\Setup\App Framework Core.kspx")
$s1 = "EN_$(Get-Date -Format 'yyyyMMddHHmmss')"
$session = $pdm.CreateSession($s1, $stream)
$stream.Close()
$templateKspx = Join-Path $exportDir "template.kspx"
$outStream = [System.IO.File]::Create($templateKspx)
$session.Model.Save($outStream)
$outStream.Close()
$pdm.CloseSession($s1)

# Read the template ZIP, write a new ZIP with the SAME entry names
# but replace the WF content with our modified KPRX
$finalKspx = Join-Path $exportDir "exact_deploy.kspx"
if (Test-Path $finalKspx) { Remove-Item $finalKspx -Force }

$inArchive = [System.IO.Compression.ZipFile]::OpenRead($templateKspx)
$outArchive = [System.IO.Compression.ZipFile]::Open($finalKspx, [System.IO.Compression.ZipArchiveMode]::Create)

$wfEntryName = $null
foreach ($entry in $inArchive.Entries) {
    if ($entry.Name -match "FrameworkGeneric\.Workflow") {
        $wfEntryName = $entry.Name
        # Create entry with EXACT SAME name, but our content
        $newEntry = $outArchive.CreateEntry($entry.Name)
        $es = $newEntry.Open()
        $es.Write($modBytes, 0, $modBytes.Length)
        $es.Close()
        Write-Host "  REPLACED: $($entry.Name) ($($entry.Length) -> $($modBytes.Length) bytes)" -ForegroundColor Green
    } elseif ($entry.Name -eq "definition.model") {
        # Modify definition.model
        $reader = $entry.Open()
        $ms = New-Object System.IO.MemoryStream
        $reader.CopyTo($ms)
        $reader.Close()
        $defContent = [System.Text.Encoding]::UTF8.GetString($ms.ToArray())
        $ms.Close()
        
        # Only change WF-related entries
        $defContent = $defContent.Replace("Framework Core\FrameworkGeneric.Workflow.Reference", "SPD Migration\SPD_Migrated_Approval")
        $defContent = $defContent.Replace("FrameworkGeneric%2EWorkflow%2EReference", "SPD_Migrated_Approval")
        $defContent = $defContent.Replace("FrameworkGeneric.Workflow.Reference", "SPD_Migrated_Approval")
        $defContent = $defContent.Replace(
            "urn:SourceCode/Categories?Framework_Core#Path.%2Froot%2FApps%2FK2%2FFramework%2FCore%2FWorkflows%2F",
            "urn:SourceCode/Categories?SPD_Migration#Path.%2Froot%2FApps%2FK2%2FFramework%2FCore%2FWorkflows%2F")
        
        $defBytes = [System.Text.Encoding]::UTF8.GetBytes($defContent)
        $newEntry = $outArchive.CreateEntry("definition.model")
        $es = $newEntry.Open()
        $es.Write($defBytes, 0, $defBytes.Length)
        $es.Close()
        Write-Host "  UPDATED: definition.model" -ForegroundColor Green
    } else {
        # Copy unchanged
        $newEntry = $outArchive.CreateEntry($entry.Name)
        $entryStream = $entry.Open()
        $newEntryStream = $newEntry.Open()
        $entryStream.CopyTo($newEntryStream)
        $newEntryStream.Close()
        $entryStream.Close()
    }
}
$inArchive.Dispose()
$outArchive.Dispose()
Write-Host "  WF entry name preserved: $wfEntryName" -ForegroundColor Cyan
Write-Host "  Package: $([math]::Round((Get-Item $finalKspx).Length/1KB))KB" -ForegroundColor Green

# ============================================================
# Deploy
# ============================================================
Write-Host "`n[2] Deploy-Package..." -ForegroundColor Yellow
$deployConfigXml = Join-Path $exportDir "deploy_config.xml"
Write-DeploymentConfig -InputFile $finalKspx -OutputFile $deployConfigXml
Write-Host "  Config generated" -ForegroundColor Green
Deploy-Package -FileName $finalKspx -ConfigFile $deployConfigXml -ConnectionString $connStr
Write-Host "`n  Deploy-Package completed!" -ForegroundColor Green

# ============================================================
# Check Event Log for the latest entry 
# ============================================================
Write-Host "`n[3] Latest K2 event:" -ForegroundColor Yellow
try {
    $events = Get-WinEvent -LogName Application -MaxEvents 5 -ErrorAction SilentlyContinue |
        Where-Object { $_.ProviderName -like "*SourceCode*" }
    foreach ($ev in $events | Select-Object -First 2) {
        Write-Host "  [$($ev.TimeCreated)] $($ev.Message.Substring(0, [Math]::Min(800, $ev.Message.Length)))" -ForegroundColor DarkYellow
    }
} catch {}

# ============================================================
# VERIFY
# ============================================================
Write-Host "`n[4] Processes:" -ForegroundColor Yellow
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
