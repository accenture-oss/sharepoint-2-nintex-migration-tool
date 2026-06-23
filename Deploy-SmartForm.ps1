param (
    [string]$K2Server = "NINTEX-SP-POC",
    [int]$K2Port = 5555,
    [string]$SmartObjectJsonFile = "",
    [string]$K2DllPath = "",
    [string]$K2User = "",
    [string]$K2Password = "",
    [string]$K2Domain = ""
)

$ErrorActionPreference = "Stop"

if ([string]::IsNullOrWhiteSpace($K2DllPath)) {
    $K2DllPath = "C:\Program Files\K2\Bin"
}

if (-not (Test-Path $K2DllPath)) {
    Write-Host ('{"success":false,"error":"K2DllPath not found: ' + $K2DllPath + '"}')
    exit 1
}

[System.AppDomain]::CurrentDomain.AppendPrivatePath($K2DllPath)

try {
    # Load K2 DLLs with unblock-file support for bank environments with copied DLLs
    $dlls = @("SourceCode.Forms.Management.dll", "SourceCode.SmartObjects.Management.dll", "SourceCode.SmartObjects.Client.dll", "SourceCode.HostClientAPI.dll", "SourceCode.Framework.dll")
    $loadErrors = @()
    foreach ($dll in $dlls) {
        $p = Join-Path $K2DllPath $dll
        if (Test-Path $p) {
            try {
                try { Unblock-File -Path $p -ErrorAction Stop } catch { }
                [System.Reflection.Assembly]::LoadFrom($p) | Out-Null
            } catch {
                $loadErrors += "$dll : $($_.Exception.Message)"
            }
        } else {
            $loadErrors += "$dll : file not found at $p"
        }
    }
    if ($loadErrors.Count -gt 0) {
        $errorText = 'K2 Forms SDK load failures (K2DllPath=' + $K2DllPath + '): ' + ($loadErrors -join '; ')
        if ($errorText -match '0x80131515') {
            $errorText += ' | Hint: DLLs are likely blocked (MOTW). Run: Get-ChildItem "' + $K2DllPath + '\*.dll" | Unblock-File'
        }
        Write-Host ('{"success":false,"error":"' + $errorText + '"}')
        exit 1
    }

    $soJson = Get-Content $SmartObjectJsonFile -Raw | ConvertFrom-Json
    $rawName = $soJson.name -replace '[^a-zA-Z0-9_]', '_'
    $brokerType = if ($soJson.brokerType) { $soJson.brokerType } else { "SmartBox" }

    # Build connection string
    if ($K2User -and $K2Password) {
        $connStr = "Integrated=False;IsPrimaryLogin=True;Authenticate=True;EncryptedPassword=False;UserID=$K2Domain\$K2User;Password=$K2Password;Host=$K2Server;Port=$K2Port"
    } else {
        $connStr = "Integrated=True;IsPrimaryLogin=True;Authenticate=True;EncryptedPassword=False;Host=$K2Server;Port=$K2Port"
    }

    $results = @()

    # ─────────────────────────────────────────────────────────────────
    # SharePoint Broker: Use K2's built-in GenerateArtifactsForSharePointList
    # This is the official K2 Application approach — generates SmartObjects,
    # SmartForms (New/Edit/Display), Views, and sets Content Type form URLs
    # automatically with proper GUID bindings and event wiring.
    # ─────────────────────────────────────────────────────────────────
    if ($brokerType -eq "SharePoint") {
        $soName = $rawName
        $soDisplayName = if ($soJson.listTitle) { $soJson.listTitle } else { ($rawName -replace '_', ' ') }

        $results += "DIAG: brokerType=SharePoint"
        $results += "DIAG: Using K2 SP Broker GenerateArtifactsForSharePointList"

        # ── Get SP context from JSON (set by server.js from linkedSO) ──
        $siteUrl   = if ($soJson.webUrl) { $soJson.webUrl } else { "" }
        $listTitle = if ($soJson.listTitle) { $soJson.listTitle } else { $soDisplayName }
        $listId    = if ($soJson.listId) { $soJson.listId } else { "" }
        $siteTitle = if ($soJson.siteTitle) { $soJson.siteTitle } else { "" }

        # Extract siteTitle from URL if not provided
        if (-not $siteTitle -and $siteUrl -match '/sites/([^/]+)') {
            $siteTitle = $Matches[1]
        }

        $sourceUrl = "$siteUrl/Lists/$listTitle"

        # K2 App Site URL (environment-specific)
        $k2AppSiteUrl = "http://app-00e8e7b26314b2.apps.nintex-sp-poc/sites/NintexAppsCatalog/K2forSharePoint"

        # Connect to SmartObject client
        $soClient = New-Object SourceCode.SmartObjects.Client.SmartObjectClientServer
        $soClient.CreateConnection() | Out-Null
        $soClient.Connection.Open($connStr) | Out-Null

        # If listId is missing, try to get it from existing SO definition
        if (-not $listId) {
            $results += "DIAG: listId not in JSON, trying SO definition lookup..."
            try {
                $smoMgmt = New-Object SourceCode.SmartObjects.Management.SmartObjectManagementServer
                $smoMgmt.CreateConnection() | Out-Null
                $smoMgmt.Connection.Open($connStr) | Out-Null
                # Find SO by name pattern
                $allSOs = $smoMgmt.GetSmartObjects()
                $foundSO = $null
                foreach ($so in $allSOs.SmartObjects) {
                    if ($so.Name -match "_Lists_$([regex]::Escape($listTitle))`$") {
                        $foundSO = $so.Name
                        break
                    }
                }
                if ($foundSO) {
                    $soDef = $smoMgmt.GetSmartObjectDefinition($foundSO)
                    if ($soDef -match '<key name="ListId">([^<]+)</key>') { $listId = $Matches[1] }
                    if (-not $siteUrl -and $soDef -match '<key name="RelativeSiteUrl">([^<]+)</key>') {
                        $relUrl = $Matches[1]
                        if ($foundSO -match '^([^_]+)___') {
                            $hostName = $Matches[1] -replace '_', '-'
                            $siteUrl = "http://$hostName$relUrl"
                        }
                    }
                    $sourceUrl = "$siteUrl/Lists/$listTitle"
                    $results += "DIAG: Resolved from SO '$foundSO': ListId=$listId SiteUrl=$siteUrl"
                }
                $smoMgmt.Connection.Close()
            } catch {
                $results += "WARN: SO definition lookup failed: $($_.Exception.Message)"
            }
        }

        $results += "DIAG: SiteUrl=$siteUrl ListId=$listId ListTitle=$listTitle SiteTitle=$siteTitle"

        if (-not $siteUrl -or -not $listId -or -not $listTitle) {
            throw "Cannot resolve SP context: SiteUrl='$siteUrl', ListId='$listId', ListTitle='$listTitle'. Ensure the list data is available."
        }

        # ── Call GenerateArtifactsForSharePointList ──
        $helperSO = $soClient.GetSmartObject("SharePoint_Integration_Workflow_Helper_Methods")
        $helperSO.MethodToExecute = "GenerateArtifactsForSharePointList"

        $helperSO.Properties["k2_Int_K2_App_Site_URL"].Value = $k2AppSiteUrl
        $helperSO.Properties["K2_Int_SiteUrl"].Value         = $siteUrl
        $helperSO.Properties["K2_Int_SiteTitle"].Value        = $siteTitle
        $helperSO.Properties["K2_Int_ListId"].Value           = $listId
        $helperSO.Properties["K2_Int_ListTitle"].Value        = $listTitle
        $helperSO.Properties["K2_Int_SourceUrl"].Value        = $sourceUrl

        # Generate SmartForms + set content type URLs + reports
        $helperSO.Properties["k2_Int_GenerateSmartForms"].Value = "true"
        $helperSO.Properties["k2_Int_SetFormsUrl"].Value        = "true"
        $helperSO.Properties["k2_Int_GenerateReports"].Value    = "true"
        $helperSO.Properties["k2_Int_LinkSmOScope"].Value       = "System"

        $results += "Executing GenerateArtifactsForSharePointList..."

        $genResult = $soClient.ExecuteScalar($helperSO)

        $generatedSOName = $genResult.Properties["K2_Int_SmartObjectSystemName"].Value
        $categoryId      = $genResult.Properties["K2_Int_CategoryId"].Value
        $formsUrlXml     = $genResult.Properties["K2_Int_formsUrlXml"].Value
        $reportUrl       = $genResult.Properties["K2_Int_WFReportFormUrl"].Value

        $results += "GenerateArtifacts SUCCESS: SO=$generatedSOName CategoryId=$categoryId"

        $soClient.Connection.Close()

        # ── Parse form URLs from the result XML ──
        $newFormUrl = ""; $editFormUrl = ""; $displayFormUrl = ""
        if ($formsUrlXml -match '<NewFormUrl>([^<]+)</NewFormUrl>') { $newFormUrl = $Matches[1] }
        if ($formsUrlXml -match '<EditFormUrl>([^<]+)</EditFormUrl>') { $editFormUrl = $Matches[1] }
        if ($formsUrlXml -match '<DisplayFormUrl>([^<]+)</DisplayFormUrl>') { $displayFormUrl = $Matches[1] }

        # Extract form names from URLs (last path segment, URL-decoded)
        $newFormName = [System.Uri]::UnescapeDataString(($newFormUrl -replace '.*/Form/', ''))
        $editFormName = [System.Uri]::UnescapeDataString(($editFormUrl -replace '.*/Form/', ''))
        $displayFormName = [System.Uri]::UnescapeDataString(($displayFormUrl -replace '.*/Form/', ''))

        $results += "Forms generated: New=$newFormName Edit=$editFormName Display=$displayFormName"
        $results += "Content type URLs set automatically by K2 broker"

        $result = @{
            "success" = $true
            "smartObjectName" = $generatedSOName
            "brokerType" = $brokerType
            "loadMethod" = "GetListItem"
            "listMethod" = "GetListItems"
            "newForm" = $newFormName
            "editForm" = $editFormName
            "displayForm" = $displayFormName
            "newFormUrl" = $newFormUrl
            "editFormUrl" = $editFormUrl
            "displayFormUrl" = $displayFormUrl
            "reportUrl" = $reportUrl
            "runtimeUrl" = $editFormUrl
            "designerUrl" = "https://$K2Server/Designer/"
            "details" = ($results -join "; ")
        }
        Write-Output ($result | ConvertTo-Json -Compress)

    } else {
        # ─────────────────────────────────────────────────────────────────
        # SmartBox Broker: Manual XML form generation (existing logic)
        # Used for custom SmartObjects that aren't backed by SharePoint lists
        # ─────────────────────────────────────────────────────────────────
        $soName = $rawName
        $soDisplayName = $soJson.displayName
        $smartObjectName = if ($soJson.smartObjectName) { $soJson.smartObjectName } else { $soName }
        $soGuid = $soJson.guid

        $loadMethod   = "Read"
        $listMethod   = "GetList"
        $createMethod = "Create"
        $updateMethod = "Update"
        $deleteMethod = "Delete"

        # Connect to FormsManager
        $fm = New-Object SourceCode.Forms.Management.FormsManager
        $fm.CreateConnection() | Out-Null
        $fm.Open($connStr) | Out-Null

        # Verify connection
        if ($K2User -and $K2Password) {
            if (-not $fm.Connection.IsConnected -or -not $fm.Connection.IsAuthenticated) {
                $error_msg = "K2 Forms API authentication failed. IsConnected=$($fm.Connection.IsConnected), IsAuthenticated=$($fm.Connection.IsAuthenticated)"
                Write-Host ('{"success":false,"error":"' + $error_msg + '"}')
                exit 1
            }
        }

        # Generate GUIDs
        $viewGuid = [System.Guid]::NewGuid().ToString()
        $formGuid = [System.Guid]::NewGuid().ToString()

        $btnSaveGuid = [System.Guid]::NewGuid().ToString()
        $btnCancelGuid = [System.Guid]::NewGuid().ToString()
        $btnCellSaveGuid = [System.Guid]::NewGuid().ToString()
        $btnCellCancelGuid = [System.Guid]::NewGuid().ToString()
        $btnCellSpacerGuid = [System.Guid]::NewGuid().ToString()
        $btnRowGuid = [System.Guid]::NewGuid().ToString()

        $ev_viewInit_guid = [System.Guid]::NewGuid().ToString()
        $ev_viewInit_def = [System.Guid]::NewGuid().ToString()
        $ev_viewInit_handler = [System.Guid]::NewGuid().ToString()
        $ev_viewInit_handlerDef = [System.Guid]::NewGuid().ToString()
        $ev_viewInit_action = [System.Guid]::NewGuid().ToString()
        $ev_viewInit_actionDef = [System.Guid]::NewGuid().ToString()

        $ev_saveClick_guid = [System.Guid]::NewGuid().ToString()
        $ev_saveClick_def = [System.Guid]::NewGuid().ToString()
        $ev_saveClick_handler = [System.Guid]::NewGuid().ToString()
        $ev_saveClick_handlerDef = [System.Guid]::NewGuid().ToString()
        $ev_saveClick_action = [System.Guid]::NewGuid().ToString()
        $ev_saveClick_actionDef = [System.Guid]::NewGuid().ToString()

        $ev_formInit_guid = [System.Guid]::NewGuid().ToString()
        $ev_formInit_def = [System.Guid]::NewGuid().ToString()
        $ev_formInit_handler = [System.Guid]::NewGuid().ToString()
        $ev_formInit_handlerDef = [System.Guid]::NewGuid().ToString()
        $ev_formInit_action = [System.Guid]::NewGuid().ToString()
        $ev_formInit_actionDef = [System.Guid]::NewGuid().ToString()
        $formStateGuid = [System.Guid]::NewGuid().ToString()

        # Filter properties
        $excludePatterns = @(
            '^K2_Int_', '^ContentTypeId$', '^ComplianceAssetId$', '^_UIVersionString$',
            '^FileLeafRef$', '^Folder$', '^LinkFilename$', '^LinkToItem$',
            '^Attachments$', '^SharePoint_TimeZone$',
            '^Author$', '^Author_Value$', '^Editor$', '^Editor_Value$',
            '^Created$', '^Modified$', '^ContentType$',
            '^IgnoreIfExist$', '^Overwrite$', '^OverwriteMinorVersion$', '^RetainCheckout$'
        )
        $excludeRegex = ($excludePatterns -join '|')

        $formProperties = @()
        foreach ($prop in $soJson.properties) {
            if ($prop.name -notmatch $excludeRegex) {
                $formProperties += $prop
            }
        }

        $viewName = "$soName Item View"
        $formName = "$soName Form"

        $results += "DIAG: brokerType=SmartBox loadMethod=$loadMethod"
        $results += "DIAG: smartObjectName=$smartObjectName"
        $results += "DIAG: Using manual XML form generation (SmartBox)"

        # Build Item View controls
        $controlsXml = ''
        $canvasRowsXml = ''
        $rowIndex = 0
        $dataFieldMappingsXml = ''

        foreach ($prop in $formProperties) {
            $propName = $prop.name
            $propDisplay = $prop.displayName
            $controlId = [System.Guid]::NewGuid().ToString()
            $labelId = [System.Guid]::NewGuid().ToString()
            $cellId1 = [System.Guid]::NewGuid().ToString()
            $cellId2 = [System.Guid]::NewGuid().ToString()
            $rowId = [System.Guid]::NewGuid().ToString()

            $controlsXml += '<Control ID="' + $labelId + '" Type="Label"><Name>lbl' + $propName + '</Name><DisplayName>' + $propDisplay + '</DisplayName>'
            $controlsXml += '<Properties><Property><Name>ControlName</Name><Value>lbl' + $propName + '</Value></Property>'
            $controlsXml += '<Property><Name>Text</Name><Value>' + $propDisplay + '</Value></Property>'
            $controlsXml += '<Property><Name>LiteralVal</Name><Value>true</Value></Property></Properties></Control>'

            $controlsXml += '<Control ID="' + $controlId + '" Type="TextBox"><Name>txt' + $propName + '</Name><DisplayName>' + $propDisplay + '</DisplayName>'
            $controlsXml += '<Properties><Property><Name>ControlName</Name><Value>txt' + $propName + '</Value></Property>'
            $controlsXml += '<Property><Name>Width</Name><Value>100%</Value></Property></Properties></Control>'

            $controlsXml += '<Control ID="' + $cellId1 + '" Type="Cell"><Name>Cell_L' + $rowIndex + '</Name><Properties><Property><Name>ControlName</Name><Value>Cell_L' + $rowIndex + '</Value></Property></Properties></Control>'
            $controlsXml += '<Control ID="' + $cellId2 + '" Type="Cell"><Name>Cell_R' + $rowIndex + '</Name><Properties><Property><Name>ControlName</Name><Value>Cell_R' + $rowIndex + '</Value></Property></Properties></Control>'
            $controlsXml += '<Control ID="' + $rowId + '" Type="Row"><Name>Row' + $rowIndex + '</Name><Properties><Property><Name>ControlName</Name><Value>Row' + $rowIndex + '</Value></Property></Properties></Control>'

            $canvasRowsXml += '<Row ID="' + $rowId + '"><Cells><Cell ID="' + $cellId1 + '"><Control ID="' + $labelId + '" /></Cell><Cell ID="' + $cellId2 + '"><Control ID="' + $controlId + '" /></Cell></Cells></Row>'
            $dataFieldMappingsXml += '<Mapping FieldName="' + $propName + '" ControlName="txt' + $propName + '" Direction="Both" />'
            $rowIndex++
        }

        # Buttons
        $controlsXml += '<Control ID="' + $btnSaveGuid + '" Type="Button"><Name>btnSave</Name><DisplayName>Save</DisplayName>'
        $controlsXml += '<Properties><Property><Name>ControlName</Name><Value>btnSave</Value></Property>'
        $controlsXml += '<Property><Name>Text</Name><Value>Save</Value></Property></Properties></Control>'
        $controlsXml += '<Control ID="' + $btnCancelGuid + '" Type="Button"><Name>btnCancel</Name><DisplayName>Cancel</DisplayName>'
        $controlsXml += '<Properties><Property><Name>ControlName</Name><Value>btnCancel</Value></Property>'
        $controlsXml += '<Property><Name>Text</Name><Value>Cancel</Value></Property></Properties></Control>'
        $controlsXml += '<Control ID="' + $btnCellSaveGuid + '" Type="Cell"><Name>Cell_BtnSave</Name><Properties><Property><Name>ControlName</Name><Value>Cell_BtnSave</Value></Property></Properties></Control>'
        $controlsXml += '<Control ID="' + $btnCellCancelGuid + '" Type="Cell"><Name>Cell_BtnCancel</Name><Properties><Property><Name>ControlName</Name><Value>Cell_BtnCancel</Value></Property></Properties></Control>'
        $controlsXml += '<Control ID="' + $btnCellSpacerGuid + '" Type="Cell"><Name>Cell_BtnSpacer</Name><Properties><Property><Name>ControlName</Name><Value>Cell_BtnSpacer</Value></Property></Properties></Control>'
        $controlsXml += '<Control ID="' + $btnRowGuid + '" Type="Row"><Name>ButtonRow</Name><Properties><Property><Name>ControlName</Name><Value>ButtonRow</Value></Property></Properties></Control>'

        $canvasRowsXml += '<Row ID="' + $btnRowGuid + '"><Cells><Cell ID="' + $btnCellSpacerGuid + '" />'
        $canvasRowsXml += '<Cell ID="' + $btnCellSaveGuid + '"><Control ID="' + $btnSaveGuid + '" /></Cell>'
        $canvasRowsXml += '<Cell ID="' + $btnCellCancelGuid + '"><Control ID="' + $btnCancelGuid + '" /></Cell></Cells></Row>'

        # Layout controls
        $tableId = [System.Guid]::NewGuid().ToString()
        $sectionId = [System.Guid]::NewGuid().ToString()
        $col1Id = [System.Guid]::NewGuid().ToString()
        $col2Id = [System.Guid]::NewGuid().ToString()

        $controlsXml += '<Control ID="' + $tableId + '" Type="Table"><Name>MainTable</Name><Properties><Property><Name>ControlName</Name><Value>MainTable</Value></Property></Properties></Control>'
        $controlsXml += '<Control ID="' + $sectionId + '" Type="Section"><Name>MainSection</Name><Properties><Property><Name>Type</Name><Value>Body</Value></Property><Property><Name>ControlName</Name><Value>MainSection</Value></Property></Properties></Control>'
        $controlsXml += '<Control ID="' + $col1Id + '" Type="Column"><Name>LabelCol</Name><Properties><Property><Name>ControlName</Name><Value>LabelCol</Value></Property><Property><Name>Size</Name><Value>30%</Value></Property></Properties></Control>'
        $controlsXml += '<Control ID="' + $col2Id + '" Type="Column"><Name>InputCol</Name><Properties><Property><Name>ControlName</Name><Value>InputCol</Value></Property><Property><Name>Size</Name><Value>70%</Value></Property></Properties></Control>'
        $controlsXml += '<Control ID="' + $viewGuid + '" Type="View"><Name>' + $viewName + '</Name><Properties><Property><Name>ControlName</Name><Value>' + $viewName + '</Value></Property></Properties></Control>'

        # DataSource
        $dataSourceXml  = '<DataSource Type="SmartObject"><SmartObject Name="' + $smartObjectName + '" /><Methods>'
        $dataSourceXml += '<Method Name="' + $loadMethod + '" Type="Read" /><Method Name="' + $createMethod + '" Type="Create" />'
        $dataSourceXml += '<Method Name="' + $updateMethod + '" Type="Update" /><Method Name="' + $deleteMethod + '" Type="Delete" /></Methods>'
        $dataSourceXml += '<PropertyMappings>' + $dataFieldMappingsXml + '</PropertyMappings></DataSource>'

        # Events — CLEAN: no ObjectID, no Parameters in actions
        $eventsXml  = '<Events>'
        $eventsXml += '<Event ID="' + $ev_viewInit_guid + '" DefinitionID="' + $ev_viewInit_def + '" Type="User"'
        $eventsXml += ' SourceID="' + $viewGuid + '" SourceType="View"'
        $eventsXml += ' SourceName="' + $viewName + '" SourceDisplayName="' + $viewName + '">'
        $eventsXml += '<Name>Init</Name><Properties>'
        $eventsXml += '<Property><Name>RuleFriendlyName</Name><Value>When the View executed Initialize</Value></Property>'
        $eventsXml += '<Property><Name>Location</Name><Value>' + $viewName + '</Value></Property></Properties>'
        $eventsXml += '<Handlers><Handler ID="' + $ev_viewInit_handler + '" DefinitionID="' + $ev_viewInit_handlerDef + '">'
        $eventsXml += '<Properties><Property><Name>HandlerName</Name><Value>IfLogicalHandler</Value></Property>'
        $eventsXml += '<Property><Name>Location</Name><Value>view</Value></Property></Properties>'
        $eventsXml += '<Actions><Action ID="' + $ev_viewInit_action + '" DefinitionID="' + $ev_viewInit_actionDef + '"'
        $eventsXml += ' Type="Execute" ExecutionType="Synchronous"><Properties>'
        $eventsXml += '<Property><Name>Location</Name><Value>View</Value></Property>'
        $eventsXml += '<Property><Name>Method</Name><Value>' + $loadMethod + '</Value></Property>'
        $eventsXml += '<Property><Name>ViewID</Name><Value>' + $viewGuid + '</Value></Property>'
        $eventsXml += '</Properties></Action></Actions></Handler></Handlers></Event>'

        $eventsXml += '<Event ID="' + $ev_saveClick_guid + '" DefinitionID="' + $ev_saveClick_def + '" Type="User"'
        $eventsXml += ' SourceID="' + $btnSaveGuid + '" SourceType="Control"'
        $eventsXml += ' SourceName="btnSave" SourceDisplayName="Save">'
        $eventsXml += '<Name>OnClick</Name><Properties>'
        $eventsXml += '<Property><Name>RuleFriendlyName</Name><Value>When Save is Clicked</Value></Property>'
        $eventsXml += '<Property><Name>Location</Name><Value>' + $viewName + '</Value></Property></Properties>'
        $eventsXml += '<Handlers><Handler ID="' + $ev_saveClick_handler + '" DefinitionID="' + $ev_saveClick_handlerDef + '">'
        $eventsXml += '<Properties><Property><Name>HandlerName</Name><Value>IfLogicalHandler</Value></Property>'
        $eventsXml += '<Property><Name>Location</Name><Value>view</Value></Property></Properties>'
        $eventsXml += '<Actions><Action ID="' + $ev_saveClick_action + '" DefinitionID="' + $ev_saveClick_actionDef + '"'
        $eventsXml += ' Type="Execute" ExecutionType="Synchronous"><Properties>'
        $eventsXml += '<Property><Name>Location</Name><Value>View</Value></Property>'
        $eventsXml += '<Property><Name>Method</Name><Value>' + $createMethod + '</Value></Property>'
        $eventsXml += '<Property><Name>ViewID</Name><Value>' + $viewGuid + '</Value></Property>'
        $eventsXml += '</Properties></Action></Actions></Handler></Handlers></Event>'
        $eventsXml += '</Events>'

        # Assemble view
        $itemViewXml = '<SourceCode.Forms><Views><View ID="' + $viewGuid + '" Type="Capture">'
        $itemViewXml += '<Name>' + $viewName + '</Name><DisplayName>' + $soDisplayName + ' Item View</DisplayName>'
        $itemViewXml += $dataSourceXml
        $itemViewXml += '<Controls>' + $controlsXml + '</Controls>'
        $itemViewXml += '<Canvas><Sections><Section ID="' + $sectionId + '" Type="Body">'
        $itemViewXml += '<Control ID="' + $tableId + '" LayoutType="Grid">'
        $itemViewXml += '<Columns><Column ID="' + $col1Id + '" Size="30%" /><Column ID="' + $col2Id + '" Size="70%" /></Columns>'
        $itemViewXml += '<Rows>' + $canvasRowsXml + '</Rows>'
        $itemViewXml += '</Control></Section></Sections></Canvas>'
        $itemViewXml += $eventsXml
        $itemViewXml += '</View></Views></SourceCode.Forms>'

        # Assemble form
        $panelId = [System.Guid]::NewGuid().ToString()
        $areaId = [System.Guid]::NewGuid().ToString()
        $areaItemId = [System.Guid]::NewGuid().ToString()

        $formXml = '<SourceCode.Forms><Forms><Form ID="' + $formGuid + '" Type="Normal" Layout="Normal" Theme="Platinum2">'
        $formXml += '<Name>' + $formName + '</Name><DisplayName>' + $soDisplayName + '</DisplayName><Controls>'
        $formRootControlName = $soName + '_FormRoot'
        $formXml += '<Control ID="' + $formGuid + '" Type="Form"><Name>' + $formRootControlName + '</Name><DisplayName>' + $soDisplayName + '</DisplayName>'
        $formXml += '<Properties><Property><Name>ControlName</Name><Value>' + $formRootControlName + '</Value></Property>'
        $formXml += '<Property><Name>IsVisible</Name><Value>true</Value></Property></Properties></Control>'
        $formXml += '<Control ID="' + $panelId + '" Type="Panel"><Name>' + $soDisplayName + '</Name><Properties><Property><Name>ControlName</Name><Value>' + $soDisplayName + '</Value></Property></Properties></Control>'
        $formXml += '<Control ID="' + $areaId + '" Type="Area"><Name>' + $formName + ' Area</Name><Properties><Property><Name>ControlName</Name><Value>' + $formName + ' Area</Value></Property></Properties></Control>'
        $formXml += '<Control ID="' + $areaItemId + '" Type="AreaItem"><Name>ViewArea</Name><Properties><Property><Name>ControlName</Name><Value>ViewArea</Value></Property></Properties></Control>'
        $formXml += '</Controls>'
        $formXml += '<Panels><Panel ID="' + $panelId + '" Layout="Rows"><Name>' + $soDisplayName + '</Name>'
        $formXml += '<Areas><Area ID="' + $areaId + '"><Items>'
        $formXml += '<Item ID="' + $areaItemId + '" ViewID="' + $viewGuid + '"><Name>' + $viewName + '</Name></Item>'
        $formXml += '</Items></Area></Areas></Panel></Panels>'

        # Form Init event
        $formXml += '<States><State ID="' + $formStateGuid + '" IsBase="True"><Events>'
        $formXml += '<Event ID="' + $ev_formInit_guid + '" DefinitionID="' + $ev_formInit_def + '" Type="User"'
        $formXml += ' SourceID="' + $formGuid + '" SourceType="Form"'
        $formXml += ' SourceName="' + $formName + '" SourceDisplayName="' + $soDisplayName + '">'
        $formXml += '<Name>Init</Name><Properties>'
        $formXml += '<Property><Name>Location</Name><Value>' + $formName + '</Value></Property>'
        $formXml += '<Property><Name>RuleFriendlyName</Name><Value>When the Form is Initializing</Value></Property></Properties>'
        $formXml += '<Handlers><Handler ID="' + $ev_formInit_handler + '" DefinitionID="' + $ev_formInit_handlerDef + '">'
        $formXml += '<Actions><Action ID="' + $ev_formInit_action + '" DefinitionID="' + $ev_formInit_actionDef + '"'
        $formXml += ' Type="Execute" ExecutionType="Synchronous" InstanceID="' + $areaItemId + '">'
        $formXml += '<Properties><Property><Name>Method</Name><DisplayValue>Initialize</DisplayValue><NameValue>Init</NameValue><Value>Init</Value></Property>'
        $formXml += '<Property><Name>ViewID</Name><DisplayValue>' + $viewName + '</DisplayValue>'
        $formXml += '<NameValue>' + $viewName + '</NameValue><Value>' + $viewGuid + '</Value></Property>'
        $formXml += '</Properties></Action></Actions></Handler></Handlers></Event>'
        $formXml += '</Events></State></States>'
        $formXml += '</Form></Forms></SourceCode.Forms>'

        # Deploy
        $category = "Generated\Migration"

        # Delete existing
        foreach ($n in @($formName, "$soName New Form", "$soName Edit Form", "$soName Display Form")) {
            try { $fm.DeleteForm($n) } catch {}
        }
        foreach ($n in @($viewName, "$soName New View", "$soName Edit View", "$soName Display View")) {
            try { $fm.DeleteView($n) } catch {}
        }

        try {
            $fm.DeployViews($itemViewXml, $category, $true)
            $results += "View deployed: $viewName"
        } catch {
            $results += "FAIL DeployViews: $($_.Exception.Message)"
            throw
        }
        try {
            $fm.DeployForms($formXml, $category, $true)
            $results += "Form deployed: $formName"
        } catch {
            $results += "FAIL DeployForms: $($_.Exception.Message)"
            throw
        }

        $fm.Dispose()

        $result = @{
            "success" = $true
            "smartObjectName" = $soName
            "brokerType" = $brokerType
            "loadMethod" = $loadMethod
            "listMethod" = $listMethod
            "newForm" = $formName
            "editForm" = $formName
            "displayForm" = $formName
            "runtimeUrl" = "https://$K2Server/Runtime/Runtime/Form/$([System.Uri]::EscapeDataString($formName))/"
            "designerUrl" = "https://$K2Server/Designer/"
            "details" = ($results -join "; ")
        }
        Write-Output ($result | ConvertTo-Json -Compress)
    }

} catch {
    $result = @{
        "success" = $false
        "error" = "$($_.Exception.Message)"
        "smartObjectName" = if ($soName) { $soName } else { $rawName }
        "brokerType" = if ($brokerType) { $brokerType } else { "unknown" }
        "details" = if ($results -and $results.Count -gt 0) { ($results -join "; ") } else { "No diagnostic info captured" }
    }
    Write-Output ($result | ConvertTo-Json -Compress)
}
