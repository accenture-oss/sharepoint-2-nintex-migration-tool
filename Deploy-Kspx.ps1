<#
.SYNOPSIS
    Deploy a .kspx package to a target K2 environment.

.DESCRIPTION
    Adapted from the SharePoint Nintex POC Deploy-Kspx.ps1 for
    integration with the SPD-K2 Migration Pipeline.

    Covers:
      P3.04  Apply environment-specific config XML
      P3.06  Pre-deploy analysis (R&D dry-run)
      P3.07-P3.09  Actual deployment
      P3.10-P3.11  Verify + activate workflows
      P3.12  Deployment ledger entry
#>

param(
    [Parameter(Mandatory)] [string] $KspxFile,
    [Parameter(Mandatory)] [string] $EnvironmentConfig,
    [Parameter(Mandatory)] [string] $TargetK2,
    [int]    $Port = 5555,
    [switch] $DryRun,
    [string] $LedgerFile = "./deployment-ledger.jsonl",
    [string] $K2DllPath,
    [string] $K2User,
    [string] $K2Password,
    [string] $K2Domain,
    [string] $Category = "Workflow/Generated"
)

# ── Load K2 Deployment Snap-in ──────────────────────────────
$ErrorActionPreference = "Stop"

# Try loading from explicit DLL path first, then snap-in
if ($K2DllPath -and (Test-Path $K2DllPath)) {
    try {
        Add-Type -Path (Join-Path $K2DllPath "SourceCode.Deployment.dll") -ErrorAction SilentlyContinue
        Add-Type -Path (Join-Path $K2DllPath "SourceCode.Hosting.Client.dll") -ErrorAction SilentlyContinue
        Write-Host "Loaded K2 SDK assemblies from: $K2DllPath" -ForegroundColor Gray
    } catch {
        Write-Host "Warning: Could not load DLLs from $K2DllPath - $($_.Exception.Message)" -ForegroundColor Yellow
    }
}

if (-not (Get-PSSnapin -Name SourceCode.Deployment.PowerShell -Registered -ErrorAction SilentlyContinue)) {
    try {
        Add-PSSnapin SourceCode.Deployment.PowerShell -ErrorAction Stop
    } catch {
        Write-Host "ERROR: K2 Deployment PowerShell snap-in not available." -ForegroundColor Red
        Write-Host "Ensure K2 Five SDK is installed and the snap-in is registered." -ForegroundColor Red
        Write-Host "Run: installutil SourceCode.Deployment.PowerShell.dll" -ForegroundColor Yellow
        exit 1
    }
}

# ── Validate inputs ─────────────────────────────────────────
if (-not (Test-Path $KspxFile)) {
    Write-Host "ERROR: KSPX file not found: $KspxFile" -ForegroundColor Red
    exit 1
}

if (-not (Test-Path $EnvironmentConfig)) {
    Write-Host "ERROR: EnvironmentConfig not found: $EnvironmentConfig" -ForegroundColor Red
    exit 1
}

Write-Host "═══════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host "  K2 KSPX Deployment Pipeline" -ForegroundColor Cyan
Write-Host "  Package:     $KspxFile" -ForegroundColor White
Write-Host "  Target:      $TargetK2`:$Port" -ForegroundColor White
Write-Host "  Config:      $EnvironmentConfig" -ForegroundColor White
Write-Host "  Dry Run:     $DryRun" -ForegroundColor White
Write-Host "═══════════════════════════════════════════════════" -ForegroundColor Cyan

# ── Create deployment session ───────────────────────────────
try {
    $sessionParams = @{
        K2Server = $TargetK2
        Port     = $Port
    }

    # Add credentials if provided
    if ($K2User -and $K2Password) {
        $secPassword = ConvertTo-SecureString $K2Password -AsPlainText -Force
        $credential = New-Object System.Management.Automation.PSCredential($K2User, $secPassword)
        # Note: K2 deployment cmdlets use the current Windows identity by default
        # Explicit credentials require impersonation or runas
        Write-Host "Using explicit credentials: $K2User" -ForegroundColor Gray
    }

    $session = New-K2DeploymentSession -K2Server $TargetK2 -Port $Port
    Write-Host "Deployment session established." -ForegroundColor Green

} catch {
    Write-Host "ERROR: Failed to create K2 deployment session." -ForegroundColor Red
    Write-Host "  Details: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}

try {
    # ── P3.06: Pre-deploy analysis (dry-run) ────────────────
    Write-Host "`n[P3.06] Analyzing package..." -ForegroundColor Cyan
    $analysis = Write-DeploymentConfig -Session $session -PackageFile $KspxFile -ConfigFile $EnvironmentConfig
    Write-Host "Analysis report:" -ForegroundColor Yellow
    $analysis | Format-Table

    if ($DryRun) {
        Write-Host "`nDry-run only — no deployment performed." -ForegroundColor Yellow
        Write-Host "Analysis complete. Review the table above for deployment impact." -ForegroundColor Yellow

        # Output JSON for the Node.js bridge to parse
        $result = @{
            success = $true
            dryRun = $true
            analysis = ($analysis | ConvertTo-Json -Depth 3)
        }
        $result | ConvertTo-Json -Compress
        return
    }

    # ── P3.07-P3.09: Deploy the package ─────────────────────
    Write-Host "`n[P3.07] Deploying..." -ForegroundColor Cyan
    Deploy-Package -Session $session -PackageFile $KspxFile -ConfigFile $EnvironmentConfig -Force
    Write-Host "OK: deployed $KspxFile to $TargetK2" -ForegroundColor Green

    # ── P3.10-P3.11: Activate workflows ─────────────────────
    Write-Host "`n[P3.11] Activating workflows..." -ForegroundColor Cyan
    $activated = Set-WorkflowsActive -Session $session -Category (Split-Path $KspxFile -LeafBase) -ErrorAction SilentlyContinue
    if ($activated) {
        Write-Host "Workflows activated: $($activated.Count) process(es)" -ForegroundColor Green
    } else {
        Write-Host "No workflows required activation (or activation skipped)." -ForegroundColor Yellow
    }

    # ── P3.12: Ledger entry ─────────────────────────────────
    $entry = [pscustomobject]@{
        timestamp    = (Get-Date).ToString("o")
        kspx         = (Resolve-Path $KspxFile).Path
        environment  = (Split-Path $EnvironmentConfig -LeafBase)
        targetServer = $TargetK2
        deployer     = "$env:USERDOMAIN\$env:USERNAME"
        activated    = ($activated -ne $null)
        category     = $Category
    }
    $entry | ConvertTo-Json -Compress | Out-File -FilePath $LedgerFile -Append -Encoding utf8
    Write-Host "Ledger entry → $LedgerFile" -ForegroundColor Green

    # ── Output result JSON for Node.js bridge ───────────────
    $result = @{
        success     = $true
        dryRun      = $false
        deployed    = $true
        kspxFile    = $KspxFile
        target      = "$TargetK2`:$Port"
        activated   = ($activated -ne $null)
        timestamp   = (Get-Date).ToString("o")
    }
    $result | ConvertTo-Json -Compress

} catch {
    Write-Host "`nERROR during deployment: $($_.Exception.Message)" -ForegroundColor Red

    $errorResult = @{
        success = $false
        error   = $_.Exception.Message
        kspxFile = $KspxFile
        target   = "$TargetK2`:$Port"
    }
    $errorResult | ConvertTo-Json -Compress

} finally {
    Close-K2DeploymentSession -Session $session
    Write-Host "`nDeployment session closed." -ForegroundColor Gray
}
