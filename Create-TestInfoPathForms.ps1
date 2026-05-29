# Create-TestInfoPathForms.ps1
# Creates realistic InfoPath form libraries with XSN templates on SharePoint
# using REST API + makecab.exe (no InfoPath Designer needed).
# An XSN file is a CAB archive containing: manifest.xsf, template.xml, myschema.xsd

param(
    [string]$SiteUrl = ""
)

if ($SiteUrl -eq "") {
    $SiteUrl = Read-Host "Enter SharePoint site URL (e.g., https://sp/sites/Test)"
}

$SiteUrl = $SiteUrl.TrimEnd('/')

function Invoke-SPRest($Endpoint, $Method, $Body) {
    $url = $SiteUrl + "/_api/" + $Endpoint
    $hdrs = @{}
    $hdrs["Accept"] = "application/json;odata=verbose"
    if ($Method -eq $null) { $Method = "Get" }

    $params = @{
        Uri = $url
        Method = $Method
        UseDefaultCredentials = $true
        Headers = $hdrs
        ContentType = "application/json"
    }

    if ($Body) {
        $params["Body"] = ($Body | ConvertTo-Json -Depth 5)
    }

    $resp = Invoke-RestMethod @params
    return $resp.d
}

function Get-RequestDigest {
    $url = $SiteUrl + "/_api/contextinfo"
    $hdrs = @{}
    $hdrs["Accept"] = "application/json;odata=verbose"
    $resp = Invoke-RestMethod -Uri $url -Method Post -UseDefaultCredentials -Headers $hdrs -ContentType "application/json"
    return $resp.d.GetContextWebInformation.FormDigestValue
}

function Upload-FileToSP($LibraryTitle, $FileName, $FileBytes, $Digest) {
    # Use getbytitle to navigate directly to RootFolder/Files/add
    $url = $SiteUrl + "/_api/web/lists/getbytitle('" + $LibraryTitle + "')/RootFolder/Files/add(url='" + $FileName + "',overwrite=true)"
    Write-Host "    Uploading to: $url"
    $hdrs = @{}
    $hdrs["Accept"] = "application/json;odata=verbose"
    $hdrs["X-RequestDigest"] = $Digest

    Invoke-RestMethod -Uri $url -Method Post -UseDefaultCredentials -Headers $hdrs -ContentType "application/octet-stream" -Body $FileBytes
}

function Create-FormLibrary($Title, $Digest) {
    $url = $SiteUrl + "/_api/web/lists"
    $hdrs = @{}
    $hdrs["Accept"] = "application/json;odata=verbose"
    $hdrs["X-RequestDigest"] = $Digest

    $body = @{
        "__metadata" = @{ "type" = "SP.List" }
        "AllowContentTypes" = $true
        "BaseTemplate" = 115
        "ContentTypesEnabled" = $true
        "Description" = "InfoPath form library for migration testing"
        "Title" = $Title
    } | ConvertTo-Json -Depth 3

    try {
        Invoke-RestMethod -Uri $url -Method Post -UseDefaultCredentials -Headers $hdrs -ContentType "application/json;odata=verbose" -Body $body
        Write-Host "    Library created: $Title"
        return $true
    } catch {
        # Library likely already exists ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÂ¢Ã¢â€šÂ¬Ã‚Â verify it
        try {
            $check = Invoke-SPRest "web/lists/getbytitle('$Title')?`$select=Title"
            Write-Host "    Library already exists: $($check.Title)"
            return $true
        } catch {
            Write-Host "    Failed to create library: $($_.Exception.Message)" -ForegroundColor Red
            throw
        }
    }
}

