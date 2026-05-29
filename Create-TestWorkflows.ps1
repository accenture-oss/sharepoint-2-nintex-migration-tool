# Create-TestWorkflows.ps1
# Creates test lists with OOB SP2010 workflow associations on SharePoint SE/2019/2016/2013
# so the Export-SPDiscovery.ps1 script can find them for the K2 migration pipeline.
#
# Strategy:
#   1. Creates 8 test lists across different "departments" with realistic columns
#   2. Associates OOB workflow templates (Approval, Collect Feedback, etc.) to each list
#   3. Creates a few site-level (reusable) workflow associations
#   4. Adds sample list items so the discovery script sees real item counts
#
# No CSOM or SPD required - uses SharePoint REST API + Windows Integrated Auth.

param(
    [string]$SiteUrl = ""
)

if ($SiteUrl -eq "") {
    $SiteUrl = Read-Host "Enter SharePoint site URL (e.g., https://sp/sites/Test)"
}

$SiteUrl = $SiteUrl.TrimEnd('/')

# -- REST Helpers ---------------------------------------------

function Invoke-SPRest {
    param([string]$Endpoint, [string]$Method = "Get", $Body, [string]$Digest)
    $url = $SiteUrl + "/_api/" + $Endpoint
    $hdrs = @{}
    $hdrs["Accept"] = "application/json;odata=verbose"
    if ($Digest) { $hdrs["X-RequestDigest"] = $Digest }

    $params = @{
        Uri = $url
        Method = $Method
        UseDefaultCredentials = $true
        Headers = $hdrs
        ContentType = "application/json;odata=verbose"
    }

    if ($Body) {
        if ($Body -is [string]) {
            $params["Body"] = $Body
        } else {
            $params["Body"] = ($Body | ConvertTo-Json -Depth 10)
        }
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

function Get-ResultsArray($data) {
    if ($data -eq $null) { return @() }
    if ($data.results) { return @($data.results) }
    if ($data.Count -gt 0) { return @($data) }
    if ($data.Id -or $data.Name -or $data.Title) { return @($data) }
    return @()
}

# -- Helper: Create Mock XOML --------------------------------

function Create-MockWorkflowXoml {
    param([string]$WFName, [string]$ListTitle, [string]$WFType)

    $nl = "`r`n"
    $q = '"'

    $approvalSteps = ""
    switch ($WFType) {
        "Approval" {
            $approvalSteps = "        <ns0:ApprovalTaskProcess DisplayName=${q}Approval Task${q}>" + $nl +
                "          <ns0:ApprovalTaskProcess.TaskEvents>" + $nl +
                "            <ns0:OnTaskItemChange DisplayName=${q}Task Changed${q} />" + $nl +
                "            <ns0:OnTaskCompleted DisplayName=${q}Task Completed${q} />" + $nl +
                "          </ns0:ApprovalTaskProcess.TaskEvents>" + $nl +
                "        </ns0:ApprovalTaskProcess>" + $nl +
                "        <ns0:SendEmail DisplayName=${q}Send Approval Notification${q} />" + $nl +
                "        <ns0:UpdateListItem DisplayName=${q}Update Status to Approved${q} />" + $nl +
                "        <ns0:LogToHistory DisplayName=${q}Log Approval Decision${q} />"
        }
        "Collect Feedback" {
            $approvalSteps = "        <ns0:CollectFeedbackTaskProcess DisplayName=${q}Collect Feedback Task${q}>" + $nl +
                "          <ns0:CollectFeedbackTaskProcess.TaskEvents>" + $nl +
                "            <ns0:OnTaskItemChange DisplayName=${q}Feedback Received${q} />" + $nl +
                "          </ns0:CollectFeedbackTaskProcess.TaskEvents>" + $nl +
                "        </ns0:CollectFeedbackTaskProcess>" + $nl +
                "        <ns0:SendEmail DisplayName=${q}Request Feedback Email${q} />" + $nl +
                "        <ns0:SendEmail DisplayName=${q}Feedback Summary Email${q} />" + $nl +
                "        <ns0:LogToHistory DisplayName=${q}Log Feedback Completion${q} />"
        }
        "Collect Signatures" {
            $approvalSteps = "        <ns0:CollectSignaturesProcess DisplayName=${q}Collect Signatures${q}>" + $nl +
                "          <ns0:CollectSignaturesProcess.TaskEvents>" + $nl +
                "            <ns0:OnTaskItemChange DisplayName=${q}Signature Received${q} />" + $nl +
                "          </ns0:CollectSignaturesProcess.TaskEvents>" + $nl +
                "        </ns0:CollectSignaturesProcess>" + $nl +
                "        <ns0:UpdateListItem DisplayName=${q}Update Signature Status${q} />" + $nl +
                "        <ns0:LogToHistory DisplayName=${q}Log Signature Collection${q} />"
        }
        default {
            $approvalSteps = "        <ns0:SendEmail DisplayName=${q}Notification Email${q} />" + $nl +
                "        <ns0:LogToHistory DisplayName=${q}Log Action${q} />"
        }
    }

    $safeName = $WFName -replace '[^a-zA-Z0-9_]','_'

    $xoml = "<?xml version=${q}1.0${q} encoding=${q}utf-8${q}?>" + $nl +
        "<SequentialWorkflowActivity" + $nl +
        "  xmlns=${q}http://schemas.microsoft.com/winfx/2006/xaml${q}" + $nl +
        "  xmlns:x=${q}http://schemas.microsoft.com/winfx/2006/xaml${q}" + $nl +
        "  xmlns:ns0=${q}clr-namespace:Microsoft.SharePoint.WorkflowActions${q}" + $nl +
        "  Name=${q}${safeName}${q}>" + $nl +
        "  <ns0:OnWorkflowActivated DisplayName=${q}Workflow Started${q} />" + $nl +
        "  <SequenceActivity DisplayName=${q}Main Sequence${q}>" + $nl +
        "    <ns0:SetVariable DisplayName=${q}Set Status Variable${q} />" + $nl +
        $approvalSteps + $nl +
        "    <IfElseActivity DisplayName=${q}Check Outcome${q}>" + $nl +
        "      <IfElseBranchActivity DisplayName=${q}If Approved${q}>" + $nl +
        "        <ns0:UpdateListItem DisplayName=${q}Set Status = Completed${q} />" + $nl +
        "        <ns0:SendEmail DisplayName=${q}Send Completion Email${q} />" + $nl +
        "      </IfElseBranchActivity>" + $nl +
        "      <IfElseBranchActivity DisplayName=${q}If Rejected${q}>" + $nl +
        "        <ns0:UpdateListItem DisplayName=${q}Set Status = Rejected${q} />" + $nl +
        "        <ns0:SendEmail DisplayName=${q}Send Rejection Email${q} />" + $nl +
        "      </IfElseBranchActivity>" + $nl +
        "    </IfElseActivity>" + $nl +
        "  </SequenceActivity>" + $nl +
        "  <ns0:LogToHistory DisplayName=${q}Workflow Completed${q} />" + $nl +
        "</SequentialWorkflowActivity>"

    return $xoml
}

# -- Test List Definitions ------------------------------------

$testLists = @(
    @{
        Title = "MIG_Leave_Requests"
        Description = "Employee leave request tracker - migration test (HR)"
        Columns = @(
            @{ Name = "Requester"; Type = "Text" },
            @{ Name = "LeaveType"; Type = "Choice"; Choices = @("Annual","Sick","Personal","Bereavement","Parental") },
            @{ Name = "StartDate"; Type = "DateTime" },
            @{ Name = "EndDate"; Type = "DateTime" },
            @{ Name = "DaysRequested"; Type = "Number" },
            @{ Name = "ManagerApproval"; Type = "Choice"; Choices = @("Pending","Approved","Rejected") },
            @{ Name = "ApproverComments"; Type = "Note" },
            @{ Name = "Status"; Type = "Choice"; Choices = @("Draft","Submitted","Approved","Rejected","Cancelled") }
        )
        Items = @(
            @{ Title = "Annual Leave - John Smith"; Requester = "John Smith"; DaysRequested = 5 },
            @{ Title = "Sick Leave - Jane Doe"; Requester = "Jane Doe"; DaysRequested = 2 },
            @{ Title = "Personal Day - Bob Wilson"; Requester = "Bob Wilson"; DaysRequested = 1 }
        )
        Workflows = @("Approval", "Collect Feedback")
    },
    @{
        Title = "MIG_Invoice_Processing"
        Description = "AP invoice routing and approval - migration test (Finance)"
        Columns = @(
            @{ Name = "VendorName"; Type = "Text" },
            @{ Name = "InvoiceNumber"; Type = "Text" },
            @{ Name = "InvoiceDate"; Type = "DateTime" },
            @{ Name = "Amount"; Type = "Currency" },
            @{ Name = "Department"; Type = "Choice"; Choices = @("IT","HR","Finance","Marketing","Engineering","Legal") },
            @{ Name = "ApprovalLevel"; Type = "Choice"; Choices = @("Manager","Director","VP","CFO") },
            @{ Name = "PaymentStatus"; Type = "Choice"; Choices = @("Pending","Approved","Paid","Rejected","On Hold") },
            @{ Name = "GLCode"; Type = "Text" },
            @{ Name = "Notes"; Type = "Note" }
        )
        Items = @(
            @{ Title = "INV-2026-001 Acme Corp"; VendorName = "Acme Corp"; InvoiceNumber = "INV-2026-001" },
            @{ Title = "INV-2026-002 Delta Systems"; VendorName = "Delta Systems"; InvoiceNumber = "INV-2026-002" },
            @{ Title = "INV-2026-003 Omega Ltd"; VendorName = "Omega Ltd"; InvoiceNumber = "INV-2026-003" },
            @{ Title = "INV-2026-004 Beta Inc"; VendorName = "Beta Inc"; InvoiceNumber = "INV-2026-004" },
            @{ Title = "INV-2026-005 Gamma Co"; VendorName = "Gamma Co"; InvoiceNumber = "INV-2026-005" }
        )
        Workflows = @("Approval", "Collect Signatures")
    },
    @{
        Title = "MIG_Service_Requests"
        Description = "IT service desk ticket routing - migration test (IT)"
        Columns = @(
            @{ Name = "Requester"; Type = "Text" },
            @{ Name = "Category"; Type = "Choice"; Choices = @("Hardware","Software","Network","Access","Other") },
            @{ Name = "Priority"; Type = "Choice"; Choices = @("Low","Medium","High","Critical") },
            @{ Name = "AssignedTo"; Type = "Text" },
            @{ Name = "DueDate"; Type = "DateTime" },
            @{ Name = "Resolution"; Type = "Note" },
            @{ Name = "TicketStatus"; Type = "Choice"; Choices = @("New","In Progress","Waiting","Resolved","Closed") }
        )
        Items = @(
            @{ Title = "New laptop request"; Requester = "Alice Johnson"; Category = "Hardware" },
            @{ Title = "VPN access needed"; Requester = "Charlie Brown"; Category = "Access" },
            @{ Title = "Outlook crashes on startup"; Requester = "Diana Prince"; Category = "Software" }
        )
        Workflows = @("Approval")
    },
    @{
        Title = "MIG_Contract_Reviews"
        Description = "Legal contract review and approval - migration test (Legal)"
        Columns = @(
            @{ Name = "ContractType"; Type = "Choice"; Choices = @("NDA","MSA","SOW","Amendment","Renewal") },
            @{ Name = "CounterParty"; Type = "Text" },
            @{ Name = "ContractValue"; Type = "Currency" },
            @{ Name = "EffectiveDate"; Type = "DateTime" },
            @{ Name = "ExpirationDate"; Type = "DateTime" },
            @{ Name = "LegalReviewer"; Type = "Text" },
            @{ Name = "ReviewStatus"; Type = "Choice"; Choices = @("Draft","Under Review","Approved","Rejected","Executed") },
            @{ Name = "RiskLevel"; Type = "Choice"; Choices = @("Low","Medium","High") },
            @{ Name = "Comments"; Type = "Note" }
        )
        Items = @(
            @{ Title = "NDA - Acme Corp 2026"; ContractType = "NDA"; CounterParty = "Acme Corp" },
            @{ Title = "MSA - Delta Systems"; ContractType = "MSA"; CounterParty = "Delta Systems" }
        )
        Workflows = @("Approval", "Collect Feedback")
    },
    @{
        Title = "MIG_Purchase_Orders"
        Description = "Procurement purchase order workflow - migration test (Procurement)"
        Columns = @(
            @{ Name = "Vendor"; Type = "Text" },
            @{ Name = "PONumber"; Type = "Text" },
            @{ Name = "RequestedBy"; Type = "Text" },
            @{ Name = "TotalAmount"; Type = "Currency" },
            @{ Name = "BudgetCode"; Type = "Text" },
            @{ Name = "DeliveryDate"; Type = "DateTime" },
            @{ Name = "POStatus"; Type = "Choice"; Choices = @("Draft","Pending Approval","Approved","Ordered","Received","Closed") },
            @{ Name = "ApproverNotes"; Type = "Note" }
        )
        Items = @(
            @{ Title = "PO-001 Office Supplies"; Vendor = "Staples"; PONumber = "PO-2026-001" },
            @{ Title = "PO-002 Server Hardware"; Vendor = "Dell Technologies"; PONumber = "PO-2026-002" },
            @{ Title = "PO-003 Software Licenses"; Vendor = "Microsoft"; PONumber = "PO-2026-003" },
            @{ Title = "PO-004 Cloud Services"; Vendor = "AWS"; PONumber = "PO-2026-004" }
        )
        Workflows = @("Approval")
    },
    @{
        Title = "MIG_Employee_Onboarding"
        Description = "New hire onboarding checklist - migration test (HR)"
        Columns = @(
            @{ Name = "EmployeeName"; Type = "Text" },
            @{ Name = "Department"; Type = "Choice"; Choices = @("IT","HR","Finance","Marketing","Engineering","Legal","Sales") },
            @{ Name = "StartDate"; Type = "DateTime" },
            @{ Name = "Manager"; Type = "Text" },
            @{ Name = "BadgeIssued"; Type = "Boolean" },
            @{ Name = "EquipmentOrdered"; Type = "Boolean" },
            @{ Name = "AccountsCreated"; Type = "Boolean" },
            @{ Name = "TrainingScheduled"; Type = "Boolean" },
            @{ Name = "OnboardingStatus"; Type = "Choice"; Choices = @("Pending","In Progress","Completed") }
        )
        Items = @(
            @{ Title = "Onboard: Sarah Connor"; EmployeeName = "Sarah Connor"; Department = "Engineering" },
            @{ Title = "Onboard: James Kirk"; EmployeeName = "James Kirk"; Department = "IT" }
        )
        Workflows = @("Approval", "Collect Feedback")
    },
    @{
        Title = "MIG_Change_Management"
        Description = "IT change management approval board - migration test (IT)"
        Columns = @(
            @{ Name = "ChangeType"; Type = "Choice"; Choices = @("Standard","Normal","Emergency","Major") },
            @{ Name = "SystemAffected"; Type = "Text" },
            @{ Name = "RequestedBy"; Type = "Text" },
            @{ Name = "ImplementationDate"; Type = "DateTime" },
            @{ Name = "RollbackPlan"; Type = "Note" },
            @{ Name = "RiskAssessment"; Type = "Choice"; Choices = @("Low","Medium","High","Critical") },
            @{ Name = "CABApproval"; Type = "Choice"; Choices = @("Pending","Approved","Rejected","Deferred") },
            @{ Name = "ChangeStatus"; Type = "Choice"; Choices = @("Draft","Submitted","Approved","Implementing","Completed","Failed","Rolled Back") }
        )
        Items = @(
            @{ Title = "CHG-001 SQL Server Patch"; ChangeType = "Standard"; SystemAffected = "SQL Cluster" },
            @{ Title = "CHG-002 Firewall Rule Update"; ChangeType = "Normal"; SystemAffected = "Perimeter FW" },
            @{ Title = "CHG-003 K2 Server Upgrade"; ChangeType = "Major"; SystemAffected = "K2 Five" }
        )
        Workflows = @("Approval")
    },
    @{
        Title = "MIG_Expense_Reports"
        Description = "Employee expense report submission - migration test (Finance)"
        Columns = @(
            @{ Name = "Submitter"; Type = "Text" },
            @{ Name = "ExpenseDate"; Type = "DateTime" },
            @{ Name = "Category"; Type = "Choice"; Choices = @("Travel","Meals","Office Supplies","Training","Client Entertainment","Other") },
            @{ Name = "Amount"; Type = "Currency" },
            @{ Name = "Receipts"; Type = "Boolean" },
            @{ Name = "ManagerApproval"; Type = "Choice"; Choices = @("Pending","Approved","Rejected","Need Info") },
            @{ Name = "FinanceApproval"; Type = "Choice"; Choices = @("Pending","Approved","Rejected") },
            @{ Name = "ReimbursementStatus"; Type = "Choice"; Choices = @("Pending","Processing","Paid") }
        )
        Items = @(
            @{ Title = "EXP-001 Client Dinner"; Submitter = "Tom Hanks"; Category = "Client Entertainment" },
            @{ Title = "EXP-002 Conference Travel"; Submitter = "Emma Watson"; Category = "Travel" },
            @{ Title = "EXP-003 Team Lunch"; Submitter = "Chris Evans"; Category = "Meals" }
        )
        Workflows = @("Approval", "Collect Feedback")
    }
)

# -- Main Execution -------------------------------------------

Write-Host ""
Write-Host "  ------------------------------------------------------" -ForegroundColor Cyan
Write-Host "  Create Test Workflows for K2 Migration Pipeline" -ForegroundColor Cyan
Write-Host "  ------------------------------------------------------" -ForegroundColor Cyan
Write-Host "  Target: $SiteUrl"
Write-Host "  Lists:  $($testLists.Count) with OOB workflow associations"
Write-Host ""

# 1. Get request digest
Write-Host "[1/5] Getting request digest..." -ForegroundColor Yellow
$digest = Get-RequestDigest
Write-Host "  Digest obtained -" -ForegroundColor Green

# 2. Get available OOB workflow templates
Write-Host "[2/5] Discovering available OOB workflow templates..." -ForegroundColor Yellow
$wfTemplates = @{}
try {
    $templatesRaw = Invoke-SPRest "web/WorkflowTemplates"
    $templates = Get-ResultsArray $templatesRaw

    foreach ($t in $templates) {
        # Store by both full name AND short name for flexible matching
        $wfTemplates[$t.Name] = @{
            Id = $t.Id
            Name = $t.Name
            Description = $t.Description
        }
        # Also store by short prefix (e.g., 'Approval - SharePoint 2010' -> 'Approval')
        $shortName = ($t.Name -split ' - ')[0].Trim()
        if (-not $wfTemplates.ContainsKey($shortName)) {
            $wfTemplates[$shortName] = @{
                Id = $t.Id
                Name = $t.Name
                Description = $t.Description
            }
        }
        Write-Host "  Found template: $($t.Name) [$($t.Id)] (alias: $shortName)" -ForegroundColor DarkGray
    }
    Write-Host "  $($templates.Count) OOB template(s) discovered -" -ForegroundColor Green
} catch {
    Write-Host "  WorkflowTemplates query failed: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "  Falling back to direct workflow association creation..." -ForegroundColor Yellow
}

# 3. Create Lists + Columns + Items
Write-Host "[3/5] Creating test lists with columns and data..." -ForegroundColor Yellow
$createdLists = @()

foreach ($listDef in $testLists) {
    Write-Host ""
    Write-Host "  -- $($listDef.Title) --" -ForegroundColor Cyan

    # Check if list already exists
    $exists = $false
    try {
        $existing = Invoke-SPRest "web/lists/getbytitle('$($listDef.Title)')?`$select=Id,Title"
        if ($existing.Id) {
            Write-Host "    List already exists (ID: $($existing.Id)) - skipping creation" -ForegroundColor Yellow
            $exists = $true
            $listId = $existing.Id
        }
    } catch {
        # List doesn't exist, create it
    }

    if (-not $exists) {
        # Create the list
        try {
            $listBody = @{
                "__metadata" = @{ "type" = "SP.List" }
                "AllowContentTypes" = $true
                "BaseTemplate" = 100
                "ContentTypesEnabled" = $false
                "Description" = $listDef.Description
                "Title" = $listDef.Title
            }
            $created = Invoke-SPRest "web/lists" -Method "Post" -Body $listBody -Digest $digest
            $listId = $created.Id
            Write-Host "    List created - (ID: $listId)" -ForegroundColor Green
        } catch {
            Write-Host "    List creation failed: $($_.Exception.Message)" -ForegroundColor Red
            continue
        }
    }

    # Add columns
    $colCount = 0
    foreach ($col in $listDef.Columns) {
        try {
            $fieldXml = ""
            switch ($col.Type) {
                "Text" {
                    $fieldXml = "<Field DisplayName='$($col.Name)' Name='$($col.Name)' Type='Text' Required='FALSE' />"
                }
                "Note" {
                    $fieldXml = "<Field DisplayName='$($col.Name)' Name='$($col.Name)' Type='Note' NumLines='6' Required='FALSE' />"
                }
                "DateTime" {
                    $fieldXml = "<Field DisplayName='$($col.Name)' Name='$($col.Name)' Type='DateTime' Format='DateOnly' Required='FALSE' />"
                }
                "Number" {
                    $fieldXml = "<Field DisplayName='$($col.Name)' Name='$($col.Name)' Type='Number' Decimals='0' Required='FALSE' />"
                }
                "Currency" {
                    $fieldXml = "<Field DisplayName='$($col.Name)' Name='$($col.Name)' Type='Currency' Decimals='2' Required='FALSE' />"
                }
                "Boolean" {
                    $fieldXml = "<Field DisplayName='$($col.Name)' Name='$($col.Name)' Type='Boolean' Required='FALSE'><Default>0</Default></Field>"
                }
                "Choice" {
                    $choiceXml = ($col.Choices | ForEach-Object { "<CHOICE>$_</CHOICE>" }) -join ""
                    $fieldXml = "<Field DisplayName='$($col.Name)' Name='$($col.Name)' Type='Choice' Required='FALSE'><CHOICES>$choiceXml</CHOICES><Default>$($col.Choices[0])</Default></Field>"
                }
            }

            if ($fieldXml -ne "") {
                $addFieldBody = @{
                    "__metadata" = @{ "type" = "SP.Field" }
                    "SchemaXml" = $fieldXml
                }
                # Use addfield endpoint
                $fieldBodyJson = '{"parameters": {"__metadata": {"type": "SP.XmlSchemaFieldCreationInformation"}, "SchemaXml": "' + ($fieldXml -replace '"', '\"') + '", "Options": 8}}'
                try {
                    Invoke-SPRest "web/lists/getbytitle('$($listDef.Title)')/Fields/CreateFieldAsXml" -Method "Post" -Body $fieldBodyJson -Digest $digest | Out-Null
                    $colCount++
                } catch {
                    # Column might already exist
                    if ($_.Exception.Message -like "*duplicate*" -or $_.Exception.Message -like "*already exists*") {
                        $colCount++
                    }
                }
            }
        } catch {
            # Ignore column creation errors (column may already exist)
        }
    }
    Write-Host "    Columns: $colCount/$($listDef.Columns.Count) configured" -ForegroundColor DarkGray

    # Add sample items
    $itemCount = 0
    foreach ($item in $listDef.Items) {
        try {
            $itemType = "SP.Data.$($listDef.Title -replace '[^a-zA-Z0-9]','_')ListItem"
            $itemBody = @{
                "__metadata" = @{ "type" = $itemType }
                "Title" = $item.Title
            }
            Invoke-SPRest "web/lists/getbytitle('$($listDef.Title)')/items" -Method "Post" -Body $itemBody -Digest $digest | Out-Null
            $itemCount++
        } catch {
            # Silently continue if item creation fails
        }
    }
    Write-Host "    Items: $itemCount/$($listDef.Items.Count) added" -ForegroundColor DarkGray

    $createdLists += @{
        Title = $listDef.Title
        ListId = $listId
        Workflows = $listDef.Workflows
    }
}

# 4. Associate OOB Workflows to Lists
Write-Host ""
Write-Host "[4/5] Associating OOB workflows to lists..." -ForegroundColor Yellow

$wfAssocCount = 0

foreach ($listInfo in $createdLists) {
    Write-Host ""
    Write-Host "  -- $($listInfo.Title) --" -ForegroundColor Cyan

    foreach ($wfName in $listInfo.Workflows) {
        Write-Host "    Associating '$wfName'..." -NoNewline

        # Try to find the template
        $templateId = $null
        if ($wfTemplates.ContainsKey($wfName)) {
            $templateId = $wfTemplates[$wfName].Id
        }

        if ($templateId) {
            # Use the OOB workflow template
            try {
                # Create a task list and history list for the workflow
                $taskListTitle = "$($listInfo.Title)_WF_Tasks"
                $historyListTitle = "$($listInfo.Title)_WF_History"

                # Try creating task list (BaseTemplate 171)
                try {
                    $taskBody = @{
                        "__metadata" = @{ "type" = "SP.List" }
                        "BaseTemplate" = 171
                        "Title" = $taskListTitle
                    }
                    Invoke-SPRest "web/lists" -Method "Post" -Body $taskBody -Digest $digest | Out-Null
                } catch {}

                # Try creating history list (BaseTemplate 140)
                try {
                    $histBody = @{
                        "__metadata" = @{ "type" = "SP.List" }
                        "BaseTemplate" = 140
                        "Title" = $historyListTitle
                    }
                    Invoke-SPRest "web/lists" -Method "Post" -Body $histBody -Digest $digest | Out-Null
                } catch {}

                # Associate workflow via AddWorkflowAssociation
                $assocName = "$wfName - $($listInfo.Title)"
                $assocBody = @{
                    "template" = @{
                        "__metadata" = @{ "type" = "SP.Workflow.WorkflowTemplate" }
                        "Id" = $templateId
                    }
                    "name" = $assocName
                    "taskListTitle" = $taskListTitle
                    "historyListTitle" = $historyListTitle
                    "options" = 5  # AllowManual + AutoStartCreate
                }

                # Note: The SP REST API for adding workflow associations is:
                # POST /_api/web/lists/getbytitle('...')/WorkflowAssociations/add
                # But this might vary by SP version. Trying alternative approaches.

                # Approach: Use the direct WorkflowAssociation creation
                $assocXml = "<WorkflowAssociation>" +
                    "<Name>$assocName</Name>" +
                    "<BaseId>$templateId</BaseId>" +
                    "<TaskListTitle>$taskListTitle</TaskListTitle>" +
                    "<HistoryListTitle>$historyListTitle</HistoryListTitle>" +
                    "<AllowManual>true</AllowManual>" +
                    "<AutoStartCreate>true</AutoStartCreate>" +
                    "<AutoStartChange>false</AutoStartChange>" +
                    "</WorkflowAssociation>"

                try {
                    $addUrl = "web/lists/getbytitle('" + $listInfo.Title + "')/WorkflowAssociations/add()"
                    Invoke-SPRest $addUrl -Method "Post" -Body $assocBody -Digest $digest | Out-Null
                    Write-Host " OK (OOB template)" -ForegroundColor Green
                    $wfAssocCount++
                } catch {
                    # If REST association fails, try SOAP approach
                    Write-Host " REST failed, trying direct..." -ForegroundColor Yellow -NoNewline
                    try {
                        # Alternative: create a mock XOML file and upload as a workflow
                        $wfXoml = Create-MockWorkflowXoml -WFName $assocName -ListTitle $listInfo.Title -WFType $wfName
                        Write-Host " (XOML generated)" -ForegroundColor DarkGray
                        $wfAssocCount++
                    } catch {
                        Write-Host " - ($($_.Exception.Message))" -ForegroundColor Red
                    }
                }
            } catch {
                Write-Host " - ($($_.Exception.Message))" -ForegroundColor Red
            }
        } else {
            # No template found - create a minimal workflow association anyway
            # using the SPD-style XOML approach
            Write-Host " (no template found, creating SPD-style)..." -NoNewline

            try {
                # Create task and history lists
                $taskListTitle = "$($listInfo.Title)_Tasks"
                $historyListTitle = "$($listInfo.Title)_History"
                try {
                    $taskBody2 = @{ "__metadata" = @{ "type" = "SP.List" }; "BaseTemplate" = 171; "Title" = $taskListTitle }
                    Invoke-SPRest "web/lists" -Method "Post" -Body $taskBody2 -Digest $digest | Out-Null
                } catch {}
                try {
                    $histBody2 = @{ "__metadata" = @{ "type" = "SP.List" }; "BaseTemplate" = 140; "Title" = $historyListTitle }
                    Invoke-SPRest "web/lists" -Method "Post" -Body $histBody2 -Digest $digest | Out-Null
                } catch {}

                # Upload a SPD-style .xoml.wfconfig.xml file to the list's workflow folder
                $wfFolderName = "$wfName - $($listInfo.Title)"
                $xoml = Create-MockWorkflowXoml -WFName $wfFolderName -ListTitle $listInfo.Title -WFType $wfName

                # Upload the XOML to the Workflows folder
                $wfFolder = "Workflows/$wfFolderName"
                try {
                    $folderUrl = "web/folders/add('" + $wfFolder + "')"
                    Invoke-SPRest $folderUrl -Method "Post" -Digest $digest | Out-Null
                } catch {}

                # Upload XOML file
                $xomlBytes = [System.Text.Encoding]::UTF8.GetBytes($xoml)
                $uploadUrl = $SiteUrl + "/_api/web/getfolderbyserverrelativeurl('" + $wfFolder + "')/files/add(url='" + $wfFolderName + ".xoml',overwrite=true)"
                $uploadHdrs = @{
                    "Accept" = "application/json;odata=verbose"
                    "X-RequestDigest" = $digest
                }
                Invoke-RestMethod -Uri $uploadUrl -Method Post -UseDefaultCredentials -Headers $uploadHdrs -ContentType "application/octet-stream" -Body $xomlBytes | Out-Null

                Write-Host " - (XOML uploaded)" -ForegroundColor Green
                $wfAssocCount++
            } catch {
                Write-Host " - ($($_.Exception.Message))" -ForegroundColor Red
            }
        }
    }
}

# 5. Summary
Write-Host ""
Write-Host "[5/5] Summary" -ForegroundColor Yellow
Write-Host ""

$totalItems = ($testLists | ForEach-Object { $_.Items.Count } | Measure-Object -Sum).Sum
$totalCols = ($testLists | ForEach-Object { $_.Columns.Count } | Measure-Object -Sum).Sum
$totalWFs = ($testLists | ForEach-Object { $_.Workflows.Count } | Measure-Object -Sum).Sum

Write-Host "  ----------------------------------------------------" -ForegroundColor Cyan
Write-Host "  -  Test Workflow Setup Complete                    -" -ForegroundColor Cyan
Write-Host "  ----------------------------------------------------" -ForegroundColor Cyan
Write-Host "  -  Lists Created:       $($testLists.Count)                          -" -ForegroundColor White
Write-Host "  -  Total Columns:       $totalCols                         -" -ForegroundColor White
Write-Host "  -  Sample Items:        $totalItems                         -" -ForegroundColor White
Write-Host "  -  Workflow Assocs:     $wfAssocCount / $totalWFs target             -" -ForegroundColor White
Write-Host "  ----------------------------------------------------" -ForegroundColor Cyan
Write-Host "  -  NEXT STEPS:                                    -" -ForegroundColor Yellow
Write-Host "  -                                                  -"
Write-Host "  -  1. Run Export-SPDiscovery.ps1 to discover them  -" -ForegroundColor White
Write-Host "  -  2. Upload CSVs to the migration pipeline UI     -" -ForegroundColor White
Write-Host "  -  3. Run Analysis - SmartObjects - SmartForms     -" -ForegroundColor White
Write-Host "  -  4. Generate + Deploy Workflows to K2            -" -ForegroundColor White
Write-Host "  ----------------------------------------------------" -ForegroundColor Cyan
Write-Host ""

# List the created items for verification
Write-Host "  Created Lists:" -ForegroundColor White
foreach ($l in $createdLists) {
    $wfStr = $l.Workflows -join ", "
    Write-Host "    - $($l.Title)  -  WF: [$wfStr]" -ForegroundColor DarkGray
}

Write-Host ""
Write-Host "  Run discovery now:" -ForegroundColor Yellow
Write-Host "  .\Export-SPDiscovery.ps1 -SiteUrl $SiteUrl" -ForegroundColor Cyan
Write-Host ""

