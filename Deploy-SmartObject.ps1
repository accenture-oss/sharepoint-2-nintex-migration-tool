# Deploy-SmartObject.ps1
# Creates SmartObjects on K2 Five using the correct K2 native XML format
# Reverse-engineered from existing K2 SmartObject definition

param(
    [string]$K2Server = "",
    [int]$K2Port = 5555,
    [string]$SmartObjectJsonFile = "",
    [string]$SodxXmlFile = "",
    [string]$K2DllPath = "C:\Program Files\K2\Bin",
    [string]$K2User = "",          # Optional: explicit K2 user for on-premises
    [string]$K2Password = "",      # Optional: explicit K2 password
    [string]$K2Domain = ""         # Optional: domain for K2 user
)

$ErrorActionPreference = "Stop"

if ([string]::IsNullOrWhiteSpace($K2DllPath)) {
    $K2DllPath = "C:\Program Files\K2\Bin"
}

if (-not (Test-Path $K2DllPath)) {
    Write-Host ('{"success":false,"error":"K2DllPath not found: ' + $K2DllPath + '"}')
    exit 1
}

# Load K2 SDK — AppendPrivatePath tells .NET to probe $K2DllPath when
# resolving any dependency, so no event handler or pre-load loop is needed.
[System.AppDomain]::CurrentDomain.AppendPrivatePath($K2DllPath)

$loadErrors = @()
foreach ($dll in @("SourceCode.Framework.dll","SourceCode.HostClientAPI.dll","SourceCode.SmartObjects.Authoring.dll","SourceCode.SmartObjects.Management.dll")) {
    $p = Join-Path $K2DllPath $dll
    if (Test-Path $p) {
        try {
            # Bank/distributed environments often copy DLLs from another server.
            # Windows can mark them with Zone.Identifier (MOTW), causing 0x80131515 on LoadFrom.
            try { Unblock-File -Path $p -ErrorAction Stop } catch { }
            [System.Reflection.Assembly]::LoadFrom($p) | Out-Null
        }
        catch { $loadErrors += "$dll : $($_.Exception.Message)" }
    } else {
        $loadErrors += "$dll : file not found at $p"
    }
}
if ($loadErrors.Count -gt 0) {
    $errorText = 'K2 SDK load failures (K2DllPath=' + $K2DllPath + '): ' + ($loadErrors -join '; ')
    if ($errorText -match '0x80131515') {
        $errorText += ' | Hint: DLLs are likely blocked (MOTW). Run: Get-ChildItem "' + $K2DllPath + '\*.dll" | Unblock-File'
    }
    Write-Host ('{"success":false,"error":"' + $errorText + '"}')
    exit 1
}

# Read SmartObject JSON
if ($SmartObjectJsonFile -eq "" -or -not (Test-Path $SmartObjectJsonFile)) {
    Write-Host '{"success":false,"error":"SmartObjectJsonFile not found"}'
    exit 1
}
$so = (Get-Content $SmartObjectJsonFile -Raw) | ConvertFrom-Json

if ($K2Server -eq "") {
    Write-Host '{"success":false,"error":"K2Server is required"}'
    exit 1
}

# Build connection string for on-premises K2
# IsPrimaryLogin=True is REQUIRED for SmartObjectManagementServer
# To avoid browser auth: provide explicit credentials (K2User + K2Password)
# or rely on Windows Integrated auth if user has K2 permissions
if ($K2User -and $K2Password) {
    # Explicit credentials: for service account deployments (no browser popup)
    $userPart = if ($K2Domain) { "$K2Domain\$K2User" } else { $K2User }
    $connStr = "Integrated=False;IsPrimaryLogin=True;Authenticate=True;EncryptedPassword=False;UserID=$userPart;Password=$K2Password;Host=$K2Server;Port=$K2Port"
} else {
    # Integrated Windows auth (current user) with IsPrimaryLogin=True
    # Note: May still prompt if user lacks K2 permissions or K2 is configured for Forms auth
    $connStr = "Integrated=True;IsPrimaryLogin=True;Authenticate=True;EncryptedPassword=False;Host=$K2Server;Port=$K2Port"
}

