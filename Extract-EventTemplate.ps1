<#
.SYNOPSIS
    Extract SmartForm Event Rules XML from a K2 Five server.
    Searches all deployed views/forms for non-empty <Events> blocks
    and saves them for use as templates in our migration pipeline.

.DESCRIPTION
    Uses SourceCode.Forms.Management.FormsManager to:
      1. List all deployed views on the K2 server
      2. Download each view's full XML definition
      3. Find views that have non-empty <Events> blocks (i.e., working rules)
      4. Save the events XML + full view XML for reverse-engineering

.EXAMPLE
    .\Extract-EventTemplate.ps1 -K2Server NINTEX-SP-POC
    .\Extract-EventTemplate.ps1 -K2Server NINTEX-SP-POC -K2User admin -K2Password pass123 -K2Domain CORP
#>

param(
    [string]$K2Server = "NINTEX-SP-POC",
    [int]$K2Port = 5555,
    [string]$K2DllPath = "",
    [string]$K2User = "",
    [string]$K2Password = "",
    [string]$K2Domain = "",
    [string]$OutputDir = ".\k2-event-templates"
)

$ErrorActionPreference = "Stop"

# ── Load K2 SDK ─────────────────────────────────────────────
if ([string]::IsNullOrWhiteSpace($K2DllPath)) {
    $K2DllPath = "C:\Program Files\K2\Bin"
}

if (-not (Test-Path $K2DllPath)) {
    Write-Host "ERROR: K2DllPath not found: $K2DllPath" -ForegroundColor Red
    exit 1
}

[System.AppDomain]::CurrentDomain.AppendPrivatePath($K2DllPath)

$dlls = @("SourceCode.Forms.Management.dll", "SourceCode.HostClientAPI.dll", "SourceCode.Framework.dll")
foreach ($dll in $dlls) {
    $p = Join-Path $K2DllPath $dll
    if (Test-Path $p) {
        try { Unblock-File -Path $p -ErrorAction SilentlyContinue } catch { }
        [System.Reflection.Assembly]::LoadFrom($p) | Out-Null
    } else {
        Write-Host "WARNING: $dll not found at $p" -ForegroundColor Yellow
    }
}

# ── Create output directory ─────────────────────────────────
if (-not (Test-Path $OutputDir)) {
    New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
}

# ── Connect to K2 Forms Manager ─────────────────────────────
Write-Host "═══════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host "  K2 SmartForm Event Template Extractor" -ForegroundColor Cyan
Write-Host "  Server: $K2Server`:$K2Port" -ForegroundColor White
Write-Host "  Output: $OutputDir" -ForegroundColor White
Write-Host "═══════════════════════════════════════════════════" -ForegroundColor Cyan

$fm = New-Object SourceCode.Forms.Management.FormsManager
$fm.CreateConnection() | Out-Null

if ($K2User -and $K2Password) {
    $userPart = if ($K2Domain) { "$K2Domain\$K2User" } else { $K2User }
    $connStr = "Integrated=False;IsPrimaryLogin=True;Authenticate=True;EncryptedPassword=False;UserID=$userPart;Password=$K2Password;Host=$K2Server;Port=$K2Port"
} else {
    $connStr = "Integrated=True;IsPrimaryLogin=True;Authenticate=True;EncryptedPassword=False;Host=$K2Server;Port=$K2Port"
}

