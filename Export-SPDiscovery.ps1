# Export-SPDiscovery.ps1
# REST-based workflow and InfoPath discovery for the SPD to K2 Migration Pipeline.
# Discovers SP2010 workflows, SP2013 workflows, and InfoPath form libraries.
# No CSOM required - uses SharePoint REST API with Windows auth.

param(
    [string]$SiteUrl = "",
    [string]$WorkflowCsv = "",
    [string]$InfoPathCsv = ""
)

if ($SiteUrl -eq "") {
    $SiteUrl = Read-Host "Enter SharePoint site URL (e.g., https://sp/sites/HR)"
}

$SiteUrl = $SiteUrl.TrimEnd('/')

$ts = Get-Date -Format "yyyyMMdd_HHmmss"
if ($WorkflowCsv -eq "") { $WorkflowCsv = ".\Workflows_$ts.csv" }
if ($InfoPathCsv -eq "") { $InfoPathCsv = ".\InfoPath_$ts.csv" }

function Invoke-SPRest($Endpoint) {
    $url = $SiteUrl + "/_api/" + $Endpoint
    $hdrs = @{}
    $hdrs["Accept"] = "application/json;odata=verbose"
    $resp = Invoke-RestMethod -Uri $url -Method Get -UseDefaultCredentials -Headers $hdrs -ContentType "application/json"
    return $resp.d
}

function Get-ResultsArray($data) {
    if ($data -eq $null) { return @() }
    if ($data.results) { return @($data.results) }
    if ($data.Count -gt 0) { return @($data) }
    if ($data.Id -or $data.Name -or $data.Title) { return @($data) }
    return @()
}

Write-Host ""
Write-Host "  ===================================================="
Write-Host "  SP Discovery for K2 Five Migration Pipeline (REST)"
Write-Host "  ===================================================="
Write-Host "  Target: $SiteUrl"
Write-Host ""

# Step 1: Connect
Write-Host "  [1/5] Connecting to SharePoint..."
try {
    $web = Invoke-SPRest "web?`$select=Title,Url,ServerRelativeUrl"
    Write-Host "  Connected: $($web.Title) ($($web.Url))"
} catch {
    Write-Host "  Connection failed: $($_.Exception.Message)"
    exit 1
}

# Step 2: Get all visible lists
Write-Host "  [2/5] Discovering lists..."

$listEndpoint = "web/lists?`$filter=Hidden eq false and BaseTemplate lt 1000" + "&" + "`$select=Id,Title,BaseTemplate,ItemCount,DefaultViewUrl,Created,LastItemModifiedDate"
$listsRaw = Invoke-SPRest $listEndpoint
$allLists = Get-ResultsArray $listsRaw

Write-Host "  Found $($allLists.Count) list(s)"

# Step 3: Discover SP2010 workflows (WorkflowAssociations on each list + web level)
Write-Host "  [3/5] Discovering SP2010 workflows..."

$wfResults = @()
$sp2010Count = 0

# 3a: Web-level workflow associations (reusable/site workflows)
Write-Host "    Checking web-level workflow associations..."
try {
    $webWfRaw = Invoke-SPRest "web/WorkflowAssociations"
    $webAssocs = Get-ResultsArray $webWfRaw

    foreach ($wf in $webAssocs) {
        $entry = @{}
        $entry["WebUrl"] = $web.Url
        $entry["WebTitle"] = $web.Title
        $entry["ListTitle"] = "(Site Workflow)"
        $entry["ListUrl"] = $web.Url
        $entry["WorkflowName"] = $wf.Name
        $entry["WorkflowType"] = "SP2010"
        $entry["ActivityCount"] = 0
        $entry["ActionCount"] = 0
        $entry["ConditionCount"] = 0
        $entry["ListItemCount"] = 0
        $entry["LastItemCreatedDate"] = ""
        $entry["LastModified"] = $wf.Modified
        $wfResults += New-Object PSObject -Property $entry
        $sp2010Count++
    }
    if ($webAssocs.Count -gt 0) {
        Write-Host "    Found $($webAssocs.Count) web-level SP2010 workflow(s)"
    }
} catch {
    Write-Host "    Web-level WorkflowAssociations: $($_.Exception.Message)" -ForegroundColor Yellow
}

