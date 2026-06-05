param (
    [string]$K2Server = "localhost",
    [int]$K2Port = 5555,
    [string]$WorkflowJsonFile
)

try {
    $k2Bin = "C:\Program Files\K2\Bin"

    # Load workflow definition JSON
    $wfJson = Get-Content $WorkflowJsonFile -Raw | ConvertFrom-Json
    $wfName = $wfJson.name
    $wfDisplayName = $wfJson.displayName
    $wfSystemName = $wfName -replace '[^a-zA-Z0-9_]', '_'

    Write-Host "[K2 WF] Deploying: $wfDisplayName ($($wfJson.steps.Count) steps)" -ForegroundColor Cyan

    # Load K2 SDK assemblies
    foreach ($dll in @(
        "SourceCode.Framework.dll",
        "SourceCode.HostClientAPI.dll",
        "SourceCode.Workflow.Authoring.dll",
        "SourceCode.Workflow.Design.dll",
        "SourceCode.Workflow.Management.dll",
        "SourceCode.Deployment.Management.dll",
        "SourceCode.EnvironmentSettings.Client.dll"
    )) {
        $p = Join-Path $k2Bin $dll
        if (Test-Path $p) { [System.Reflection.Assembly]::LoadFrom($p) | Out-Null }
    }
    Write-Host "[K2 WF] SDK loaded" -ForegroundColor Green

    $connStr = "Integrated=True;IsPrimaryLogin=True;Authenticate=True;EncryptedPassword=False;Host=$K2Server;Port=$K2Port"

    # =====================================================
    # Build process using DefaultProcess (concrete subclass)
    # =====================================================
    Write-Host "[K2 WF] Creating DefaultProcess..." -ForegroundColor Cyan

    $process = New-Object SourceCode.Workflow.Design.DefaultProcess
    $process.Name = $wfSystemName
    $process.DisplayName = $wfDisplayName
    $process.Description = "Auto-migrated from SharePoint Designer. $($wfJson.description)"

    Write-Host "[K2 WF] Process: $($process.Name) / $($process.DisplayName)" -ForegroundColor Green

    # Add DataFields
    foreach ($field in $wfJson.dataFields) {
        try {
            # Probe DataField constructor
            $dfType = [SourceCode.Workflow.Authoring.DataField]
            $df = New-Object SourceCode.Workflow.Authoring.DataField
            $df.Name = $field.name
            # Set type
            $k2Type = switch ($field.type) {
                "Number" { "System.Int32" }
                "DateTime" { "System.DateTime" }
                "Boolean" { "System.Boolean" }
                default { "System.String" }
            }
            try { $df.Type = $k2Type } catch {}
            try { $df.InitialValue = $field.initialValue } catch {}
            $process.DataFields.Add($df)
            Write-Host "  DataField: $($field.name) ($k2Type)" -ForegroundColor DarkGray
        } catch {
            Write-Host "  DataField failed: $($_.Exception.Message)" -ForegroundColor Yellow
        }
    }

    # Add Activities
    foreach ($step in $wfJson.steps) {
        try {
            $actType = [SourceCode.Workflow.Design.DefaultActivity]
            if (-not $actType) { $actType = [SourceCode.Workflow.Authoring.Activity] }
            $activity = New-Object $actType.FullName
            $activity.Name = $step.name
            $activity.DisplayName = $step.displayName
            try { $activity.Description = $step.description } catch {}
            $process.Activities.Add($activity)
            Write-Host "  Activity: $($step.displayName)" -ForegroundColor DarkGray
        } catch {
            Write-Host "  Activity failed ($($step.name)): $($_.Exception.Message)" -ForegroundColor Yellow
        }
    }
    Write-Host "[K2 WF] $($process.Activities.Count) activities, $($process.DataFields.Count) data fields" -ForegroundColor Cyan

    # =====================================================
    # Try Deploy() — direct deployment
    # =====================================================
    Write-Host "[K2 WF] Attempting Process.Deploy()..." -ForegroundColor Cyan
    $deployed = $false

    try {
        # Set connection properties on the process
        $connProp = $process.GetType().GetProperty("Connection")
        if ($connProp) {
            Write-Host "  Setting connection..." -ForegroundColor DarkGray
        }
        # Some Process subclasses need a connection string set before Deploy()
        $wcProp = $process.GetType().GetProperty("WorkflowManagementConnectionString")
        if ($wcProp) { $wcProp.SetValue($process, $connStr) }
        $soProp = $process.GetType().GetProperty("SmartObjectConnectionString")
        if ($soProp) { $soProp.SetValue($process, $connStr) }

        $deployResult = $process.Deploy()
        if ($deployResult.Successful) {
            Write-Host "[K2 WF] DEPLOYED via Process.Deploy()!" -ForegroundColor Green
            $deployed = $true
        } else {
            $errors = @()
            foreach ($e in $deployResult.Errors) { $errors += $e.ErrorText }
            Write-Host "[K2 WF] Deploy returned errors: $($errors -join '; ')" -ForegroundColor Yellow
        }
    } catch {
        Write-Host "[K2 WF] Deploy() failed: $($_.Exception.Message)" -ForegroundColor Yellow
        if ($_.Exception.InnerException) {
            Write-Host "  Inner: $($_.Exception.InnerException.Message)" -ForegroundColor DarkYellow
        }
    }

    # =====================================================
    # Fallback: CreateDeploymentPackage + Execute
    # =====================================================
    if (-not $deployed) {
        Write-Host "[K2 WF] Trying CreateDeploymentPackage()..." -ForegroundColor Cyan
        try {
            $package = $process.CreateDeploymentPackage()
            $package.WorkflowManagementConnectionString = $connStr
            $package.SmartObjectConnectionString = $connStr
            $package.DeploymentLabelName = "SPD_Migration_$wfSystemName"
            $package.DeploymentLabelDescription = "Auto-migrated: $wfDisplayName"

            Write-Host "[K2 WF] Package created, executing..." -ForegroundColor DarkGray
            $execResult = $package.Execute()
            if ($execResult.Successful) {
                Write-Host "[K2 WF] DEPLOYED via CreateDeploymentPackage + Execute!" -ForegroundColor Green
                $deployed = $true
            } else {
                $errors = @()
                foreach ($e in $execResult.Errors) { $errors += $e.ErrorText }
                Write-Host "[K2 WF] Package errors: $($errors -join '; ')" -ForegroundColor Yellow
            }
        } catch {
            Write-Host "[K2 WF] CreateDeploymentPackage failed: $($_.Exception.Message)" -ForegroundColor Yellow
            if ($_.Exception.InnerException) {
                Write-Host "  Inner: $($_.Exception.InnerException.Message)" -ForegroundColor DarkYellow
            }
        }
    }

    # =====================================================
    # Fallback 2: Save to .kprx + Deploy-Package cmdlet
    # =====================================================
    if (-not $deployed) {
        Write-Host "[K2 WF] Trying SaveAs + Deploy-Package cmdlet..." -ForegroundColor Cyan
        $scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
        $exportDir = Join-Path $scriptDir "k2-export\$wfSystemName"
        if (-not (Test-Path $exportDir)) { New-Item -Path $exportDir -ItemType Directory -Force | Out-Null }

        $kprxFile = Join-Path $exportDir "$wfSystemName.kprx"
        try {
            $process.SaveAs($kprxFile)
            Write-Host "[K2 WF] Saved to: $kprxFile" -ForegroundColor Green

            # Load snap-in and use Deploy-Package
            Add-PSSnapin SourceCode.Deployment.PowerShell -ErrorAction SilentlyContinue
            $dpCmd = Get-Command "Deploy-Package" -ErrorAction SilentlyContinue
            if ($dpCmd) {
                & $dpCmd -FileName $kprxFile -K2Host $K2Server -Port $K2Port -Integrated $true -IsPrimaryLogin $true -NoAnalyze
                $deployed = $true
                Write-Host "[K2 WF] DEPLOYED via Deploy-Package cmdlet!" -ForegroundColor Green
            }
        } catch {
            Write-Host "[K2 WF] SaveAs/Deploy-Package failed: $($_.Exception.Message)" -ForegroundColor Yellow
        }
    }

    # Report
    $result = @{
        "success" = $deployed
        "workflowName" = $wfName
        "displayName" = $wfDisplayName
        "activities" = $process.Activities.Count
        "dataFields" = $process.DataFields.Count
        "deployResult" = if ($deployed) { "deployed" } else { "failed" }
        "method" = "DefaultProcess"
    }
    Write-Output ($result | ConvertTo-Json -Compress)

} catch {
    Write-Host "[K2 WF ERROR] $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "[K2 WF ERROR] Stack: $($_.ScriptStackTrace)" -ForegroundColor DarkRed
    if ($_.Exception.InnerException) {
        Write-Host "[K2 WF ERROR] Inner: $($_.Exception.InnerException.Message)" -ForegroundColor DarkRed
    }
    $result = @{
        "success" = $false
        "error" = "$($_.Exception.Message)"
        "workflowName" = $wfName
    }
    Write-Output ($result | ConvertTo-Json -Compress)
}
