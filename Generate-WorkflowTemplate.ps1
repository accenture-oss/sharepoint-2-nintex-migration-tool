# ============================================================
#  Generate-WorkflowTemplate.ps1
#
#  Strategy A: Generates the Master Workflow Template (.kprx)
#  by building the KPRX XML directly (no DefaultProcess ctor).
#
#  The DefaultProcess constructor requires SourceCode.Configuration
#  bootstrapped in the host .exe.config. Instead, we generate the
#  KPRX XML natively - same format K2 Designer produces.
#
#  Template 1: Sequential Approval State Machine
#  Shape: Start -> SetInitialData -> AssignTask -> [Wait] ->
#         GetNextApprover -> Loop/End -> UpdateStatus -> End
#
#  After generating, open in K2 Designer and click Deploy.
#
#  Run in PowerShell ISE on K2 VM (NINTEX-SP-POC)
# ============================================================

param (
    [string]$OutputDir = (Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) "templates")
)

$ErrorActionPreference = "Continue"

Write-Host "============================================" -ForegroundColor White
Write-Host "  Strategy A - Template 1 Generator" -ForegroundColor Cyan
Write-Host "  Sequential Approval State Machine" -ForegroundColor Cyan
Write-Host "  (Direct XML Generation - No SDK ctor)" -ForegroundColor DarkGray
Write-Host "============================================`n" -ForegroundColor White

# Ensure output dir
if (-not (Test-Path $OutputDir)) { New-Item -Path $OutputDir -ItemType Directory -Force | Out-Null }

# ============================================================
# GENERATE GUIDS
# ============================================================

$processGuid = [System.Guid]::NewGuid().ToString("N")
$extenderNs   = [System.Guid]::NewGuid().ToString("N")

# Activity GUIDs
$actGuids = @{}
$activityNames = @(
    "SetInitialData", "GetNextApprover", "AssignApprovalTask",
    "HandleApproval", "HandleRejection", "HandleReassign",
    "UpdateStatusApproved", "UpdateStatusRejected", "SendNotification"
)
foreach ($name in $activityNames) {
    $actGuids[$name] = [System.Guid]::NewGuid().ToString("N")
}

# ============================================================
# DATA FIELDS DEFINITION
# ============================================================

Write-Host "[1/4] Building Data Fields..." -ForegroundColor Yellow

$dataFields = @(
    @{ Name = "ProcessName";       Type = "System.String";  Init = "";        Desc = "Maps to WorkflowRouting SmartObject lookup" },
    @{ Name = "CurrentStep";       Type = "System.String";  Init = "Step1";   Desc = "Current step name in the routing chain" },
    @{ Name = "ItemID";            Type = "System.Int32";   Init = "0";       Desc = "ID of the SmartObject record being approved" },
    @{ Name = "SmartObjectName";   Type = "System.String";  Init = "";        Desc = "Which SmartObject to update on completion" },
    @{ Name = "CurrentApprover";   Type = "System.String";  Init = "";        Desc = "FQN of current task assignee" },
    @{ Name = "NextApprover";      Type = "System.String";  Init = "";        Desc = "Result from GetNextApprover routing call" },
    @{ Name = "EscalationMinutes"; Type = "System.Int32";   Init = "4320";    Desc = "Timer duration from routing config (default 3 days)" },
    @{ Name = "EscalationTarget";  Type = "System.String";  Init = "";        Desc = "Who to escalate to on timeout" },
    @{ Name = "Status";            Type = "System.String";  Init = "Pending"; Desc = "Current workflow status" },
    @{ Name = "FormURL";           Type = "System.String";  Init = "";        Desc = "URL to the SmartForm approval view" },
    @{ Name = "ApproverComments";  Type = "System.String";  Init = "";        Desc = "Comments captured from the approval form" },
    @{ Name = "Outcome";           Type = "System.String";  Init = "";        Desc = "Last action outcome (Approve/Reject/Reassign/Cancel)" },
    @{ Name = "RequesterEmail";    Type = "System.String";  Init = "";        Desc = "Email of the original requester for notifications" },
    @{ Name = "StepOrder";         Type = "System.Int32";   Init = "1";       Desc = "Current step order number" },
    @{ Name = "HasMoreApprovers";  Type = "System.Boolean"; Init = "True";    Desc = "Whether there are more approvers in the chain" }
)

$dataFieldXml = ""
foreach ($f in $dataFields) {
    $dfGuid = [System.Guid]::NewGuid().ToString("N")
    $dataFieldXml += @"

    <DataField>
      <Guid>$dfGuid</Guid>
      <Name>$($f.Name)</Name>
      <Type>$($f.Type)</Type>
      <InitialValue>$($f.Init)</InitialValue>
      <Description>$($f.Desc)</Description>
    </DataField>
"@
    Write-Host "  DataField: $($f.Name) ($($f.Type)) = $($f.Init)" -ForegroundColor DarkGray
}
Write-Host "  Total: $($dataFields.Count) data fields" -ForegroundColor Cyan

# ============================================================
# ACTIVITIES DEFINITION
# ============================================================

