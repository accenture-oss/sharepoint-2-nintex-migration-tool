<#
.SYNOPSIS
    List all SmartForm Views and Forms deployed on K2 server.
    Shows which ones have event rules vs empty events.
    
.EXAMPLE
    .\List-K2Forms.ps1 -K2Server NINTEX-SP-POC
#>

param(
    [string]$K2Server = "NINTEX-SP-POC",
    [int]$K2Port = 5555,
    [string]$K2DllPath = "",
    [string]$K2User = "",
    [string]$K2Password = "",
    [string]$K2Domain = ""
)

$ErrorActionPreference = "Stop"

if ([string]::IsNullOrWhiteSpace($K2DllPath)) {
    $K2DllPath = "C:\Program Files\K2\Bin"
}

[System.AppDomain]::CurrentDomain.AppendPrivatePath($K2DllPath)
@("SourceCode.Forms.Management.dll","SourceCode.HostClientAPI.dll","SourceCode.Framework.dll") | ForEach-Object {
    $p = Join-Path $K2DllPath $_
    if (Test-Path $p) {
        try { Unblock-File -Path $p -ErrorAction SilentlyContinue } catch {}
        [System.Reflection.Assembly]::LoadFrom($p) | Out-Null
    }
}

$fm = New-Object SourceCode.Forms.Management.FormsManager
$fm.CreateConnection()

if ($K2User -and $K2Password) {
    $userPart = if ($K2Domain) { "$K2Domain\$K2User" } else { $K2User }
    $connStr = "Integrated=False;IsPrimaryLogin=True;Authenticate=True;EncryptedPassword=False;UserID=$userPart;Password=$K2Password;Host=$K2Server;Port=$K2Port"
} else {
    $connStr = "Integrated=True;IsPrimaryLogin=True;Authenticate=True;EncryptedPassword=False;Host=$K2Server;Port=$K2Port"
}

$fm.Open($connStr)
Write-Host "Connected to $K2Server" -ForegroundColor Green

# ── List all available methods on FormsManager ──────────────
Write-Host "`n=== FormsManager Available Methods ===" -ForegroundColor Cyan
$fm.GetType().GetMethods() | Where-Object { $_.IsPublic -and !$_.IsSpecialName } | ForEach-Object {
    $params = ($_.GetParameters() | ForEach-Object { "$($_.ParameterType.Name) $($_.Name)" }) -join ", "
    Write-Host "  $($_.ReturnType.Name) $($_.Name)($params)" -ForegroundColor Gray
} | Out-Null

$methods = $fm.GetType().GetMethods() | Where-Object { $_.IsPublic -and !$_.IsSpecialName } | Select-Object -Property Name, @{N='Params';E={($_.GetParameters() | ForEach-Object { "$($_.ParameterType.Name) $($_.Name)" }) -join ", "}} | Sort-Object Name -Unique
foreach ($m in $methods) {
    Write-Host "  $($m.Name)($($m.Params))" -ForegroundColor Gray
}

# ── Try various methods to enumerate views ──────────────────
Write-Host "`n=== Attempting View Enumeration ===" -ForegroundColor Cyan

# Method 1: GetViews()
try {
    $views = $fm.GetViews()
    Write-Host "GetViews() returned: $($views.GetType().Name)" -ForegroundColor Yellow
    if ($views) {
        # Try common property patterns
        foreach ($prop in @("Views","Items","Count","Length")) {
            try {
                $val = $views.$prop
                if ($val -ne $null) {
                    Write-Host "  .$prop = $val" -ForegroundColor White
                }
            } catch {}
        }
        # Try iterating
        try {
            $count = 0
            foreach ($v in $views) {
                $count++
                $vName = ""
                try { $vName = $v.Name } catch {}
                if (-not $vName) { try { $vName = $v.ToString() } catch { $vName = "?" } }
                Write-Host "  VIEW: $vName" -ForegroundColor White
                if ($count -ge 50) { Write-Host "  ... (truncated at 50)" -ForegroundColor Yellow; break }
            }
            Write-Host "  Total views found: $count" -ForegroundColor Green
        } catch {
            Write-Host "  Cannot iterate: $($_.Exception.Message)" -ForegroundColor Yellow
        }
    }
} catch {
    Write-Host "GetViews() failed: $($_.Exception.Message)" -ForegroundColor Yellow
}

