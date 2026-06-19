<#
.SYNOPSIS
  Deploys the Contoso Healthcare data estate (Azure Health Data Services FHIR R4)
  and populates it from the baked-in synthetic seed via the bulk $import method.

.DESCRIPTION
  Infrastructure is provisioned with Bicep (infra/storage.bicep + infra/fhir.bicep);
  data population uses server-side bulk $import (reads NDJSON from blob) instead
  of per-resource REST PUT.

  Ordering is tuned so the long pole (FHIR service create, ~6 min) runs in
  parallel with everything it does not depend on:
    1. storage.bicep (fast, synchronous) creates the ADLS account + containers.
    2. fhir.bicep is launched with --no-wait (workspace + FHIR service, with
       import/export + auth config baked in, plus both role assignments).
    3. While FHIR provisions, the seed is uploaded to the storage account.
    4. We wait for the FHIR deployment, then $import and $export.

  Resource names use a uniqueString(resourceGroup().id) suffix (same pattern as
  the retail vertical), so names are deterministic and globally unique without
  any caller input.

  Every phase is wrapped in a stopwatch; a timing table is printed at the end and
  written to .\logs\deploy-timings-<timestamp>.json so deploy duration can be
  audited part-by-part.

.NOTES
  Requires: az CLI (logged in), the 'healthcareapis' extension, and rights to
  create role assignments in the target RG (Owner / User Access Administrator)
  because the FHIR managed identity must be granted Storage Blob Data Contributor.
#>
[CmdletBinding()]
param(
    [string] $ResourceGroup   = "rg-contoso-health-poc",
    [string] $Location        = "westus3",
    [string] $ResourcePrefix  = "contoso",
    [string] $FhirServiceName = "fhirr4",
    [string] $ImportContainer = "fhirimport",
    [string] $ExportContainer = "fhirexport",
    [string] $SeedDir         = (Join-Path $PSScriptRoot "data\fhir-seed"),
    [string] $FabricWorkspace = "cts-health-analytics",
    [switch] $SkipExport,
    [switch] $SkipFabric
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

# ---------------------------------------------------------------------------
# deployment.config (written by the web package builder) carries the user's
# choices into the downloaded package. Region is deliberately NOT configurable:
# everything (AHDS, storage, and the Fabric F8 capacity) is pinned to a single
# region that supports Azure Health Data Services AND has Fabric capacity quota.
# West US 3 satisfies both; East US / East US 2 are excluded. The region is
# hard-pinned regardless of any param/config input.
# ---------------------------------------------------------------------------
$ConfigFile = Join-Path $PSScriptRoot "deployment.config"
if (Test-Path $ConfigFile) {
    $cfg = @{}
    Get-Content $ConfigFile | ForEach-Object {
        $line = $_.Trim()
        if ($line -and -not $line.StartsWith('#') -and $line.Contains('=')) {
            $k, $v = $line.Split('=', 2)
            $cfg[$k.Trim()] = $v.Trim()
        }
    }
    if ($cfg.ContainsKey('RESOURCE_GROUP')  -and $cfg['RESOURCE_GROUP'])  { $ResourceGroup  = $cfg['RESOURCE_GROUP'] }
    if ($cfg.ContainsKey('RESOURCE_PREFIX') -and $cfg['RESOURCE_PREFIX']) { $ResourcePrefix = $cfg['RESOURCE_PREFIX'] }
    # LOCATION from the config is intentionally ignored (see note above).
}
$Location = "westus3"

# Transcript so a full run is auditable from the package folder.
$LogDir = Join-Path $PSScriptRoot "logs"
New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
$TranscriptPath = Join-Path $LogDir ("deploy-{0}.log" -f (Get-Date -Format "yyyyMMdd-HHmmss"))
try { Start-Transcript -Path $TranscriptPath | Out-Null } catch {}

$InfraDir     = Join-Path $PSScriptRoot "infra"
$StorageBicep = Join-Path $InfraDir "storage.bicep"
$FhirBicep    = Join-Path $InfraDir "fhir.bicep"
$FabricPs1    = Join-Path $PSScriptRoot "scripts\Fabric.ps1"

# Dot-source the Fabric REST helpers at SCRIPT scope (not inside an Invoke-Phase
# block) so every phase can see Get-FabricToken / New-FabricWorkspace / etc.
# Invoke-Phase runs each body via '& $Body' (child scope), so a dot-source inside
# a phase would only define the functions for that one phase.
if (-not $SkipFabric) {
    if (-not (Test-Path $FabricPs1)) { throw "Missing $FabricPs1" }
    . $FabricPs1
}

# ---------------------------------------------------------------------------
# Timing harness
# ---------------------------------------------------------------------------
$script:Timings = [System.Collections.Generic.List[object]]::new()
$script:DeploySw = [System.Diagnostics.Stopwatch]::StartNew()

function Format-Eta {
    param([double] $Seconds)
    if ($Seconds -le 0) { return $null }
    if ($Seconds -ge 90) { return ("~{0:N0} min" -f ($Seconds / 60)) }
    return ("~{0:N0}s" -f $Seconds)
}

function Invoke-Phase {
    param(
        [Parameter(Mandatory)][string]      $Name,
        [Parameter(Mandatory)][scriptblock] $Body,
        [double]                            $EstSeconds = 0
    )
    $ts = (Get-Date).ToString("HH:mm:ss")
    $eta = Format-Eta $EstSeconds
    Write-Host ""
    if ($eta) {
        Write-Host ("==== [{0}] {1} ====" -f $ts, $Name) -ForegroundColor Cyan -NoNewline
        Write-Host ("  (est {0})" -f $eta) -ForegroundColor DarkGray
    }
    else {
        Write-Host ("==== [{0}] {1} ====" -f $ts, $Name) -ForegroundColor Cyan
    }
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    & $Body
    $sw.Stop()
    $secs = [math]::Round($sw.Elapsed.TotalSeconds, 1)
    $script:Timings.Add([pscustomobject]@{ Phase = $Name; Seconds = $secs })
    Write-Host ("---- {0} done in {1}s ----" -f $Name, $secs) -ForegroundColor DarkGray
}

function Write-TimingSummary {
    $script:DeploySw.Stop()
    $total = [math]::Round($script:DeploySw.Elapsed.TotalSeconds, 1)
    Write-Host ""
    Write-Host "================ DEPLOY TIMING ================" -ForegroundColor Green
    $script:Timings |
        Select-Object Phase,
            @{ N = "Seconds"; E = { "{0,7:N1}" -f $_.Seconds } },
            @{ N = "Pct"; E = { "{0,5:N1}%" -f (($_.Seconds / $total) * 100) } } |
        Format-Table -AutoSize | Out-Host
    Write-Host ("TOTAL: {0}s ({1:N1} min)" -f $total, ($total / 60)) -ForegroundColor Green
    Write-Host "(phases overlap: FHIR provisions while the seed uploads, so the" -ForegroundColor DarkGray
    Write-Host " sum of phase times exceeds wall-clock total.)" -ForegroundColor DarkGray

    $logDir = Join-Path $PSScriptRoot "logs"
    New-Item -ItemType Directory -Force -Path $logDir | Out-Null
    $logFile = Join-Path $logDir ("deploy-timings-{0}.json" -f (Get-Date -Format "yyyyMMdd-HHmmss"))
    [pscustomobject]@{
        timestamp     = (Get-Date).ToString("o")
        resourceGroup = $ResourceGroup
        location      = $Location
        method        = "import"
        totalSeconds  = $total
        phases        = $script:Timings
    } | ConvertTo-Json -Depth 5 | Set-Content -Path $logFile -Encoding utf8
    Write-Host ("timing log: {0}" -f $logFile) -ForegroundColor DarkGray
}

# ---------------------------------------------------------------------------
# az CLI hardening: retry transient (429 / 5xx / transport) errors with
# exponential backoff, and recover from expired tokens (silent refresh, then
# interactive 'az login --tenant'). Mirrors the retail vertical's helper.
#
# Usage:
#   $acct = (Invoke-AzWithRetry -Label 'az account show' { az account show -o json }) | ConvertFrom-Json
#   Invoke-AzWithRetry -Label 'rg create' { az group create -n $rg -l $loc -o none } | Out-Null
# ---------------------------------------------------------------------------
function Invoke-AzWithRetry {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][scriptblock] $Script,
        [string] $Label = 'az call',
        [int] $MaxAttempts = 6,
        [switch] $AllowNonZeroExit
    )
    $maxTokenRefreshes = 2
    $tokenRefreshes    = 0
    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        $errFile = [System.IO.Path]::GetTempFileName()
        try {
            $result = & $Script 2>$errFile
            $exit   = $LASTEXITCODE
            $stderr = (Get-Content -Raw -Path $errFile -ErrorAction SilentlyContinue) ?? ''
            if ($exit -eq 0) { return $result }
            if ($AllowNonZeroExit -and $exit -ne 0 -and -not ($stderr -match 'AADSTS|TokenExpired|please run.*az login|InvalidAuthenticationToken|429|5\d\d ')) {
                return $result
            }
            # CAE (Continuous Access Evaluation) interactive challenge: a SILENT
            # token fetch cannot satisfy 'InteractionRequired' — only interactive
            # 'az login' mints a fresh token with current Conditional-Access policies.
            $isCaeChallenge = $stderr -match 'InteractionRequired|TokenCreatedWithOutdatedPolicies|Continuous access evaluation resulted in challenge|AADSTS50076|AADSTS50079|AADSTS50173'
            $isTokenExpired = $stderr -match 'AADSTS70043|AADSTS50173|AADSTS500011|AADSTS50076|AADSTS50079|TokenExpired|Access token has expired|InvalidAuthenticationToken|expired or revoked|Continuous Access Evaluation|please run.*az login|Please run.*az login|run.*az login.*again'
            if (($isCaeChallenge -or $isTokenExpired) -and $tokenRefreshes -lt $maxTokenRefreshes) {
                $tokenRefreshes++
                if ($isCaeChallenge) {
                    # Skip silent refresh entirely — it returns exit 0 on ARM while
                    # the Graph token stays challenged, masking the real failure.
                    if (-not $script:DeployTenantId) {
                        throw "${Label}: Conditional-Access (CAE) challenge requires interactive sign-in, but tenant id not registered. Run 'az login --tenant <your-tenant>' then restart the deploy."
                    }
                    Write-Host "    [auth] ${Label}: Conditional-Access challenge ($tokenRefreshes/$maxTokenRefreshes); launching interactive 'az login --tenant $script:DeployTenantId'..." -ForegroundColor Yellow
                    az login --tenant $script:DeployTenantId | Out-Null
                    if ($LASTEXITCODE -ne 0) { throw "${Label}: az login failed (cannot recover the CAE challenge)." }
                    Write-Host "    [auth] Re-authenticated; resuming." -ForegroundColor Green
                    continue
                }
                Write-Host "    [auth] ${Label}: token rejected (refresh $tokenRefreshes/$maxTokenRefreshes); re-acquiring..." -ForegroundColor DarkYellow
                az account get-access-token --resource https://management.azure.com --output none 2>$null
                if ($LASTEXITCODE -ne 0) {
                    if (-not $script:DeployTenantId) {
                        throw "${Label}: token expired, silent refresh failed, and tenant id not registered. Restart deploy after 'az login'."
                    }
                    Write-Host "    [auth] Silent refresh failed; launching 'az login --tenant $script:DeployTenantId'..." -ForegroundColor Yellow
                    az login --tenant $script:DeployTenantId | Out-Null
                    if ($LASTEXITCODE -ne 0) { throw "${Label}: az login failed (cannot recover)." }
                    Write-Host "    [auth] Re-authenticated; resuming." -ForegroundColor Green
                }
                continue
            }
            $isTransient = $stderr -match 'TooManyRequests|\b429\b|throttl|\b500\b|\b502\b|\b503\b|\b504\b|temporary|service unavailable|timeout|timed out|connection.*reset|connection.*aborted|name or service|name resolution|EOF|TLS|SSL'
            if ($isTransient -and $attempt -lt $MaxAttempts) {
                $delay = [int][Math]::Min(30, [Math]::Pow(2, $attempt))
                Write-Host "    [retry] ${Label}: transient error (attempt $attempt/$MaxAttempts); retrying in ${delay}s" -ForegroundColor DarkYellow
                if ($stderr) { Write-Host "      $($stderr.Trim() -replace "`r?`n",' | ')" -ForegroundColor DarkGray }
                Start-Sleep -Seconds $delay
                continue
            }
            throw "${Label} failed (exit $exit): $($stderr.Trim())"
        }
        finally {
            Remove-Item -LiteralPath $errFile -ErrorAction SilentlyContinue
        }
    }
    throw "${Label} failed after $MaxAttempts attempts"
}