# 3b: List-level workflow associations
foreach ($list in $allLists) {
    Write-Host "    $($list.Title)..." -NoNewline

    try {
        $wfEndpoint = "web/lists(guid'$($list.Id)')/WorkflowAssociations"
        $wfRaw = Invoke-SPRest $wfEndpoint
        $assocs = Get-ResultsArray $wfRaw

        if ($assocs.Count -gt 0) {
            foreach ($wf in $assocs) {
                $entry = @{}
                $entry["WebUrl"] = $web.Url
                $entry["WebTitle"] = $web.Title
                $entry["ListTitle"] = $list.Title
                $entry["ListUrl"] = $web.Url.TrimEnd('/') + '/' + $list.DefaultViewUrl.TrimStart('/')
                $entry["WorkflowName"] = $wf.Name
                $entry["WorkflowType"] = "SP2010"
                $entry["ActivityCount"] = 0
                $entry["ActionCount"] = 0
                $entry["ConditionCount"] = 0
                $entry["ListItemCount"] = $list.ItemCount
                $entry["LastItemCreatedDate"] = $list.LastItemModifiedDate
                $entry["LastModified"] = $wf.Modified
                $wfResults += New-Object PSObject -Property $entry
                $sp2010Count++
            }
            Write-Host " $($assocs.Count) SP2010 workflow(s)" -ForegroundColor Cyan
        } else {
            Write-Host " 0"
        }
    } catch {
        Write-Host " (error: $($_.Exception.Message))" -ForegroundColor Yellow
    }
}

Write-Host "  SP2010 total: $sp2010Count"

# Step 4: Discover SP2013 workflows (WorkflowSubscriptionService)
Write-Host "  [4/5] Discovering SP2013 workflows..."

$sp2013Count = 0

foreach ($list in $allLists) {
    try {
        $subEndpoint = "SP.WorkflowServices.WorkflowSubscriptionService.Current/EnumerateSubscriptionsByList(listId='$($list.Id)')"
        $subsRaw = Invoke-SPRest $subEndpoint
        $subs = Get-ResultsArray $subsRaw

        foreach ($sub in $subs) {
            $entry = @{}
            $entry["WebUrl"] = $web.Url
            $entry["WebTitle"] = $web.Title
            $entry["ListTitle"] = $list.Title
            $entry["ListUrl"] = $web.Url.TrimEnd('/') + '/' + $list.DefaultViewUrl.TrimStart('/')
            $entry["WorkflowName"] = $sub.Name
            $entry["WorkflowType"] = "SP2013"
            $entry["ActivityCount"] = 0
            $entry["ActionCount"] = 0
            $entry["ConditionCount"] = 0
            $entry["ListItemCount"] = $list.ItemCount
            $entry["LastItemCreatedDate"] = $list.LastItemModifiedDate
            $entry["LastModified"] = $sub.Created
            $wfResults += New-Object PSObject -Property $entry
            $sp2013Count++
        }
    } catch {
        # SP2013 workflow service not available for this list
    }
}