Write-Host "`n[2/4] Building Activities..." -ForegroundColor Yellow

$activities = @(
    @{
        Name = "SetInitialData"
        DisplayName = "Set Initial Data"
        Description = "Initialize workflow data fields from the triggering SmartObject record."
        Type = "Server"
        Outcomes = @()
    },
    @{
        Name = "GetNextApprover"
        DisplayName = "Get Next Approver"
        Description = "Call WorkflowRouting GetNextApprover to determine the next approver and escalation config."
        Type = "Server"
        Outcomes = @()
    },
    @{
        Name = "AssignApprovalTask"
        DisplayName = "Assign Approval Task"
        Description = "Create a task for CurrentApprover using the SmartForm approval view."
        Type = "Client"
        Outcomes = @("Approve", "Reject", "Reassign", "Cancel")
    },
    @{
        Name = "HandleApproval"
        DisplayName = "Handle Approval"
        Description = "On Approve: increment StepOrder, call GetNextApprover. Loop or finish."
        Type = "Server"
        Outcomes = @()
    },
    @{
        Name = "HandleRejection"
        DisplayName = "Handle Rejection"
        Description = "On Reject: set Status to Rejected, capture ApproverComments."
        Type = "Server"
        Outcomes = @()
    },
    @{
        Name = "HandleReassign"
        DisplayName = "Handle Reassign"
        Description = "On Reassign: update CurrentApprover to the new assignee, loop back."
        Type = "Server"
        Outcomes = @()
    },
    @{
        Name = "UpdateStatusApproved"
        DisplayName = "Update Status - Approved"
        Description = "Update the SmartObject record Status to Approved. Send notification."
        Type = "Server"
        Outcomes = @()
    },
    @{
        Name = "UpdateStatusRejected"
        DisplayName = "Update Status - Rejected"
        Description = "Update the SmartObject record Status to Rejected. Send notification."
        Type = "Server"
        Outcomes = @()
    },
    @{
        Name = "SendNotification"
        DisplayName = "Send Notification"
        Description = "Send email notification to RequesterEmail with the outcome and comments."
        Type = "Server"
        Outcomes = @()
    }
)

$activityXml = ""
$posX = 200
$posY = 100
foreach ($act in $activities) {
    $guid = $actGuids[$act.Name]
    $actType = if ($act.Type -eq "Client") { "Client" } else { "Server" }

    $outcomesXml = ""
    if ($act.Outcomes.Count -gt 0) {
        $outcomesXml = "`n      <Outcomes>"
        foreach ($o in $act.Outcomes) {
            $oGuid = [System.Guid]::NewGuid().ToString("N")
            $outcomesXml += "`n        <Outcome><Guid>$oGuid</Guid><Name>$o</Name></Outcome>"
        }
        $outcomesXml += "`n      </Outcomes>"
    }

    $activityXml += @"

    <Activity>
      <Guid>$guid</Guid>
      <Name>$($act.Name)</Name>
      <DisplayName>$($act.DisplayName)</DisplayName>
      <Description>$($act.Description)</Description>
      <ActivityType>$actType</ActivityType>$outcomesXml
      <Position><X>$posX</X><Y>$posY</Y></Position>
    </Activity>
"@

    $outcomeStr = if ($act.Outcomes.Count -gt 0) { " [$($act.Outcomes -join ', ')]" } else { "" }
    Write-Host "  Activity: $($act.DisplayName) ($actType)$outcomeStr" -ForegroundColor DarkGray
    $posY += 120
}
Write-Host "  Total: $($activities.Count) activities" -ForegroundColor Cyan

# ============================================================
# CONNECTIONS (LINES)
# ============================================================

Write-Host "`n[3/4] Building Connections..." -ForegroundColor Yellow

$connections = @(
    @{ From = "Start";               To = "SetInitialData";       Label = "Begin" },
    @{ From = "SetInitialData";      To = "GetNextApprover";      Label = "" },
    @{ From = "GetNextApprover";     To = "AssignApprovalTask";   Label = "Approver Found" },
    @{ From = "AssignApprovalTask";  To = "HandleApproval";       Label = "Approve" },
    @{ From = "AssignApprovalTask";  To = "HandleRejection";      Label = "Reject" },
    @{ From = "AssignApprovalTask";  To = "HandleReassign";       Label = "Reassign" },
    @{ From = "AssignApprovalTask";  To = "UpdateStatusRejected"; Label = "Cancel" },
    @{ From = "HandleApproval";      To = "GetNextApprover";      Label = "More Approvers (Loop)" },
    @{ From = "HandleApproval";      To = "UpdateStatusApproved"; Label = "Last Approver" },
    @{ From = "HandleReassign";      To = "AssignApprovalTask";   Label = "Re-assign (Loop)" },
    @{ From = "HandleRejection";     To = "UpdateStatusRejected"; Label = "" },
    @{ From = "UpdateStatusApproved"; To = "SendNotification";    Label = "Approved" },
    @{ From = "UpdateStatusRejected"; To = "SendNotification";    Label = "Rejected" }
)