# ---------------------------------------------------------------------------
# FHIR data-plane helpers (FhirUrl is known only after fhir.bicep finishes).
# Get-FhirToken fetches a fresh token (with az retry); Invoke-Fhir retries
# transport errors, 401 (token refresh), and 429 / 5xx (honoring Retry-After).
# ---------------------------------------------------------------------------
function Get-FhirToken {
    (Invoke-AzWithRetry -Label 'fhir data-plane token' {
        az account get-access-token --resource $script:FhirUrl --query accessToken -o tsv
    } | Out-String).Trim()
}

function Invoke-Fhir {
    # REST wrapper: fresh token per call, retries transport / 401 / 429 / 5xx.
    param(
        [Parameter(Mandatory)][string] $Method,
        [Parameter(Mandatory)][string] $Path,        # e.g. "/`$import" or "/_operations/import/1"
        [string] $Body,
        [hashtable] $ExtraHeaders,
        [int] $MaxAttempts = 6
    )
    $uri = "$script:FhirUrl$Path"
    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        $headers = @{ Authorization = "Bearer $(Get-FhirToken)" }
        if ($ExtraHeaders) { $ExtraHeaders.GetEnumerator() | ForEach-Object { $headers[$_.Key] = $_.Value } }
        $reqArgs = @{ Uri = $uri; Headers = $headers; Method = $Method; SkipHttpErrorCheck = $true }
        if ($Body) { $reqArgs.Body = $Body; $headers["Content-Type"] = "application/fhir+json" }
        try {
            $resp = Invoke-WebRequest @reqArgs
        }
        catch {
            # Transport-level failure (DNS / TLS / reset) - retry with backoff.
            if ($attempt -lt $MaxAttempts) {
                $delay = [int][Math]::Min(30, [Math]::Pow(2, $attempt))
                Write-Host "    [retry] FHIR $Method $Path transport error (attempt $attempt/$MaxAttempts); ${delay}s: $($_.Exception.Message)" -ForegroundColor DarkYellow
                Start-Sleep -Seconds $delay
                continue
            }
            throw
        }
        $sc = [int]$resp.StatusCode
        if ($sc -eq 401 -and $attempt -lt $MaxAttempts) {
            Write-Host "    [auth] FHIR $Method $Path returned 401; re-acquiring token (attempt $attempt/$MaxAttempts)" -ForegroundColor DarkYellow
            Start-Sleep -Seconds 3
            continue
        }
        if (($sc -eq 429 -or $sc -ge 500) -and $attempt -lt $MaxAttempts) {
            $retryAfter = $null
            try { $retryAfter = [int]($resp.Headers["Retry-After"] | Select-Object -First 1) } catch {}
            $delay = if ($retryAfter) { $retryAfter } else { [int][Math]::Min(30, [Math]::Pow(2, $attempt)) }
            Write-Host "    [retry] FHIR $Method $Path HTTP $sc (attempt $attempt/$MaxAttempts); waiting ${delay}s" -ForegroundColor DarkYellow
            Start-Sleep -Seconds $delay
            continue
        }
        return $resp
    }
}

function ConvertFrom-FhirContent {
    param($Response)
    $c = $Response.Content
    $text = if ($c -is [byte[]]) { [System.Text.Encoding]::UTF8.GetString($c) } else { [string]$c }
    if ([string]::IsNullOrWhiteSpace($text)) { return $null }
    return $text | ConvertFrom-Json
}

# ---------------------------------------------------------------------------
# Fabric Healthcare data solutions (HDS) helpers - used by phases 09-12.
# These call Invoke-FabricRest from scripts\Fabric.ps1 (dot-sourced at script scope, top of file).
# ---------------------------------------------------------------------------
function Wait-FabricOperation {
    param(
        [Parameter(Mandatory)][string] $Token,
        [Parameter(Mandatory)][string] $OperationUrl,
        [int] $TimeoutSec = 900
    )
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while ($sw.Elapsed.TotalSeconds -lt $TimeoutSec) {
        Start-Sleep -Seconds 5
        $r = Invoke-FabricRest -Token $Token -Method GET -Path $OperationUrl
        $st = $null; try { $st = $r.Body.status } catch {}
        if ($st -eq 'Succeeded') { return $r }
        if ($st -in 'Failed', 'Undefined', 'Cancelled') { throw "Fabric operation $st" }
    }
    throw "Fabric operation timed out after ${TimeoutSec}s"
}

function Get-FabricItems {
    param(
        [Parameter(Mandatory)][string] $Token,
        [Parameter(Mandatory)][string] $WorkspaceId
    )
    $r = Invoke-FabricRest -Token $Token -Method GET -Path "/workspaces/$WorkspaceId/items"
    return $r.Body.value
}

# Wait for an HDS Spark Environment to finish PUBLISHING. After foundations
# deploys, the custom environment keeps publishing in the background - the FIRST
# publish installs the HDS libraries and usually takes ~5-10 min (seen up to 8).
# If the ingestion pipeline runs first the notebooks fail with "publishing state
# is running, please wait until publishing succeeds." Polls publishDetails.state
# until Success (returns $true), Failed/Cancelled or timeout (returns $false).
# Invoke-FabricRest refreshes its own token, so this survives long waits.
function Wait-FabricEnvironmentPublish {
    param(
        [Parameter(Mandatory)][string] $Token,
        [Parameter(Mandatory)][string] $WorkspaceId,
        [Parameter(Mandatory)][string] $EnvironmentId,
        [int] $TimeoutSec = 2700,
        [int] $PollSec = 30
    )
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while ($sw.Elapsed.TotalSeconds -lt $TimeoutSec) {
        $state = $null
        try {
            $env = (Invoke-FabricRest -Token $Token -Method GET -Path "/workspaces/$WorkspaceId/environments/$EnvironmentId").Body
            $state = $env.properties.publishDetails.state
        }
        catch {}
        if ($state -eq 'Success') {
            Write-Host ("  environment published (after {0:mm\:ss})." -f $sw.Elapsed) -ForegroundColor Green
            return $true
        }
        if ($state -in 'Failed', 'Cancelled') { Write-Host "  [!] Environment publish state: $state." -ForegroundColor Yellow; return $false }
        Write-Host ("  ... still publishing (state: {0}); {1:mm\:ss} elapsed, checking again in {2}s..." -f $(if ($state) { $state } else { 'unknown' }), $sw.Elapsed, $PollSec) -ForegroundColor DarkGray
        Start-Sleep -Seconds $PollSec
    }
    Write-Host ("  [!] Environment still publishing after {0:mm\:ss}; giving up the wait." -f $sw.Elapsed) -ForegroundColor Yellow
    return $false
}

# ---------------------------------------------------------------------------
# Teardown emitter. Called twice during deploy:
#   1) right after RG create  -> RG-only teardown (delete the resource group).
#   2) after the workspace exists -> adds the Fabric workspace delete.
# The second call overwrites teardown.ps1; teardown.cmd is written once.
#
# Emitting EARLY matters: phases 09-12 include a long manual portal pause, and
# the F8 capacity + AHDS are already deployed by phase 08. If the user aborts
# (Ctrl-C) during the pause, an RG-only teardown is already on disk to stop the
# bill - they don't have to hand-delete from the portal.
# ---------------------------------------------------------------------------
function Write-Teardown {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $Rg,
        [Parameter(Mandatory)][string] $Sub,
        [Parameter(Mandatory)][string] $Tenant,
        [string] $DeployedBy = '',
        [string] $WorkspaceId = '',
        [string] $WorkspaceName = '',
        [string] $Capacity = '',
        [string[]] $ConnectionIds = @()
    )
    $teardownPath = Join-Path $PSScriptRoot 'teardown.ps1'

    # Emit the connection ids this deploy created so teardown can DELETE them.
    # Fabric connections are TENANT-level (not in the resource group / workspace),
    # so dropping the RG + workspace leaves them behind as orphans. Retail records
    # + deletes its connections the same way; healthcare must too, otherwise stale
    # 'contoso-fhirexport-*' connections pile up and a later deploy can match a
    # mismatched one (DMTSConnectionServerAndTargetPathMismatch).
    $connLines = if ($ConnectionIds -and $ConnectionIds.Count -gt 0) {
        ($ConnectionIds | ForEach-Object { "    '$_'" }) -join ",`r`n"
    } else { '' }

    $teardownBody = @"
