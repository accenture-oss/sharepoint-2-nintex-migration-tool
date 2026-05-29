##############################################################
# K2 Deployment Discovery - Phase 2
# Find K2 PowerShell modules, cmdlets, and CLI tools
##############################################################

$outFile = Join-Path (Get-Location) "Test-K2Deploy-Results.txt"
Start-Transcript -Path $outFile -Force | Out-Null

$k2Bin = "C:\Program Files\K2\Bin"
$K2Server = "localhost"
$K2Port = 5555

Write-Host "============================================"
Write-Host "  K2 Deployment Discovery Phase 2"
Write-Host "  $(Get-Date)"
Write-Host "============================================"

# 1. Check for K2 PowerShell modules
Write-Host "`n[1] K2 PowerShell Modules:"
$k2Modules = Get-Module -ListAvailable | Where-Object { $_.Name -match "K2|SourceCode" }
if ($k2Modules) {
    foreach ($m in $k2Modules) {
        Write-Host "  Module: $($m.Name) v$($m.Version) at $($m.Path)"
    }
} else {
    Write-Host "  No K2 modules found in standard paths"
}

# Check K2-specific module paths
$k2ModulePaths = @(
    "C:\Program Files\K2\Bin\Modules",
    "C:\Program Files\K2\PowerShell",
    "C:\Program Files\K2\Modules"
)
foreach ($mp in $k2ModulePaths) {
    if (Test-Path $mp) {
        Write-Host "  K2 Module Path: $mp"
        Get-ChildItem $mp -Recurse -Filter "*.psd1" | ForEach-Object {
            Write-Host "    $($_.FullName)"
        }
    }
}

# 2. Check for K2 snap-ins
Write-Host "`n[2] K2 PowerShell Snap-ins:"
$snapins = Get-PSSnapin -Registered -ErrorAction SilentlyContinue | Where-Object { $_.Name -match "K2|SourceCode" }
if ($snapins) {
    foreach ($s in $snapins) {
        Write-Host "  Snap-in: $($s.Name) - $($s.Description)"
    }
} else {
    Write-Host "  No K2 snap-ins registered"
}

# 3. Check for K2 CLI tools
Write-Host "`n[3] K2 Command Line Tools:"
$cliTools = @(
    "C:\Program Files\K2\Bin\K2Deploy.exe",
    "C:\Program Files\K2\Bin\K2Package.exe",
    "C:\Program Files\K2\Bin\PackageDeploy.exe",
    "C:\Program Files\K2\Bin\SourceCode.Deployment.exe",
    "C:\Program Files\K2\Bin\SmartBroker.exe"
)
foreach ($tool in $cliTools) {
    if (Test-Path $tool) {
        Write-Host "  FOUND: $tool"
    }
}
# Also search for any .exe with Deploy/Package in name
$k2Exes = Get-ChildItem $k2Bin -Filter "*.exe" | Where-Object { $_.Name -match "Deploy|Package|Process" }
foreach ($exe in $k2Exes) {
    Write-Host "  EXE: $($exe.Name) ($([math]::Round($exe.Length/1KB))KB)"
}

# 4. Check for K2 PowerShell cmdlet DLLs
Write-Host "`n[4] K2 PowerShell Cmdlet DLLs:"
$psDlls = Get-ChildItem $k2Bin -Filter "*.dll" | Where-Object { $_.Name -match "PowerShell|Cmdlet" }
foreach ($d in $psDlls) {
    Write-Host "  $($d.Name)"
    try {
        Add-Type -Path $d.FullName -ErrorAction SilentlyContinue
        $asm = [System.Reflection.Assembly]::LoadFrom($d.FullName)
        $cmdletTypes = $asm.GetTypes() | Where-Object {
            $_.IsClass -and (-not $_.IsAbstract) -and
            ($_.BaseType.Name -match "Cmdlet|PSCmdlet" -or $_.Name -match "Cmdlet")
        }
        foreach ($ct in $cmdletTypes) {
            # Get CmdletAttribute to find the verb-noun
            $cmdletAttr = $ct.GetCustomAttributes($true) | Where-Object { $_.TypeId.Name -eq "CmdletAttribute" }
            if ($cmdletAttr) {
                Write-Host "    Cmdlet: $($cmdletAttr.VerbName)-$($cmdletAttr.NounName)"
            } else {
                Write-Host "    Type: $($ct.FullName)"
            }
        }
    } catch {
        Write-Host "    (could not inspect)"
    }
}