# Method 2: GetForms()
Write-Host "`n=== Attempting Form Enumeration ===" -ForegroundColor Cyan
try {
    $forms = $fm.GetForms()
    Write-Host "GetForms() returned: $($forms.GetType().Name)" -ForegroundColor Yellow
    if ($forms) {
        foreach ($prop in @("Forms","Items","Count","Length")) {
            try {
                $val = $forms.$prop
                if ($val -ne $null) {
                    Write-Host "  .$prop = $val" -ForegroundColor White
                }
            } catch {}
        }
        try {
            $count = 0
            foreach ($f in $forms) {
                $count++
                $fName = ""
                try { $fName = $f.Name } catch {}
                if (-not $fName) { try { $fName = $f.ToString() } catch { $fName = "?" } }
                Write-Host "  FORM: $fName" -ForegroundColor White
                if ($count -ge 50) { Write-Host "  ... (truncated at 50)" -ForegroundColor Yellow; break }
            }
            Write-Host "  Total forms found: $count" -ForegroundColor Green
        } catch {
            Write-Host "  Cannot iterate: $($_.Exception.Message)" -ForegroundColor Yellow
        }
    }
} catch {
    Write-Host "GetForms() failed: $($_.Exception.Message)" -ForegroundColor Yellow
}

# Method 3: Try GetCategories
Write-Host "`n=== Attempting Category Enumeration ===" -ForegroundColor Cyan
try {
    $cats = $fm.GetCategories()
    Write-Host "GetCategories() returned: $($cats.GetType().Name)" -ForegroundColor Yellow
    try {
        foreach ($c in $cats) {
            $cName = ""
            try { $cName = $c.Name } catch { try { $cName = $c.ToString() } catch { $cName = "?" } }
            Write-Host "  CATEGORY: $cName" -ForegroundColor White
        }
    } catch {
        Write-Host "  Cannot iterate: $($_.Exception.Message)" -ForegroundColor Yellow
    }
} catch {
    Write-Host "GetCategories() failed: $($_.Exception.Message)" -ForegroundColor Yellow
}

# Method 4: Try to get a specific known view from our deployments
Write-Host "`n=== Trying Known View Names ===" -ForegroundColor Cyan
$tryNames = @(
    "MIG_Leave_Requests Item View",
    "MIG_Leave_Requests List View",
    "MIG_Leave_Requests Form"
)

# Also try to discover from our migration state
$stateFile = Join-Path $PSScriptRoot ".migration-state\smartforms.json"
if (Test-Path $stateFile) {
    try {
        $sfState = Get-Content $stateFile -Raw | ConvertFrom-Json
        foreach ($sf in $sfState) {
            $soName = $sf.smartObjectName
            if ($soName) {
                $tryNames += "$soName Item View"
                $tryNames += "$soName List View"
                $tryNames += "$soName Form"
            }
        }
        Write-Host "  Loaded $($sfState.Count) SmartForm names from migration state" -ForegroundColor Gray
    } catch {}
}

foreach ($name in $tryNames) {
    try {
        $exists = $fm.CheckViewExists($name)
        if ($exists) {
            Write-Host "  FOUND VIEW: $name" -ForegroundColor Green
            # Try to get its definition
            try {
                $xml = $fm.GetViewDefinition($name)
                $hasEvents = ($xml -and $xml -match '<Events[^/]*>(.+?)</Events>')
                $xmlLen = if ($xml) { $xml.Length } else { 0 }
                Write-Host "    XML length: $xmlLen chars | Has events: $hasEvents" -ForegroundColor $(if ($hasEvents) { "Green" } else { "Yellow" })
                
                if ($xml -and $xmlLen -gt 0) {
                    $safeName = $name -replace '[^a-zA-Z0-9_]', '_'
                    $outPath = "C:\temp\k2_${safeName}.xml"
                    $xml | Out-File $outPath -Encoding utf8
                    Write-Host "    Saved to: $outPath" -ForegroundColor Cyan
                }
            } catch {
                Write-Host "    GetViewDefinition failed: $($_.Exception.Message)" -ForegroundColor Yellow
            }
        }
    } catch {}

    # Also check as form
    try {
        $exists = $fm.CheckFormExists($name)
        if ($exists) {
            Write-Host "  FOUND FORM: $name" -ForegroundColor Green
            try {
                $xml = $fm.GetFormDefinition($name)
                $hasEvents = ($xml -and $xml -match '<Events[^/]*>(.+?)</Events>')
                $xmlLen = if ($xml) { $xml.Length } else { 0 }
                Write-Host "    XML length: $xmlLen chars | Has events: $hasEvents" -ForegroundColor $(if ($hasEvents) { "Green" } else { "Yellow" })

                if ($xml -and $xmlLen -gt 0) {
                    $safeName = $name -replace '[^a-zA-Z0-9_]', '_'
                    $outPath = "C:\temp\k2_FORM_${safeName}.xml"
                    $xml | Out-File $outPath -Encoding utf8
                    Write-Host "    Saved to: $outPath" -ForegroundColor Cyan
                }
            } catch {
                Write-Host "    GetFormDefinition failed: $($_.Exception.Message)" -ForegroundColor Yellow
            }
        }
    } catch {}
}

$fm.Dispose()
Write-Host "`nDone." -ForegroundColor Green