try {
    $mgmt = New-Object SourceCode.SmartObjects.Management.SmartObjectManagementServer
    $mgmt.CreateConnection()
    $mgmt.Connection.Open($connStr)

    if (-not $mgmt.Connection.IsConnected) {
        Write-Host ('{"success":false,"error":"Could not connect to K2 at ' + $K2Server + ':' + $K2Port + '"}')
        exit 1
    }

    # Find SmartBox Service Instance GUID
    # Try to get it from an existing SmartObject
    $smartBoxGuid = "e5609413-d844-4325-98c3-db3cacbd406d"  # default from sample
    try {
        $existingSOs = $mgmt.GetSmartObjects()
        if ($existingSOs.SmartObjects.Count -gt 0) {
            $sampleXml = $mgmt.GetSmartObjectDefinition($false, $existingSOs.SmartObjects[0].Name)
            if ($sampleXml -match 'serviceinstance name="SmartBoxService" guid="([a-f0-9\-]+)"') {
                $smartBoxGuid = $Matches[1]
            }
        }
    } catch {}

    # Build system name (no spaces, underscores)
    $soName = $so.name -replace '[^a-zA-Z0-9_]', '_'
    $soDisplayName = $so.displayName
    $soGuid = $so.guid
    if (-not $soGuid -or $soGuid -eq "") {
        $soGuid = [System.Guid]::NewGuid().ToString()
    }
    $objectGuid = [System.Guid]::NewGuid().ToString()

    # Map property types
    function Get-K2Type($soType) {
        switch ($soType) {
            "Text"      { return "text" }
            "Memo"      { return "memo" }
            "Number"    { return "number" }
            "Decimal"   { return "decimal" }
            "DateTime"  { return "datetime" }
            "YesNo"     { return "yesno" }
            "Guid"      { return "guid" }
            "AutoGuid"  { return "autoguid" }
            "HyperLink" { return "hyperlink" }
            "Image"     { return "image" }
            default     { return "text" }
        }
    }

    # Build ID props XML snippet
    $idPropsXml = @"
<object type="System.Collections.Generic.List``1[[System.String, mscorlib, Version=4.0.0.0, Culture=neutral, PublicKeyToken=b77a5c561934e089]]"><ArrayOfString xmlns:xsd="http://www.w3.org/2001/XMLSchema" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"><string>ID</string></ArrayOfString></object>
"@

    $serviceMetaXml = @"
<key name="idprops">$idPropsXml</key><key name="noofuniqueproperties"><object type="System.Int32"><int>1</int></object></key><key name="autonumberprop">ID</key><key name="autoguidprop" /><key name="guid"><object type="System.Guid"><guid>$objectGuid</guid></object></key>
"@

    # Build top-level properties XML
    $propsXml = '<property name="ID" type="autonumber" unique="true" system="false" required="false"><metadata><display><displayname>ID</displayname><description>The key used to identify a specific record.</description></display><service /></metadata></property>'
    foreach ($prop in $so.properties) {
        if ($prop.name -eq "ID" -or $prop.name -eq "Id") { continue }
        $k2Type = Get-K2Type $prop.soType
        $propsXml += '<property name="' + $prop.name + '" type="' + $k2Type + '" unique="false" system="false" required="false"><metadata><display><displayname>' + $prop.displayName + '</displayname><description /></display><service /></metadata></property>'
    }

    # Build service-level properties XML (used inside each method's service instance)
    $svcPropsXml = '<property name="ID" type="System.Int64" extendtype="UniqueIdAuto" sotype="autonumber"><metadata><display><displayname>ID</displayname><description>The key used to identify a specific record.</description></display><service><key name="uniqueid"><object type="System.Boolean"><boolean>true</boolean></object></key><key name="autonumber"><object type="System.Boolean"><boolean>true</boolean></object></key><key name="unique">true</key></service></metadata><mappings><mapping type="property"><property name="ID" /></mapping></mappings></property>'
    foreach ($prop in $so.properties) {
        if ($prop.name -eq "ID" -or $prop.name -eq "Id") { continue }
        $k2Type = Get-K2Type $prop.soType
        $svcPropsXml += '<property name="' + $prop.name + '" type="" extendtype="Default" sotype="' + $k2Type + '"><metadata><display><displayname>' + $prop.displayName + '</displayname><description /></display><service><key name="uniqueid"><object type="System.Boolean"><boolean>false</boolean></object></key><key name="autonumber"><object type="System.Boolean"><boolean>false</boolean></object></key></service></metadata><mappings><mapping type="property"><property name="' + $prop.name + '" /></mapping></mappings></property>'
    }

    # Build input properties list (all props)
    $allPropNames = @("ID")
    foreach ($prop in $so.properties) {
        if ($prop.name -ne "ID" -and $prop.name -ne "Id") { $allPropNames += $prop.name }
    }
    $inputAll = ($allPropNames | ForEach-Object { '<property name="' + $_ + '" />' }) -join ''
    $returnAll = $inputAll
    $inputId = '<property name="ID" />'

    # Service instance block template
    $svcBlock = '<serviceinstance name="SmartBoxService" guid="' + $smartBoxGuid + '" type="SourceCode.SmartObjects.Services.SmartBox.SBService" execblock="0"><metadata><display><displayname>SmartBox Service</displayname><description /></display><service /></metadata><objects><object name="' + $soName + '" version="" type="default"><metadata><display><displayname>' + $soName + '</displayname><description /></display><service>' + $serviceMetaXml + '</service></metadata><properties>' + $svcPropsXml + '</properties><methods>%%METHOD%%</methods></object></objects></serviceinstance>'

    # Build methods
    function Build-Method($mName, $mType, $mDisplay, $mDesc, $mInput, $mReturn, $mRequired) {
        $reqXml = '<requiredproperties>'
        if ($mRequired) { $reqXml += $mRequired }
        $reqXml += '</requiredproperties>'
        $innerMethod = '<method name="' + $mName + '" type="' + $mType + '"><metadata><display><displayname>' + $mDisplay + '</displayname><description>' + $mDesc + '</description></display><service /></metadata><parameters /><validation>' + $reqXml + '</validation><input>' + $mInput + '</input><return>' + $mReturn + '</return></method>'
        $svc = $svcBlock.Replace('%%METHOD%%', $innerMethod)
        return '<method name="' + $mName + '" type="' + $mType + '" transaction="continue" execblockno="0"><metadata><display><displayname>' + $mDisplay + '</displayname><description>' + $mDesc + '</description></display><service /></metadata><serviceinstances>' + $svc + '</serviceinstances><parameters /></method>'
    }

    $methodsXml = ""
    $methodsXml += Build-Method "Create" "create" "Create" "This method creates a new entry" $inputAll '<property name="ID" />' ""
    $methodsXml += Build-Method "Save" "update" "Save" "This method updates an entry, or if the entry does not exist creates it." $inputAll '<property name="ID" />' ""
    $methodsXml += Build-Method "Delete" "delete" "Delete" "This method deletes a single entry" $inputId "" ('<property name="ID" />')
    $methodsXml += Build-Method "Load" "read" "Load" "This method loads a single entry" $inputId $returnAll ('<property name="ID" />')
    $methodsXml += Build-Method "GetList" "list" "Get List" "This method gets a list of entries" $inputAll $returnAll ""

    # Build extending object properties
    $extPropsXml = '<propertydata name="ID" type="System.Int64" extendtype="UniqueIdAuto" sotype="autonumber"><metadata><display><displayname>ID</displayname><description>The key used to identify a specific record.</description></display><service><key name="uniqueid"><object type="System.Boolean"><boolean>true</boolean></object></key><key name="autonumber"><object type="System.Boolean"><boolean>true</boolean></object></key><key name="unique">true</key></service></metadata></propertydata>'
    foreach ($prop in $so.properties) {
        if ($prop.name -eq "ID" -or $prop.name -eq "Id") { continue }
        $k2Type = Get-K2Type $prop.soType
        $extPropsXml += '<propertydata name="' + $prop.name + '" type="" extendtype="Default" sotype="' + $k2Type + '"><metadata><display><displayname>' + $prop.displayName + '</displayname><description /></display><service><key name="uniqueid"><object type="System.Boolean"><boolean>false</boolean></object></key><key name="autonumber"><object type="System.Boolean"><boolean>false</boolean></object></key></service></metadata></propertydata>'
    }

    # Build extending object methods
    $extMethodsXml = ""
    $extTypes_create = '<extendtype name="uniqueid" /><extendtype name="uniqueidauto" /><extendtype name="default" /><extendtype name="uniqueauto" />'
    $extTypes_id = '<extendtype name="uniqueid" /><extendtype name="uniqueidauto" />'
    $extTypes_all = '<extendtype name="uniqueid" /><extendtype name="uniqueidauto" /><extendtype name="default" /><extendtype name="uniqueauto" />'
    $extTypes_ret_id = '<extendtype name="uniqueidauto" /><extendtype name="uniqueauto" />'
    
    $extMethodsXml += '<methoddata name="Create" type="create" isdefined="true"><metadata><display><displayname>Create</displayname><description>This method creates a new entry</description></display><service /></metadata><validation><requiredproperties><properties /><extendtypes><extendtype name="uniqueid" /></extendtypes></requiredproperties></validation><parameters /><input><properties /><extendtypes>' + $extTypes_create + '</extendtypes></input><return><properties /><extendtypes>' + $extTypes_ret_id + '</extendtypes></return></methoddata>'
    $extMethodsXml += '<methoddata name="Save" type="update" isdefined="true"><metadata><display><displayname>Save</displayname><description>This method updates an entry, or if the entry does not exist creates it.</description></display><service /></metadata><validation><requiredproperties><properties /><extendtypes><extendtype name="uniqueid" /></extendtypes></requiredproperties></validation><parameters /><input><properties /><extendtypes>' + $extTypes_create + '</extendtypes></input><return><properties /><extendtypes>' + $extTypes_ret_id + '</extendtypes></return></methoddata>'
    $extMethodsXml += '<methoddata name="Delete" type="delete" isdefined="true"><metadata><display><displayname>Delete</displayname><description>This method deletes a single entry</description></display><service /></metadata><validation><requiredproperties><properties /><extendtypes>' + $extTypes_id + '</extendtypes></requiredproperties></validation><parameters /><input><properties /><extendtypes>' + $extTypes_id + '</extendtypes></input><return><properties /><extendtypes /></return></methoddata>'
    $extMethodsXml += '<methoddata name="Load" type="read" isdefined="true"><metadata><display><displayname>Load</displayname><description>This method loads a single entry</description></display><service /></metadata><validation><requiredproperties><properties /><extendtypes>' + $extTypes_id + '</extendtypes></requiredproperties></validation><parameters /><input><properties /><extendtypes>' + $extTypes_id + '</extendtypes></input><return><properties /><extendtypes>' + $extTypes_all + '</extendtypes></return></methoddata>'
    $extMethodsXml += '<methoddata name="GetList" type="list" isdefined="true"><metadata><display><displayname>Get List</displayname><description>This method gets a list of entries</description></display><service /></metadata><validation><requiredproperties><properties /><extendtypes /></requiredproperties></validation><parameters /><input><properties /><extendtypes>' + $extTypes_all + '</extendtypes></input><return><properties /><extendtypes>' + $extTypes_all + '</extendtypes></return></methoddata>'

    # Assemble the full SmartObject XML
    $fullXml = '<smartobjectroot name="' + $soName + '" guid="' + $soGuid + '" version="0" isextendible="true" mode="simple" createdfromlocal="false">'
    $fullXml += '<metadata><display><displayname>' + $soDisplayName + '</displayname><description>Migrated from SharePoint</description></display>'
    $fullXml += '<service><key name="serviceinstance">' + $smartBoxGuid + '</key><key name="serviceobject">' + $soName + '</key></service></metadata>'
    $fullXml += '<types><type name="user" /></types>'
    $fullXml += '<properties>' + $propsXml + '</properties>'
    $fullXml += '<methods>' + $methodsXml + '</methods>'
    $fullXml += '<defaults><methods><read name="Load" /><list name="GetList" /><report name="GetList" /></methods></defaults>'
    $fullXml += '<associations />'
    $fullXml += '<extendingobject><objectdata name="' + $soName + '" type="Default" serviceinstanceguid="' + $smartBoxGuid + '"><metadata><display><displayname>' + $soName + '</displayname><description /></display><service>' + $serviceMetaXml + '</service></metadata><properties>' + $extPropsXml + '</properties><methods>' + $extMethodsXml + '</methods></objectdata></extendingobject>'
    $fullXml += '</smartobjectroot>'

    # Check if SmartObject already exists and delete it before publishing (to handle redeploys)
    $existsAlready = $mgmt.CheckSmartObjectExists($soName)
    if ($existsAlready) {
        try {
            $mgmt.DeleteSmartObject($soName)
            Write-Host "[INFO] Deleted existing SmartObject '$soName' to allow republish"
        } catch {
            Write-Host "[WARN] Could not delete existing SmartObject '$soName': $($_.Exception.Message)"
        }
    }

    # Publish with category so it appears in K2 Management under Generated > Migration
    $category = "Generated\Migration"
    $publishResult = $mgmt.PublishSmartObject($fullXml, $category)

    # Verify
    $exists = $mgmt.CheckSmartObjectExists($soName)

    $mgmt.Connection.Close()

    if ($exists) {
        $result = @{
            "success" = $true
            "smartObjectName" = $soName
            "displayName" = $soDisplayName
            "exists" = $true
            "publishResult" = "$publishResult"
            "message" = "SmartObject created and verified on K2"
        }
    } else {
        $result = @{
            "success" = $false
            "smartObjectName" = $soName
            "exists" = $false
            "error" = "PublishSmartObject returned but SmartObject not found. publishResult: $publishResult"
        }
    }
    Write-Host ($result | ConvertTo-Json -Compress)

} catch {
    $errorMsg = $_.Exception.Message
    if ($_.Exception.InnerException) {
        $errorMsg += " | Inner: " + $_.Exception.InnerException.Message
    }
    $result = @{
        "success" = $false
        "error" = $errorMsg
        "smartObjectName" = $so.name
    }
    Write-Host ($result | ConvertTo-Json -Compress)
    exit 1
}