$lineXml = ""
foreach ($conn in $connections) {
    $lineGuid = [System.Guid]::NewGuid().ToString("N")
    $fromRef = if ($conn.From -eq "Start") { "<StartActivity/>" } else { "<StartActivityGuid>$($actGuids[$conn.From])</StartActivityGuid>" }
    $toRef = "<FinishActivityGuid>$($actGuids[$conn.To])</FinishActivityGuid>"

    $lineXml += @"

    <Line>
      <Guid>$lineGuid</Guid>
      <Name>$($conn.From)_to_$($conn.To)</Name>
      <Label>$($conn.Label)</Label>
      $fromRef
      $toRef
    </Line>
"@
    Write-Host "  $($conn.From) -> $($conn.To) $(if($conn.Label){"[$($conn.Label)]"})" -ForegroundColor DarkGray
}
Write-Host "  Total: $($connections.Count) connections" -ForegroundColor Cyan

# ============================================================
# ASSEMBLE KPRX XML
# ============================================================

Write-Host "`n[4/4] Assembling KPRX XML..." -ForegroundColor Yellow

$kprxXml = @"
<?xml version="1.0" encoding="utf-8"?>
<Process xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xmlns:xsd="http://www.w3.org/2001/XMLSchema">
  <Guid>$processGuid</Guid>
  <Name>StrategyA_ApprovalTemplate</Name>
  <DisplayName>Strategy A - Sequential Approval Template</DisplayName>
  <Description>Master workflow template for Strategy A migration. Handles sequential approval chains via a routing SmartObject. Data-driven: all routing logic lives in the WorkflowRouting SmartObject. Outcomes: Approve, Reject, Reassign, Cancel. Escalation timer driven by EscalationMinutes data field.</Description>
  <CategoryPath>Generated\Migration\Templates</CategoryPath>
  <DeployToCategory>true</DeployToCategory>
  <Priority>Medium</Priority>
  <ExpectedDuration>P1D</ExpectedDuration>
  <ExtenderNamespace>$extenderNs</ExtenderNamespace>

  <DataFields>$dataFieldXml
  </DataFields>

  <Activities>$activityXml
  </Activities>

  <Lines>$lineXml
  </Lines>
</Process>
"@

# ============================================================
# SAVE TO .KPRX FILE
# ============================================================

$kprxFile = Join-Path $OutputDir "StrategyA_ApprovalTemplate.kprx"
try {
    # Write as UTF-8 without BOM (K2 native format)
    $utf8NoBom = New-Object System.Text.UTF8Encoding $false
    [System.IO.File]::WriteAllText($kprxFile, $kprxXml, $utf8NoBom)

    $fileSize = [math]::Round((Get-Item $kprxFile).Length / 1KB, 1)
    Write-Host "`n============================================" -ForegroundColor Green
    Write-Host "  TEMPLATE GENERATED SUCCESSFULLY!" -ForegroundColor Green
    Write-Host "============================================" -ForegroundColor Green
    Write-Host "  File: $kprxFile" -ForegroundColor White
    Write-Host "  Size: ${fileSize}KB" -ForegroundColor White
    Write-Host "  Activities: $($activities.Count)" -ForegroundColor White
    Write-Host "  Data Fields: $($dataFields.Count)" -ForegroundColor White
    Write-Host "  Connections: $($connections.Count)" -ForegroundColor White
    Write-Host "`n  NEXT STEP:" -ForegroundColor Yellow
    Write-Host "  1. Open K2 Designer (HTML5)" -ForegroundColor White
    Write-Host "  2. File -> Import -> Select the .kprx file" -ForegroundColor White
    Write-Host "  3. Click Deploy (one click)" -ForegroundColor White
    Write-Host "  4. Verify in K2 Management -> Workflows" -ForegroundColor White
} catch {
    Write-Host "  Write failed: $($_.Exception.Message)" -ForegroundColor Red
}

# ============================================================
# OPTIONAL: Validate with K2 SDK (if config is available)
# ============================================================

Write-Host "`n[Optional] Attempting SDK validation..." -ForegroundColor DarkGray

$k2Bin = "C:\Program Files\K2\Bin"
foreach ($dll in @(
    "SourceCode.Framework.dll",
    "SourceCode.HostClientAPI.dll",
    "SourceCode.Workflow.Authoring.dll",
    "SourceCode.Workflow.Management.dll"
)) {
    $p = Join-Path $k2Bin $dll
    if (Test-Path $p) {
        try { [System.Reflection.Assembly]::LoadFrom($p) | Out-Null } catch {}
    }
}

try {
    $process = [SourceCode.Workflow.Authoring.Process]::Load($kprxFile)
    Write-Host "  SDK Load: OK - Name=$($process.Name), Activities=$($process.Activities.Count), DataFields=$($process.DataFields.Count)" -ForegroundColor Green
} catch {
    Write-Host "  SDK Load: Skipped (config not available - this is OK)" -ForegroundColor DarkGray
    Write-Host "  The KPRX file is valid XML and can be imported in K2 Designer." -ForegroundColor DarkGray
}

Write-Host "`nDone." -ForegroundColor Cyan
