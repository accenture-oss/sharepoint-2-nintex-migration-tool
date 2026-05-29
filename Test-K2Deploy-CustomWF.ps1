# ============================================================
#  Test-K2Deploy-CustomWF.ps1
#  Strategy: Take real .kspx, strip it down, inject our KPRX,
#  then deploy via PDM
#  Run in PowerShell ISE on K2 VM
# ============================================================

$ErrorActionPreference = "Continue"
$k2Bin = "C:\Program Files\K2\Bin"
$connStr = "Integrated=True;IsPrimaryLogin=True;Authenticate=True;EncryptedPassword=False;Host=localhost;Port=5555"
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$outputFile = Join-Path $scriptDir "Test-K2Deploy-CustomWF-Results.txt"
$exportDir = Join-Path $scriptDir "k2-export\_customwf"

if (-not (Test-Path $exportDir)) { New-Item -Path $exportDir -ItemType Directory -Force | Out-Null }

Start-Transcript -Path $outputFile -Force

Write-Host "============================================" -ForegroundColor White
Write-Host "  K2 Custom Workflow Deploy" -ForegroundColor White
Write-Host "============================================`n" -ForegroundColor White

# Load assemblies
Get-ChildItem "$k2Bin\SourceCode.*.dll" | ForEach-Object {
    try { [System.Reflection.Assembly]::LoadFrom($_.FullName) | Out-Null } catch {}
}
Add-Type -AssemblyName System.IO.Compression

# Connect PDM
$pdm = New-Object SourceCode.Deployment.Management.PackageDeploymentManager
$conn = $pdm.CreateConnection()
$conn.Open($connStr)
Write-Host "PDM Connected!" -ForegroundColor Green

# ============================================================
# APPROACH 1: Use a WORKFLOW-containing .kspx as template
# App Framework Core has FrameworkGeneric.Workflow inside
# ============================================================
Write-Host "`n=== APPROACH 1: Use WF-containing .kspx as template ===" -ForegroundColor Cyan

$kspxPath = "C:\Program Files\K2\Setup\App Framework Core.kspx"
$stream = [System.IO.File]::OpenRead($kspxPath)
$s1 = "WFTemplate_$(Get-Date -Format 'yyyyMMddHHmmss')"
$session = $pdm.CreateSession($s1, $stream)
$stream.Close()

$model = $session.Model
Write-Host "Loaded: $($model.Name), Members: $($model.Members.Count)" -ForegroundColor Green

# Let's find the workflow member and study its structure
Write-Host "`nSearching for workflow members..." -ForegroundColor Yellow
foreach ($member in $model.Members) {
    $ns = try { $member.Namespace } catch { "" }
    $it = $member.ItemType
    Write-Host "  [$it] $($member.Name) ns=$ns" -ForegroundColor DarkGray
    
    if ($ns -like "*Workflow*" -or $member.Name -like "*Workflow*") {
        Write-Host "  *** WORKFLOW FOUND: $($member.Name) ***" -ForegroundColor Green
        Write-Host "    Type: $($member.GetType().FullName)" -ForegroundColor DarkYellow
        Write-Host "    ItemType: $it" -ForegroundColor DarkYellow
        
        # List all properties
        $member.GetType().GetProperties() | ForEach-Object {
            $val = try { $_.GetValue($member) } catch { "ERR" }
            # Truncate long values
            $valStr = "$val"
            if ($valStr.Length -gt 100) { $valStr = $valStr.Substring(0, 100) + "..." }
            Write-Host "    PROP: $($_.Name) = $valStr" -ForegroundColor DarkCyan
        }
        
        # Check sub-members
        try {
            $subMembers = $member.GetType().GetProperty("Members")
            if ($subMembers) {
                $subs = $subMembers.GetValue($member)
                Write-Host "    Sub-members: $($subs.Count)" -ForegroundColor DarkYellow
                foreach ($sub in $subs) {
                    $subNs = try { $sub.Namespace } catch { "" }
                    Write-Host "      [$($sub.ItemType)] $($sub.Name) ns=$subNs" -ForegroundColor DarkGray
                }
            }
        } catch {}
    }
}

$pdm.CloseSession($s1)

# ============================================================
# APPROACH 2: Save real .kspx via Model.Save() to get valid format
# then study the output 
# ============================================================
Write-Host "`n=== APPROACH 2: Save .kspx from loaded model ===" -ForegroundColor Cyan

