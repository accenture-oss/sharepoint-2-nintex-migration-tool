##############################################################
# K2 SDK Discovery Test Script
# Run directly on the K2 server (NINTEX-SP-POC)
# Outputs results to Test-K2SDK-Results.txt
##############################################################

$k2Bin = "C:\Program Files\K2\Bin"
$K2Server = "localhost"
$K2Port = 5555
$outFile = Join-Path (Get-Location) "Test-K2SDK-Results.txt"

# Redirect all output to file AND console
Start-Transcript -Path $outFile -Force | Out-Null

Write-Host "============================================"
Write-Host "  K2 SDK Discovery - $(Get-Date)"
Write-Host "  Server: $K2Server : $K2Port"
Write-Host "============================================"

# 1. Find ALL deployment-related DLLs
Write-Host "`n[1] Scanning $k2Bin for DLLs..."
$allDlls = Get-ChildItem $k2Bin -Filter "*.dll" | Where-Object {
    $_.Name -match "Deploy|Package|Workflow|SmartObject|Hosting|Environment|Process|Framework|HostClient"
}
Write-Host "  Found $($allDlls.Count) relevant DLLs:"
foreach ($d in $allDlls) {
    Write-Host "    $($d.Name) ($([math]::Round($d.Length/1KB))KB)"
}

# 2. Load core DLLs
Write-Host "`n[2] Loading SDK assemblies..."
$loaded = @()
$coreDlls = @(
    "SourceCode.Framework.dll",
    "SourceCode.HostClientAPI.dll",
    "SourceCode.Workflow.Authoring.dll",
    "SourceCode.Workflow.Design.dll",
    "SourceCode.Workflow.Client.dll",
    "SourceCode.Workflow.Management.dll"
)

foreach ($dll in $coreDlls) {
    $p = Join-Path $k2Bin $dll
    if (Test-Path $p) {
        try { Add-Type -Path $p; $loaded += $dll; Write-Host "  OK: $dll" }
        catch { Write-Host "  FAIL: $dll - $($_.Exception.Message)" }
    } else {
        Write-Host "  NOT FOUND: $dll"
    }
}

# Load Deploy/Package DLLs
foreach ($dll in (Get-ChildItem $k2Bin -Filter "*.dll" | Where-Object { $_.Name -match "Deploy|Package" })) {
    try { Add-Type -Path $dll.FullName; $loaded += $dll.Name; Write-Host "  OK: $($dll.Name)" }
    catch { Write-Host "  SKIP: $($dll.Name)" }
}

Write-Host "  Total loaded: $($loaded.Count)"

# 3. Find ALL concrete SourceCode types (comprehensive)
Write-Host "`n[3] ALL concrete SourceCode types with deployment/process/package methods:"
foreach ($asm in [AppDomain]::CurrentDomain.GetAssemblies()) {
    try {
        $types = $asm.GetTypes() | Where-Object {
            $_.IsClass -and (-not $_.IsAbstract) -and
            $_.FullName -like "SourceCode.*" -and
            $_.FullName -match "Deploy|Package|Process|Workflow"
        }
        foreach ($t in $types) {
            Write-Host ""
            Write-Host "  TYPE: $($t.FullName)"
            Write-Host "  Assembly: $($t.Assembly.GetName().Name)"

            # Constructors
            $ctors = $t.GetConstructors()
            foreach ($c in $ctors) {
                $ps = ($c.GetParameters() | ForEach-Object { "$($_.ParameterType.Name) $($_.Name)" }) -join ", "
                Write-Host "    CTOR($ps)"
            }

            # Public instance methods (declared only)
            $methods = $t.GetMethods([System.Reflection.BindingFlags]::Public -bor [System.Reflection.BindingFlags]::Instance -bor [System.Reflection.BindingFlags]::DeclaredOnly) |
                Where-Object { $_.Name -notmatch "^(get_|set_|add_|remove_|Equals|GetHash|ToString|GetType|Dispose|Finalize)" }
            foreach ($m in $methods) {
                $ps = ($m.GetParameters() | ForEach-Object { "$($_.ParameterType.Name) $($_.Name)" }) -join ", "
                Write-Host "    $($m.ReturnType.Name) $($m.Name)($ps)"
            }

            # Public properties
            $props = $t.GetProperties([System.Reflection.BindingFlags]::Public -bor [System.Reflection.BindingFlags]::Instance -bor [System.Reflection.BindingFlags]::DeclaredOnly)
            if ($props.Count -gt 0) {
                Write-Host "    Properties: $($props.Name -join ', ')"
            }
        }
    } catch {}
}

