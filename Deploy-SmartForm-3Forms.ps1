# Deploy-SmartForm-3Forms.ps1
# Generates 3 forms (New, Edit, Display) following the K2 Application pattern.
# Dot-sourced from Deploy-SmartForm.ps1 — expects all variables to be in scope.
#
# KEY FINDINGS (from debugging GUID parse errors):
# - View events must NOT include ObjectID or Parameters in Action properties
# - K2 binds SO methods via DataSource established at deploy time
# - Events only need: Location, Method, ViewID
# - ObjectID with DisplayValue/NameValue causes Guid.Parse() failure at runtime
# - IsGenerated="True" and RenderVersion="3" should NOT be used

# DataSource XML (tells K2 which SmartObject to bind — processed at deploy, stripped from stored XML)
$dataFieldMappingsXml = ''
foreach ($prop in $formProperties) {
    $dataFieldMappingsXml += '<Mapping FieldName="' + $prop.name + '" ControlName="txt' + $prop.name + '" Direction="Both" />'
}
$dsXml = '<DataSource Type="SmartObject"><SmartObject Name="' + $smartObjectName + '" />'
$dsXml += '<Methods><Method Name="' + $loadMethod + '" Type="Read" />'
$dsXml += '<Method Name="' + $createMethod + '" Type="Create" />'
$dsXml += '<Method Name="' + $updateMethod + '" Type="Update" />'
$dsXml += '<Method Name="' + $deleteMethod + '" Type="Delete" /></Methods>'
$dsXml += '<PropertyMappings>' + $dataFieldMappingsXml + '</PropertyMappings></DataSource>'

# Define 3 form types
$viewTypes = @(
    @{ Prefix='New';     HasInit=$false; SaveMethod=$createMethod }
    @{ Prefix='Edit';    HasInit=$true;  SaveMethod=$updateMethod }
    @{ Prefix='Display'; HasInit=$true;  SaveMethod=$null }
)
$allViewXmls = @{}; $allViewGuids = @{}; $allViewNames = @{}
$allFormXmls = @{}; $allFormGuids = @{}; $allFormNames = @{}

