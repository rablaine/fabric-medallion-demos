# Phase 9: trigger scans + poll to completion, with temp public-network exposure.
#
# Why: Purview AutoResolveIntegrationRuntime needs network reach to the data
# source. Customer SQL/ADLS may be private. We flip them public for the scan,
# run, then flip back. try/finally ensures the close-down ALWAYS fires even
# on errors or Ctrl-C — never leave resources public.
#
# Run modes:
#   -SqlOnly      run only SQL scan
#   -AdlsOnly     run only ADLS scan
#   default       run both in sequence (SQL first, smaller / validates plumbing)

[CmdletBinding()]
param(
    [switch]$SqlOnly,
    [switch]$AdlsOnly,
    [int]$TimeoutMinutes = 30
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\_lib.ps1"
$ctx = Read-Context

$endpoint    = $ctx.purview.endpoint
$sqlSrcName  = $ctx.dataSources.sql
$adlsSrcName = $ctx.dataSources.adls
$sqlScan     = $ctx.scans.sql
$adlsScan    = $ctx.scans.adls

$sqlSrv  = $ctx.retail.sqlServer
$adls    = $ctx.retail.adls
$rgRetail = $ctx.resourceGroup

# ---------- Capture original state so we can restore exactly ----------------

$sqlOriginalPNA = az sql server show -g $rgRetail -n $sqlSrv.name --query publicNetworkAccess -o tsv
$sqlOrigAzureSvcRule = az sql server firewall-rule show -g $rgRetail -s $sqlSrv.name -n AllowAllWindowsAzureIps --query name -o tsv 2>$null

$adlsOriginalPNA   = az storage account show -g $rgRetail -n $adls.name --query publicNetworkAccess -o tsv
$adlsOriginalDeflt = az storage account show -g $rgRetail -n $adls.name --query networkRuleSet.defaultAction -o tsv
$adlsOriginalBypass = az storage account show -g $rgRetail -n $adls.name --query networkRuleSet.bypass -o tsv
# Storage accounts can have unset publicNetworkAccess (empty string). Treat as "Enabled" for restore purposes.
if (-not $adlsOriginalPNA) { $adlsOriginalPNA = 'Enabled' }
if (-not $adlsOriginalDeflt) { $adlsOriginalDeflt = 'Allow' }

Write-Host "Original state captured:"
Write-Host "  SQL    PNA=$sqlOriginalPNA  AllowAzureSvc=$([bool]$sqlOrigAzureSvcRule)"
Write-Host "  ADLS   PNA=$adlsOriginalPNA  defaultAction=$adlsOriginalDeflt  bypass=$adlsOriginalBypass"

# ---------- Helpers ---------------------------------------------------------

function Open-Network {
    Write-Host ""
    Write-Host "=== Opening public network temporarily ===" -ForegroundColor Yellow

    Write-Host "  SQL: PNA -> Enabled, add AllowAllWindowsAzureIps firewall rule"
    az sql server update -g $rgRetail -n $sqlSrv.name --set publicNetworkAccess=Enabled --output none
    az sql server firewall-rule create -g $rgRetail -s $sqlSrv.name -n AllowAllWindowsAzureIps --start-ip-address 0.0.0.0 --end-ip-address 0.0.0.0 --output none 2>$null | Out-Null

    Write-Host "  ADLS: PNA -> Enabled, defaultAction -> Allow"
    az storage account update -g $rgRetail -n $adls.name --public-network-access Enabled --default-action Allow --output none

    Write-Host "  Wait 60s for network changes to propagate..."
    Start-Sleep -Seconds 60
}

function Close-Network {
    Write-Host ""
    Write-Host "=== Restoring private network ===" -ForegroundColor Yellow

    try {
        az sql server update -g $rgRetail -n $sqlSrv.name --set "publicNetworkAccess=$sqlOriginalPNA" --output none
        if (-not $sqlOrigAzureSvcRule) {
            az sql server firewall-rule delete -g $rgRetail -s $sqlSrv.name -n AllowAllWindowsAzureIps --output none 2>$null | Out-Null
        }
        Write-Host "  SQL    restored: PNA=$sqlOriginalPNA"
    } catch { Write-Host "  SQL restore FAILED: $($_.Exception.Message)" -ForegroundColor Red }

    try {
        az storage account update -g $rgRetail -n $adls.name --public-network-access $adlsOriginalPNA --default-action $adlsOriginalDeflt --output none
        Write-Host "  ADLS   restored: PNA=$adlsOriginalPNA  defaultAction=$adlsOriginalDeflt"
    } catch { Write-Host "  ADLS restore FAILED: $($_.Exception.Message)" -ForegroundColor Red }
}

function Start-ScanRun {
    param([string]$DataSource, [string]$ScanName)
    $runId = [guid]::NewGuid().ToString()
    Write-Host "  trigger: $ScanName runId=$runId" -ForegroundColor Cyan
    $url = "$endpoint/scan/datasources/$DataSource/scans/$ScanName/runs/$runId`?api-version=2022-02-01-preview&scanLevel=Full"
    Invoke-PurviewRest -Method PUT -Url $url -Body @{} | Out-Null
    return $runId
}

function Wait-ScanRun {
    param([string]$DataSource, [string]$ScanName, [string]$RunId, [int]$TimeoutMinutes)
    $url = "$endpoint/scan/datasources/$DataSource/scans/$ScanName/runs/$RunId`?api-version=2022-02-01-preview"
    $deadline = (Get-Date).AddMinutes($TimeoutMinutes)
    $lastStatus = ''
    while ((Get-Date) -lt $deadline) {
        $r = Invoke-PurviewRest -Method GET -Url $url
        if ($r) {
            $status = $r.status
            if ($status -ne $lastStatus) {
                Write-Host "    [$status] discovered=$($r.assetsDiscovered)" -ForegroundColor Yellow
                $lastStatus = $status
            }
            if ($status -in @('Succeeded','Failed','Canceled','PartialSucceeded','TransientFailure','Quarantined')) {
                return $r
            }
        }
        Start-Sleep -Seconds 15
    }
    throw "Scan did not finish within $TimeoutMinutes minutes (last=$lastStatus)"
}

# ---------- Main flow with try/finally so Close-Network always runs ---------

$results = @()
try {
    Open-Network

    if (-not $AdlsOnly) {
        Write-Host ""
        Write-Host "=== Triggering SQL scan ===" -ForegroundColor Cyan
        $id = Start-ScanRun -DataSource $sqlSrcName -ScanName $sqlScan
        $r  = Wait-ScanRun  -DataSource $sqlSrcName -ScanName $sqlScan -RunId $id -TimeoutMinutes $TimeoutMinutes
        $results += [pscustomobject]@{ Source='SQL';  Status=$r.status; Discovered=$r.assetsDiscovered; Error=$r.errorMessage }
    }

    if (-not $SqlOnly) {
        Write-Host ""
        Write-Host "=== Triggering ADLS scan ===" -ForegroundColor Cyan
        $id = Start-ScanRun -DataSource $adlsSrcName -ScanName $adlsScan
        $r  = Wait-ScanRun  -DataSource $adlsSrcName -ScanName $adlsScan -RunId $id -TimeoutMinutes $TimeoutMinutes
        $results += [pscustomobject]@{ Source='ADLS'; Status=$r.status; Discovered=$r.assetsDiscovered; Error=$r.errorMessage }
    }
}
finally {
    Close-Network
}

Write-Host ""
Write-Host "=== Summary ===" -ForegroundColor Cyan
$results | Format-Table -AutoSize

if ($results | Where-Object { $_.Status -ne 'Succeeded' }) {
    exit 1
}
