<#
.SYNOPSIS
    Harvest a deployable .kspx package from a K2 build server using the
    SourceCode.Deployment.PowerShell snap-in.

.DESCRIPTION
    Exports all artifacts under a given category from a K2 server into
    a single .kspx package file. Useful for reverse-engineering existing
    deployments or for backup/restore scenarios.

    Adapted from the SharePoint Nintex POC repository.
#>

param(
    [Parameter(Mandatory)] [string] $K2Server,
    [int]    $Port = 5555,
    [Parameter(Mandatory)] [string] $Category,
    [Parameter(Mandatory)] [string] $OutFile,
    [string] $K2DllPath
)

# ── Load K2 Deployment Snap-in ──────────────────────────────
$ErrorActionPreference = "Stop"

if ($K2DllPath -and (Test-Path $K2DllPath)) {
    try {
        Add-Type -Path (Join-Path $K2DllPath "SourceCode.Deployment.dll") -ErrorAction SilentlyContinue
        Add-Type -Path (Join-Path $K2DllPath "SourceCode.Hosting.Client.dll") -ErrorAction SilentlyContinue
    } catch { }
}

if (-not (Get-PSSnapin -Name SourceCode.Deployment.PowerShell -Registered -ErrorAction SilentlyContinue)) {
    Add-PSSnapin SourceCode.Deployment.PowerShell -ErrorAction Stop
}

# ── Create session ──────────────────────────────────────────
$session = New-K2DeploymentSession -K2Server $K2Server -Port $Port

try {
    Write-Host "Harvesting from $K2Server (category $Category)..." -ForegroundColor Cyan
    Export-K2Package -Session $session -Category $Category -OutFile $OutFile -Recurse -OverwriteIfExists
    Write-Host "OK: kspx written to $OutFile" -ForegroundColor Green

    @{
        success  = $true
        server   = $K2Server
        category = $Category
        outFile  = $OutFile
    } | ConvertTo-Json -Compress

} catch {
    Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
    @{
        success = $false
        error   = $_.Exception.Message
    } | ConvertTo-Json -Compress

} finally {
    Close-K2DeploymentSession -Session $session
}
