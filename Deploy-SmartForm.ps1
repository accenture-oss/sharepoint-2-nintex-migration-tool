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
    $dlls = @("SourceCode.Forms.Management.dll", "SourceCode.HostClientAPI.dll", "SourceCode.Framework.dll")
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
    $soName = $soJson.name -replace '[^a-zA-Z0-9_]', '_'
    $soDisplayName = $soJson.displayName
    $soGuid = $soJson.guid

    # Connect to FormsManager with optional explicit credentials
    $fm = New-Object SourceCode.Forms.Management.FormsManager
    $fm.CreateConnection() | Out-Null
    
    # Build connection string with explicit credentials if available
    if ($K2User -and $K2Password) {
        $connStr = "Integrated=False;IsPrimaryLogin=True;Authenticate=True;EncryptedPassword=False;UserID=$K2Domain\$K2User;Password=$K2Password;Host=$K2Server;Port=$K2Port"
    } else {
        $connStr = "Integrated=True;IsPrimaryLogin=True;Authenticate=True;EncryptedPassword=False;Host=$K2Server;Port=$K2Port"
    }
    
    $fm.Open($connStr) | Out-Null
    
    # Verify connection is authenticated (especially important for explicit credentials)
    # For Windows Integrated auth, the connection may appear not fully authenticated until first use,
    # so we only enforce this check for explicit credential scenarios
    if ($K2User -and $K2Password) {
        if (-not $fm.Connection.IsConnected -or -not $fm.Connection.IsAuthenticated) {
            $error_msg = "K2 Forms API authentication failed with provided credentials. IsConnected=$($fm.Connection.IsConnected), IsAuthenticated=$($fm.Connection.IsAuthenticated), Host=$K2Server, User=$K2Domain\$K2User"
            Write-Host ('{"success":false,"error":"' + $error_msg + '"}')
            exit 1
        }
    }

    # Generate GUIDs
    $viewGuid = [System.Guid]::NewGuid().ToString()
    $listViewGuid = [System.Guid]::NewGuid().ToString()
    $formGuid = [System.Guid]::NewGuid().ToString()

    $viewName = "$soName Item View"
    $listViewName = "$soName List View"
    $formName = "$soName Form"

    # =====================================================
    # 1. Build Item View (Capture/Edit view)
    # =====================================================
    $controlsXml = ''
    $canvasRowsXml = ''
    $rowIndex = 0

    foreach ($prop in $soJson.properties) {
        $propName = $prop.name
        $propDisplay = $prop.displayName
        $controlId = [System.Guid]::NewGuid().ToString()
        $labelId = [System.Guid]::NewGuid().ToString()
        $cellId1 = [System.Guid]::NewGuid().ToString()
        $cellId2 = [System.Guid]::NewGuid().ToString()
        $rowId = [System.Guid]::NewGuid().ToString()

        $controlType = "TextBox"

        # Label control
        $controlsXml += '<Control ID="' + $labelId + '" Type="Label"><Name>lbl' + $propName + '</Name><DisplayName>' + $propDisplay + '</DisplayName>'
        $controlsXml += '<Properties><Property><Name>ControlName</Name><Value>lbl' + $propName + '</Value></Property>'
        $controlsXml += '<Property><Name>Text</Name><Value>' + $propDisplay + '</Value></Property>'
        $controlsXml += '<Property><Name>LiteralVal</Name><Value>true</Value></Property></Properties></Control>'

        # Input control
        $controlsXml += '<Control ID="' + $controlId + '" Type="' + $controlType + '"><Name>txt' + $propName + '</Name><DisplayName>' + $propDisplay + '</DisplayName>'
        $controlsXml += '<Properties><Property><Name>ControlName</Name><Value>txt' + $propName + '</Value></Property>'
        $controlsXml += '<Property><Name>Width</Name><Value>100%</Value></Property></Properties></Control>'

        # Cells
        $controlsXml += '<Control ID="' + $cellId1 + '" Type="Cell"><Name>Cell_L' + $rowIndex + '</Name><Properties><Property><Name>ControlName</Name><Value>Cell_L' + $rowIndex + '</Value></Property></Properties></Control>'
        $controlsXml += '<Control ID="' + $cellId2 + '" Type="Cell"><Name>Cell_R' + $rowIndex + '</Name><Properties><Property><Name>ControlName</Name><Value>Cell_R' + $rowIndex + '</Value></Property></Properties></Control>'

        # Row
        $controlsXml += '<Control ID="' + $rowId + '" Type="Row"><Name>Row' + $rowIndex + '</Name><Properties><Property><Name>ControlName</Name><Value>Row' + $rowIndex + '</Value></Property></Properties></Control>'

        $canvasRowsXml += '<Row ID="' + $rowId + '"><Cells><Cell ID="' + $cellId1 + '"><Control ID="' + $labelId + '" /></Cell><Cell ID="' + $cellId2 + '"><Control ID="' + $controlId + '" /></Cell></Cells></Row>'
        $rowIndex++
    }

    # Table and section controls
    $tableId = [System.Guid]::NewGuid().ToString()
    $sectionId = [System.Guid]::NewGuid().ToString()
    $col1Id = [System.Guid]::NewGuid().ToString()
    $col2Id = [System.Guid]::NewGuid().ToString()

    $controlsXml += '<Control ID="' + $tableId + '" Type="Table"><Name>MainTable</Name><Properties><Property><Name>ControlName</Name><Value>MainTable</Value></Property></Properties></Control>'
    $controlsXml += '<Control ID="' + $sectionId + '" Type="Section"><Name>MainSection</Name><Properties><Property><Name>Type</Name><Value>Body</Value></Property><Property><Name>ControlName</Name><Value>MainSection</Value></Property></Properties></Control>'
    $controlsXml += '<Control ID="' + $col1Id + '" Type="Column"><Name>LabelCol</Name><Properties><Property><Name>ControlName</Name><Value>LabelCol</Value></Property><Property><Name>Size</Name><Value>30%</Value></Property></Properties></Control>'
    $controlsXml += '<Control ID="' + $col2Id + '" Type="Column"><Name>InputCol</Name><Properties><Property><Name>ControlName</Name><Value>InputCol</Value></Property><Property><Name>Size</Name><Value>70%</Value></Property></Properties></Control>'

    # View control
    $controlsXml += '<Control ID="' + $viewGuid + '" Type="View"><Name>' + $viewName + '</Name><Properties><Property><Name>ControlName</Name><Value>' + $viewName + '</Value></Property></Properties></Control>'

    $itemViewXml = '<SourceCode.Forms Version="28"><Views>'
    $itemViewXml += '<View ID="' + $viewGuid + '" Type="Capture" RenderVersion="3">'
    $itemViewXml += '<Name>' + $viewName + '</Name>'
    $itemViewXml += '<DisplayName>' + $soDisplayName + ' Item View</DisplayName>'
    $itemViewXml += '<Controls>' + $controlsXml + '</Controls>'
    $itemViewXml += '<Canvas><Sections><Section ID="' + $sectionId + '" Type="Body">'
    $itemViewXml += '<Control ID="' + $tableId + '" LayoutType="Grid">'
    $itemViewXml += '<Columns><Column ID="' + $col1Id + '" Size="30%" /><Column ID="' + $col2Id + '" Size="70%" /></Columns>'
    $itemViewXml += '<Rows>' + $canvasRowsXml + '</Rows>'
    $itemViewXml += '</Control></Section></Sections></Canvas>'
    $itemViewXml += '<Events />'
    $itemViewXml += '</View></Views></SourceCode.Forms>'

    # =====================================================
    # 2. Build List View
    # =====================================================
    $listControlsXml = ''
    $listFieldsXml = ''

    foreach ($prop in $soJson.properties) {
        $fieldId = [System.Guid]::NewGuid().ToString()
        $listControlsXml += '<Control ID="' + $fieldId + '" Type="DataLabel"><Name>dl' + $prop.name + '</Name><DisplayName>' + $prop.displayName + '</DisplayName>'
        $listControlsXml += '<Properties><Property><Name>ControlName</Name><Value>dl' + $prop.name + '</Value></Property>'
        $listControlsXml += '<Property><Name>LiteralVal</Name><Value>false</Value></Property></Properties></Control>'

        $listFieldsXml += '<Field ID="' + $fieldId + '" />'
    }

    $listSectionId = [System.Guid]::NewGuid().ToString()
    $listControlsXml += '<Control ID="' + $listViewGuid + '" Type="View"><Name>' + $listViewName + '</Name><Properties><Property><Name>ControlName</Name><Value>' + $listViewName + '</Value></Property></Properties></Control>'
    $listControlsXml += '<Control ID="' + $listSectionId + '" Type="Section"><Name>ListSection</Name><Properties><Property><Name>Type</Name><Value>Body</Value></Property><Property><Name>ControlName</Name><Value>ListSection</Value></Property></Properties></Control>'

    $listViewXml = '<SourceCode.Forms Version="28"><Views>'
    $listViewXml += '<View ID="' + $listViewGuid + '" Type="List" RenderVersion="3">'
    $listViewXml += '<Name>' + $listViewName + '</Name>'
    $listViewXml += '<DisplayName>' + $soDisplayName + ' List View</DisplayName>'
    $listViewXml += '<Controls>' + $listControlsXml + '</Controls>'
    $listViewXml += '<Canvas><Sections><Section ID="' + $listSectionId + '" Type="Body">'
    $listViewXml += $listFieldsXml
    $listViewXml += '</Section></Sections></Canvas>'
    $listViewXml += '<Events />'
    $listViewXml += '</View></Views></SourceCode.Forms>'

    # =====================================================
    # 3. Build Form (container for views)
    # =====================================================
    $panelId = [System.Guid]::NewGuid().ToString()
    $areaId = [System.Guid]::NewGuid().ToString()
    $areaItemId = [System.Guid]::NewGuid().ToString()

    $formXml = '<SourceCode.Forms Version="28"><Forms>'
    $formXml += '<Form ID="' + $formGuid + '" Type="Normal" RenderVersion="3" Layout="Normal" Theme="Platinum2">'
    $formXml += '<Name>' + $formName + '</Name>'
    $formXml += '<DisplayName>' + $soDisplayName + '</DisplayName>'
    $formXml += '<Controls>'
    # Avoid control-name collision with the form name itself; K2 creates internal form records for the form name.
    $formRootControlName = $soName + '_FormRoot'
    $formXml += '<Control ID="' + $formGuid + '" Type="Form"><Name>' + $formRootControlName + '</Name><DisplayName>' + $soDisplayName + '</DisplayName>'
    $formXml += '<Properties><Property><Name>ControlName</Name><Value>' + $formRootControlName + '</Value></Property>'
    $formXml += '<Property><Name>IsVisible</Name><Value>true</Value></Property></Properties></Control>'
    $formXml += '<Control ID="' + $panelId + '" Type="Panel"><Name>' + $soDisplayName + '</Name><Properties><Property><Name>ControlName</Name><Value>' + $soDisplayName + '</Value></Property></Properties></Control>'
    $formXml += '<Control ID="' + $areaId + '" Type="Area"><Name>' + $formName + ' Area</Name><Properties><Property><Name>ControlName</Name><Value>' + $formName + ' Area</Value></Property></Properties></Control>'
    $formXml += '<Control ID="' + $areaItemId + '" Type="AreaItem"><Name>ViewArea</Name><Properties>'
    $formXml += '<Property><Name>ControlName</Name><Value>ViewArea</Value></Property></Properties></Control>'
    $formXml += '</Controls>'
    $formXml += '<Panels><Panel ID="' + $panelId + '" Layout="Rows"><Name>' + $soDisplayName + '</Name>'
    $formXml += '<Areas><Area ID="' + $areaId + '"><Items>'
    $formXml += '<Item ID="' + $areaItemId + '" ViewID="' + $viewGuid + '"><Name>' + $viewName + '</Name></Item>'
    $formXml += '</Items></Area></Areas></Panel></Panels>'
    $formXml += '<States><State ID="' + ([System.Guid]::NewGuid().ToString()) + '" IsBase="True"><Events /></State></States>'
    $formXml += '</Form></Forms></SourceCode.Forms>'

    # =====================================================
    # 4. Deploy to K2
    # =====================================================
    $category = "Generated\Migration"

    # Check if views/form already exist and delete them to allow clean redeploy
    # K2 APIs can resolve by plain name or category-qualified path depending on environment.
    $itemViewPath = "$category\$viewName"
    $listViewPath = "$category\$listViewName"
    $formPath = "$category\$formName"

    $itemViewExists = $fm.CheckViewExists($viewName) -or $fm.CheckViewExists($itemViewPath)
    $listViewExists = $fm.CheckViewExists($listViewName) -or $fm.CheckViewExists($listViewPath)
    $formExists = $fm.CheckFormExists($formName) -or $fm.CheckFormExists($formPath)

    $results = @()
    $results += "DIAG: formExists=$formExists (checked '$formName' and '$formPath')"
    $results += "DIAG: itemViewExists=$itemViewExists (checked '$viewName' and '$itemViewPath')"
    $results += "DIAG: listViewExists=$listViewExists (checked '$listViewName' and '$listViewPath')"

    # Delete existing form first (to allow republish)
    if ($formExists) {
        $formDeleted = $false

        try {
            $fm.DeleteForm($formName)
            $formDeleted = $true
            $results += "Deleted existing form: $formName"
        } catch {
            $results += "DeleteForm by name failed for '$formName': $($_.Exception.Message)"
        }

        if (-not $formDeleted) {
            try {
                $fm.DeleteForm($formPath)
                $formDeleted = $true
                $results += "Deleted existing form by category path: $formPath"
            } catch {
                $results += "DeleteForm by path failed for '$formPath': $($_.Exception.Message)"
            }
        }

        $formStillExists = $fm.CheckFormExists($formName) -or $fm.CheckFormExists($formPath)
        if ($formStillExists) {
            throw "Cannot safely redeploy: existing form still present after delete attempts ('$formName' / '$formPath')."
        }
    }

    # Delete existing views if they exist
    if ($itemViewExists) {
        $itemDeleted = $false

        try {
            $fm.DeleteView($viewName)
            $itemDeleted = $true
            $results += "Deleted existing view: $viewName"
        } catch {
            $results += "DeleteView by name failed for '$viewName': $($_.Exception.Message)"
        }

        if (-not $itemDeleted) {
            try {
                $fm.DeleteView($itemViewPath)
                $itemDeleted = $true
                $results += "Deleted existing view by category path: $itemViewPath"
            } catch {
                $results += "DeleteView by path failed for '$itemViewPath': $($_.Exception.Message)"
            }
        }

        $itemStillExists = $fm.CheckViewExists($viewName) -or $fm.CheckViewExists($itemViewPath)
        if ($itemStillExists) {
            throw "Cannot safely redeploy: existing item view still present after delete attempts ('$viewName' / '$itemViewPath')."
        }
    }

    if ($listViewExists) {
        $listDeleted = $false

        try {
            $fm.DeleteView($listViewName)
            $listDeleted = $true
            $results += "Deleted existing view: $listViewName"
        } catch {
            $results += "DeleteView by name failed for '$listViewName': $($_.Exception.Message)"
        }

        if (-not $listDeleted) {
            try {
                $fm.DeleteView($listViewPath)
                $listDeleted = $true
                $results += "Deleted existing view by category path: $listViewPath"
            } catch {
                $results += "DeleteView by path failed for '$listViewPath': $($_.Exception.Message)"
            }
        }

        $listStillExists = $fm.CheckViewExists($listViewName) -or $fm.CheckViewExists($listViewPath)
        if ($listStillExists) {
            throw "Cannot safely redeploy: existing list view still present after delete attempts ('$listViewName' / '$listViewPath')."
        }
    }

    # Now deploy fresh
    $fm.DeployViews($itemViewXml, $category, $true)
    $results += "Item View deployed: $viewName"

    $fm.DeployViews($listViewXml, $category, $true)
    $results += "List View deployed: $listViewName"

    $fm.DeployForms($formXml, $category, $true)
    $results += "Form deployed: $formName"

    $fm.Dispose()

    $result = @{
        "success" = $true
        "smartObjectName" = $soName
        "itemView" = $viewName
        "listView" = $listViewName
        "form" = $formName
        "details" = ($results -join "; ")
    }
    Write-Output ($result | ConvertTo-Json -Compress)

} catch {
    $result = @{
        "success" = $false
        "error" = "$($_.Exception.Message)"
        "smartObjectName" = $soName
        "details" = if ($results -and $results.Count -gt 0) { ($results -join "; ") } else { "No diagnostic info captured" }
    }
    Write-Output ($result | ConvertTo-Json -Compress)
}
