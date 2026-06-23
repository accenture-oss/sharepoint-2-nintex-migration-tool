# Find-XSN.ps1 — Finds all InfoPath XSN templates on a SharePoint site
# Uses proper CSOM batching to avoid context scoping issues

param(
    [string]$SiteUrl = "http://nintex-sp-poc/sites/NimeshTest8",
    [string]$CsomDllFolder = "C:\Program Files\Common Files\microsoft shared\Web Server Extensions\16\ISAPI"
)

Add-Type -Path (Join-Path $CsomDllFolder "Microsoft.SharePoint.Client.dll")
Add-Type -Path (Join-Path $CsomDllFolder "Microsoft.SharePoint.Client.Runtime.dll")

$ctx = New-Object Microsoft.SharePoint.Client.ClientContext($SiteUrl)
$ctx.Credentials = [System.Net.CredentialCache]::DefaultNetworkCredentials

# Step 1: Load all lists in one query
$lists = $ctx.Web.Lists
$ctx.Load($lists)
$ctx.ExecuteQuery()

$visibleLists = @($lists | Where-Object { -not $_.Hidden })
Write-Host "Found $($visibleLists.Count) visible lists" -ForegroundColor Cyan

# Step 2: Batch load ALL content types and root folders in ONE query
foreach ($list in $visibleLists) {
    $ctx.Load($list.ContentTypes)
    $ctx.Load($list.RootFolder)
}
$ctx.ExecuteQuery()

# Step 3: Now iterate — everything is already loaded, no more queries needed
Write-Host ""
Write-Host "=== Checking Content Type DocumentTemplateUrl ===" -ForegroundColor Cyan

$found = 0
foreach ($list in $visibleLists) {
    foreach ($ct in $list.ContentTypes) {
        $dtUrl = $ct.DocumentTemplateUrl
        if ($dtUrl -and $dtUrl -like "*.xsn*") {
            Write-Host "  LIST: $($list.Title) | CT: $($ct.Name)" -ForegroundColor Yellow
            Write-Host "  XSN:  $dtUrl" -ForegroundColor Green
            Write-Host ""
            $found++
        }
    }
}

Write-Host "Found $found list(s) with XSN in ContentType" -ForegroundColor Cyan
Write-Host ""

# Step 4: Check root folder files (batch load files separately)
Write-Host "=== Checking Root Folder Files ===" -ForegroundColor Cyan
foreach ($list in $visibleLists) {
    $ctx.Load($list.RootFolder.Files)
}
$ctx.ExecuteQuery()

foreach ($list in $visibleLists) {
    foreach ($f in $list.RootFolder.Files) {
        if ($f.Name -like "*.xsn") {
            Write-Host "  LIST: $($list.Title) | File: $($f.ServerRelativeUrl)" -ForegroundColor Green
            $found++
        }
    }
}

# Step 5: Check Forms/ subfolders one by one (can't batch GetFolderByUrl)
Write-Host ""
Write-Host "=== Checking Forms/ Subfolders ===" -ForegroundColor Cyan
foreach ($list in $visibleLists) {
    try {
        $formsPath = $list.RootFolder.ServerRelativeUrl + "/Forms"
        $formsFolder = $ctx.Web.GetFolderByServerRelativeUrl($formsPath)
        $ctx.Load($formsFolder)
        $ctx.Load($formsFolder.Files)
        $ctx.ExecuteQuery()
        foreach ($f in $formsFolder.Files) {
            if ($f.Name -like "*.xsn") {
                Write-Host "  LIST: $($list.Title) | File: $($f.ServerRelativeUrl)" -ForegroundColor Green
                $found++
            }
        }
    } catch { }
}

Write-Host ""
Write-Host "=============================" -ForegroundColor Cyan
Write-Host "Total XSN locations found: $found" -ForegroundColor Cyan