# Also check site-level SP2013 workflow subscriptions
try {
    $siteSubs = Invoke-SPRest "SP.WorkflowServices.WorkflowSubscriptionService.Current/EnumerateSubscriptions"
    $siteSubList = Get-ResultsArray $siteSubs

    foreach ($sub in $siteSubList) {
        # Check if not already discovered at list level
        $already = $false
        foreach ($existing in $wfResults) {
            if ($existing.WorkflowName -eq $sub.Name -and $existing.WorkflowType -eq "SP2013") {
                $already = $true
                break
            }
        }
        if (-not $already) {
            $entry = @{}
            $entry["WebUrl"] = $web.Url
            $entry["WebTitle"] = $web.Title
            $entry["ListTitle"] = "(Site Workflow)"
            $entry["ListUrl"] = $web.Url
            $entry["WorkflowName"] = $sub.Name
            $entry["WorkflowType"] = "SP2013"
            $entry["ActivityCount"] = 0
            $entry["ActionCount"] = 0
            $entry["ConditionCount"] = 0
            $entry["ListItemCount"] = 0
            $entry["LastItemCreatedDate"] = ""
            $entry["LastModified"] = $sub.Created
            $wfResults += New-Object PSObject -Property $entry
            $sp2013Count++
        }
    }
} catch {
    # Site-level SP2013 subscriptions not available
}

Write-Host "  SP2013 total: $sp2013Count"

# Step 4b: Discover SPD-style workflows (XOML files in Workflows folder)
Write-Host "  [4b] Discovering SPD-style workflows (XOML in Workflows folder)..."
$spdCount = 0

try {
    $wfFolderEndpoint = "web/getfolderbyserverrelativeurl('Workflows')/Folders"
    $wfFoldersRaw = Invoke-SPRest $wfFolderEndpoint
    $wfFolders = Get-ResultsArray $wfFoldersRaw

    foreach ($folder in $wfFolders) {
        $folderName = $folder.Name
        if ($folderName -eq "Forms" -or $folderName -eq "_cts") { continue }

        # Look for .xoml files in this subfolder
        try {
            $filesEndpoint = "web/getfolderbyserverrelativeurl('Workflows/" + $folderName + "')/Files"
            $filesRaw = Invoke-SPRest $filesEndpoint
            $files = Get-ResultsArray $filesRaw
            $xomlFile = $files | Where-Object { $_.Name -like "*.xoml" } | Select-Object -First 1

            if ($xomlFile) {
                # Try to figure out which list this workflow belongs to
                $listTitle = "(SPD Workflow)"
                $listUrl = $web.Url
                $listItemCount = 0

                # Parse the folder name to extract list name (format: "WFType - ListName")
                if ($folderName -match ' - (.+)$') {
                    $possibleList = $Matches[1]
                    $matchedList = $allLists | Where-Object { $_.Title -eq $possibleList } | Select-Object -First 1
                    if ($matchedList) {
                        $listTitle = $matchedList.Title
                        $listUrl = $web.Url.TrimEnd('/') + '/' + $matchedList.DefaultViewUrl.TrimStart('/')
                        $listItemCount = $matchedList.ItemCount
                    }
                }

                # Check for duplicate
                $isDup = $false
                foreach ($existing in $wfResults) {
                    if ($existing.WorkflowName -eq $folderName) { $isDup = $true; break }
                }

                if (-not $isDup) {
                    $entry = @{}
                    $entry["WebUrl"] = $web.Url
                    $entry["WebTitle"] = $web.Title
                    $entry["ListTitle"] = $listTitle
                    $entry["ListUrl"] = $listUrl
                    $entry["WorkflowName"] = $folderName
                    $entry["WorkflowType"] = "SPD"
                    $entry["ActivityCount"] = 0
                    $entry["ActionCount"] = 0
                    $entry["ConditionCount"] = 0
                    $entry["ListItemCount"] = $listItemCount
                    $entry["LastItemCreatedDate"] = ""
                    $entry["LastModified"] = $xomlFile.TimeLastModified
                    $wfResults += New-Object PSObject -Property $entry
                    $spdCount++
                    Write-Host "    $folderName -> $listTitle" -ForegroundColor Cyan
                }
            }
        } catch {}
    }
    Write-Host "  SPD XOML workflows: $spdCount"
} catch {
    Write-Host "  Workflows folder not found or inaccessible" -ForegroundColor DarkGray
}

