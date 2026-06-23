param (
    [string]$SiteUrl = "",
    [string]$K2User = "",
    [string]$K2Password = "",
    [string]$K2Domain = ""
)

$ErrorActionPreference = "Stop"

try {
    # Load SharePoint CSOM
    $csomPath = "C:\Program Files\Common Files\microsoft shared\Web Server Extensions\15\ISAPI"
    if (-not (Test-Path $csomPath)) {
        $csomPath = "C:\Program Files\Common Files\microsoft shared\Web Server Extensions\16\ISAPI"
    }
    Add-Type -Path "$csomPath\Microsoft.SharePoint.Client.dll" -ErrorAction Stop
    Add-Type -Path "$csomPath\Microsoft.SharePoint.Client.Runtime.dll" -ErrorAction Stop

    $ctx = New-Object Microsoft.SharePoint.Client.ClientContext($SiteUrl)
    if ($K2User -and $K2Password) {
        $ctx.Credentials = New-Object System.Net.NetworkCredential($K2User, $K2Password, $K2Domain)
    }

    # Load site info
    $web = $ctx.Web
    $ctx.Load($web)

    # Load all lists
    $lists = $web.Lists
    $ctx.Load($lists)
    $ctx.ExecuteQuery()

    $siteTitle = $web.Title
    $serverRelUrl = $web.ServerRelativeUrl

    $results = @()
    foreach ($list in $lists) {
        $ctx.Load($list)
    }
    $ctx.ExecuteQuery()

    foreach ($list in $lists) {
        # Skip hidden and system lists
        if ($list.Hidden) { continue }
        if ($list.Title -match '^(Master Page Gallery|Style Library|Site Assets|Site Pages|Form Templates|Composed Looks|Solution Gallery|Web Part Gallery|Theme Gallery|Content and Structure Reports|Reusable Content|Workflow Tasks|Workflow History|TaxonomyHiddenList|appdata|Content type publishing error log)$') { continue }

        $results += @{
            listId = $list.Id.ToString()
            listTitle = $list.Title
            itemCount = $list.ItemCount
            baseTemplate = $list.BaseTemplate
            baseType = [int]$list.BaseType
            description = $list.Description
            created = $list.Created.ToString("yyyy-MM-dd")
            lastModified = if ($list.LastItemModifiedDate) { $list.LastItemModifiedDate.ToString("yyyy-MM-dd") } else { "" }
            sourceUrl = $SiteUrl + $list.DefaultViewUrl -replace '/[^/]+\.aspx$', ''
            fieldCount = 0
        }
    }

    # Get field count for each list
    foreach ($r in $results) {
        try {
            $l = $ctx.Web.Lists.GetById([Guid]$r.listId)
            $fields = $l.Fields
            $ctx.Load($fields)
            $ctx.ExecuteQuery()
            $r.fieldCount = ($fields | Where-Object { -not $_.Hidden -and -not $_.ReadOnlyField }).Count
        } catch {
            $r.fieldCount = -1
        }
    }

    $ctx.Dispose()

    $output = @{
        success = $true
        siteUrl = $SiteUrl
        siteTitle = $siteTitle
        serverRelativeUrl = $serverRelUrl
        listCount = $results.Count
        lists = $results
    }
    Write-Output ($output | ConvertTo-Json -Depth 5 -Compress)

} catch {
    $output = @{
        success = $false
        error = $_.Exception.Message
        siteUrl = $SiteUrl
    }
    Write-Output ($output | ConvertTo-Json -Compress)
}
