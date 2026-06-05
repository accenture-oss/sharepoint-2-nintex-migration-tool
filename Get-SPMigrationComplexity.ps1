#Requires -Version 5.1
<#
.SYNOPSIS
    High-performance SharePoint 2010/2013 Migration Complexity Assessment Tool
    with full recursive subsite traversal.

.DESCRIPTION
    Pass root site collection URLs — the script automatically discovers ALL
    subsites recursively, then audits each web in parallel.

    WORKFLOWS (SP2010 XOML + SP2013 XAML):
        WebUrl, WebTitle, ListTitle, ListUrl, WorkflowName, WorkflowType,
        ActivityCount, ActionCount, ConditionCount, ListItemCount,
        LastItemCreatedDate, LastModified

    INFOPATH FORMS (XSN parsed as ZIP):
        WebUrl, WebTitle, ListTitle, FormName, FormType, FormUrl,
        RuleCount, ActionCount, ValidationCount, FormattingCount,
        ConditionCount, DataConnectionCount, FieldCount,
        ItemCount, LastItemCreatedDate, XsnLastModified

    PERFORMANCE:
        - Phase 1 : Recursive subsite discovery (breadth-first, parallel per root)
        - Phase 2 : Parallel per-web auditing via RunspacePool
        - Batched CSOM ExecuteQuery() to minimise round trips (N+1 eliminated)
        - In-memory XOML/XAML and XSN parsing, no temp files
        - ConcurrentDictionary for thread-safe deduplication
        - Pre-compiled regexes for parsing performance
        - Retry logic with exponential backoff for transient failures
        - Domain-aware credential handling
        - Proper resource disposal via try/finally
        - Supports mixed SP2010 + SP2013 farms

.PARAMETER SiteUrls
    Root site collection URLs. Subsites are discovered automatically.

.PARAMETER WorkflowCsv
    Output path for workflow results CSV.

.PARAMETER InfoPathCsv
    Output path for InfoPath results CSV.

.PARAMETER CsomDllFolder
    Folder containing CSOM DLLs.
    Default: SP2013 hive C:\Program Files\Common Files\microsoft shared\Web Server Extensions\15\ISAPI

.PARAMETER Credential
    PSCredential for authentication. Omit to use current Windows credentials.

.PARAMETER ThrottleLimit
    Parallel runspaces for the audit phase. Default: 8.

.PARAMETER DiscoveryThrottle
    Parallel runspaces for subsite discovery. Default: 5.

.PARAMETER BatchSize
    CAML page size for paged item queries. Default: 2000.

.PARAMETER MaxSubsiteDepth
    How deep to recurse. Default: 99 (unlimited).
    Set to 1 for root only, 2 for root + direct children, etc.

.PARAMETER MaxRetries
    Number of retry attempts for transient CSOM failures. Default: 3.