function Build-XsnFile($FormName, $FormFields, $TempDir) {
    # Create temp directory for XSN contents
    $xsnDir = Join-Path $TempDir $FormName
    if (Test-Path $xsnDir) { Remove-Item $xsnDir -Recurse -Force }
    New-Item -ItemType Directory -Path $xsnDir -Force | Out-Null

    $ns = "urn:schemas-microsoft-com:office:infopath:${FormName}:-myXSD-$(Get-Date -Format 'yyyy-MM-dd')T00-00-00"

    # 1. Build template.xml (default data)
    $myXsdNs = "http://schemas.microsoft.com/office/infopath/2003/myXSD/" + (Get-Date).ToString('yyyy-MM-ddTHH-mm-ss')
    $templateXml = '<?xml version="1.0" encoding="UTF-8"?>' + "`r`n"
    $templateXml += '<?mso-infoPathSolution name="' + $ns + '" solutionVersion="1.0.0.1" productVersion="15.0.0" PIVersion="1.0.0.0"?>' + "`r`n"
    $templateXml += '<?mso-application progid="InfoPath.Document" versionProgid="InfoPath.Document.4"?>' + "`r`n"
    $templateXml += '<my:myFields xmlns:my="' + $myXsdNs + '">' + "`r`n"
    foreach ($f in $FormFields) {
        $templateXml += "  <my:$($f.Name)/>`r`n"
    }
    $templateXml += "</my:myFields>"
    [System.IO.File]::WriteAllText("$xsnDir\template.xml", $templateXml, [System.Text.UTF8Encoding]::new($false))

    # 2. Build myschema.xsd (schema definition)
    $xsd = '<?xml version="1.0" encoding="UTF-8"?>' + "`r`n"
    $xsd += '<xs:schema xmlns:xs="http://www.w3.org/2001/XMLSchema" xmlns:my="' + $myXsdNs + '" targetNamespace="' + $myXsdNs + '">' + "`r`n"
    $xsd += "  <xs:element name=`"myFields`">`r`n"
    $xsd += "    <xs:complexType>`r`n"
    $xsd += "      <xs:sequence>`r`n"
    foreach ($f in $FormFields) {
        $xsdType = "xs:string"
        if ($f.Type -eq "Date") { $xsdType = "xs:date" }
        if ($f.Type -eq "Number") { $xsdType = "xs:decimal" }
        if ($f.Type -eq "Boolean") { $xsdType = "xs:boolean" }
        $reqAttr = ""
        if ($f.Required) { $reqAttr = " minOccurs=`"1`"" }
        $xsd += "        <xs:element name=`"$($f.Name)`" type=`"$xsdType`"$reqAttr/>`r`n"
    }
    $xsd += "      </xs:sequence>`r`n"
    $xsd += "    </xs:complexType>`r`n"
    $xsd += "  </xs:element>`r`n"
    $xsd += "</xs:schema>"
    [System.IO.File]::WriteAllText("$xsnDir\myschema.xsd", $xsd, [System.Text.UTF8Encoding]::new($false))

    # 3. Build manifest.xsf (form definition with rules, views, data connections)
    $xsf = "<?xml version=`"1.0`" encoding=`"UTF-8`"?>`r`n"
    $xsf += "<xsf:xDocumentClass xmlns:xsf=`"http://schemas.microsoft.com/office/infopath/2003/solutionDefinition`" xmlns:xsf2=`"http://schemas.microsoft.com/office/infopath/2006/solutionDefinition/extensions`" name=`"$ns`" solutionVersion=`"1.0.0.1`" productVersion=`"15.0.0.0`" solutionFormatVersion=`"3.0.0.0`">`r`n"

    # File list
    $xsf += "  <xsf:package>`r`n"
    $xsf += "    <xsf:files>`r`n"
    $xsf += "      <xsf:file name=`"template.xml`"/>`r`n"
    $xsf += "      <xsf:file name=`"myschema.xsd`"/>`r`n"
    $xsf += "      <xsf:file name=`"view1.xsl`"/>`r`n"
    $xsf += "    </xsf:files>`r`n"
    $xsf += "  </xsf:package>`r`n"

    # Rules
    $xsf += "  <xsf2:solutionDefinition>`r`n"
    $xsf += "    <xsf2:ruleSetAction>`r`n"
    # Add sample rules
    $xsf += "      <xsf2:rule name=`"Validate Required Fields`" caption=`"Check required fields`">`r`n"
    $xsf += "        <xsf2:condition>`r`n"
    $xsf += "          <xsf2:and>`r`n"
    foreach ($f in $FormFields) {
        if ($f.Required) {
            $xsf += "            <xsf2:condition expression=`"my:$($f.Name) = &quot;&quot;`"/>`r`n"
        }
    }
    $xsf += "          </xsf2:and>`r`n"
    $xsf += "        </xsf2:condition>`r`n"
    $xsf += "        <xsf2:action name=`"setField`"/>`r`n"
    $xsf += "      </xsf2:rule>`r`n"
    $xsf += "      <xsf2:rule name=`"Auto Calculate`" caption=`"Calculate derived fields`">`r`n"
    $xsf += "        <xsf2:condition expression=`"true()`"/>`r`n"
    $xsf += "        <xsf2:action name=`"setField`"/>`r`n"
    $xsf += "      </xsf2:rule>`r`n"
    $xsf += "    </xsf2:ruleSetAction>`r`n"

    # Validation rules
    $xsf += "    <xsf2:validationRules>`r`n"
    foreach ($f in $FormFields) {
        if ($f.Required) {
            $xsf += "      <xsf2:errorCondition expression=`"my:$($f.Name) = &quot;&quot;`" match=`"/my:myFields/my:$($f.Name)`">`r`n"
            $xsf += "        <xsf2:errorMessage type=`"modeless`">$($f.Name) is required</xsf2:errorMessage>`r`n"
            $xsf += "      </xsf2:errorCondition>`r`n"
        }
    }
    $xsf += "    </xsf2:validationRules>`r`n"

    # Data connections
    $xsf += "    <xsf2:dataObjects>`r`n"
    $xsf += "      <xsf2:dataObject name=`"LookupData`" initOnLoad=`"yes`">`r`n"
    $xsf += "        <xsf2:sharepointListAdapter name=`"EmployeeLookup`" siteUrl=`"$SiteUrl`" listId=`"{00000000-0000-0000-0000-000000000000}`"/>`r`n"
    $xsf += "      </xsf2:dataObject>`r`n"
    $xsf += "    </xsf2:dataObjects>`r`n"

    $xsf += "  </xsf2:solutionDefinition>`r`n"

    # Views
    $xsf += "  <xsf:views default=`"Main View`">`r`n"
    $xsf += "    <xsf:view name=`"Main View`" caption=`"Main View`">`r`n"
    $xsf += "      <xsf:mainpane transform=`"view1.xsl`"/>`r`n"
    $xsf += "    </xsf:view>`r`n"
    $xsf += "    <xsf:view name=`"Approval View`" caption=`"Approval View`">`r`n"
    $xsf += "      <xsf:mainpane transform=`"view1.xsl`"/>`r`n"
    $xsf += "    </xsf:view>`r`n"
    $xsf += "  </xsf:views>`r`n"

    $xsf += "</xsf:xDocumentClass>"
    [System.IO.File]::WriteAllText("$xsnDir\manifest.xsf", $xsf, [System.Text.UTF8Encoding]::new($false))

    # 4. Build a minimal view XSL
    $xsl = '<?xml version="1.0" encoding="UTF-8"?>' + "`r`n"
    $xsl += '<xsl:stylesheet version="1.0" xmlns:xsl="http://www.w3.org/1999/XSL/Transform" xmlns:my="' + $myXsdNs + '">' + "`r`n"
    $xsl += "  <xsl:template match=`"/`">`r`n"
    $xsl += "    <html><body>`r`n"
    $xsl += "      <h1>$FormName</h1>`r`n"
    $xsl += "      <table border=`"1`">`r`n"
    foreach ($f in $FormFields) {
        $xsl += "        <tr><td><b>$($f.Name)</b></td><td><xsl:value-of select=`"my:myFields/my:$($f.Name)`"/></td></tr>`r`n"
    }
    $xsl += "      </table>`r`n"
    $xsl += "    </body></html>`r`n"
    $xsl += "  </xsl:template>`r`n"
    $xsl += "</xsl:stylesheet>"
    [System.IO.File]::WriteAllText("$xsnDir\view1.xsl", $xsl, [System.Text.UTF8Encoding]::new($false))

    # 5. Package as CAB/XSN using makecab.exe
    $xsnPath = Join-Path $TempDir "$FormName.xsn"
    $ddfLines = @()
    $ddfLines += ".OPTION EXPLICIT"
    $ddfLines += ".Set CabinetNameTemplate=${FormName}.xsn"
    $ddfLines += ".Set DiskDirectoryTemplate=$TempDir"
    $ddfLines += ".Set CompressionType=MSZIP"
    $ddfLines += ".Set Cabinet=on"
    $ddfLines += ".Set Compress=on"
    $ddfLines += ".Set MaxDiskSize=0"
    $ddfLines += "$xsnDir\manifest.xsf"
    $ddfLines += "$xsnDir\template.xml"
    $ddfLines += "$xsnDir\myschema.xsd"
    $ddfLines += "$xsnDir\view1.xsl"
    $ddfContent = $ddfLines -join "`r`n"
    $ddfPath = Join-Path $TempDir "$FormName.ddf"
    [System.IO.File]::WriteAllText($ddfPath, $ddfContent, [System.Text.UTF8Encoding]::new($false))

    Push-Location $TempDir
    $makecabOut = & makecab.exe /F $ddfPath 2>&1
    Pop-Location

    # makecab creates the file in a disk1 subfolder
    $cabSource = Join-Path $TempDir "disk1\${FormName}.xsn"
    if (-not (Test-Path $cabSource)) {
        # Try current directory
        $cabSource = Join-Path $TempDir "${FormName}.xsn"
    }

    # Copy to final output path (avoid self-copy)
    $finalPath = Join-Path $TempDir "output_${FormName}.xsn"
    if (Test-Path $cabSource) {
        Copy-Item $cabSource $finalPath -Force
        return $finalPath
    } else {
        Write-Host "    makecab output: $makecabOut" -ForegroundColor Yellow
        return $null
    }
}

# ============================================================
# MAIN
# ============================================================

Write-Host ""
Write-Host "  ===================================================="
Write-Host "  InfoPath Test Form Creator (no Designer needed)"
Write-Host "  ===================================================="
Write-Host "  Target: $SiteUrl"
Write-Host ""

$digest = Get-RequestDigest
$tempDir = Join-Path $env:TEMP "InfoPathTestForms"
if (Test-Path $tempDir) { Remove-Item $tempDir -Recurse -Force }
New-Item -ItemType Directory -Path $tempDir -Force | Out-Null

# ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã‚ÂÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã‚ÂÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ Form 1: Leave Request ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã‚ÂÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã‚ÂÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã‚ÂÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã‚ÂÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã‚ÂÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã‚ÂÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã‚ÂÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã‚ÂÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã‚ÂÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã‚ÂÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã‚ÂÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã‚ÂÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã‚ÂÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã‚ÂÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã‚ÂÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã‚ÂÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã‚ÂÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã‚ÂÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã‚ÂÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã‚ÂÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã‚ÂÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã‚ÂÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã‚ÂÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã‚ÂÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã‚ÂÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã‚ÂÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã‚ÂÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã‚ÂÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã‚ÂÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã‚ÂÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬
Write-Host "  [1/3] Creating Leave Request form..."

$leaveFields = @(
    @{ Name = "EmployeeName"; Type = "Text"; Required = $true },
    @{ Name = "EmployeeId"; Type = "Text"; Required = $true },
    @{ Name = "Department"; Type = "Text"; Required = $true },
    @{ Name = "LeaveType"; Type = "Text"; Required = $true },
    @{ Name = "StartDate"; Type = "Date"; Required = $true },
    @{ Name = "EndDate"; Type = "Date"; Required = $true },
    @{ Name = "TotalDays"; Type = "Number"; Required = $false },
    @{ Name = "Reason"; Type = "Text"; Required = $false },
    @{ Name = "ManagerApproval"; Type = "Text"; Required = $false },
    @{ Name = "ManagerComments"; Type = "Text"; Required = $false }
)

try {
    Create-FormLibrary -Title "Leave Requests" -Digest $digest | Out-Null
    $formTempDir = Join-Path $tempDir "form1"
    New-Item -ItemType Directory -Path $formTempDir -Force | Out-Null
    $xsnPath = Build-XsnFile -FormName "LeaveRequest" -FormFields $leaveFields -TempDir $formTempDir
    if ($xsnPath) {
        $bytes = [System.IO.File]::ReadAllBytes($xsnPath)
        Upload-FileToSP -LibraryTitle "Leave Requests" -FileName "template.xsn" -FileBytes $bytes -Digest $digest
        Write-Host "  Done: Leave Requests (10 fields, 2 views, 2 rules)" -ForegroundColor Green
    }
} catch {
    Write-Host "  Error: $($_.Exception.Message)" -ForegroundColor Red
}

# ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã‚ÂÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã‚ÂÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ Form 2: Purchase Order ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã‚ÂÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã‚ÂÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã‚ÂÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã‚ÂÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã‚ÂÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã‚ÂÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã‚ÂÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã‚ÂÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã‚ÂÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã‚ÂÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã‚ÂÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã‚ÂÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã‚ÂÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã‚ÂÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã‚ÂÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã‚ÂÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã‚ÂÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã‚ÂÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã‚ÂÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã‚ÂÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã‚ÂÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã‚ÂÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã‚ÂÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã‚ÂÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã‚ÂÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã‚ÂÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã‚ÂÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã‚ÂÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã‚ÂÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã‚ÂÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬
Write-Host "  [2/3] Creating Purchase Order form..."

$poFields = @(
    @{ Name = "RequestorName"; Type = "Text"; Required = $true },
    @{ Name = "RequestDate"; Type = "Date"; Required = $true },
    @{ Name = "VendorName"; Type = "Text"; Required = $true },
    @{ Name = "VendorEmail"; Type = "Text"; Required = $false },
    @{ Name = "ItemDescription"; Type = "Text"; Required = $true },
    @{ Name = "Quantity"; Type = "Number"; Required = $true },
    @{ Name = "UnitPrice"; Type = "Number"; Required = $true },
    @{ Name = "TotalAmount"; Type = "Number"; Required = $false },
    @{ Name = "CostCenter"; Type = "Text"; Required = $true },
    @{ Name = "Priority"; Type = "Text"; Required = $false },
    @{ Name = "Justification"; Type = "Text"; Required = $false },
    @{ Name = "ApprovalStatus"; Type = "Text"; Required = $false }
)

# Refresh digest
$digest = Get-RequestDigest

try {
    Create-FormLibrary -Title "Purchase Orders" -Digest $digest | Out-Null
    $formTempDir = Join-Path $tempDir "form2"
    New-Item -ItemType Directory -Path $formTempDir -Force | Out-Null
    $xsnPath = Build-XsnFile -FormName "PurchaseOrder" -FormFields $poFields -TempDir $formTempDir
    if ($xsnPath) {
        $bytes = [System.IO.File]::ReadAllBytes($xsnPath)
        Upload-FileToSP -LibraryTitle "Purchase Orders" -FileName "template.xsn" -FileBytes $bytes -Digest $digest
        Write-Host "  Done: Purchase Orders (12 fields, 2 views, 2 rules)" -ForegroundColor Green
    }
} catch {
    Write-Host "  Error: $($_.Exception.Message)" -ForegroundColor Red
}

# ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã‚ÂÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã‚ÂÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ Form 3: Expense Report ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã‚ÂÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã‚ÂÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã‚ÂÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã‚ÂÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã‚ÂÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã‚ÂÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã‚ÂÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã‚ÂÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã‚ÂÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã‚ÂÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã‚ÂÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã‚ÂÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã‚ÂÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã‚ÂÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã‚ÂÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã‚ÂÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã‚ÂÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã‚ÂÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã‚ÂÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã‚ÂÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã‚ÂÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã‚ÂÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã‚ÂÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã‚ÂÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã‚ÂÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã‚ÂÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã‚ÂÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã‚ÂÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã‚ÂÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã‚ÂÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬
Write-Host "  [3/3] Creating Expense Report form..."

$expFields = @(
    @{ Name = "SubmitterName"; Type = "Text"; Required = $true },
    @{ Name = "SubmitDate"; Type = "Date"; Required = $true },
    @{ Name = "ExpenseCategory"; Type = "Text"; Required = $true },
    @{ Name = "Description"; Type = "Text"; Required = $true },
    @{ Name = "Amount"; Type = "Number"; Required = $true },
    @{ Name = "Currency"; Type = "Text"; Required = $false },
    @{ Name = "ReceiptAttached"; Type = "Boolean"; Required = $false },
    @{ Name = "ProjectCode"; Type = "Text"; Required = $false },
    @{ Name = "ApproverName"; Type = "Text"; Required = $false },
    @{ Name = "ApprovalDate"; Type = "Date"; Required = $false },
    @{ Name = "Status"; Type = "Text"; Required = $false },
    @{ Name = "ReimbursementMethod"; Type = "Text"; Required = $false },
    @{ Name = "Notes"; Type = "Text"; Required = $false }
)

# Refresh digest
$digest = Get-RequestDigest

try {
    Create-FormLibrary -Title "Expense Reports" -Digest $digest | Out-Null
    $formTempDir = Join-Path $tempDir "form3"
    New-Item -ItemType Directory -Path $formTempDir -Force | Out-Null
    $xsnPath = Build-XsnFile -FormName "ExpenseReport" -FormFields $expFields -TempDir $formTempDir
    if ($xsnPath) {
        $bytes = [System.IO.File]::ReadAllBytes($xsnPath)
        Upload-FileToSP -LibraryTitle "Expense Reports" -FileName "template.xsn" -FileBytes $bytes -Digest $digest
        Write-Host "  Done: Expense Reports (13 fields, 2 views, 2 rules)" -ForegroundColor Green
    }
} catch {
    Write-Host "  Error: $($_.Exception.Message)" -ForegroundColor Red
}

# Cleanup
Remove-Item $tempDir -Recurse -Force -ErrorAction SilentlyContinue

Write-Host ""
Write-Host "  ===================================================="
Write-Host "  COMPLETE" -ForegroundColor Green
Write-Host "  ===================================================="
Write-Host "  Created 3 Form Libraries with XSN templates:"
Write-Host "    1. Leave Requests     (10 fields)"
Write-Host "    2. Purchase Orders    (12 fields)"
Write-Host "    3. Expense Reports    (13 fields)"
Write-Host "  Each has: manifest.xsf, template.xml, myschema.xsd, view1.xsl"
Write-Host "  ===================================================="
Write-Host ""
Write-Host "  Now run discovery:"
Write-Host "    .\Export-SPDiscovery.ps1 -SiteUrl `"$SiteUrl`""
Write-Host "    .\Export-SPListSchema.ps1 -SiteUrl `"$SiteUrl`""
Write-Host ""
