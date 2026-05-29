param (
    [string]$K2Server = "NINTEX-SP-POC",
    [int]$K2Port = 5555,
    [string]$SmartObjectJsonFile
)

try {
    Add-Type -Path "C:\Program Files\K2\Bin\SourceCode.Forms.Management.dll"
    Add-Type -Path "C:\Program Files\K2\Bin\SourceCode.HostClientAPI.dll"
    Add-Type -Path "C:\Program Files\K2\Bin\SourceCode.Framework.dll"

    $soJson = Get-Content $SmartObjectJsonFile -Raw | ConvertFrom-Json
    $soName = $soJson.name -replace '[^a-zA-Z0-9_]', '_'
    $soDisplayName = $soJson.displayName
    $soGuid = $soJson.guid

    # Connect to FormsManager
    $fm = New-Object SourceCode.Forms.Management.FormsManager
    $fm.CreateConnection()
    $fm.Open("Integrated=True;IsPrimaryLogin=True;Authenticate=True;EncryptedPassword=False;Host=$K2Server;Port=$K2Port")

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
    $formXml += '<Control ID="' + $formGuid + '" Type="Form"><Name>' + $formName + '</Name><DisplayName>' + $soDisplayName + '</DisplayName>'
    $formXml += '<Properties><Property><Name>ControlName</Name><Value>' + $formName + '</Value></Property>'
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

    # Check if views/form already exist and skip
    $itemViewExists = $fm.CheckViewExists($viewName)
    $listViewExists = $fm.CheckViewExists($listViewName)
    $formExists = $fm.CheckFormExists($formName)

    $results = @()

    if (-not $itemViewExists) {
        $fm.DeployViews($itemViewXml, $category, $true)
        $results += "Item View deployed: $viewName"
    } else {
        $results += "Item View already exists: $viewName"
    }

    if (-not $listViewExists) {
        $fm.DeployViews($listViewXml, $category, $true)
        $results += "List View deployed: $listViewName"
    } else {
        $results += "List View already exists: $listViewName"
    }

    if (-not $formExists) {
        $fm.DeployForms($formXml, $category, $true)
        $results += "Form deployed: $formName"
    } else {
        $results += "Form already exists: $formName"
    }

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
    }
    Write-Output ($result | ConvertTo-Json -Compress)
}