$stream2 = [System.IO.File]::OpenRead($kspxPath)
$s2 = "SaveTest_$(Get-Date -Format 'yyyyMMddHHmmss')"
$session2 = $pdm.CreateSession($s2, $stream2)
$stream2.Close()

# Save the model as .kspx
$savedKspx = Join-Path $exportDir "Saved_AppFramework.kspx"
$outStream = [System.IO.File]::Create($savedKspx)
try {
    $session2.Model.Save($outStream)
    $outStream.Close()
    Write-Host "Saved: $savedKspx ($([math]::Round((Get-Item $savedKspx).Length/1KB))KB)" -ForegroundColor Green
    
    # Extract and show contents
    $savedExtract = Join-Path $exportDir "saved_extract"
    if (Test-Path $savedExtract) { Remove-Item $savedExtract -Recurse -Force }
    [System.IO.Compression.ZipFile]::ExtractToDirectory($savedKspx, $savedExtract)
    
    Write-Host "Saved .kspx contents:" -ForegroundColor Yellow
    Get-ChildItem $savedExtract -Recurse -File | ForEach-Object {
        Write-Host "  $($_.Name) ($([math]::Round($_.Length/1KB))KB)" -ForegroundColor DarkGray
    }
    
    # Show the definition.model from SAVED version
    $savedDef = Join-Path $savedExtract "definition.model"
    if (Test-Path $savedDef) {
        $defContent = Get-Content $savedDef -Raw -Encoding UTF8
        Write-Host "`nSaved definition.model (first 2000 chars):" -ForegroundColor Yellow
        Write-Host $defContent.Substring(0, [Math]::Min(2000, $defContent.Length)) -ForegroundColor DarkYellow
    }
} catch {
    $outStream.Close()
    Write-Host "Save failed: $($_.Exception.Message)" -ForegroundColor Red
}
$pdm.CloseSession($s2)

# ============================================================
# APPROACH 3: Create session from a WORKFLOW-ONLY .kspx  
# Use K2 Basic Task Form (has workflow + simpler structure)
# ============================================================
Write-Host "`n=== APPROACH 3: K2 Basic Task Form as simpler template ===" -ForegroundColor Cyan

$btfPath = "C:\Program Files\K2\Setup\K2 Basic Task Form.kspx"
if (Test-Path $btfPath) {
    $stream3 = [System.IO.File]::OpenRead($btfPath)
    $s3 = "BTFTemplate_$(Get-Date -Format 'yyyyMMddHHmmss')"
    $session3 = $pdm.CreateSession($s3, $stream3)
    $stream3.Close()
    
    Write-Host "BTF Model: $($session3.Model.Name), Members: $($session3.Model.Members.Count)" -ForegroundColor Green
    foreach ($member in $session3.Model.Members) {
        $ns = try { $member.Namespace } catch { "" }
        Write-Host "  [$($member.ItemType)] $($member.Name) ns=$ns" -ForegroundColor DarkGray
    }
    
    # Save it for analysis 
    $btfSaved = Join-Path $exportDir "Saved_BTF.kspx"
    $outStream3 = [System.IO.File]::Create($btfSaved)
    $session3.Model.Save($outStream3)
    $outStream3.Close()
    Write-Host "Saved BTF: $btfSaved ($([math]::Round((Get-Item $btfSaved).Length/1KB))KB)" -ForegroundColor Green
    
    # Extract and show definition.model
    $btfExtract = Join-Path $exportDir "btf_extract"
    if (Test-Path $btfExtract) { Remove-Item $btfExtract -Recurse -Force }
    [System.IO.Compression.ZipFile]::ExtractToDirectory($btfSaved, $btfExtract)
    $btfDef = Get-Content (Join-Path $btfExtract "definition.model") -Raw -Encoding UTF8
    Write-Host "`nBTF definition.model (first 3000 chars):" -ForegroundColor Yellow
    Write-Host $btfDef.Substring(0, [Math]::Min(3000, $btfDef.Length)) -ForegroundColor DarkYellow
    
    $pdm.CloseSession($s3)
} else {
    Write-Host "K2 Basic Task Form.kspx not found" -ForegroundColor Red
}

# ============================================================
# APPROACH 4: Use PDM to export an EXISTING deployed workflow
# Then modify and redeploy as new process
# ============================================================
Write-Host "`n=== APPROACH 4: Export existing WF via PackageItems ===" -ForegroundColor Cyan