# 4. Connect to management server
Write-Host "`n============================================"
Write-Host "[4] Connecting to K2 Management Server..."
Write-Host "============================================"
$connStr = "Integrated=True;IsPrimaryLogin=True;Authenticate=True;EncryptedPassword=False;Host=$K2Server;Port=$K2Port"
try {
    $mgmt = New-Object SourceCode.Workflow.Management.WorkflowManagementServer
    $mgmt.CreateConnection()
    $mgmt.Connection.Open($connStr)
    Write-Host "  CONNECTED!"

    # List ALL management methods with full signatures
    Write-Host "`n[5] ALL WorkflowManagementServer methods:"
    $allMethods = $mgmt.GetType().GetMethods() |
        Where-Object { $_.DeclaringType.FullName -like "SourceCode.*" } |
        Sort-Object Name
    foreach ($m in $allMethods) {
        $ps = ($m.GetParameters() | ForEach-Object { "$($_.ParameterType.Name) $($_.Name)" }) -join ", "
        Write-Host "  $($m.ReturnType.Name) $($m.Name)($ps)"
    }

    # List existing processes
    Write-Host "`n[6] Existing K2 Processes:"
    try {
        $procSets = $mgmt.GetProcSets()
        if ($procSets -and $procSets.Count -gt 0) {
            foreach ($ps in $procSets) {
                Write-Host "  [$($ps.ProcSetID)] $($ps.FullName) v$($ps.VersionNumber)"
            }
        } else {
            Write-Host "  (no processes found)"
        }
    } catch {
        Write-Host "  GetProcSets error: $($_.Exception.Message)"
    }

    $mgmt.Connection.Close()
} catch {
    Write-Host "  Management connection failed: $($_.Exception.Message)"
}

# 5. Try Workflow Client - use correct Open() signature
Write-Host "`n============================================"
Write-Host "[7] Workflow.Client.Connection..."
Write-Host "============================================"
try {
    $clientType = [SourceCode.Workflow.Client.Connection]
    Write-Host "  Client type found. Checking Open() overloads:"
    $openMethods = $clientType.GetMethods() | Where-Object { $_.Name -eq "Open" }
    foreach ($om in $openMethods) {
        $ps = ($om.GetParameters() | ForEach-Object { "$($_.ParameterType.Name) $($_.Name)" }) -join ", "
        Write-Host "    Open($ps)"
    }

    # Try with just server name (single arg)
    $client = New-Object SourceCode.Workflow.Client.Connection
    try {
        $client.Open($K2Server)
        Write-Host "  Connected via Open(server)!"

        $clientMethods = $client.GetType().GetMethods() |
            Where-Object { $_.DeclaringType.FullName -like "SourceCode.*" } |
            Sort-Object Name
        foreach ($m in $clientMethods) {
            $ps = ($m.GetParameters() | ForEach-Object { "$($_.ParameterType.Name) $($_.Name)" }) -join ", "
            Write-Host "  $($m.ReturnType.Name) $($m.Name)($ps)"
        }
        $client.Close()
    } catch {
        Write-Host "  Open(server) failed: $($_.Exception.Message)"

        # Try with connection string only
        try {
            $client2 = New-Object SourceCode.Workflow.Client.Connection
            $client2.Open($connStr)
            Write-Host "  Connected via Open(connStr)!"
            $client2.Close()
        } catch {
            Write-Host "  Open(connStr) failed: $($_.Exception.Message)"
        }
    }
} catch {
    Write-Host "  Workflow.Client not available: $($_.Exception.Message)"
}

Write-Host "`n============================================"
Write-Host "  Discovery Complete!"
Write-Host "  Results saved to: $outFile"
Write-Host "============================================"

Stop-Transcript | Out-Null

Write-Host "`nOutput saved to: $outFile" -ForegroundColor Green
Write-Host "Please share this file!" -ForegroundColor Yellow