# Auto-generated by deploy.ps1 on $(Get-Date -Format o)
# Tears down EXACTLY what this deploy created: the Fabric workspace (if one was
# created), then the resource group (F8 capacity, AHDS / FHIR, storage). Other
# workspaces / resources are left alone.
#Requires -Version 7.0
`$ErrorActionPreference = 'Continue'
Set-Location `$env:TEMP

`$ResourceGroup  = '$Rg'
`$Subscription   = '$Sub'
`$TenantId       = '$Tenant'
`$DeployedByUser = '$DeployedBy'
`$WorkspaceId    = '$WorkspaceId'
`$WorkspaceName  = '$WorkspaceName'
`$CapacityName   = '$Capacity'
`$ConnectionIds = @(
$connLines
)

`$logDir = Join-Path `$PSScriptRoot 'logs'
New-Item -ItemType Directory -Force -Path `$logDir | Out-Null
`$logPath = Join-Path `$logDir ("teardown-{0}.log" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
try { Start-Transcript -Path `$logPath | Out-Null } catch {}

`$ctx = try { az account show -o json 2>`$null | ConvertFrom-Json } catch { `$null }
if (-not `$ctx) {
    Write-Host 'Not signed in to Azure CLI. Launching az login...' -ForegroundColor Yellow
    az login --tenant `$TenantId | Out-Null
    `$ctx = try { az account show -o json 2>`$null | ConvertFrom-Json } catch { `$null }
}
if (`$ctx -and `$ctx.tenantId -ne `$TenantId) {
    Write-Host "WARNING: signed into tenant `$(`$ctx.tenantId), expected `$TenantId." -ForegroundColor Yellow
    `$r = Read-Host "Run 'az login --tenant `$TenantId' now? [y/N]"
    if (`$r -match '^(y|yes)`$') { az login --tenant `$TenantId | Out-Null; `$ctx = az account show -o json 2>`$null | ConvertFrom-Json }
}
if (`$ctx -and `$ctx.id -ne `$Subscription) { az account set --subscription `$Subscription 2>`$null | Out-Null }

Write-Host ''
Write-Host 'About to PERMANENTLY DELETE:' -ForegroundColor Yellow
Write-Host "  Subscription: `$Subscription"
Write-Host "  Tenant:       `$TenantId"
if (`$WorkspaceId) { Write-Host "  Fabric ws:    `$WorkspaceName (`$WorkspaceId)" }
if (`$ConnectionIds.Count -gt 0) { Write-Host "  Connections:  `$(`$ConnectionIds.Count) Fabric cloud connection(s)" }
Write-Host "  Resource grp: `$ResourceGroup (F8 capacity, AHDS / FHIR, storage)"
Write-Host ''
`$ans = Read-Host 'Type YES to proceed'
if (`$ans -ne 'YES') { Write-Host 'Cancelled.'; try { Stop-Transcript | Out-Null } catch {}; exit 0 }

# Fabric workspace FIRST, resource group SECOND. The RG holds the F8 capacity;
# if the RG is dropped before the workspace, the capacity vanishes and the
# workspace is orphaned (Fabric REST needs an attached capacity to delete a
# workspace, so it can't be cleaned up without standing up a new one). So if the
# workspace delete fails we ABORT and leave the RG (capacity) intact for a rerun.
if (`$WorkspaceId) {
    `$helper = Join-Path `$PSScriptRoot 'scripts\Fabric.ps1'
    if (-not (Test-Path `$helper)) {
        Write-Host 'Fabric.ps1 helper missing (package folder deleted?). Cannot delete the' -ForegroundColor Red
        Write-Host 'workspace via REST without it, and dropping the RG now would orphan it.' -ForegroundColor Red
        Write-Host "Delete workspace `$WorkspaceName by hand at https://app.fabric.microsoft.com," -ForegroundColor Yellow
        Write-Host "then run:  az group delete --name `$ResourceGroup --yes --no-wait" -ForegroundColor Yellow
        try { Stop-Transcript | Out-Null } catch {}
        Read-Host 'Press Enter to exit'
        exit 1
    }
    . `$helper
    Set-FabricTenant -TenantId `$TenantId
    `$tok = Get-FabricToken
    `$wsDeleted = `$false
    `$wait = 15  # exp backoff: 15,30,60,120,120,120
    for (`$attempt = 1; `$attempt -le 6; `$attempt++) {
        try {
            Invoke-FabricRest -Token `$tok -Method DELETE -Path "/workspaces/`$WorkspaceId" | Out-Null
            Write-Host "Deleted Fabric workspace `$WorkspaceName (`$WorkspaceId)" -ForegroundColor Green
            `$wsDeleted = `$true
            break
        } catch {
            `$msg = `$_.ToString()
            if (`$msg -match 'WorkspaceNotFound|404|401 \(Unauthorized\)|User is not authorized') {
                Write-Host 'Workspace already gone.' -ForegroundColor DarkGray
                `$wsDeleted = `$true
                break
            }
            if (`$attempt -lt 6) {
                Write-Host "  workspace delete attempt `$attempt/6 failed; retrying in `${wait}s..." -ForegroundColor DarkYellow
                Start-Sleep -Seconds `$wait
                `$wait = [Math]::Min(120, `$wait * 2)
                continue
            }
            Write-Host "  FAILED to delete workspace `${WorkspaceName}: `$msg" -ForegroundColor Red
        }
    }
    if (-not `$wsDeleted) {
        Write-Host ''
        Write-Host 'ABORTING TEARDOWN.' -ForegroundColor Red
        Write-Host "Fabric workspace `$WorkspaceName failed to delete." -ForegroundColor Red
        Write-Host 'The resource group (with the F8 capacity) has NOT been touched, so the' -ForegroundColor Yellow
        Write-Host 'workspace is not orphaned. Wait a minute, then re-run teardown.cmd.' -ForegroundColor Yellow
        try { Stop-Transcript | Out-Null } catch {}
        Read-Host 'Press Enter to exit'
        exit 1
    }
}

# Delete the Fabric cloud connections this deploy created. Connections are
# TENANT-level, so the RG + workspace deletes don't remove them -- they orphan.
# Only the ids this deploy recorded are removed (no tenant-wide sweep).
# Best-effort: never blocks the RG drop.
if (`$ConnectionIds.Count -gt 0) {
    `$helper = Join-Path `$PSScriptRoot 'scripts\Fabric.ps1'
    if (Test-Path `$helper) {
        if (-not (Get-Command Invoke-FabricRest -ErrorAction SilentlyContinue)) { . `$helper; Set-FabricTenant -TenantId `$TenantId }
        if (-not `$tok) { `$tok = Get-FabricToken }
        Write-Host 'Deleting the Fabric cloud connection(s) this deploy created...' -ForegroundColor Cyan
        foreach (`$cid in `$ConnectionIds) {
            if (-not `$cid) { continue }
            try {
                Invoke-FabricRest -Token `$tok -Method DELETE -Path "/connections/`$cid" | Out-Null
                Write-Host "  deleted connection `$cid" -ForegroundColor Green
            } catch {
                Write-Host "  skip connection `${cid}: `$_" -ForegroundColor DarkYellow
            }
        }
    } else {
        Write-Host 'Fabric.ps1 helper missing; cannot delete cloud connections. Delete these by hand in Fabric (Manage connections):' -ForegroundColor DarkYellow
        foreach (`$cid in `$ConnectionIds) { Write-Host "  `$cid" -ForegroundColor DarkYellow }
    }
}

# RG delete is fire-and-forget (--no-wait): submit the delete and return instead
# of blocking for the several minutes it takes to complete.
Write-Host 'Deleting resource group (async)...' -ForegroundColor Yellow
Write-Host "  `$ResourceGroup" -ForegroundColor Green
`$out = az group delete --name `$ResourceGroup --yes --no-wait 2>&1
if (`$LASTEXITCODE -ne 0) {
    Write-Host 'Resource group delete submit FAILED:' -ForegroundColor Red
    `$out | ForEach-Object { Write-Host `$_ -ForegroundColor Red }
    Write-Host 'Resource group was NOT deleted. Investigate the error above and re-run teardown.' -ForegroundColor Yellow
    try { Stop-Transcript | Out-Null } catch {}
    Read-Host 'Press Enter to exit'
    exit 1
}
Write-Host ''
Write-Host 'Teardown initiated. Resource group deletion runs in the background.' -ForegroundColor Green
Write-Host 'The F8 capacity stops billing once the delete completes (usually a few minutes).' -ForegroundColor Green
Write-Host "If the RG still exists after ~1 hour, re-run: az group delete --name `$ResourceGroup --yes" -ForegroundColor DarkGray
try { Stop-Transcript | Out-Null } catch {}
Read-Host 'Press Enter to exit'
"@
    Set-Content -Path $teardownPath -Value $teardownBody -Encoding UTF8

    # teardown.cmd: tiny static launcher next to teardown.ps1. Content never
    # varies between calls, so write it once (Test-Path guard).
    $teardownCmdPath = Join-Path $PSScriptRoot 'teardown.cmd'
    if (-not (Test-Path $teardownCmdPath)) {
        $teardownCmdBody = @"
@echo off
REM Launcher for teardown.ps1 (pwsh 7 via -Command so Read-Host works).
set TEARDOWN_PS1=%~dp0teardown.ps1
cd /d %TEMP%
if not exist "%TEARDOWN_PS1%" (
    echo Teardown script not found at %TEARDOWN_PS1%
    echo If your resource group still exists, delete it manually:
    echo   az group delete --name $Rg --yes
    pause
    exit /b 1
)
pwsh -NoLogo -NoProfile -ExecutionPolicy Bypass -Command "& '%TEARDOWN_PS1%'"
set TEARDOWN_EXIT=%errorlevel%
if %TEARDOWN_EXIT% NEQ 0 (
    echo.
    echo Teardown failed. Press any key to close.
    pause >nul
)
exit /b %TEARDOWN_EXIT%
"@
        Set-Content -Path $teardownCmdPath -Value $teardownCmdBody -Encoding ASCII
    }
}

# ---------------------------------------------------------------------------
# Phases
# ---------------------------------------------------------------------------
Write-Host "Provisioning healthcare estate in '$ResourceGroup' ($Location)"
if (-not (Test-Path $SeedDir))      { throw "Seed dir not found: $SeedDir" }
if (-not (Test-Path $StorageBicep)) { throw "Missing $StorageBicep" }
if (-not (Test-Path $FhirBicep))    { throw "Missing $FhirBicep" }

Invoke-Phase "00 Preflight" -EstSeconds 19 {
    $acct = (Invoke-AzWithRetry -Label 'az account show' { az account show --query "{sub:name, tenant:tenantId, id:id}" -o json }) | ConvertFrom-Json
    Write-Host "subscription: $($acct.sub)"
    # Register tenant + sub up front so Invoke-AzWithRetry can re-login
    # interactively if a token expires partway through a long deploy.
    $script:Tenant         = $acct.tenant
    $script:SubId          = $acct.id
    $script:DeployTenantId = $acct.tenant
    az extension show -n healthcareapis -o none 2>$null
    if ($LASTEXITCODE -ne 0) {
        Invoke-AzWithRetry -Label 'az extension add healthcareapis' { az extension add -n healthcareapis -o none } | Out-Null
    }
    $providers = @("Microsoft.HealthcareApis", "Microsoft.Storage")
    if (-not $SkipFabric) { $providers += "Microsoft.Fabric" }
    foreach ($ns in $providers) {
        $state = Invoke-AzWithRetry -Label "az provider show $ns" { az provider show --namespace $ns --query registrationState -o tsv }
        if ($state -ne "Registered") {
            Write-Host "registering provider $ns ..."
            Invoke-AzWithRetry -Label "az provider register $ns" { az provider register --namespace $ns --wait } | Out-Null
        }
    }
    # Identify the deployer WITHOUT calling MS Graph. 'az ad signed-in-user show'
    # hits Graph, which on this tenant keeps firing a CAE 'InteractionRequired /
    # TokenCreatedWithOutdatedPolicies' challenge that a fresh 'az login' does NOT
    # clear (known az CLI bug). The ARM access token already carries the caller's
    # object id (oid) and UPN (upn / preferred_username) as claims, so decode those
    # from the JWT instead — no Graph round-trip, no CAE.
    $armToken = (Invoke-AzWithRetry -Label 'arm access token' {
        az account get-access-token --resource https://management.azure.com --query accessToken -o tsv
    } | Out-String).Trim()
    $payloadSeg = $armToken.Split('.')[1].Replace('-', '+').Replace('_', '/')
    switch ($payloadSeg.Length % 4) { 2 { $payloadSeg += '==' } 3 { $payloadSeg += '=' } }
    $claims = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($payloadSeg)) | ConvertFrom-Json
    $script:Me    = $claims.oid
    $script:MeUpn = $claims.upn
    if (-not $script:MeUpn) { $script:MeUpn = $claims.preferred_username }
    if (-not $script:MeUpn) { $script:MeUpn = $claims.unique_name }
    if (-not $script:Me)    { throw "Could not read deployer object id (oid) from the ARM access token." }
    Write-Host "deployer objectId: $($script:Me)"
    Write-Host "deployer UPN:      $($script:MeUpn)"
}

Invoke-Phase "01 Resource group" -EstSeconds 4 {
    Invoke-AzWithRetry -Label 'az group create' { az group create -n $ResourceGroup -l $Location -o none } | Out-Null
}

# Emit an RG-only teardown the moment the RG exists, so an abort/crash after
# this point (incl. the manual portal pause in phase 10, by which time the F8
# capacity is already billing) still leaves a working teardown on disk.
Write-Teardown -Rg $ResourceGroup -Sub $script:SubId -Tenant $script:Tenant -DeployedBy $script:MeUpn
Write-Host "teardown.cmd written (RG-only; refreshed once the Fabric workspace exists)." -ForegroundColor DarkGray

Invoke-Phase "02 Storage (bicep, sync)" -EstSeconds 45 {
    $name = "contoso-health-storage-$(Get-Date -Format 'yyyyMMddHHmmss')"
    # Keep stdout (JSON) clean: let az warnings/errors flow to the console via
    # stderr instead of merging them into the output we parse.
    $out = Invoke-AzWithRetry -Label 'storage bicep deploy' {
        az deployment group create --name $name --resource-group $ResourceGroup `
            --template-file $StorageBicep `
            --parameters resourcePrefix=$ResourcePrefix location=$Location deployerObjectId=$script:Me `
            --query properties.outputs -o json
    }
    $o = ($out | Out-String | ConvertFrom-Json)
    $script:StorageAccount = $o.storageAccountName.value
    Write-Host "storage account: $($script:StorageAccount)"
}

Invoke-Phase "03 Launch FHIR + Fabric capacity (bicep, async)" -EstSeconds 11 {
    # --no-wait returns immediately so the seed upload can overlap the ~6 min
    # FHIR service create. Import/export + auth config are baked into the
    # template, so there is no separate post-create config step.
    #
    # The Fabric F8 capacity is provisioned by this SAME deployment (fhir.bicep)
    # so the whole estate lands in one ARM operation - it provisions in parallel
    # with the FHIR service and lands in the same region. The analytics
    # workspace is still created post-deploy (phase 08) via the Fabric REST API,
    # since workspaces are a Fabric (not ARM) resource.
    $script:FhirDeployName = "contoso-health-fhir-$(Get-Date -Format 'yyyyMMddHHmmss')"
    $deployFabric = (-not $SkipFabric).ToString().ToLower()
    Invoke-AzWithRetry -Label 'launch FHIR + Fabric bicep' {
        az deployment group create --no-wait --name $script:FhirDeployName --resource-group $ResourceGroup `
            --template-file $FhirBicep `
            --parameters resourcePrefix=$ResourcePrefix location=$Location deployerObjectId=$script:Me fhirServiceName=$FhirServiceName adminUserPrincipalName=$script:MeUpn deployFabric=$deployFabric `
            -o none
    } | Out-Null
    Write-Host "FHIR + Fabric deployment '$($script:FhirDeployName)' launched (running in background)."
}

Invoke-Phase "04 Upload seed (parallel to FHIR)" -EstSeconds 24 {
    # Storage RBAC for the deployer was created in storage.bicep; retry to
    # absorb role-assignment propagation lag. This whole phase overlaps the
    # FHIR provision, so the retries are effectively free.
    $uploaded = $false
    for ($attempt = 1; $attempt -le 8; $attempt++) {
        az storage blob upload-batch --account-name $script:StorageAccount --auth-mode login `
            -d $ImportContainer -s $SeedDir --pattern "*.ndjson" --overwrite -o none 2>$null
        if ($LASTEXITCODE -eq 0) { $uploaded = $true; break }
        Write-Host "  upload attempt $attempt failed (RBAC propagating?), retrying in 15s ..."
        Start-Sleep -Seconds 15
    }
    if (-not $uploaded) { throw "seed upload to blob failed after retries" }
    $script:Blobs = az storage blob list --account-name $script:StorageAccount --auth-mode login -c $ImportContainer `
        --query "[].name" -o json | ConvertFrom-Json
    Write-Host "uploaded $($script:Blobs.Count) NDJSON files"
}

Invoke-Phase "05 Wait for FHIR deployment" -EstSeconds 338 {
    while ($true) {
        $state = az deployment group show -n $script:FhirDeployName -g $ResourceGroup --query properties.provisioningState -o tsv 2>$null
        if ($state -eq "Succeeded") { break }
        if ($state -eq "Failed" -or $state -eq "Canceled") {
            az deployment operation group list -g $ResourceGroup -n $script:FhirDeployName `
                --query "[?properties.provisioningState=='Failed'].{Resource:properties.targetResource.resourceName, Code:properties.statusMessage.error.code, Message:properties.statusMessage.error.message}" `
                -o table 2>&1 | ForEach-Object { Write-Host $_ -ForegroundColor Yellow }
            throw "FHIR deployment $state"
        }
        Write-Host "  ... FHIR provisioning ($state)"
        Start-Sleep -Seconds 15
    }
    $o = (Invoke-AzWithRetry -Label 'read FHIR deploy outputs' { az deployment group show -n $script:FhirDeployName -g $ResourceGroup --query properties.outputs -o json }) | ConvertFrom-Json
    $script:FhirUrl = $o.fhirServiceUrl.value
    $script:FhirMsi = $o.fhirPrincipalId.value
    if (-not $SkipFabric) { $script:FabricCapacityName = $o.capacityName.value }
    Write-Host "FHIR endpoint: $($script:FhirUrl)"
    Write-Host "FHIR MSI principalId: $($script:FhirMsi)"
}

Invoke-Phase "06 FHIR `$import" -EstSeconds 135 {
    # Build Parameters: one input entry per blob (type parsed from file name).
    $inputs = @()
    foreach ($b in $script:Blobs) {
        $type = [System.IO.Path]::GetFileNameWithoutExtension($b)
        $inputs += @{
            name = "input"
            part = @(
                @{ name = "type"; valueString = $type }
                @{ name = "url";  valueUri = "https://$($script:StorageAccount).blob.core.windows.net/$ImportContainer/$b" }
            )
        }
    }
    $params = @{
        resourceType = "Parameters"
        parameter    = @(
            @{ name = "inputFormat";   valueString = "application/fhir+ndjson" }
            @{ name = "mode";          valueString = "IncrementalLoad" }
            @{ name = "storageDetail"; part = @(@{ name = "type"; valueString = "azure-blob" }) }
        ) + $inputs
    }
    $body = $params | ConvertTo-Json -Depth 10

    # Belt-and-suspenders: fhir.bicep already grants the FHIR MSI Storage Blob
    # Data Contributor, but assert it here too (idempotent) so a bicep timing
    # race can't leave import without blob access. Use --assignee-object-id +
    # --assignee-principal-type so az does NOT try to resolve the freshly
    # created MSI through Graph (that lookup lags for new identities). Then give
    # the data-plane RBAC a head start before the first import attempt.
    if ($script:FhirMsi) {
        $storageId = "/subscriptions/$($script:SubId)/resourceGroups/$ResourceGroup/providers/Microsoft.Storage/storageAccounts/$($script:StorageAccount)"
        Invoke-AzWithRetry -Label 'grant FHIR MSI Storage Blob Data Contributor' -AllowNonZeroExit {
            az role assignment create --assignee-object-id $script:FhirMsi --assignee-principal-type ServicePrincipal `
                --role "Storage Blob Data Contributor" --scope $storageId -o none
        } | Out-Null
        Write-Host "  asserted FHIR MSI ($($script:FhirMsi)) -> Storage Blob Data Contributor on $($script:StorageAccount)"
        Write-Host "  waiting 45s for storage data-plane RBAC to settle before import..."
        Start-Sleep -Seconds 45
    }

    # The FHIR MSI's Storage Blob Data Contributor assignment can still take a
    # few minutes to reach the storage DATA plane. Import accepts the job (202)
    # immediately, then fails server-side with a 403 "Failed to get properties of
    # blob ..." until RBAC lands. On such a failure we CANCEL the failed import
    # operation and re-run: AHDS otherwise dedups a re-POSTed $import back to the
    # last (terminal-failed) operation, so without the cancel the retry just
    # re-polls the same dead job (operation id never advances past /import/1).
    $imported      = $false
    $maxImportRuns = 8
    for ($run = 1; $run -le $maxImportRuns; $run++) {
        # --- kickoff (202 = job accepted) ---
        $contentLocation = $null
        for ($attempt = 1; $attempt -le 6; $attempt++) {
            $r = Invoke-Fhir -Method Post -Path "/`$import" -Body $body -ExtraHeaders @{ Prefer = "respond-async" }
            if ($r.StatusCode -eq 202) {
                $contentLocation = $r.Headers["Content-Location"]
                if ($contentLocation -is [array]) { $contentLocation = $contentLocation[0] }
                break
            }
            $detail = (ConvertFrom-FhirContent $r | ConvertTo-Json -Depth 5 -Compress)
            Write-Host "  import kickoff attempt $attempt -> HTTP $($r.StatusCode): $detail"
            Start-Sleep -Seconds 15
        }
        if (-not $contentLocation) { throw "`$import did not start (HTTP 202 never returned)." }
        Write-Host "import operation: $contentLocation"

        # --- poll to completion ---
        $opPath     = $contentLocation.Substring($script:FhirUrl.Length)
        $failDetail = ''
        while ($true) {
            Start-Sleep -Seconds 10
            $p = Invoke-Fhir -Method Get -Path $opPath
            if ($p.StatusCode -eq 200) {
                $j = ConvertFrom-FhirContent $p
                Write-Host "--- imported ---"
                $j.output | ForEach-Object { "  {0,-26} {1}" -f $_.type, $_.count }
                if ($j.PSObject.Properties.Name -contains "error" -and $j.error) {
                    $errCount = ($j.error | Measure-Object -Property count -Sum).Sum
                    Write-Host "--- errors: $errCount ---" -ForegroundColor Yellow
                }
                $imported = $true
                break
            }
            elseif ($p.StatusCode -eq 202) {
                Write-Host "  ... import running"
            }
            else {
                $failDetail = (ConvertFrom-FhirContent $p | ConvertTo-Json -Depth 5 -Compress)
                break
            }
        }
        if ($imported) { break }

        # Operation failed. If it's a blob-access / RBAC-propagation failure,
        # cancel the failed operation (so AHDS starts a NEW import instead of
        # handing back this terminal-failed one), wait, then re-run. Anything
        # else is a real error.
        $isPropagation = $failDetail -match 'Failed to get properties of blob|AuthorizationPermissionMismatch|AuthorizationFailure|Forbidden|\b403\b|not authorized|does not have'
        if ($isPropagation -and $run -lt $maxImportRuns) {
            # Cancel the poisoned operation so the next $import gets a fresh id.
            try { Invoke-Fhir -Method Delete -Path $opPath | Out-Null } catch {}
            $delay = [int][Math]::Min(60, 20 * $run)
            Write-Host "  import failed (FHIR MSI -> storage RBAC still propagating?); cancelled op, re-running import $run/$maxImportRuns in ${delay}s" -ForegroundColor DarkYellow
            Write-Host "    $failDetail" -ForegroundColor DarkGray
            Start-Sleep -Seconds $delay
            continue
        }
        throw "import failed: $failDetail"
    }
    if (-not $imported) { throw "`$import did not complete after $maxImportRuns runs." }
}

if (-not $SkipExport) {
    Invoke-Phase "07 FHIR `$export" -EstSeconds 42 {
        $r = Invoke-Fhir -Method Get -Path "/`$export?_container=$ExportContainer" -ExtraHeaders @{ Accept = "application/fhir+json"; Prefer = "respond-async" }
        if ($r.StatusCode -ne 202) {
            $detail = (ConvertFrom-FhirContent $r | ConvertTo-Json -Depth 5 -Compress)
            throw "`$export did not start: HTTP $($r.StatusCode): $detail"
        }
        $contentLocation = $r.Headers["Content-Location"]
        if ($contentLocation -is [array]) { $contentLocation = $contentLocation[0] }
        Write-Host "export operation: $contentLocation"
        $opPath = $contentLocation.Substring($script:FhirUrl.Length)
        while ($true) {
            Start-Sleep -Seconds 10
            $p = Invoke-Fhir -Method Get -Path $opPath
            if ($p.StatusCode -eq 200) {
                $j = ConvertFrom-FhirContent $p
                Write-Host "export complete. $($j.output.Count) files written to container '$ExportContainer'."
                break
            }
            elseif ($p.StatusCode -eq 202) { Write-Host "  ... export running" }
            else {
                $detail = (ConvertFrom-FhirContent $p | ConvertTo-Json -Depth 5 -Compress)
                throw "export poll failed: HTTP $($p.StatusCode): $detail"
            }
        }
    }
}

if (-not $SkipFabric) {
    Invoke-Phase "08 Fabric workspace" -EstSeconds 34 {
        # The F8 capacity was provisioned by the phase 03 deployment (fhir.bicep)
        # and confirmed Succeeded in phase 05, which also captured its name.
        # Create the analytics workspace bound to it via the Fabric REST API.
        Write-Host "Fabric capacity: $($script:FabricCapacityName)"

        Set-FabricTenant -TenantId $script:Tenant
        $tok = Get-FabricToken

        # Capacity may take a few seconds to surface in the Fabric tenant after ARM reports Succeeded.
        $capGuid = $null
        for ($i = 1; $i -le 12; $i++) {
            try { $capGuid = Get-FabricCapacityGuid -Token $tok -CapacityName $script:FabricCapacityName; break }
            catch {
                if ($i -eq 12) { throw }
                Write-Host "  capacity not visible in Fabric yet (attempt $i/12); waiting 10s..."
                Start-Sleep -Seconds 10
            }
        }
        Write-Host "Fabric capacity GUID: $capGuid"

        $ws = New-FabricWorkspace -Token $tok -Name $FabricWorkspace -CapacityId $capGuid `
            -Description "Contoso Healthcare - FHIR analytics (medallion over FHIR `$export)"
        $script:FabricWorkspaceId = $ws.id
        Write-Host "workspace: $($ws.displayName) (id=$($ws.id))"

        # Provision the workspace identity and grant it Storage Blob Data Reader
        # on the export storage NOW - not in phase 11. Azure data-plane RBAC can
        # take several minutes to reach the blob plane; granting here lets it
        # settle during the HDS item create (09) and the multi-minute manual
        # foundations deploy (10), so the phase-11 connection test AND shortcut
        # validation see a fully-propagated grant (this is how the retail vertical
        # avoids the "Access to target location ... denied" shortcut failure).
        $script:WsPrincipal = $null
        $script:WsGranted   = $false
        try {
            $pi = Invoke-FabricRest -Token $tok -Method POST -Path "/workspaces/$($script:FabricWorkspaceId)/provisionIdentity"
            if ($pi.Status -eq 202 -and $pi.OperationLocation) { Wait-FabricOperation -Token $tok -OperationUrl $pi.OperationLocation | Out-Null }
            $wsInfo = (Invoke-FabricRest -Token $tok -Method GET -Path "/workspaces/$($script:FabricWorkspaceId)").Body
            try { $script:WsPrincipal = $wsInfo.workspaceIdentity.servicePrincipalId } catch {}
        }
        catch {
            Write-Host "  [!] Could not provision the workspace identity now; phase 11 will retry. ($($_.Exception.Message))" -ForegroundColor DarkYellow
        }
        if ($script:WsPrincipal) {
            $storageScope = "/subscriptions/$($script:SubId)/resourceGroups/$ResourceGroup/providers/Microsoft.Storage/storageAccounts/$($script:StorageAccount)"
            for ($ra = 1; $ra -le 6; $ra++) {
                az role assignment create --assignee-object-id $script:WsPrincipal --assignee-principal-type ServicePrincipal `
                    --role "Storage Blob Data Reader" --scope $storageScope -o none 2>$null
                if ($LASTEXITCODE -eq 0) { $script:WsGranted = $true; break }
                Write-Host "  workspace identity role grant attempt $ra/6 (AAD replication?); retrying in 15s..." -ForegroundColor DarkYellow
                Start-Sleep -Seconds 15
            }
            if ($script:WsGranted) {
                Write-Host "  granted Storage Blob Data Reader to workspace identity ($($script:WsPrincipal)); it will propagate while you deploy foundations." -ForegroundColor Green
            }
            else {
                Write-Host "  [!] Could not grant Storage Blob Data Reader to the workspace identity yet; phase 11 will retry." -ForegroundColor Yellow
            }
        }
    }
}

# Refresh the teardown now that the workspace exists, so teardown deletes the
# workspace (and everything the portal foundations step puts inside it) before
# dropping the resource group.
if (-not $SkipFabric -and $script:FabricWorkspaceId) {
    Write-Teardown -Rg $ResourceGroup -Sub $script:SubId -Tenant $script:Tenant -DeployedBy $script:MeUpn `
        -WorkspaceId $script:FabricWorkspaceId -WorkspaceName $FabricWorkspace -Capacity $script:FabricCapacityName
    Write-Host "teardown.ps1 refreshed with the Fabric workspace id." -ForegroundColor DarkGray
}

if (-not $SkipFabric) {
    Invoke-Phase "09 Create Healthcare data solutions item" -EstSeconds 10 {
        # The HDS item is createable via REST (empty shell). Its 'foundations'
        # children (lakehouses, notebooks, pipelines) can only be provisioned by
        # the portal setup wizard - see phase 10.
        $tok = Get-FabricToken
        $hdsName = "${ResourcePrefix}healthcare"
        $existing = Get-FabricItems -Token $tok -WorkspaceId $script:FabricWorkspaceId |
            Where-Object { $_.type -eq 'Healthcaredatasolution' } | Select-Object -First 1
        if ($existing) {
            $script:HdsItemId = $existing.id
            $script:HdsName   = $existing.displayName
            Write-Host "HDS item already exists: $($existing.displayName) (id=$($existing.id))"
        }
        else {
            $body = @{ displayName = $hdsName; type = 'Healthcaredatasolution' }
            $r = Invoke-FabricRest -Token $tok -Method POST -Path "/workspaces/$($script:FabricWorkspaceId)/items" -Body $body
            if ($r.Status -eq 202 -and $r.OperationLocation) { Wait-FabricOperation -Token $tok -OperationUrl $r.OperationLocation | Out-Null }
            $item = Get-FabricItems -Token $tok -WorkspaceId $script:FabricWorkspaceId |
                Where-Object { $_.type -eq 'Healthcaredatasolution' } | Select-Object -First 1
            if (-not $item) { throw "HDS item create did not surface an item in the workspace." }
            $script:HdsItemId = $item.id
            $script:HdsName   = $item.displayName
            Write-Host "HDS item created: $($item.displayName) (id=$($item.id))"
        }
    }

    Invoke-Phase "10 Deploy Data Foundations (portal, manual)" -EstSeconds 175 {
        # No supported REST API deploys HDS foundations; it's a portal-only
        # wizard. Pause here, hand the user the direct link, and resume once they
        # confirm. After they confirm, discover the provisioned children.
        $wsUrl = "https://app.fabric.microsoft.com/groups/$($script:FabricWorkspaceId)/list"
        $hdsLabel = if ($script:HdsName) { $script:HdsName } else { "${ResourcePrefix}healthcare" }
        # Deep-link straight into the setup wizard ('health-data-manager' is the
        # HDS item route, '/wizard' opens 'Setup your solution' already started).
        # Falls back to the workspace list if we don't have an item id.
        $wizardUrl = if ($script:HdsItemId) {
            "https://app.fabric.microsoft.com/groups/$($script:FabricWorkspaceId)/health-data-manager/$($script:HdsItemId)/wizard?experience=power-bi"
        }
        else { $wsUrl }
        Write-Host ""
        Write-Host "  ============================================================" -ForegroundColor Yellow
        Write-Host "  ACTION REQUIRED - deploy Healthcare data foundations:" -ForegroundColor Yellow
        Write-Host "    1. (optional) Open your Fabric workspace '$FabricWorkspace':" -ForegroundColor Yellow
        Write-Host "       $wsUrl" -ForegroundColor Yellow
        Write-Host "    2. Open the setup wizard for '$hdsLabel' (already started):" -ForegroundColor Yellow
        Write-Host "       $wizardUrl" -ForegroundColor Yellow
        Write-Host "    3. Step through the wizard - just Next through each page:" -ForegroundColor Yellow
        Write-Host "         a. 'Data Foundations' is checked by default        -> Next" -ForegroundColor Yellow
        Write-Host "         b. Do NOT enable sample data                        -> Next" -ForegroundColor Yellow
        Write-Host "         c. No additional capabilities (added later)         -> Next" -ForegroundColor Yellow
        Write-Host "         d. No settings to configure                         -> Next" -ForegroundColor Yellow
        Write-Host "         e. Check the box to accept the terms of service     -> Deploy" -ForegroundColor Yellow
        Write-Host "    4. Wait for it to finish (do NOT close the portal tab while it runs)." -ForegroundColor Yellow
        Write-Host "       NOTE: the spinner does NOT auto-update. If it's still" -ForegroundColor Yellow
        Write-Host "       spinning past ~3 min, REFRESH the page - it's likely done." -ForegroundColor Yellow
        Write-Host "  ============================================================" -ForegroundColor Yellow
        Write-Host ""

        # Loop until foundations is actually deployed. Pressing Enter too early
        # (before the wizard finishes) used to let the deploy march on and fail
        # downstream. Instead we re-check the workspace each time and keep the
        # user in the loop until the key children (bronze lakehouse + ingestion
        # pipeline) exist. They can close the terminal window to bail out.
        $tok = $null
        while ($true) {
            Read-Host "When Data Foundations has finished deploying, press Enter to continue (or close this window to exit)"
            $tok = Get-FabricToken
            $items = Get-FabricItems -Token $tok -WorkspaceId $script:FabricWorkspaceId
            $script:BronzeLakehouse = $items | Where-Object { $_.type -eq 'Lakehouse'     -and $_.displayName -match 'bronze' } | Select-Object -First 1
            $script:IngestPipeline  = $items | Where-Object { $_.type -eq 'DataPipeline'  -and $_.displayName -match 'ingest' } | Select-Object -First 1
            $script:AdminLakehouse  = $items | Where-Object { $_.type -eq 'Lakehouse'     -and $_.displayName -match 'admin'  } | Select-Object -First 1
            $script:ConfigNotebook  = $items | Where-Object { $_.type -eq 'Notebook'      -and $_.displayName -match 'config' } | Select-Object -First 1
            $script:HdsEnvironment  = $items | Where-Object { $_.type -eq 'Environment' } | Select-Object -First 1
            if ($script:BronzeLakehouse -and $script:IngestPipeline) { break }
            Write-Host ""
            Write-Host "  [!] Data Foundations doesn't look deployed yet - I can't see the bronze" -ForegroundColor Yellow
            Write-Host "      lakehouse / ingestion pipeline in the workspace." -ForegroundColor Yellow
            Write-Host "      Finish the wizard (click Deploy) and wait for it to complete, then" -ForegroundColor Yellow
            Write-Host "      press Enter to check again. Close this terminal window any time to exit." -ForegroundColor Yellow
            Write-Host ""
        }

        if ($script:BronzeLakehouse) { Write-Host "bronze lakehouse:   $($script:BronzeLakehouse.displayName) (id=$($script:BronzeLakehouse.id))" }
        if ($script:IngestPipeline) { Write-Host "ingestion pipeline: $($script:IngestPipeline.displayName) (id=$($script:IngestPipeline.id))" }
        if ($script:AdminLakehouse) { Write-Host "admin lakehouse:    $($script:AdminLakehouse.displayName) (id=$($script:AdminLakehouse.id))" }
        else { Write-Host "  [!] No admin lakehouse found - can't auto-update the ingestion source path." -ForegroundColor Yellow }
        if ($script:ConfigNotebook) { Write-Host "config notebook:    $($script:ConfigNotebook.displayName) (id=$($script:ConfigNotebook.id))" }
        else { Write-Host "  [!] No config notebook found - can't auto-inject the scipy repair cell." -ForegroundColor Yellow }
        if ($script:HdsEnvironment) { Write-Host "spark environment:  $($script:HdsEnvironment.displayName) (id=$($script:HdsEnvironment.id))" }
        else { Write-Host "  [!] No Spark environment found - can't wait for publishing before ingestion." -ForegroundColor Yellow }
    }

    Invoke-Phase "11 OneLake shortcut to FHIR `$export" -EstSeconds 30 {
        # Best-effort: provision the workspace identity, grant it read on the
        # export storage, create an ADLS connection, then a OneLake shortcut in
        # the bronze lakehouse. If any step can't run unattended, print exact
        # portal steps so the user can finish it by hand in ~1 minute.
        $script:ShortcutDone = $false
        if (-not $script:BronzeLakehouse) {
            Write-Host "  [!] No bronze lakehouse discovered; skipping shortcut. Create it manually once foundations is deployed." -ForegroundColor Yellow
            return
        }
        $tok   = Get-FabricToken
        $dfs   = "https://$($script:StorageAccount).dfs.core.windows.net"
        $subId = $script:SubId
        $storageScope = "/subscriptions/$subId/resourceGroups/$ResourceGroup/providers/Microsoft.Storage/storageAccounts/$($script:StorageAccount)"

        $connectionId = $null
        try {
            # The workspace identity is normally provisioned + granted Storage
            # Blob Data Reader back in phase 08, so the grant has had the HDS item
            # create + the manual foundations deploy to propagate. Only do it here
            # if phase 08 couldn't (fallback).
            $wsPrincipal = $script:WsPrincipal
            if (-not $script:WsGranted) {
                if (-not $wsPrincipal) {
                    $pi = Invoke-FabricRest -Token $tok -Method POST -Path "/workspaces/$($script:FabricWorkspaceId)/provisionIdentity"
                    if ($pi.Status -eq 202 -and $pi.OperationLocation) { Wait-FabricOperation -Token $tok -OperationUrl $pi.OperationLocation | Out-Null }
                    $wsInfo = (Invoke-FabricRest -Token $tok -Method GET -Path "/workspaces/$($script:FabricWorkspaceId)").Body
                    try { $wsPrincipal = $wsInfo.workspaceIdentity.servicePrincipalId } catch {}
                }
                if ($wsPrincipal) {
                    # --assignee-object-id + explicit principal type skips the Graph
                    # lookup (which fails for a freshly-provisioned workspace identity
                    # with PrincipalNotFound) and retries to absorb AAD replication.
                    $granted = $false
                    for ($ra = 1; $ra -le 6; $ra++) {
                        az role assignment create --assignee-object-id $wsPrincipal --assignee-principal-type ServicePrincipal `
                            --role "Storage Blob Data Reader" --scope $storageScope -o none 2>$null
                        if ($LASTEXITCODE -eq 0) { $granted = $true; break }
                        Write-Host "  workspace identity role grant attempt $ra/6 (AAD replication?); retrying in 15s..." -ForegroundColor DarkYellow
                        Start-Sleep -Seconds 15
                    }
                    if ($granted) { Write-Host "  granted Storage Blob Data Reader to workspace identity ($wsPrincipal)" -ForegroundColor Green }
                    else { Write-Host "  [!] Could not grant Storage Blob Data Reader to the workspace identity; the connection test below may fail." -ForegroundColor Yellow }
                }
            }
            else {
                Write-Host "  workspace identity Storage Blob Data Reader granted in phase 08 ($wsPrincipal); propagated during foundations deploy." -ForegroundColor Green
            }

            $connBody = @{
                connectivityType  = "ShareableCloud"
                displayName       = "contoso-fhirexport-$($script:FabricWorkspaceId.Substring(0,8))"
                connectionDetails = @{
                    type           = "AzureDataLakeStorage"
                    creationMethod = "AzureDataLakeStorage"
                    parameters     = @(
                        @{ dataType = "Text"; name = "server"; value = $dfs }
                        # Scope the connection at the ACCOUNT ROOT (matches the
                        # working retail vertical). The shortcut below points at
                        # the container via its subpath; scoping the connection to
                        # a single container makes Fabric resolve container+subpath
                        # twice -> "Access to target location .../fhirexport// denied".
                        @{ dataType = "Text"; name = "path";   value = "/" }
                    )
                }
                privacyLevel      = "Organizational"
                credentialDetails = @{
                    singleSignOnType     = "None"
                    connectionEncryption = "Encrypted"
                    # ADLS + ShareableCloud + WorkspaceIdentity does NOT support
                    # skipTestConnection - the create always runs a live test, so
                    # the workspace identity must already have blob read access.
                    skipTestConnection   = $false
                    credentials          = @{
                        credentialType = "WorkspaceIdentity"
                        workspaceId    = $script:FabricWorkspaceId
                    }
                }
            }
            # The create runs a live connection test; the identity's brand-new
            # Storage Blob Data Reader grant may still be propagating, so retry.
            $connDisplayName = $connBody.displayName
            for ($cc = 1; $cc -le 6; $cc++) {
                try {
                    $cr = Invoke-FabricRest -Token $tok -Method POST -Path "/connections" -Body $connBody
                    # Connection create can return 202 + LRO (matches retail):
                    # wait for it, then re-GET the connection id by display name.
                    if ($cr.Status -eq 202 -and $cr.OperationLocation) {
                        Wait-FabricOperation -Token $tok -OperationUrl $cr.OperationLocation | Out-Null
                        $list = (Invoke-FabricRest -Token $tok -Method GET -Path "/connections").Body
                        $connectionId = ($list.value | Where-Object { $_.displayName -eq $connDisplayName } | Select-Object -First 1).id
                    }
                    else {
                        $connectionId = $cr.Body.id
                    }
                    if (-not $connectionId) { throw "connection created but id not returned" }
                    Write-Host "  created ADLS connection (id=$connectionId)" -ForegroundColor Green
                    $script:ConnectionId = $connectionId
                    # Refresh teardown immediately so it will delete this
                    # tenant-level connection even if a later step fails.
                    Write-Teardown -Rg $ResourceGroup -Sub $script:SubId -Tenant $script:Tenant -DeployedBy $script:MeUpn `
                        -WorkspaceId $script:FabricWorkspaceId -WorkspaceName $FabricWorkspace -Capacity $script:FabricCapacityName `
                        -ConnectionIds @($connectionId)
                    break
                }
                catch {
                    if ($cc -eq 6) { throw }
                    Write-Host "  connection attempt $cc/6 failed (identity grant propagating?); retry in 20s..." -ForegroundColor DarkYellow
                    Write-Host "    $($_.Exception.Message)" -ForegroundColor DarkGray
                    Start-Sleep -Seconds 20
                }
            }
        }
        catch {
            Write-Host "  [!] Could not auto-create the storage connection: $($_.Exception.Message)" -ForegroundColor Yellow
        }

        if ($connectionId) {
            # Healthcare data solutions CREATES the AHDS-FHIR folder in the bronze
            # lakehouse. The shortcut must live INSIDE it (the HDS bronze
            # FHIR-NDJSON ingestion pipeline scans
            # Files/External/Clinical/FHIR-NDJSON/AHDS-FHIR recursively). So the
            # shortcut's parent path is that AHDS-FHIR folder and its name is a
            # source identifier (we use the storage account name).
            $scParent = "Files/External/Clinical/FHIR-NDJSON/AHDS-FHIR"
            $scLeaf   = $script:StorageAccount
            $scBody = @{
                path   = $scParent
                name   = $scLeaf
                target = @{ adlsGen2 = @{ location = $dfs; subpath = "/$ExportContainer"; connectionId = $connectionId } }
            }
            # The shortcut create runs its OWN data-plane authorization check
            # against the target container with the workspace identity. The
            # identity's Storage Blob Data Reader grant can pass the connection
            # test yet still be propagating to the blob data plane when the
            # shortcut is validated (Azure data-plane RBAC can take several
            # minutes - the retail vertical naturally absorbs this because its
            # grant lands 5-15 min before its shortcut). Retry on the
            # "Unauthorized / denied / 403" class with backoff, fail fast on
            # anything else.
            for ($sc = 1; $sc -le 8; $sc++) {
                try {
                    Invoke-FabricRest -Token $tok -Method POST `
                        -Path "/workspaces/$($script:FabricWorkspaceId)/items/$($script:BronzeLakehouse.id)/shortcuts?shortcutConflictPolicy=CreateOrOverwrite" `
                        -Body $scBody | Out-Null
                    Write-Host "  OneLake shortcut '$scParent/$scLeaf' -> $dfs/$ExportContainer created." -ForegroundColor Green
                    $script:ShortcutDone = $true
                    break
                }
                catch {
                    $msg = $_.Exception.Message
                    $isAuthLag = $msg -match 'Unauthorized|denied|AuthorizationPermissionMismatch|\b403\b|not authorized'
                    if ($isAuthLag -and $sc -lt 8) {
                        $d = [int][Math]::Min(60, 15 * $sc)
                        Write-Host "  shortcut auth not propagated yet (attempt $sc/8); retry in ${d}s..." -ForegroundColor DarkYellow
                        Start-Sleep -Seconds $d
                        # refresh the Fabric token in case the wait spans expiry
                        $tok = Get-FabricToken
                        continue
                    }
                    Write-Host "  [!] Shortcut create failed: $msg" -ForegroundColor Yellow
                    break
                }
            }
        }

        if (-not $script:ShortcutDone) {
            $wsUrl = "https://app.fabric.microsoft.com/groups/$($script:FabricWorkspaceId)/list"
            $bronzeName = if ($script:BronzeLakehouse) { $script:BronzeLakehouse.displayName } else { "the bronze lakehouse (name contains 'bronze')" }
            Write-Host ""
            Write-Host "  MANUAL SHORTCUT FALLBACK:" -ForegroundColor Yellow
            Write-Host "    1. Open the workspace: $wsUrl" -ForegroundColor Yellow
            Write-Host "    2. Open the lakehouse '$bronzeName'." -ForegroundColor Yellow
            Write-Host "    3. In the Lakehouse explorer, expand 'Files' and open the folder" -ForegroundColor Yellow
            Write-Host "       that Healthcare data solutions created:" -ForegroundColor Yellow
            Write-Host "         Files/External/Clinical/FHIR-NDJSON/AHDS-FHIR" -ForegroundColor Yellow
            Write-Host "       Right-click the 'AHDS-FHIR' folder -> New shortcut" -ForegroundColor Yellow
            Write-Host "       -> Azure Data Lake Storage Gen2. The shortcut lives INSIDE" -ForegroundColor Yellow
            Write-Host "       AHDS-FHIR (that's the folder the bronze ingestion pipeline scans)." -ForegroundColor Yellow
            Write-Host "    4. URL:  $dfs" -ForegroundColor Yellow
            Write-Host "       Sub path: /$ExportContainer    (shortcut name: '$($script:StorageAccount)')" -ForegroundColor Yellow
            Write-Host "    5. Auth: Workspace identity (or your Organizational account)." -ForegroundColor Yellow
        }

        # --- Repoint the HDS bronze ingestion at the OneLake shortcut ---------
        # Healthcare data solutions defaults the *_fhir_ndjson_bronze_ingestion
        # activity's source_path_pattern at Files/Process/Clinical/FHIR-NDJSON.
        # Our FHIR $export lands under the shortcut at
        # Files/External/Clinical/FHIR-NDJSON/AHDS-FHIR (validated against the
        # README + memory: the pipeline scans that folder recursively), so
        # repoint the activity there. The config is a JSON file in the *_admin
        # lakehouse: Files/system-configurations/deploymentParametersConfiguration.json.
        # OneLake exposes it via the Blob API; a single PUT BlockBlob overwrites.
        # We do a targeted regex swap on the raw JSON so nothing else is touched.
        if ($script:AdminLakehouse) {
            try {
                $olTok = az account get-access-token --resource 'https://storage.azure.com' --query accessToken -o tsv
                if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($olTok)) { throw 'could not get a OneLake (storage) access token' }
                $olHdr  = @{ Authorization = "Bearer $olTok"; 'x-ms-version' = '2021-06-08' }
                $cfgUri = "https://onelake.blob.fabric.microsoft.com/$($script:FabricWorkspaceId)/$($script:AdminLakehouse.id)/Files/system-configurations/deploymentParametersConfiguration.json"
                # NOTE: OneLake returns the blob as application/octet-stream, so on
                # PowerShell 7 Invoke-WebRequest .Content is a byte[], NOT a string.
                # Coercing a byte[] into -replace stringifies it to "123 34 97 ..."
                # (space-joined decimals) and writing that back CORRUPTS the JSON
                # (HDS then can't parse lakehouse ids -> raw_process_movement fails
                # with is_guid(None) TypeError). Always decode to UTF-8 text first
                # and PUT the bytes back explicitly.
                $cfgContent = (Invoke-WebRequest -Method GET -Uri $cfgUri -Headers $olHdr).Content
                $rawCfg = if ($cfgContent -is [byte[]]) { [System.Text.Encoding]::UTF8.GetString($cfgContent) } else { [string]$cfgContent }
                # Normalize any Process|External (with/without /AHDS-FHIR) to the
                # validated External/AHDS-FHIR path. Idempotent on re-run.
                $newCfg = $rawCfg -replace '(/Files/)(Process|External)(/Clinical/FHIR-NDJSON)(/AHDS-FHIR)?', '${1}External${3}/AHDS-FHIR'
                if ($newCfg -ne $rawCfg) {
                    $putHdr = @{ Authorization = "Bearer $olTok"; 'x-ms-version' = '2021-06-08'; 'x-ms-blob-type' = 'BlockBlob' }
                    $putBytes = [System.Text.Encoding]::UTF8.GetBytes($newCfg)
                    Invoke-WebRequest -Method PUT -Uri $cfgUri -Headers $putHdr -Body $putBytes -ContentType 'application/json' | Out-Null
                    $m = [regex]::Match($newCfg, '"source_path_pattern"\s*:\s*"([^"]+)"')
                    if ($m.Success) { Write-Host "  source_path_pattern -> $($m.Groups[1].Value)" -ForegroundColor Green }
                    Write-Host "  updated deploymentParametersConfiguration.json in $($script:AdminLakehouse.displayName)" -ForegroundColor Green
                }
                else {
                    Write-Host "  source_path_pattern already points at Files/External/Clinical/FHIR-NDJSON/AHDS-FHIR" -ForegroundColor DarkGray
                }
            }
            catch {
                Write-Host "  [!] Could not auto-update source_path_pattern: $($_.Exception.Message)" -ForegroundColor Yellow
                Write-Host "      Manually edit Files/system-configurations/deploymentParametersConfiguration.json in '$($script:AdminLakehouse.displayName)':" -ForegroundColor Yellow
                Write-Host "      set the *_fhir_ndjson_bronze_ingestion source_path_pattern to end with /Files/External/Clinical/FHIR-NDJSON/AHDS-FHIR" -ForegroundColor Yellow
            }
        }
        else {
            Write-Host "  [!] No *_admin lakehouse discovered; cannot auto-update source_path_pattern. Edit deploymentParametersConfiguration.json by hand." -ForegroundColor Yellow
        }

        # --- scipy runtime repair cell in the config notebook -----------------
        # TEMPORARY: Fabric Runtime 1.3 HDS env ships scipy .py over an older
        # _rotation.so; the hds/dtt import dies until a forced scipy reinstall.
        # Microsoft PG has a platform fix rolling out - until it lands we inject
        # the repair cell into the *_config notebook right after the parameters
        # cell so it runs before any HDS import. See fixes/scipy-runtime-repair.md.
        # Idempotent: skips if the cell is already present.
        if ($script:ConfigNotebook) {
            try {
                $tok  = Get-FabricToken
                $nbId = $script:ConfigNotebook.id
                $gd   = Invoke-FabricRest -Token $tok -Method POST -Path "/workspaces/$($script:FabricWorkspaceId)/notebooks/$nbId/getDefinition?format=ipynb"
                $def  = $null
                if ($gd.Status -eq 202 -and $gd.OperationLocation) {
                    Wait-FabricOperation -Token $tok -OperationUrl $gd.OperationLocation | Out-Null
                    $def = (Invoke-FabricRest -Token $tok -Method GET -Path "$($gd.OperationLocation)/result").Body
                }
                else { $def = $gd.Body }

                $parts = $def.definition.parts
                $contentPart = $parts | Where-Object { $_.path -like '*.ipynb' } | Select-Object -First 1
                if (-not $contentPart) { throw 'notebook-content part not found in the definition' }
                $ipynbJson = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($contentPart.payload))

                if ($ipynbJson -match 'scipy runtime repair') {
                    Write-Host "  config notebook '$($script:ConfigNotebook.displayName)' already has the scipy repair cell" -ForegroundColor DarkGray
                }
                else {
                    # Repair cell. source is an array of lines (matches the
                    # notebook's existing cells); the first line carries the
                    # 'scipy runtime repair' idempotency marker checked above.
                    $scipySrc = @(
                        "# --- scipy runtime repair (Fabric Runtime 1.3 HDS env) ---`n",
                        "# Env ships scipy 1.17.1 python files over a 1.11.4 compiled _rotation.so (version skew),`n",
                        "# which breaks 'from scipy.spatial.transform import Rotation' used by the hds/dtt library.`n",
                        "# Force a clean, complete scipy reinstall so .py and .so agree. Idempotent + in-session.`n",
                        "try:`n",
                        "    from scipy.spatial.transform import Rotation as _scipy_rotation_probe`n",
                        "except Exception:`n",
                        "    import subprocess, sys, importlib`n",
                        "    subprocess.run([sys.executable, `"-m`", `"pip`", `"install`", `"scipy==1.17.1`",`n",
                        "                    `"--force-reinstall`", `"--no-deps`", `"-q`"], check=True)`n",
                        "    for _m in [k for k in list(sys.modules) if k == `"scipy`" or k.startswith(`"scipy.`")]:`n",
                        "        del sys.modules[_m]`n",
                        "    importlib.invalidate_caches()"
                    )
                    $cell = [pscustomobject]@{
                        cell_type       = 'code'
                        metadata        = [pscustomobject]@{}
                        source          = $scipySrc
                        outputs         = @()
                        execution_count = $null
                    }
                    $nb = $ipynbJson | ConvertFrom-Json
                    $cells = [System.Collections.Generic.List[object]]::new()
                    $cells.AddRange([object[]]$nb.cells)
                    # Insert right after the parameters-tagged cell (HDS reads its
                    # config from there); fall back to the top if none is tagged.
                    $pIdx = -1
                    for ($i = 0; $i -lt $cells.Count; $i++) {
                        $tags = $null
                        try { $tags = $cells[$i].metadata.tags } catch {}
                        if ($tags -and ($tags -contains 'parameters')) { $pIdx = $i; break }
                    }
                    if ($pIdx -ge 0) { $cells.Insert($pIdx + 1, $cell) } else { $cells.Insert(0, $cell) }
                    $nb.cells = $cells.ToArray()

                    $newIpynb = $nb | ConvertTo-Json -Depth 64
                    $contentPart.payload = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($newIpynb))
                    # Send EVERY original part back (esp. .platform); only the
                    # notebook-content payload changed (mutated in place above).
                    # CRITICAL: pass format=ipynb on updateDefinition. Without it
                    # Fabric assumes the default .py source format and the
                    # converter throws PyToIPynbFailure ("file suffix .ipynb is
                    # not supported"). Verified live against cts-health-analytics.
                    $updBody = @{ definition = @{ format = 'ipynb'; parts = $parts } }
                    $ud = Invoke-FabricRest -Token $tok -Method POST -Path "/workspaces/$($script:FabricWorkspaceId)/notebooks/$nbId/updateDefinition?format=ipynb&updateMetadata=false" -Body $updBody
                    if ($ud.Status -eq 202 -and $ud.OperationLocation) { Wait-FabricOperation -Token $tok -OperationUrl $ud.OperationLocation | Out-Null }
                    Write-Host "  injected scipy repair cell into '$($script:ConfigNotebook.displayName)'" -ForegroundColor Green
                }
            }
            catch {
                Write-Host "  [!] Could not patch the config notebook with the scipy fix: $($_.Exception.Message)" -ForegroundColor Yellow
                Write-Host "      Add it by hand - see fixes/scipy-runtime-repair.md." -ForegroundColor Yellow
            }
        }
        else {
            Write-Host "  [!] No *_config notebook discovered; skipping scipy repair injection (see fixes/scipy-runtime-repair.md)." -ForegroundColor Yellow
        }
    }

    Invoke-Phase "12 Ingestion pipeline" {
        if (-not $script:IngestPipeline) {
            Write-Host "  [!] No ingestion pipeline discovered; run it from the portal once foundations is deployed." -ForegroundColor Yellow
            return
        }
        $pipeUrl = "https://app.fabric.microsoft.com/groups/$($script:FabricWorkspaceId)/pipelines/$($script:IngestPipeline.id)"

        # Wait for the Spark environment to finish publishing BEFORE we prompt.
        # Ingestion notebooks fail until it's done, so make sure it's ready first
        # - that way whether the user runs it now OR triggers it later from the
        # web UI, it won't fail with "publishing state is running".
        if ($script:HdsEnvironment) {
            Write-Host "  The Spark environment '$($script:HdsEnvironment.displayName)' has to finish publishing"
            Write-Host "  before ingestion can run (first publish installs the HDS libraries). This"
            Write-Host "  usually takes ~5-10 min. Waiting for it now so the pipeline won't fail..."
            $tok = Get-FabricToken
            $envReady = Wait-FabricEnvironmentPublish -Token $tok -WorkspaceId $script:FabricWorkspaceId -EnvironmentId $script:HdsEnvironment.id
            if (-not $envReady) {
                Write-Host "  [!] The environment is still publishing. Do NOT run the pipeline yet - it" -ForegroundColor Yellow
                Write-Host "      will fail. Wait until it shows 'Published' in Fabric, then run it from:" -ForegroundColor Yellow
                Write-Host "      $pipeUrl" -ForegroundColor Yellow
                return
            }
        }

        $ans = Read-Host "Environment is ready. Kick off the '$($script:IngestPipeline.displayName)' ingestion pipeline now? [Y/n]"
        if ($ans -match '^(n|no)$') {
            Write-Host "  Skipped. The environment is published, so you can trigger it immediately from: $pipeUrl"
        }
        else {
            $tok = Get-FabricToken
            $r = Invoke-FabricRest -Token $tok -Method POST `
                -Path "/workspaces/$($script:FabricWorkspaceId)/items/$($script:IngestPipeline.id)/jobs/instances?jobType=Pipeline"
            if ($r.Status -in 200, 201, 202) { Write-Host "  pipeline run started. Watch it here: $pipeUrl" -ForegroundColor Green }
            else { Write-Host "  [!] Pipeline start returned HTTP $($r.Status). Run it from: $pipeUrl" -ForegroundColor Yellow }
        }
    }
}

Write-TimingSummary
Write-Host ""
Write-Host "FHIR endpoint: $($script:FhirUrl)" -ForegroundColor Green
Write-Host "Storage:       $($script:StorageAccount)" -ForegroundColor Green
if (-not $SkipFabric) {
    Write-Host "Fabric cap.:   $($script:FabricCapacityName) (F8)" -ForegroundColor Green
    Write-Host "Workspace:     $FabricWorkspace (id=$($script:FabricWorkspaceId))" -ForegroundColor Green
}
Write-Host "Teardown:      run teardown.cmd from this folder to delete everything." -ForegroundColor Green
Write-Host "Done." -ForegroundColor Green
try { Stop-Transcript | Out-Null } catch {}