$s4 = "Export_$(Get-Date -Format 'yyyyMMddHHmmss')"
$session4 = $pdm.CreateSession($s4)
Write-Host "Empty session: $($session4.Model.Name)" -ForegroundColor Green

# Try FindItems to locate TestKprxWF
Write-Host "Finding items on server..." -ForegroundColor Yellow
try {
    # Look for QueryItemOptions  
    $qioType = [System.AppDomain]::CurrentDomain.GetAssemblies() | ForEach-Object {
        try { $_.GetTypes() | Where-Object { $_.Name -eq "QueryItemOptions" } } catch {}
    } | Select-Object -First 1
    
    if ($qioType) {
        Write-Host "  QueryItemOptions: $($qioType.FullName)" -ForegroundColor DarkGray
        $qio = [Activator]::CreateInstance($qioType)
        $qio.GetType().GetProperties() | ForEach-Object {
            $val = try { $_.GetValue($qio) } catch { "ERR" }
            Write-Host "  QIO PROP: $($_.Name) = $val" -ForegroundColor DarkCyan
        }
    }
    
    # Try PackageItems to export FROM server
    $pioType = [System.AppDomain]::CurrentDomain.GetAssemblies() | ForEach-Object {
        try { $_.GetTypes() | Where-Object { $_.Name -eq "PackageItemOptions" } } catch {}
    } | Select-Object -First 1
    
    if ($pioType) {
        Write-Host "  PackageItemOptions: $($pioType.FullName)" -ForegroundColor DarkGray
        $pio = [Activator]::CreateInstance($pioType)
        $pio.GetType().GetProperties() | ForEach-Object {
            $val = try { $_.GetValue($pio) } catch { "ERR" }
            Write-Host "  PIO PROP: $($_.Name) ($($_.PropertyType.Name)) = $val" -ForegroundColor DarkCyan
        }
        $pio.GetType().GetMethods() | Where-Object { $_.DeclaringType.FullName -like "SourceCode.*" } | Sort-Object Name | ForEach-Object {
            $ps = ($_.GetParameters() | ForEach-Object { "$($_.ParameterType.Name) $($_.Name)" }) -join ", "
            Write-Host "  PIO METHOD: $($_.ReturnType.Name) $($_.Name)($ps)" -ForegroundColor DarkCyan
        }
        
        # Try packaging FROM the server
        Write-Host "  Attempting PackageItems..." -ForegroundColor Yellow
        try {
            $pkgResult = $session4.PackageItems($pio)
            Write-Host "  PackageItems result: $pkgResult" -ForegroundColor Green
            $pkgResult.GetType().GetProperties() | ForEach-Object {
                $val = try { $_.GetValue($pkgResult) } catch { "ERR" }
                Write-Host "    $($_.Name) = $val" -ForegroundColor DarkYellow
            }
        } catch {
            Write-Host "  PackageItems failed: $($_.Exception.Message)" -ForegroundColor Red
        }
    }
} catch {
    Write-Host "  Discovery failed: $($_.Exception.Message)" -ForegroundColor Red
}

# Try BeginPackageItems 
Write-Host "`n  Trying DiscoverItems..." -ForegroundColor Yellow
try {
    $pioType = [System.AppDomain]::CurrentDomain.GetAssemblies() | ForEach-Object {
        try { $_.GetTypes() | Where-Object { $_.Name -eq "PackageItemOptions" } } catch {}
    } | Select-Object -First 1
    $pio2 = [Activator]::CreateInstance($pioType)
    $items = $null
    $hasItems = $session4.DiscoverItems($pio2, [ref]$items)
    Write-Host "  DiscoverItems: hasItems=$hasItems" -ForegroundColor Green
    if ($items) {
        $itemCount = 0
        foreach ($item in $items) {
            if ($itemCount -ge 20) { Write-Host "  ... more items" -ForegroundColor DarkGray; break }
            Write-Host "  Item: $($item.GetType().Name) Name=$(try{$item.Name}catch{'?'}) $(try{$item.DisplayName}catch{''})" -ForegroundColor DarkYellow
            $itemCount++
        }
    }
} catch {
    Write-Host "  DiscoverItems failed: $($_.Exception.Message)" -ForegroundColor Red
}

$pdm.CloseSession($s4)
$pdm.Dispose()

Write-Host "`n============================================" -ForegroundColor White
Write-Host "  Custom WF Deploy Test Complete!" -ForegroundColor White
Write-Host "============================================" -ForegroundColor White

Stop-Transcript