Write-Host "  All workflows: $($wfResults.Count) (SP2010: $sp2010Count, SP2013: $sp2013Count, SPD: $spdCount)"

# Step 5: Discover InfoPath form libraries (BaseTemplate 115) and list forms
Write-Host "  [5/5] Discovering InfoPath forms..."

$ipResults = @()

# 5a: Form Libraries (BaseTemplate 115)
$ipEndpoint = "web/lists?`$filter=BaseTemplate eq 115 and Hidden eq false" + "&" + "`$select=Id,Title,ItemCount,DefaultViewUrl,Created,LastItemModifiedDate"
try {
    $ipRaw = Invoke-SPRest $ipEndpoint
    $ipLists = Get-ResultsArray $ipRaw
} catch {
    $ipLists = @()
}

Write-Host "    Form Libraries (BaseTemplate 115): $($ipLists.Count)"

foreach ($ipList in $ipLists) {
    Write-Host "    $($ipList.Title)..." -NoNewline

    try {
        $filesEndpoint = "web/lists(guid'$($ipList.Id)')/RootFolder/Files?`$select=Name,ServerRelativeUrl,TimeLastModified,Length"
        $filesRaw = Invoke-SPRest $filesEndpoint
        $files = Get-ResultsArray $filesRaw
        $xsnFiles = @($files | Where-Object { $_.Name -like "*.xsn" })

        if ($xsnFiles.Count -gt 0) {
            foreach ($xsn in $xsnFiles) {
                $entry = @{}
                $entry["WebUrl"] = $web.Url
                $entry["WebTitle"] = $web.Title
                $entry["ListTitle"] = $ipList.Title
                $entry["FormName"] = [System.IO.Path]::GetFileNameWithoutExtension($xsn.Name)
                $entry["FormType"] = "Form Library"
                $entry["FormUrl"] = $web.Url.TrimEnd('/') + $xsn.ServerRelativeUrl
                $entry["RuleCount"] = 0
                $entry["ActionCount"] = 0
                $entry["ValidationCount"] = 0
                $entry["FormattingCount"] = 0
                $entry["ConditionCount"] = 0
                $entry["DataConnectionCount"] = 0
                $entry["FieldCount"] = 0
                $entry["ItemCount"] = $ipList.ItemCount
                $entry["LastItemCreatedDate"] = $ipList.LastItemModifiedDate
                $entry["XsnLastModified"] = $xsn.TimeLastModified
                $ipResults += New-Object PSObject -Property $entry
            }
            Write-Host " $($xsnFiles.Count) XSN(s)" -ForegroundColor Cyan
        } else {
            $entry = @{}
            $entry["WebUrl"] = $web.Url
            $entry["WebTitle"] = $web.Title
            $entry["ListTitle"] = $ipList.Title
            $entry["FormName"] = $ipList.Title
            $entry["FormType"] = "Form Library (No XSN)"
            $entry["FormUrl"] = $web.Url.TrimEnd('/') + '/' + $ipList.DefaultViewUrl.TrimStart('/')
            $entry["RuleCount"] = 0
            $entry["ActionCount"] = 0
            $entry["ValidationCount"] = 0
            $entry["FormattingCount"] = 0
            $entry["ConditionCount"] = 0
            $entry["DataConnectionCount"] = 0
            $entry["FieldCount"] = 0
            $entry["ItemCount"] = $ipList.ItemCount
            $entry["LastItemCreatedDate"] = $ipList.LastItemModifiedDate
            $entry["XsnLastModified"] = $null
            $ipResults += New-Object PSObject -Property $entry
            Write-Host " (no XSN)"
        }
    } catch {
        Write-Host " (error: $($_.Exception.Message))" -ForegroundColor Yellow
    }
}