# 5. Try loading K2 deployment snap-in/module and listing commands
Write-Host "`n[5] Attempting to import K2 deployment..."
try {
    # Try importing SourceCode.Deployment.PowerShell as a module
    $dllPath = Join-Path $k2Bin "SourceCode.Deployment.PowerShell.dll"
    if (Test-Path $dllPath) {
        Import-Module $dllPath -ErrorAction Stop
        Write-Host "  Imported SourceCode.Deployment.PowerShell as module!"
        $cmds = Get-Command -Module "SourceCode.Deployment.PowerShell" -ErrorAction SilentlyContinue
        foreach ($c in $cmds) {
            Write-Host "    $($c.Name) [$($c.CommandType)]"
        }
    }
} catch {
    Write-Host "  Module import failed: $($_.Exception.Message)"
}

# 6. Look for .kspx files (existing deployment packages)  
Write-Host "`n[6] Existing .kspx deployment packages:"
$kspxFiles = Get-ChildItem "C:\Program Files\K2" -Filter "*.kspx" -Recurse -ErrorAction SilentlyContinue | Select-Object -First 10
foreach ($f in $kspxFiles) {
    Write-Host "  $($f.FullName) ($([math]::Round($f.Length/1KB))KB)"
}
if (-not $kspxFiles) {
    Write-Host "  No .kspx files found under K2 directory"
}

# 7. Check K2 services and URLs
Write-Host "`n[7] K2 Services (TCP check):"
foreach ($port in @(5252, 5555, 80, 443)) {
    try {
        $tcp = New-Object System.Net.Sockets.TcpClient
        $tcp.Connect($K2Server, $port)
        Write-Host "  Port $port : OPEN"
        $tcp.Close()
    } catch {
        Write-Host "  Port $port : closed"
    }
}

# 8. Check K2 web services
Write-Host "`n[8] K2 Web Service endpoints:"
foreach ($url in @(
    "http://localhost:5555/K2Services/",
    "http://localhost:5252/K2Services/",
    "http://localhost:80/K2/",
    "http://localhost/Designer/",
    "http://localhost/Workspace/"
)) {
    try {
        $resp = Invoke-WebRequest -Uri $url -UseDefaultCredentials -TimeoutSec 5 -ErrorAction Stop
        Write-Host "  $url -> $($resp.StatusCode)"
    } catch {
        if ($_.Exception.Response) {
            Write-Host "  $url -> $($_.Exception.Response.StatusCode)"
        } else {
            Write-Host "  $url -> error: $($_.Exception.Message.Substring(0, [Math]::Min(80, $_.Exception.Message.Length)))"
        }
    }
}

# 9. Detailed PackageDeployer test
Write-Host "`n[9] PackageDeployer test:"
try {
    Add-Type -Path (Join-Path $k2Bin "SourceCode.Framework.dll")
    $deployer = New-Object SourceCode.Framework.Deployment.PackageDeployer
    Write-Host "  PackageDeployer created successfully"
    
    # What does Main() expect?
    $mainMethod = $deployer.GetType().GetMethod("Main")
    $params = $mainMethod.GetParameters()
    foreach ($p in $params) {
        Write-Host "  Main param: $($p.ParameterType.FullName) $($p.Name)"
    }
} catch {
    Write-Host "  PackageDeployer failed: $($_.Exception.Message)"
}

# 10. Check for deployment project file examples
Write-Host "`n[10] Looking for .proj/.k2proj deployment files:"
$projFiles = Get-ChildItem "C:\Program Files\K2" -Filter "*.k2proj" -Recurse -ErrorAction SilentlyContinue | Select-Object -First 10
$projFiles2 = Get-ChildItem "C:\Program Files\K2" -Filter "*deploy*.xml" -Recurse -ErrorAction SilentlyContinue | Select-Object -First 10
foreach ($f in ($projFiles + $projFiles2)) {
    Write-Host "  $($f.FullName)"
    # Show first few lines
    $content = Get-Content $f.FullName -First 10
    foreach ($line in $content) {
        Write-Host "    $line"
    }
}

Write-Host "`n============================================"
Write-Host "  Discovery Phase 2 Complete!"
Write-Host "  Results: $outFile"
Write-Host "============================================"

Stop-Transcript | Out-Null
Write-Host "Output saved to: $outFile" -ForegroundColor Green