try {
    $fm.Open($connStr) | Out-Null
    Write-Host "Connected to K2 Forms Manager." -ForegroundColor Green
} catch {
    Write-Host "ERROR: Could not connect - $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}

# ── Phase 1: Enumerate all views ────────────────────────────
Write-Host "`n[Phase 1] Enumerating all deployed views..." -ForegroundColor Cyan

$allViews = @()
try {
    # GetViews returns a collection of view metadata
    $views = $fm.GetViews()
    if ($views -and $views.Views) {
        $allViews = $views.Views
    } elseif ($views) {
        # Some K2 versions return differently
        $allViews = @($views)
    }
    Write-Host "  Found $($allViews.Count) view(s) on server." -ForegroundColor White
} catch {
    Write-Host "  GetViews() failed: $($_.Exception.Message)" -ForegroundColor Yellow
    Write-Host "  Trying alternative enumeration..." -ForegroundColor Yellow
    
    # Fallback: try GetViewCategories and iterate
    try {
        $categories = $fm.GetCategories()
        Write-Host "  Found categories. Will scan each one." -ForegroundColor Yellow
    } catch {
        Write-Host "  Category enumeration also failed: $($_.Exception.Message)" -ForegroundColor Red
    }
}

# ── Phase 2: Extract view definitions and find Events ───────
Write-Host "`n[Phase 2] Extracting view definitions..." -ForegroundColor Cyan

$viewsWithEvents = @()
$viewsWithoutEvents = @()
$viewIndex = 0
$totalViews = $allViews.Count

foreach ($view in $allViews) {
    $viewIndex++
    $viewName = ""
    $viewDisplayName = ""

    # Handle different property access patterns across K2 SDK versions
    try { $viewName = $view.Name } catch { }
    if (-not $viewName) {
        try { $viewName = $view.ToString() } catch { $viewName = "View_$viewIndex" }
    }
    try { $viewDisplayName = $view.DisplayName } catch { $viewDisplayName = $viewName }

    $pct = [math]::Round(($viewIndex / [math]::Max($totalViews, 1)) * 100)
    Write-Host "  [$pct%] Processing: $viewName" -ForegroundColor Gray -NoNewline

    try {
        # Get the full XML definition of this view
        $viewXml = $fm.GetViewDefinition($viewName)

        if (-not $viewXml) {
            Write-Host " - SKIP (empty definition)" -ForegroundColor DarkGray
            continue
        }

        # Check if it has non-empty Events
        $hasEvents = $false
        $eventsContent = ""

        # Parse the XML to find <Events> blocks
        try {
            [xml]$xmlDoc = $viewXml
            
            # Look for Events nodes at any depth
            $eventsNodes = $xmlDoc.SelectNodes("//Events")
            foreach ($evtNode in $eventsNodes) {
                if ($evtNode.InnerXml -and $evtNode.InnerXml.Trim() -ne "") {
                    $hasEvents = $true
                    $eventsContent = $evtNode.OuterXml
                    break
                }
            }
        } catch {
            # Fallback: regex check
            if ($viewXml -match '<Events[^/]*>(.+?)</Events>' -and $Matches[1].Trim() -ne "") {
                $hasEvents = $true
                $eventsContent = $Matches[0]
            }
        }

        if ($hasEvents) {
            Write-Host " - HAS EVENTS!" -ForegroundColor Green
            $viewsWithEvents += @{
                Name        = $viewName
                DisplayName = $viewDisplayName
                EventsXml   = $eventsContent
                FullXml     = $viewXml
            }

            # Save immediately
            $safeName = $viewName -replace '[^a-zA-Z0-9_]', '_'
            $viewXml | Out-File (Join-Path $OutputDir "${safeName}_FULL.xml") -Encoding utf8
            $eventsContent | Out-File (Join-Path $OutputDir "${safeName}_EVENTS.xml") -Encoding utf8
        } else {
            Write-Host " - no events" -ForegroundColor DarkGray
            $viewsWithoutEvents += $viewName
        }

    } catch {
        Write-Host " - ERROR: $($_.Exception.Message)" -ForegroundColor Red
    }
}

# ── Phase 3: Also check Forms (form-level events) ───────────
Write-Host "`n[Phase 3] Checking form-level events..." -ForegroundColor Cyan

$allForms = @()
try {
    $forms = $fm.GetForms()
    if ($forms -and $forms.Forms) {
        $allForms = $forms.Forms
    } elseif ($forms) {
        $allForms = @($forms)
    }
    Write-Host "  Found $($allForms.Count) form(s) on server." -ForegroundColor White
} catch {
    Write-Host "  GetForms() failed: $($_.Exception.Message)" -ForegroundColor Yellow
}

$formsWithEvents = @()
$formIndex = 0
$totalForms = $allForms.Count

foreach ($form in $allForms) {
    $formIndex++
    $formName = ""
    try { $formName = $form.Name } catch { }
    if (-not $formName) {
        try { $formName = $form.ToString() } catch { $formName = "Form_$formIndex" }
    }

    $pct = [math]::Round(($formIndex / [math]::Max($totalForms, 1)) * 100)
    Write-Host "  [$pct%] Processing form: $formName" -ForegroundColor Gray -NoNewline

    try {
        $formXml = $fm.GetFormDefinition($formName)

        if (-not $formXml) {
            Write-Host " - SKIP (empty)" -ForegroundColor DarkGray
            continue
        }

        $hasFormEvents = $false
        $formEventsContent = ""

        try {
            [xml]$xmlDoc = $formXml
            $eventsNodes = $xmlDoc.SelectNodes("//Events")
            foreach ($evtNode in $eventsNodes) {
                if ($evtNode.InnerXml -and $evtNode.InnerXml.Trim() -ne "") {
                    $hasFormEvents = $true
                    $formEventsContent = $evtNode.OuterXml
                    break
                }
            }
        } catch {
            if ($formXml -match '<Events[^/]*>(.+?)</Events>' -and $Matches[1].Trim() -ne "") {
                $hasFormEvents = $true
                $formEventsContent = $Matches[0]
            }
        }

        if ($hasFormEvents) {
            Write-Host " - HAS EVENTS!" -ForegroundColor Green
            $formsWithEvents += @{
                Name      = $formName
                EventsXml = $formEventsContent
                FullXml   = $formXml
            }

            $safeName = $formName -replace '[^a-zA-Z0-9_]', '_'
            $formXml | Out-File (Join-Path $OutputDir "FORM_${safeName}_FULL.xml") -Encoding utf8
            $formEventsContent | Out-File (Join-Path $OutputDir "FORM_${safeName}_EVENTS.xml") -Encoding utf8
        } else {
            Write-Host " - no events" -ForegroundColor DarkGray
        }

    } catch {
        Write-Host " - ERROR: $($_.Exception.Message)" -ForegroundColor Red
    }
}

# ── Cleanup ─────────────────────────────────────────────────
$fm.Dispose()

# ── Summary ─────────────────────────────────────────────────
Write-Host "`n═══════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host "  EXTRACTION COMPLETE" -ForegroundColor Cyan
Write-Host "═══════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host "  Views scanned:        $totalViews" -ForegroundColor White
Write-Host "  Views WITH events:    $($viewsWithEvents.Count)" -ForegroundColor $(if ($viewsWithEvents.Count -gt 0) { "Green" } else { "Yellow" })
Write-Host "  Views without events: $($viewsWithoutEvents.Count)" -ForegroundColor Gray
Write-Host "  Forms scanned:        $totalForms" -ForegroundColor White
Write-Host "  Forms WITH events:    $($formsWithEvents.Count)" -ForegroundColor $(if ($formsWithEvents.Count -gt 0) { "Green" } else { "Yellow" })
Write-Host "  Output directory:     $OutputDir" -ForegroundColor White
Write-Host "═══════════════════════════════════════════════════" -ForegroundColor Cyan

if ($viewsWithEvents.Count -gt 0) {
    Write-Host "`n  Views with event rules:" -ForegroundColor Green
    foreach ($v in $viewsWithEvents) {
        Write-Host "    ✓ $($v.Name)" -ForegroundColor Green
    }
}

if ($formsWithEvents.Count -gt 0) {
    Write-Host "`n  Forms with event rules:" -ForegroundColor Green
    foreach ($f in $formsWithEvents) {
        Write-Host "    ✓ $($f.Name)" -ForegroundColor Green
    }
}

if ($viewsWithEvents.Count -eq 0 -and $formsWithEvents.Count -eq 0) {
    Write-Host "`n  ⚠ No views or forms with event rules found!" -ForegroundColor Yellow
    Write-Host "    This means either:" -ForegroundColor Yellow
    Write-Host "    - No SmartForms have been manually edited with rules yet" -ForegroundColor Yellow
    Write-Host "    - Or all forms were deployed without events" -ForegroundColor Yellow
    Write-Host "" -ForegroundColor Yellow
    Write-Host "    TO FIX: Open any deployed SmartForm in K2 Designer," -ForegroundColor Yellow
    Write-Host "    add a simple 'When Initialize > Load' rule, save it," -ForegroundColor Yellow
    Write-Host "    then re-run this script." -ForegroundColor Yellow
}

Write-Host ""

# ── Output JSON result ──────────────────────────────────────
$result = @{
    success          = $true
    server           = $K2Server
    viewsScanned     = $totalViews
    viewsWithEvents  = $viewsWithEvents.Count
    formsScanned     = $totalForms
    formsWithEvents  = $formsWithEvents.Count
    outputDir        = (Resolve-Path $OutputDir).Path
    viewNames        = @($viewsWithEvents | ForEach-Object { $_.Name })
    formNames        = @($formsWithEvents | ForEach-Object { $_.Name })
}
$result | ConvertTo-Json -Depth 3