.EXAMPLE
    $cred  = Get-Credential
    $roots = Get-Content "C:\rootsites.txt"

    .\Get-SPMigrationComplexity.ps1 `
        -SiteUrls      $roots `
        -Credential    $cred `
        -WorkflowCsv   "C:\Audit\workflows.csv" `
        -InfoPathCsv   "C:\Audit\infopath.csv" `
        -ThrottleLimit 10
#>

# [CmdletBinding()] - removed for compatibility
param(
    [Parameter(Mandatory = $true)]
    [string[]]$SiteUrls,

    [Parameter(Mandatory = $false)]
    [string]$WorkflowCsv = ".\Workflows_$(Get-Date -Format 'yyyyMMdd_HHmmss').csv",

    [Parameter(Mandatory = $false)]
    [string]$InfoPathCsv = ".\InfoPath_$(Get-Date -Format 'yyyyMMdd_HHmmss').csv",

    [Parameter(Mandatory = $false)]
    [string]$CsomDllFolder = "C:\Program Files\Common Files\microsoft shared\Web Server Extensions\15\ISAPI",

    [Parameter(Mandatory = $false)]
    [System.Management.Automation.PSCredential]$Credential,

    [Parameter(Mandatory = $false)]
    [int]$ThrottleLimit = 8,

    [Parameter(Mandatory = $false)]
    [int]$DiscoveryThrottle = 5,

    [Parameter(Mandatory = $false)]
    [int]$BatchSize = 2000,

    [Parameter(Mandatory = $false)]
    [int]$MaxSubsiteDepth = 99,

    [Parameter(Mandatory = $false)]
    [int]$MaxRetries = 3
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Continue"

# ─────────────────────────────────────────────────────────────────────────────
# ASSEMBLY LOADER
# ─────────────────────────────────────────────────────────────────────────────
function Import-CsomAssemblies ([string]$Folder) {
    foreach ($dll in @(
        "Microsoft.SharePoint.Client.dll",
        "Microsoft.SharePoint.Client.Runtime.dll",
        "Microsoft.SharePoint.Client.WorkflowServices.dll"
    )) {
        $path = Join-Path $Folder $dll
        if (Test-Path $path) { try { Add-Type -Path $path -EA SilentlyContinue } catch {} }
    }
}

Import-CsomAssemblies -Folder $CsomDllFolder

# ─────────────────────────────────────────────────────────────────────────────
# THREAD-SAFE COLLECTIONS
# Fix #11: ConcurrentDictionary for dedup instead of ConcurrentBag
# ─────────────────────────────────────────────────────────────────────────────
$AllWebs   = [System.Collections.Concurrent.ConcurrentDictionary[string,byte]]::new(
                 [System.StringComparer]::OrdinalIgnoreCase)
$WfResults = [System.Collections.Concurrent.ConcurrentBag[PSCustomObject]]::new()
$IpResults = [System.Collections.Concurrent.ConcurrentBag[PSCustomObject]]::new()
$ErrorLog  = [System.Collections.Concurrent.ConcurrentBag[PSCustomObject]]::new()

# ─────────────────────────────────────────────────────────────────────────────
# PHASE 1 SCRIPTBLOCK — RECURSIVE SUBSITE DISCOVERY (breadth-first per root)
# ─────────────────────────────────────────────────────────────────────────────
$DiscoveryScriptBlock = {
    param(
        [string]$RootUrl,
        [string]$CsomDllFolder,
        [System.Management.Automation.PSCredential]$Credential,
        [int]$MaxDepth,
        [int]$MaxRetries,
        [System.Collections.Concurrent.ConcurrentDictionary[string,byte]]$AllWebs,
        [System.Collections.Concurrent.ConcurrentBag[PSCustomObject]]$ErrorLog
    )

    foreach ($dll in @("Microsoft.SharePoint.Client.dll","Microsoft.SharePoint.Client.Runtime.dll")) {
        $p = Join-Path $CsomDllFolder $dll
        if (Test-Path $p) { try { Add-Type -Path $p -EA SilentlyContinue } catch {} }
    }

    # Fix #13: Domain-aware credential handling
    function New-Ctx ([string]$Url) {
        $c = New-Object Microsoft.SharePoint.Client.ClientContext($Url)
        if ($Credential) {
            $nc = $Credential.GetNetworkCredential()
            $c.Credentials = New-Object System.Net.NetworkCredential(
                $nc.UserName, $nc.Password, $nc.Domain)
        } else {
            $c.Credentials = [System.Net.CredentialCache]::DefaultNetworkCredentials
        }
        $c.RequestTimeout = 120000
        return $c
    }

    # Fix #12: Retry logic with exponential backoff
    function Invoke-WithRetry ([scriptblock]$Action, [int]$Retries) {
        for ($i = 0; $i -lt $Retries; $i++) {
            try { return (& $Action) }
            catch {
                if ($i -eq ($Retries - 1)) { throw }
                Start-Sleep -Milliseconds (500 * [Math]::Pow(2, $i))
            }
        }
    }

    # Breadth-first queue — each entry: hashtable {Url, Depth}
    $queue = [System.Collections.Generic.Queue[hashtable]]::new()
    $queue.Enqueue(@{ Url = $RootUrl; Depth = 0 })

    while ($queue.Count -gt 0) {
        $item  = $queue.Dequeue()
        $url   = $item.Url
        $depth = $item.Depth

        # Fix #11: Dedup at source — skip if already discovered
        if (-not $AllWebs.TryAdd($url, 0)) { continue }

        if ($depth -ge $MaxDepth) { continue }

        $ctx = $null
        try {
            $ctx = New-Ctx -Url $url
            $subs = $ctx.Web.Webs
            $ctx.Load($subs)

            Invoke-WithRetry -Retries $MaxRetries -Action {
                $ctx.ExecuteQuery()
            }

            foreach ($sub in $subs) {
                $queue.Enqueue(@{ Url = $sub.Url; Depth = $depth + 1 })
            }
        } catch {
            $ErrorLog.Add([PSCustomObject]@{
                SiteUrl = $url; Context = "Discovery"; Error = $_.Exception.Message
            })
        } finally {
            # Fix #8: Always dispose context
            if ($ctx) { $ctx.Dispose() }
        }
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# PHASE 2 SCRIPTBLOCK — PER-WEB AUDIT
# ─────────────────────────────────────────────────────────────────────────────
$AuditScriptBlock = {
    param(
        [string]$WebUrl,
        [string]$CsomDllFolder,
        [System.Management.Automation.PSCredential]$Credential,
        [int]$BatchSize,
        [int]$MaxRetries,
        [System.Collections.Concurrent.ConcurrentBag[PSCustomObject]]$WfResults,
        [System.Collections.Concurrent.ConcurrentBag[PSCustomObject]]$IpResults,
        [System.Collections.Concurrent.ConcurrentBag[PSCustomObject]]$ErrorLog
    )

    foreach ($dll in @(
        "Microsoft.SharePoint.Client.dll",
        "Microsoft.SharePoint.Client.Runtime.dll",
        "Microsoft.SharePoint.Client.WorkflowServices.dll"
    )) {
        $p = Join-Path $CsomDllFolder $dll
        if (Test-Path $p) { try { Add-Type -Path $p -EA SilentlyContinue } catch {} }
    }

    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem

    # ── Pre-compiled regexes (Fix #5) ─────────────────────────────────────────
    $rxOpts = [System.Text.RegularExpressions.RegexOptions]::IgnoreCase -bor `
              [System.Text.RegularExpressions.RegexOptions]::Compiled

    # XOML patterns
    $rxXomlActivity  = [regex]::new(
        '<[A-Za-z]+\w*Activity\b|<Sequence\b|<Parallel\b|<Listen\b|<EventHandlingScope\b|<StateActivity\b|<SetState\b', $rxOpts)
    $rxXomlAction    = [regex]::new(
        '<CodeActivity\b|<SendEmail\b|<CreateListItem\b|<UpdateListItem\b|<DeleteListItem\b|<LogToHistoryListActivity\b|<SetField\b|<CallExternalMethod\b|<InvokeWebService\b|<CreateTask\b|<CompleteTask\b|<UpdateTask\b', $rxOpts)
    $rxXomlCondition = [regex]::new(
        '<IfElse\b|<IfElseBranch\b|<While\b|<ConditionedActivityGroup\b|<CodeCondition\b|<RuleConditionReference\b', $rxOpts)

    # XAML patterns
    $rxXamlActivity  = [regex]::new(
        '<[A-Za-z]+:[A-Za-z]*Activity\b|<Sequence\b|<Parallel\b|<Flowchart\b|<FlowStep\b|<StateMachine\b|<State\b', $rxOpts)
    $rxXamlAction    = [regex]::new(
        '<Assign\b|<WriteLine\b|<InvokeMethod\b|<Delay\b|HttpSend\b|SetVariable\b|<CreateListItem\b|<UpdateListItem\b|<SingleTask\b|<CompositeTask\b|<Email\b', $rxOpts)
    $rxXamlCondition = [regex]::new(
        '<If\b|<While\b|<DoWhile\b|<FlowDecision\b|<Switch\b|<Pick\b|<PickBranch\b|<FlowSwitch\b', $rxOpts)

    # XSN patterns
    $rxXsnField      = [regex]::new('<xs:element\b[^>]*\bname=', $rxOpts)
    $rxXsnRule       = [regex]::new('<xsf2?:rule\b', $rxOpts)
    $rxXsnAction     = [regex]::new(
        '<xsf2?:action\b|<xsf2?:setField\b|<xsf2?:switchView\b|<xsf2?:submitToHostEnvironment\b|<xsf2?:closeDocument\b|<xsf2?:openNewDocument\b|<xsf2?:query\b|<xsf2?:submit\b|<xsf2?:setFieldValue\b', $rxOpts)
    $rxXsnValidation = [regex]::new('<xsf2?:errorCondition\b|<xsf2?:errorMessage\b', $rxOpts)
    $rxXsnFormat     = [regex]::new('<xsf2?:applyFormat\b|<xsf2?:format\b', $rxOpts)
    $rxXsnCondition  = [regex]::new('<xsf2?:condition\b|<xsf2?:and\b|<xsf2?:or\b|<xsf2?:not\b', $rxOpts)
    $rxXsnDataConn   = [regex]::new(
        '<xsf2?:dataObject\b|<xsf2?:webServiceAdapter\b|<xsf2?:sharepointListAdapter\b|<xsf2?:xmlFileAdapter\b|<xsf2?:adoAdapter\b|<xsf2?:sharepointListQuery\b|<xsf2?:restAdapter\b|<xsf2?:udcxFileAdapter\b', $rxOpts)

    # ── Internal helpers ──────────────────────────────────────────────────────

    # Fix #13: Domain-aware credential handling
    function New-Ctx ([string]$Url) {
        $c = New-Object Microsoft.SharePoint.Client.ClientContext($Url)
        if ($Credential) {
            $nc = $Credential.GetNetworkCredential()
            $c.Credentials = New-Object System.Net.NetworkCredential(
                $nc.UserName, $nc.Password, $nc.Domain)
        } else {
            $c.Credentials = [System.Net.CredentialCache]::DefaultNetworkCredentials
        }
        $c.RequestTimeout = 120000
        return $c
    }

    # Fix #12: Retry logic with exponential backoff
    function Invoke-WithRetry ([scriptblock]$Action, [int]$Retries) {
        for ($i = 0; $i -lt $Retries; $i++) {
            try { return (& $Action) }
            catch {
                if ($i -eq ($Retries - 1)) { throw }
                Start-Sleep -Milliseconds (500 * [Math]::Pow(2, $i))
            }
        }
    }

    function Get-FileBytes ([Microsoft.SharePoint.Client.ClientContext]$Ctx,
                            [string]$ServerRelUrl) {
        try {
            $fi  = [Microsoft.SharePoint.Client.File]::OpenBinaryDirect($Ctx, $ServerRelUrl)
            $ms  = New-Object System.IO.MemoryStream
            $fi.Stream.CopyTo($ms)
            $fi.Stream.Dispose()
            $b   = $ms.ToArray()
            $ms.Dispose()
            return $b
        } catch { return $null }
    }

    function Find-WfFile ([Microsoft.SharePoint.Client.ClientContext]$Ctx,
                          [string]$WebSRUrl, [string]$WfName, [string]$Ext) {
        foreach ($path in @(
            "$WebSRUrl/_catalogs/wfpub/$($WfName.Trim())/$($WfName.Trim()).$Ext",
            "$WebSRUrl/Workflows/$($WfName.Trim())/$($WfName.Trim()).$Ext",
            "$WebSRUrl/_catalogs/wfpub/$($WfName.Trim())/workflow.$Ext"
        )) {
            $b = Get-FileBytes -Ctx $Ctx -ServerRelUrl $path
            if ($b) { return $b }
        }
        return $null
    }

    # Fix #5: Use pre-compiled regexes
    function Parse-Xoml ([byte[]]$Bytes) {
        $r = @{ ActivityCount=0; ActionCount=0; ConditionCount=0 }
        if (-not $Bytes) { return $r }
        try {
            $xml = [System.Text.Encoding]::UTF8.GetString($Bytes)
            $r.ActivityCount  = $rxXomlActivity.Matches($xml).Count
            $r.ActionCount    = $rxXomlAction.Matches($xml).Count
            $r.ConditionCount = $rxXomlCondition.Matches($xml).Count
        } catch {}
        return $r
    }

    function Parse-Xaml ([byte[]]$Bytes) {
        $r = @{ ActivityCount=0; ActionCount=0; ConditionCount=0 }
        if (-not $Bytes) { return $r }
        try {
            $xml = [System.Text.Encoding]::UTF8.GetString($Bytes)
            $r.ActivityCount  = $rxXamlActivity.Matches($xml).Count
            $r.ActionCount    = $rxXamlAction.Matches($xml).Count
            $r.ConditionCount = $rxXamlCondition.Matches($xml).Count
        } catch {}
        return $r
    }

    function Parse-Xsn ([byte[]]$Bytes) {
        $r = @{ RuleCount=0; ActionCount=0; ValidationCount=0; FormattingCount=0
                ConditionCount=0; DataConnections=0; FieldCount=0 }
        if (-not $Bytes) { return $r }
        try {
            $ms  = New-Object System.IO.MemoryStream(,$Bytes)
            $zip = [System.IO.Compression.ZipArchive]::new(
                       $ms, [System.IO.Compression.ZipArchiveMode]::Read)

            foreach ($entry in $zip.Entries) {
                if ($entry.FullName -notmatch '\.(xsf|xsd|xml)$') { continue }
                $es = $entry.Open()
                $sr = New-Object System.IO.StreamReader($es)
                $c  = $sr.ReadToEnd()
                $sr.Dispose(); $es.Dispose()

                if ($entry.Name -like "*.xsd") {
                    $r.FieldCount      += $rxXsnField.Matches($c).Count
                }
                if ($entry.Name -like "*.xsf" -or $entry.Name -eq "manifest.xsf") {
                    $r.RuleCount       += $rxXsnRule.Matches($c).Count
                    $r.ActionCount     += $rxXsnAction.Matches($c).Count
                    $r.ValidationCount += $rxXsnValidation.Matches($c).Count
                    $r.FormattingCount += $rxXsnFormat.Matches($c).Count
                    $r.ConditionCount  += $rxXsnCondition.Matches($c).Count
                    $r.DataConnections += $rxXsnDataConn.Matches($c).Count
                }
            }
            $zip.Dispose(); $ms.Dispose()
        } catch {}
        return $r
    }

    # ── Main audit ────────────────────────────────────────────────────────────
    $ctx = $null
    try {
        $ctx = New-Ctx -Url $WebUrl

        $web   = $ctx.Web
        $lists = $ctx.Web.Lists

        $ctx.Load($web)
        $ctx.Load($lists)

        Invoke-WithRetry -Retries $MaxRetries -Action { $ctx.ExecuteQuery() }

        $webUrl   = $web.Url
        $webTitle = $web.Title
        $webSRUrl = $web.ServerRelativeUrl

        $visibleLists = @($lists | Where-Object { -not $_.Hidden })

        # ── Batched workflow associations + last-created for ALL visible lists ─
        # Fix #1: Batch Get-ListLastCreated — single round trip for all lists
        $lastCreatedItems = @{}
        foreach ($list in $visibleLists) {
            $ctx.Load($list.WorkflowAssociations)

            $q = New-Object Microsoft.SharePoint.Client.CamlQuery
            $q.ViewXml = "<View><Query><OrderBy><FieldRef Name='Created' Ascending='FALSE'/></OrderBy></Query><RowLimit>1</RowLimit><ViewFields><FieldRef Name='Created'/></ViewFields></View>"
            $items = $list.GetItems($q)
            $ctx.Load($items)
            $lastCreatedItems[$list.Id.ToString()] = $items
        }

        # Fix #10: Log batch failure and fall back to per-list loading
        $batchWfFailed = $false
        try {
            Invoke-WithRetry -Retries $MaxRetries -Action { $ctx.ExecuteQuery() }
        } catch {
            $batchWfFailed = $true
            $ErrorLog.Add([PSCustomObject]@{
                SiteUrl = $WebUrl; Context = "Batch WF+LastCreated load"
                Error   = $_.Exception.Message
            })
        }

        # If batch failed, fall back to per-list loading
        if ($batchWfFailed) {
            $lastCreatedItems = @{}
            foreach ($list in $visibleLists) {
                try {
                    $ctx.Load($list.WorkflowAssociations)

                    $q = New-Object Microsoft.SharePoint.Client.CamlQuery
                    $q.ViewXml = "<View><Query><OrderBy><FieldRef Name='Created' Ascending='FALSE'/></OrderBy></Query><RowLimit>1</RowLimit><ViewFields><FieldRef Name='Created'/></ViewFields></View>"
                    $items = $list.GetItems($q)
                    $ctx.Load($items)
                    $ctx.ExecuteQuery()

                    $lastCreatedItems[$list.Id.ToString()] = $items
                } catch {
                    # Skip this list on individual failure
                }
            }
        }

        # Helper to extract last created date from pre-loaded items
        function Get-BatchedLastCreated ([string]$ListId) {
            if ($lastCreatedItems.ContainsKey($ListId)) {
                $items = $lastCreatedItems[$ListId]
                try {
                    if ($items.Count -gt 0) { return $items[0]["Created"] }
                } catch {}
            }
            return $null
        }

        # ── SP2010 Workflows ──────────────────────────────────────────────────
        foreach ($list in $visibleLists) {
            try { $assocs = $list.WorkflowAssociations } catch { continue }
            if (-not $assocs -or $assocs.Count -eq 0) { continue }

            $lastCreated = Get-BatchedLastCreated -ListId $list.Id.ToString()

            foreach ($wf in $assocs) {
                $bytes  = Find-WfFile -Ctx $ctx -WebSRUrl $webSRUrl -WfName $wf.Name -Ext "xoml"
                $counts = if ($bytes) { Parse-Xoml -Bytes $bytes }
                          else { @{ ActivityCount=0; ActionCount=0; ConditionCount=0 } }

                $WfResults.Add([PSCustomObject]@{
                    WebUrl              = $webUrl
                    WebTitle            = $webTitle
                    ListTitle           = $list.Title
                    ListUrl             = $webUrl.TrimEnd('/') + '/' + $list.DefaultViewUrl.TrimStart('/')
                    WorkflowName        = $wf.Name
                    WorkflowType        = "SP2010"
                    ActivityCount       = $counts.ActivityCount
                    ActionCount         = $counts.ActionCount
                    ConditionCount      = $counts.ConditionCount
                    ListItemCount       = $list.ItemCount
                    LastItemCreatedDate = $lastCreated
                    LastModified        = $wf.Modified
                    Notes               = if ($bytes) { "" } else { "XOML not located" }
                })
            }
        }

        # ── SP2013 Workflows ──────────────────────────────────────────────────
        try {
            $wfMgr    = New-Object Microsoft.SharePoint.Client.WorkflowServices.WorkflowServicesManager($ctx, $web)
            $wfSubSvc = $wfMgr.GetWorkflowSubscriptionService()
            $wfDefSvc = $wfMgr.GetWorkflowDefinitionService()
            $ctx.Load($wfMgr)
            $ctx.ExecuteQuery()

            $allDefs = $wfDefSvc.EnumerateDefinitions($true)
            $ctx.Load($allDefs)
            $ctx.ExecuteQuery()

            $defMap = @{}
            foreach ($d in $allDefs) { $defMap[$d.Id] = $d }

            # Fix #2: Batch all subscription enumerations — single round trip
            $allSubsByList = @{}
            foreach ($list in $visibleLists) {
                try {
                    $subs = $wfSubSvc.EnumerateSubscriptionsByList($list.Id)
                    $ctx.Load($subs)
                    $allSubsByList[$list.Id.ToString()] = $subs
                } catch {}
            }
            try {
                Invoke-WithRetry -Retries $MaxRetries -Action { $ctx.ExecuteQuery() }
            } catch {
                $ErrorLog.Add([PSCustomObject]@{
                    SiteUrl = $WebUrl; Context = "Batch SP2013 subscription load"
                    Error   = $_.Exception.Message
                })
                $allSubsByList = @{}
            }

            foreach ($list in $visibleLists) {
                $listKey = $list.Id.ToString()
                if (-not $allSubsByList.ContainsKey($listKey)) { continue }

                $subs = $allSubsByList[$listKey]
                try { $subsCount = $subs.Count } catch { continue }
                if ($subsCount -eq 0) { continue }

                $lastCreated = Get-BatchedLastCreated -ListId $listKey

                foreach ($sub in $subs) {
                    $bytes = $null
                    try {
                        if ($defMap.ContainsKey($sub.DefinitionId)) {
                            $def = $defMap[$sub.DefinitionId]
                            # Fix #4: Prefer Xaml property first (already loaded, no round trip)
                            if ($def.Xaml) {
                                $bytes = [System.Text.Encoding]::UTF8.GetBytes($def.Xaml)
                            } else {
                                $bytes = Find-WfFile -Ctx $ctx -WebSRUrl $webSRUrl `
                                             -WfName $def.DisplayName -Ext "xaml"
                            }
                        }
                    } catch {}

                    $counts = if ($bytes) { Parse-Xaml -Bytes $bytes }
                              else { @{ ActivityCount=0; ActionCount=0; ConditionCount=0 } }

                    $WfResults.Add([PSCustomObject]@{
                        WebUrl              = $webUrl
                        WebTitle            = $webTitle
                        ListTitle           = $list.Title
                        ListUrl             = $webUrl.TrimEnd('/') + '/' + $list.DefaultViewUrl.TrimStart('/')
                        WorkflowName        = $sub.Name
                        WorkflowType        = "SP2013"
                        ActivityCount       = $counts.ActivityCount
                        ActionCount         = $counts.ActionCount
                        ConditionCount      = $counts.ConditionCount
                        ListItemCount       = $list.ItemCount
                        LastItemCreatedDate = $lastCreated
                        LastModified        = $sub.PropertyDefinitions["ModifiedDate"]
                        Notes               = if ($bytes) { "" } else { "XAML not located" }
                    })
                }
            }
        } catch {
            # SP2013 workflow services not deployed on this farm — skip silently
        }

        # ── InfoPath Form Libraries (BaseTemplate 115) ────────────────────────
        $ipLists = @($visibleLists | Where-Object { $_.BaseTemplate -eq 115 })

        if ($ipLists.Count -gt 0) {
            # Fix #3: Batch load root folders, files, and content types for all IP lists
            foreach ($list in $ipLists) {
                $rootFolder = $list.RootFolder
                $ctx.Load($rootFolder)
                $ctx.Load($rootFolder.Files)
                $ctx.Load($list.ContentTypes)
            }
            try {
                Invoke-WithRetry -Retries $MaxRetries -Action { $ctx.ExecuteQuery() }
            } catch {
                $ErrorLog.Add([PSCustomObject]@{
                    SiteUrl = $WebUrl; Context = "Batch InfoPath folder load"
                    Error   = $_.Exception.Message
                })
                $ipLists = @()  # Skip InfoPath processing on batch failure
            }
        }

        foreach ($list in $ipLists) {
            try {
                $rootFolder   = $list.RootFolder
                $lastCreated  = Get-BatchedLastCreated -ListId $list.Id.ToString()
                $formTypeName = if ($list.ContentTypes.Count -gt 0) {
                                    $list.ContentTypes[0].Name } else { "Form Library" }
                $xsnFiles     = @($rootFolder.Files | Where-Object { $_.Name -like "*.xsn" })

                if ($xsnFiles.Count -eq 0) {
                    $IpResults.Add([PSCustomObject]@{
                        WebUrl = $webUrl; WebTitle = $webTitle; ListTitle = $list.Title
                        FormName = $list.Title; FormType = "Form Library (No XSN)"
                        FormUrl  = $webUrl.TrimEnd('/') + '/' + $list.DefaultViewUrl.TrimStart('/')
                        RuleCount=0; ActionCount=0; ValidationCount=0; FormattingCount=0
                        ConditionCount=0; DataConnectionCount=0; FieldCount=0
                        ItemCount=$list.ItemCount; LastItemCreatedDate=$lastCreated
                        XsnLastModified=$null; Notes="No XSN template found"
                    })
                    continue
                }

                # Fix #3: XSN file metadata already loaded in batch above
                # Only binary downloads remain sequential (OpenBinaryDirect can't be batched)
                foreach ($xsn in $xsnFiles) {
                    $bytes  = Get-FileBytes -Ctx $ctx -ServerRelUrl $xsn.ServerRelativeUrl
                    $parsed = Parse-Xsn -Bytes $bytes

                    $IpResults.Add([PSCustomObject]@{
                        WebUrl              = $webUrl
                        WebTitle            = $webTitle
                        ListTitle           = $list.Title
                        FormName            = [System.IO.Path]::GetFileNameWithoutExtension($xsn.Name)
                        FormType            = $formTypeName
                        FormUrl             = $webUrl.TrimEnd('/') + $xsn.ServerRelativeUrl
                        RuleCount           = $parsed.RuleCount
                        ActionCount         = $parsed.ActionCount
                        ValidationCount     = $parsed.ValidationCount
                        FormattingCount     = $parsed.FormattingCount
                        ConditionCount      = $parsed.ConditionCount
                        DataConnectionCount = $parsed.DataConnections
                        FieldCount          = $parsed.FieldCount
                        ItemCount           = $list.ItemCount
                        LastItemCreatedDate = $lastCreated
                        XsnLastModified     = $xsn.TimeLastModified
                        Notes               = if ($bytes) { "" } else { "XSN download failed" }
                    })
                }
            } catch {
                $ErrorLog.Add([PSCustomObject]@{
                    SiteUrl = $WebUrl
                    Context = "InfoPath - $($list.Title)"
                    Error   = $_.Exception.Message
                })
            }
        }

    } catch {
        $ErrorLog.Add([PSCustomObject]@{
            SiteUrl = $WebUrl; Context = "Web audit"; Error = $_.Exception.Message
        })
    } finally {
        # Fix #8: Always dispose context, even on error
        if ($ctx) { $ctx.Dispose() }
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# PHASE 1 — LAUNCH DISCOVERY
# ─────────────────────────────────────────────────────────────────────────────
Write-Host "" 
Write-Host "  ====================================================" -ForegroundColor Cyan
Write-Host "  SP Migration Complexity Assessment (Patched v2)" -ForegroundColor Cyan
Write-Host "  ====================================================" -ForegroundColor Cyan
Write-Host "  PHASE 1: Discovering all webs (incl. subsites)..." -ForegroundColor Yellow
Write-Host "  Root sites: $($SiteUrls.Count) | Max depth: $MaxSubsiteDepth | Throttle: $DiscoveryThrottle" -ForegroundColor Gray
Write-Host ""

$sw1  = [System.Diagnostics.Stopwatch]::StartNew()
$pool = [RunspaceFactory]::CreateRunspacePool(1, $DiscoveryThrottle)
$pool.ApartmentState = "MTA"
$pool.Open()

$dJobs = [System.Collections.Generic.List[hashtable]]::new()
foreach ($root in $SiteUrls) {
    $ps = [PowerShell]::Create()
    $ps.RunspacePool = $pool
    [void]$ps.AddScript($DiscoveryScriptBlock)
    [void]$ps.AddArgument($root)
    [void]$ps.AddArgument($CsomDllFolder)
    [void]$ps.AddArgument($Credential)
    [void]$ps.AddArgument($MaxSubsiteDepth)
    [void]$ps.AddArgument($MaxRetries)
    [void]$ps.AddArgument($AllWebs)
    [void]$ps.AddArgument($ErrorLog)
    $dJobs.Add(@{ PS = $ps; Handle = $ps.BeginInvoke(); Url = $root })
    Write-Host "  [Queued] $root" -ForegroundColor Gray
}

foreach ($j in $dJobs) {
    try   { [void]$j.PS.EndInvoke($j.Handle) }
    catch { Write-Warning "  Discovery failed: $($j.Url) - $($_.Exception.Message)" }
    finally { $j.PS.Dispose() }
}
$pool.Close(); $pool.Dispose(); $sw1.Stop()

# Fix #11: Already deduplicated via ConcurrentDictionary — no Select-Object -Unique needed
$discoveredWebs = @($AllWebs.Keys | Sort-Object)
Write-Host ""
Write-Host "  Done in $($sw1.Elapsed.ToString('mm\:ss'))" -ForegroundColor Green
Write-Host "  Total webs to audit: $($discoveredWebs.Count) (includes all subsites)" -ForegroundColor Green
Write-Host ""

# ─────────────────────────────────────────────────────────────────────────────
# PHASE 2 — PARALLEL AUDIT
# ─────────────────────────────────────────────────────────────────────────────
Write-Host "  ====================================================" -ForegroundColor Cyan
Write-Host "  PHASE 2: Auditing $($discoveredWebs.Count) web(s) in parallel..." -ForegroundColor Yellow
Write-Host "  ThrottleLimit: $ThrottleLimit" -ForegroundColor Gray
Write-Host ""

$sw2  = [System.Diagnostics.Stopwatch]::StartNew()
$pool = [RunspaceFactory]::CreateRunspacePool(1, $ThrottleLimit)
$pool.ApartmentState = "MTA"
$pool.Open()

$aJobs = [System.Collections.Generic.List[hashtable]]::new()
foreach ($wUrl in $discoveredWebs) {
    $ps = [PowerShell]::Create()
    $ps.RunspacePool = $pool
    [void]$ps.AddScript($AuditScriptBlock)
    [void]$ps.AddArgument($wUrl)
    [void]$ps.AddArgument($CsomDllFolder)
    [void]$ps.AddArgument($Credential)
    [void]$ps.AddArgument($BatchSize)
    [void]$ps.AddArgument($MaxRetries)
    [void]$ps.AddArgument($WfResults)
    [void]$ps.AddArgument($IpResults)
    [void]$ps.AddArgument($ErrorLog)
    $aJobs.Add(@{ PS = $ps; Handle = $ps.BeginInvoke(); Url = $wUrl })
}

$done  = 0
$total = $discoveredWebs.Count

# Fix #15: Rate-limit progress output for large farms
$progressInterval = [Math]::Max(1, [int]($total / 100))

foreach ($j in $aJobs) {
    try {
        [void]$j.PS.EndInvoke($j.Handle)
        $done++
        if ($done % $progressInterval -eq 0 -or $done -eq $total) {
            Write-Progress -Activity "Auditing webs" `
                -Status "$done / $total  [$($sw2.Elapsed.ToString('mm\:ss'))]" `
                -PercentComplete ([int](($done / $total) * 100))
        }
        Write-Host "  OK [$done/$total] $($j.Url)" -ForegroundColor Green
    } catch {
        $done++
        Write-Host "  X [$done/$total] $($j.Url) - $($_.Exception.Message)" -ForegroundColor Red
    } finally { $j.PS.Dispose() }
}
$pool.Close(); $pool.Dispose(); $sw2.Stop()
Write-Progress -Activity "Auditing webs" -Completed

# ─────────────────────────────────────────────────────────────────────────────
# EXPORT
# ─────────────────────────────────────────────────────────────────────────────
$wfList = @($WfResults | Select-Object *)
$ipList = @($IpResults | Select-Object *)
$erList = @($ErrorLog  | Select-Object *)

$wfList | Sort-Object WebUrl, ListTitle, WorkflowName |
    Export-Csv -Path $WorkflowCsv -NoTypeInformation -Encoding UTF8

$ipList | Sort-Object WebUrl, ListTitle, FormName |
    Export-Csv -Path $InfoPathCsv -NoTypeInformation -Encoding UTF8

$errCsv = $null
if ($erList.Count -gt 0) {
    $errCsv = ($WorkflowCsv -replace "\.csv$","") + "_ERRORS.csv"
    $erList | Export-Csv -Path $errCsv -NoTypeInformation -Encoding UTF8
}

# ─────────────────────────────────────────────────────────────────────────────
# SUMMARY
# ─────────────────────────────────────────────────────────────────────────────
$wf2010 = @($wfList | Where-Object { $_.WorkflowType -eq "SP2010" }).Count
$wf2013 = @($wfList | Where-Object { $_.WorkflowType -eq "SP2013" }).Count

Write-Host ""
Write-Host "  ====================================================" -ForegroundColor Cyan
Write-Host "  COMPLETE" -ForegroundColor Green
Write-Host "  ====================================================" -ForegroundColor Cyan
Write-Host "  Root sites input       : $($SiteUrls.Count)"               -ForegroundColor White
Write-Host "  Total webs audited     : $total"                            -ForegroundColor White
Write-Host "  Phase 1 (discovery)    : $($sw1.Elapsed.ToString('mm\:ss'))" -ForegroundColor White
Write-Host "  Phase 2 (audit)        : $($sw2.Elapsed.ToString('mm\:ss'))" -ForegroundColor White
Write-Host "  Total elapsed          : $(($sw1.Elapsed + $sw2.Elapsed).ToString('mm\:ss'))" -ForegroundColor White
Write-Host "  ----------------------------------------------------" -ForegroundColor Cyan
Write-Host "  SP2010 Workflows       : $wf2010"                           -ForegroundColor White
Write-Host "  SP2013 Workflows       : $wf2013"                           -ForegroundColor White
Write-Host "  InfoPath Forms         : $($ipList.Count)"                  -ForegroundColor White
$errColor = "White"
if ($erList.Count -gt 0) { $errColor = "Yellow" }
Write-Host "  Errors                 : $($erList.Count)" -ForegroundColor $errColor
Write-Host "  ----------------------------------------------------" -ForegroundColor Cyan
Write-Host "  Workflow CSV  : $WorkflowCsv"                               -ForegroundColor Yellow
Write-Host "  InfoPath CSV  : $InfoPathCsv"                               -ForegroundColor Yellow
if ($errCsv) {
Write-Host "  Errors CSV    : $errCsv"                                    -ForegroundColor Yellow }
Write-Host "  ====================================================" -ForegroundColor Cyan
Write-Host ""
