# Export-SPListSchema.ps1
# Exports SharePoint list field schema to JSON

param(
    [string]$SiteUrl = "",
    [string]$OutputPath = ".\sp_list_schema.json",
    [string]$ListTitle = ""
)

if ($SiteUrl -eq "") {
    $SiteUrl = Read-Host "Enter SharePoint site URL"
}

$SiteUrl = $SiteUrl.TrimEnd('/')

function Invoke-SPRest($Endpoint) {
    $url = $SiteUrl + "/_api/" + $Endpoint
    $hdrs = @{}
    $hdrs["Accept"] = "application/json;odata=verbose"
    $resp = Invoke-RestMethod -Uri $url -Method Get -UseDefaultCredentials -Headers $hdrs -ContentType "application/json"
    return $resp.d
}

Write-Host ""
Write-Host "Connecting to $SiteUrl ..."

try {
    $web = Invoke-SPRest "web?`$select=Title,Url,ServerRelativeUrl"
    Write-Host "Connected: $($web.Title)"
}
catch {
    Write-Host "Connection failed: $($_.Exception.Message)"
    exit 1
}

# Get lists
Write-Host "Discovering lists..."

$listFilter = "Hidden eq false and BaseTemplate lt 1000"
if ($ListTitle -ne "") {
    $listFilter = "Title eq '$ListTitle'"
}

$ep = "web/lists?`$filter=" + $listFilter + "&`$select=Id,Title,ItemCount,BaseTemplate,Created,LastItemModifiedDate,Description"
$listsRaw = Invoke-SPRest $ep

$allLists = @()
if ($listsRaw.results) {
    $allLists = $listsRaw.results
}
else {
    $allLists = @($listsRaw)
}

Write-Host "Found $($allLists.Count) list(s)"

# Get fields for each list
Write-Host "Exporting field schemas..."

$listResults = @()

foreach ($list in $allLists) {
    Write-Host "  $($list.Title) ($($list.ItemCount) items)..." -NoNewline

    $ff = "Hidden eq false and ReadOnlyField eq false and FieldTypeKind ne 12"
    $fep = "web/lists(guid'$($list.Id)')/fields?`$filter=" + $ff + "&`$select=Title,InternalName,TypeDisplayName,TypeAsString,Required,MaxLength,DefaultValue,Description,FieldTypeKind,Choices"
    $fieldsRaw = Invoke-SPRest $fep

    $allFields = @()
    if ($fieldsRaw.results) {
        $allFields = $fieldsRaw.results
    }
    else {
        $allFields = @($fieldsRaw)
    }

    $fieldList = @()
    foreach ($f in $allFields) {
        $cv = @()
        if ($f.Choices -ne $null -and $f.Choices.results -ne $null) {
            $cv = $f.Choices.results
        }

        $entry = @{}
        $entry["name"] = $f.InternalName
        $entry["displayName"] = $f.Title
        $entry["spFieldType"] = $f.TypeDisplayName
        $entry["typeAsString"] = $f.TypeAsString
        $entry["fieldTypeKind"] = $f.FieldTypeKind
        $entry["required"] = [bool]$f.Required
        $entry["maxLength"] = $f.MaxLength
        $entry["defaultValue"] = $f.DefaultValue
        $entry["description"] = $f.Description
        $entry["choices"] = $cv
        $fieldList += $entry
    }

    $lr = @{}
    $lr["listId"] = $list.Id
    $lr["listTitle"] = $list.Title
    $lr["webUrl"] = $web.Url
    $lr["webTitle"] = $web.Title
    $lr["itemCount"] = $list.ItemCount
    $lr["baseTemplate"] = $list.BaseTemplate
    $lr["created"] = $list.Created
    $lr["lastModified"] = $list.LastItemModifiedDate
    $lr["description"] = $list.Description
    $lr["fields"] = $fieldList
    $lr["fieldCount"] = $fieldList.Count
    $listResults += $lr

    Write-Host " $($fieldList.Count) fields"
}

# Build output
$totalF = 0
foreach ($r in $listResults) {
    $totalF = $totalF + $r["fieldCount"]
}

$output = @{}
$output["exportedAt"] = (Get-Date -Format "yyyy-MM-ddTHH:mm:ssZ")
$output["siteUrl"] = $SiteUrl
$output["siteTitle"] = $web.Title
$output["listCount"] = $listResults.Count
$output["totalFields"] = $totalF
$output["lists"] = $listResults

$json = $output | ConvertTo-Json -Depth 10
$json | Out-File -FilePath $OutputPath -Encoding UTF8

Write-Host ""
Write-Host "Exported $($listResults.Count) lists, $totalF fields"
Write-Host "Output: $OutputPath"
Write-Host ""