foreach ($vt in $viewTypes) {
    $pf = $vt.Prefix
    $vId = [guid]::NewGuid().ToString(); $vNm = "$soDisplayName $pf View"
    $fId = [guid]::NewGuid().ToString(); $fNm = "$soDisplayName $pf Form"
    $allViewGuids[$pf]=$vId; $allViewNames[$pf]=$vNm
    $allFormGuids[$pf]=$fId; $allFormNames[$pf]=$fNm

    # Build controls
    $vc=''; $vr=''; $ri=0
    foreach ($prop in $formProperties) {
        # Decode SP _x0020_ encoded display names
        $dn = $prop.displayName
        if (-not $dn -or $dn -eq $prop.name) {
            $dn = $prop.name -replace '_x([0-9a-fA-F]{4})_', { [char][int]('0x' + $_.Groups[1].Value) }
        }
        $cId=[guid]::NewGuid().ToString(); $lId=[guid]::NewGuid().ToString()
        $c1=[guid]::NewGuid().ToString(); $c2=[guid]::NewGuid().ToString()
        $rId=[guid]::NewGuid().ToString()

        $vc += '<Control ID="'+$lId+'" Type="Label"><Name>lbl'+$prop.name+'</Name>'
        $vc += '<DisplayName>'+$dn+'</DisplayName><Properties>'
        $vc += '<Property><Name>ControlName</Name><Value>lbl'+$prop.name+'</Value></Property>'
        $vc += '<Property><Name>Text</Name><Value>'+$dn+'</Value></Property>'
        $vc += '<Property><Name>LiteralVal</Name><Value>true</Value></Property></Properties></Control>'

        $vc += '<Control ID="'+$cId+'" Type="TextBox"><Name>txt'+$prop.name+'</Name>'
        $vc += '<DisplayName>'+$dn+'</DisplayName><Properties>'
        $vc += '<Property><Name>ControlName</Name><Value>txt'+$prop.name+'</Value></Property>'
        $vc += '<Property><Name>Width</Name><Value>100%</Value></Property></Properties></Control>'

        $vc += '<Control ID="'+$c1+'" Type="Cell"><Name>CL'+$ri+'</Name><Properties>'
        $vc += '<Property><Name>ControlName</Name><Value>CL'+$ri+'</Value></Property></Properties></Control>'
        $vc += '<Control ID="'+$c2+'" Type="Cell"><Name>CR'+$ri+'</Name><Properties>'
        $vc += '<Property><Name>ControlName</Name><Value>CR'+$ri+'</Value></Property></Properties></Control>'
        $vc += '<Control ID="'+$rId+'" Type="Row"><Name>R'+$ri+'</Name><Properties>'
        $vc += '<Property><Name>ControlName</Name><Value>R'+$ri+'</Value></Property></Properties></Control>'

        $vr += '<Row ID="'+$rId+'"><Cells>'
        $vr += '<Cell ID="'+$c1+'"><Control ID="'+$lId+'" /></Cell>'
        $vr += '<Cell ID="'+$c2+'"><Control ID="'+$cId+'" /></Cell></Cells></Row>'
        $ri++
    }

    # Save/Cancel buttons (New and Edit only)
    $btnId=[guid]::NewGuid().ToString()
    if ($vt.SaveMethod) {
        $bcId=[guid]::NewGuid().ToString()
        $bcs=[guid]::NewGuid().ToString(); $bcc=[guid]::NewGuid().ToString()
        $bsp=[guid]::NewGuid().ToString(); $brw=[guid]::NewGuid().ToString()
        $vc += '<Control ID="'+$btnId+'" Type="Button"><Name>btnSave</Name><DisplayName>Save</DisplayName>'
        $vc += '<Properties><Property><Name>ControlName</Name><Value>btnSave</Value></Property>'
        $vc += '<Property><Name>Text</Name><Value>Save</Value></Property></Properties></Control>'
        $vc += '<Control ID="'+$bcId+'" Type="Button"><Name>btnCancel</Name><DisplayName>Cancel</DisplayName>'
        $vc += '<Properties><Property><Name>ControlName</Name><Value>btnCancel</Value></Property>'
        $vc += '<Property><Name>Text</Name><Value>Cancel</Value></Property></Properties></Control>'
        $vc += '<Control ID="'+$bcs+'" Type="Cell"><Name>CBS</Name><Properties>'
        $vc += '<Property><Name>ControlName</Name><Value>CBS</Value></Property></Properties></Control>'
        $vc += '<Control ID="'+$bcc+'" Type="Cell"><Name>CBC</Name><Properties>'
        $vc += '<Property><Name>ControlName</Name><Value>CBC</Value></Property></Properties></Control>'
        $vc += '<Control ID="'+$bsp+'" Type="Cell"><Name>CSP</Name><Properties>'
        $vc += '<Property><Name>ControlName</Name><Value>CSP</Value></Property></Properties></Control>'
        $vc += '<Control ID="'+$brw+'" Type="Row"><Name>BR</Name><Properties>'
        $vc += '<Property><Name>ControlName</Name><Value>BR</Value></Property></Properties></Control>'
        $vr += '<Row ID="'+$brw+'"><Cells><Cell ID="'+$bsp+'" />'
        $vr += '<Cell ID="'+$bcs+'"><Control ID="'+$btnId+'" /></Cell>'
        $vr += '<Cell ID="'+$bcc+'"><Control ID="'+$bcId+'" /></Cell></Cells></Row>'
    }

    # Layout controls
    $tbl=[guid]::NewGuid().ToString(); $sec=[guid]::NewGuid().ToString()
    $lcl=[guid]::NewGuid().ToString(); $icl=[guid]::NewGuid().ToString()
    $vc += '<Control ID="'+$tbl+'" Type="Table"><Name>MT</Name><Properties>'
    $vc += '<Property><Name>ControlName</Name><Value>MT</Value></Property></Properties></Control>'
    $vc += '<Control ID="'+$sec+'" Type="Section"><Name>MS</Name><Properties>'
    $vc += '<Property><Name>Type</Name><Value>Body</Value></Property>'
    $vc += '<Property><Name>ControlName</Name><Value>MS</Value></Property></Properties></Control>'
    $vc += '<Control ID="'+$lcl+'" Type="Column"><Name>LC</Name><Properties>'
    $vc += '<Property><Name>ControlName</Name><Value>LC</Value></Property>'
    $vc += '<Property><Name>Size</Name><Value>30%</Value></Property></Properties></Control>'
    $vc += '<Control ID="'+$icl+'" Type="Column"><Name>IC</Name><Properties>'
    $vc += '<Property><Name>ControlName</Name><Value>IC</Value></Property>'
    $vc += '<Property><Name>Size</Name><Value>70%</Value></Property></Properties></Control>'
    $vc += '<Control ID="'+$vId+'" Type="View"><Name>'+$vNm+'</Name><Properties>'
    $vc += '<Property><Name>ControlName</Name><Value>'+$vNm+'</Value></Property></Properties></Control>'

    # ── View Events ──
    # CRITICAL: Do NOT include ObjectID or Parameters in event actions.
    # K2 binds SmartObject methods via DataSource at deploy time.
    # Events only need: Location, Method, ViewID.
    $ve = '<Events>'

    # Init event (Edit/Display: calls GetListItem on load)
    if ($vt.HasInit) {
        $g1=[guid]::NewGuid().ToString();$g2=[guid]::NewGuid().ToString()
        $g3=[guid]::NewGuid().ToString();$g4=[guid]::NewGuid().ToString()
        $g5=[guid]::NewGuid().ToString();$g6=[guid]::NewGuid().ToString()
        $ve += '<Event ID="'+$g1+'" DefinitionID="'+$g2+'" Type="User"'
        $ve += ' SourceID="'+$vId+'" SourceType="View"'
        $ve += ' SourceName="'+$vNm+'" SourceDisplayName="'+$vNm+'">'
        $ve += '<Name>Init</Name><Properties>'
        $ve += '<Property><Name>RuleFriendlyName</Name>'
        $ve += '<Value>When the View executed Initialize</Value></Property>'
        $ve += '<Property><Name>Location</Name><Value>'+$vNm+'</Value></Property></Properties>'
        $ve += '<Handlers><Handler ID="'+$g3+'" DefinitionID="'+$g4+'">'
        $ve += '<Properties><Property><Name>HandlerName</Name><Value>IfLogicalHandler</Value></Property>'
        $ve += '<Property><Name>Location</Name><Value>view</Value></Property></Properties>'
        $ve += '<Actions><Action ID="'+$g5+'" DefinitionID="'+$g6+'"'
        $ve += ' Type="Execute" ExecutionType="Synchronous"><Properties>'
        $ve += '<Property><Name>Location</Name><Value>View</Value></Property>'
        $ve += '<Property><Name>Method</Name><Value>'+$loadMethod+'</Value></Property>'
        $ve += '<Property><Name>ViewID</Name><Value>'+$vId+'</Value></Property>'
        $ve += '</Properties></Action></Actions></Handler></Handlers></Event>'
    }

    # Save event (New: CreateListItem, Edit: UpdateListItem)
    if ($vt.SaveMethod) {
        $s1=[guid]::NewGuid().ToString();$s2=[guid]::NewGuid().ToString()
        $s3=[guid]::NewGuid().ToString();$s4=[guid]::NewGuid().ToString()
        $s5=[guid]::NewGuid().ToString();$s6=[guid]::NewGuid().ToString()
        $ve += '<Event ID="'+$s1+'" DefinitionID="'+$s2+'" Type="User"'
        $ve += ' SourceID="'+$btnId+'" SourceType="Control"'
        $ve += ' SourceName="btnSave" SourceDisplayName="Save">'
        $ve += '<Name>OnClick</Name><Properties>'
        $ve += '<Property><Name>RuleFriendlyName</Name><Value>When Save is Clicked</Value></Property>'
        $ve += '<Property><Name>Location</Name><Value>'+$vNm+'</Value></Property></Properties>'
        $ve += '<Handlers><Handler ID="'+$s3+'" DefinitionID="'+$s4+'">'
        $ve += '<Properties><Property><Name>HandlerName</Name><Value>IfLogicalHandler</Value></Property>'
        $ve += '<Property><Name>Location</Name><Value>view</Value></Property></Properties>'
        $ve += '<Actions><Action ID="'+$s5+'" DefinitionID="'+$s6+'"'
        $ve += ' Type="Execute" ExecutionType="Synchronous"><Properties>'
        $ve += '<Property><Name>Location</Name><Value>View</Value></Property>'
        $ve += '<Property><Name>Method</Name><Value>'+$vt.SaveMethod+'</Value></Property>'
        $ve += '<Property><Name>ViewID</Name><Value>'+$vId+'</Value></Property>'
        $ve += '</Properties></Action></Actions></Handler></Handlers></Event>'
    }
    $ve += '</Events>'

    # ── Assemble View XML ──
    $vX = '<SourceCode.Forms><Views>'
    $vX += '<View ID="'+$vId+'" Type="Capture">'
    $vX += '<Name>'+$vNm+'</Name><DisplayName>'+$vNm+'</DisplayName>'
    $vX += $dsXml
    $vX += '<Controls>'+$vc+'</Controls>'
    $vX += '<Canvas><Sections><Section ID="'+$sec+'" Type="Body">'
    $vX += '<Control ID="'+$tbl+'" LayoutType="Grid">'
    $vX += '<Columns><Column ID="'+$lcl+'" Size="30%" />'
    $vX += '<Column ID="'+$icl+'" Size="70%" /></Columns>'
    $vX += '<Rows>'+$vr+'</Rows>'
    $vX += '</Control></Section></Sections></Canvas>'
    $vX += $ve
    $vX += '</View></Views></SourceCode.Forms>'
    $allViewXmls[$pf] = $vX

    # ── Assemble Form XML ──
    $fp=[guid]::NewGuid().ToString(); $fa=[guid]::NewGuid().ToString()
    $fai=[guid]::NewGuid().ToString(); $fs=[guid]::NewGuid().ToString()
    $fe1=[guid]::NewGuid().ToString(); $fe2=[guid]::NewGuid().ToString()
    $fh1=[guid]::NewGuid().ToString(); $fh2=[guid]::NewGuid().ToString()
    $fa1=[guid]::NewGuid().ToString(); $fa2=[guid]::NewGuid().ToString()

    $fx = '<SourceCode.Forms><Forms>'
    $fx += '<Form ID="'+$fId+'" Type="Normal" Layout="Normal" Theme="Platinum2">'
    $fx += '<Name>'+$fNm+'</Name><DisplayName>'+$soDisplayName+'</DisplayName><Controls>'
    $fx += '<Control ID="'+$fId+'" Type="Form"><Name>'+$soName+'_'+$pf+'_Root</Name>'
    $fx += '<DisplayName>'+$soDisplayName+'</DisplayName><Properties>'
    $fx += '<Property><Name>ControlName</Name><Value>'+$soName+'_'+$pf+'_Root</Value></Property>'
    $fx += '<Property><Name>IsVisible</Name><Value>true</Value></Property></Properties></Control>'
    $fx += '<Control ID="'+$fp+'" Type="Panel"><Name>'+$soDisplayName+'</Name>'
    $fx += '<Properties><Property><Name>ControlName</Name><Value>'+$soDisplayName+'</Value></Property></Properties></Control>'
    $fx += '<Control ID="'+$fa+'" Type="Area"><Name>'+$fNm+' Area</Name>'
    $fx += '<Properties><Property><Name>ControlName</Name><Value>'+$fNm+' Area</Value></Property></Properties></Control>'
    $fx += '<Control ID="'+$fai+'" Type="AreaItem"><Name>VA</Name>'
    $fx += '<Properties><Property><Name>ControlName</Name><Value>VA</Value></Property></Properties></Control>'
    $fx += '</Controls>'
    $fx += '<Panels><Panel ID="'+$fp+'" Layout="Rows"><Name>'+$soDisplayName+'</Name>'
    $fx += '<Areas><Area ID="'+$fa+'"><Items>'
    $fx += '<Item ID="'+$fai+'" ViewID="'+$vId+'"><Name>'+$vNm+'</Name></Item>'
    $fx += '</Items></Area></Areas></Panel></Panels>'
    $fx += '<States><State ID="'+$fs+'" IsBase="True"><Events>'
    $fx += '<Event ID="'+$fe1+'" DefinitionID="'+$fe2+'" Type="User"'
    $fx += ' SourceID="'+$fId+'" SourceType="Form"'
    $fx += ' SourceName="'+$fNm+'" SourceDisplayName="'+$soDisplayName+'">'
    $fx += '<Name>Init</Name><Properties>'
    $fx += '<Property><Name>Location</Name><Value>'+$fNm+'</Value></Property>'
    $fx += '<Property><Name>RuleFriendlyName</Name>'
    $fx += '<Value>When the Form is Initializing</Value></Property></Properties>'
    $fx += '<Handlers><Handler ID="'+$fh1+'" DefinitionID="'+$fh2+'">'
    $fx += '<Actions><Action ID="'+$fa1+'" DefinitionID="'+$fa2+'"'
    $fx += ' Type="Execute" ExecutionType="Synchronous" InstanceID="'+$fai+'">'
    $fx += '<Properties>'
    $fx += '<Property><Name>Method</Name><DisplayValue>Initialize</DisplayValue>'
    $fx += '<NameValue>Init</NameValue><Value>Init</Value></Property>'
    $fx += '<Property><Name>ViewID</Name>'
    $fx += '<DisplayValue>'+$vNm+'</DisplayValue>'
    $fx += '<NameValue>'+$vNm+'</NameValue>'
    $fx += '<Value>'+$vId+'</Value></Property>'
    $fx += '</Properties></Action></Actions></Handler></Handlers></Event>'
    $fx += '</Events></State></States>'
    $fx += '</Form></Forms></SourceCode.Forms>'
    $allFormXmls[$pf] = $fx
}

# Set backward-compatible names for deploy section
$viewName = $allViewNames['Edit']
$formName = $allFormNames['Edit']