# 5b: Check regular lists for InfoPath customized forms (ContentType has XSN)
Write-Host "    Checking lists for InfoPath-customized forms..."
foreach ($list in $allLists) {
    if ($list.BaseTemplate -eq 115) { continue }  # Already checked form libraries

    try {
        $ctEndpoint = "web/lists(guid'$($list.Id)')/ContentTypes?`$select=Name,DisplayFormUrl,EditFormUrl,NewFormUrl"
        $ctRaw = Invoke-SPRest $ctEndpoint
        $cts = Get-ResultsArray $ctRaw

        foreach ($ct in $cts) {
            $hasInfoPath = $false
            if ($ct.EditFormUrl -and $ct.EditFormUrl -like "*.xsn*") { $hasInfoPath = $true }
            if ($ct.NewFormUrl -and $ct.NewFormUrl -like "*.xsn*") { $hasInfoPath = $true }

            if ($hasInfoPath) {
                $entry = @{}
                $entry["WebUrl"] = $web.Url
                $entry["WebTitle"] = $web.Title
                $entry["ListTitle"] = $list.Title
                $entry["FormName"] = $ct.Name
                $entry["FormType"] = "List Form (InfoPath)"
                $entry["FormUrl"] = $web.Url.TrimEnd('/') + '/' + $list.DefaultViewUrl.TrimStart('/')
                $entry["RuleCount"] = 0
                $entry["ActionCount"] = 0
                $entry["ValidationCount"] = 0
                $entry["FormattingCount"] = 0
                $entry["ConditionCount"] = 0
                $entry["DataConnectionCount"] = 0
                $entry["FieldCount"] = 0
                $entry["ItemCount"] = $list.ItemCount
                $entry["LastItemCreatedDate"] = $list.LastItemModifiedDate
                $entry["XsnLastModified"] = $null
                $ipResults += New-Object PSObject -Property $entry
                Write-Host "    $($list.Title) -> $($ct.Name) (InfoPath form)" -ForegroundColor Cyan
            }
        }
    } catch {
        # Content types not accessible
    }
}

Write-Host "  InfoPath forms total: $($ipResults.Count)"

# Export
$wfCols = @("WebUrl","WebTitle","ListTitle","ListUrl","WorkflowName","WorkflowType","ActivityCount","ActionCount","ConditionCount","ListItemCount","LastItemCreatedDate","LastModified")
$ipCols = @("WebUrl","WebTitle","ListTitle","FormName","FormType","FormUrl","RuleCount","ActionCount","ValidationCount","FormattingCount","ConditionCount","DataConnectionCount","FieldCount","ItemCount","LastItemCreatedDate","XsnLastModified")

if ($wfResults.Count -gt 0) {
    $wfResults | Select-Object $wfCols | Export-Csv -Path $WorkflowCsv -NoTypeInformation -Encoding UTF8
} else {
    $wfCols -join "," | Out-File -FilePath $WorkflowCsv -Encoding UTF8
}

if ($ipResults.Count -gt 0) {
    $ipResults | Select-Object $ipCols | Export-Csv -Path $InfoPathCsv -NoTypeInformation -Encoding UTF8
} else {
    $ipCols -join "," | Out-File -FilePath $InfoPathCsv -Encoding UTF8
}

Write-Host ""
Write-Host "  ===================================================="
Write-Host "  COMPLETE" -ForegroundColor Green
Write-Host "  ===================================================="
Write-Host "  SP2010 Workflows : $sp2010Count"
Write-Host "  SP2013 Workflows : $sp2013Count"
Write-Host "  SPD Workflows    : $spdCount"
Write-Host "  Total Workflows  : $($wfResults.Count)" -ForegroundColor Cyan
Write-Host "  InfoPath Forms   : $($ipResults.Count)"
Write-Host "  ----------------------------------------------------"
Write-Host "  Workflow CSV     : $WorkflowCsv" -ForegroundColor Yellow
Write-Host "  InfoPath CSV     : $InfoPathCsv" -ForegroundColor Yellow
Write-Host "  ===================================================="
Write-Host ""
Write-Host "  Upload both CSVs in the Discovery tab of the migration app."
Write-Host ""
