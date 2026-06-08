#Requires -Version 7.0
<#
.SYNOPSIS
    Deploys the Contoso Tech (Retail) data estate to Azure.

.DESCRIPTION
    Phase 1 deployment:
      1. Verifies Azure CLI auth and tooling
      2. Creates resource group
      3. Deploys Bicep (Azure SQL + ADLS Gen2 Storage)
      4. Applies schema.sql to the database

.PREREQUISITES
    - PowerShell 7+
    - Azure CLI (az) installed and authenticated (`az login`)
    - SqlServer PowerShell module (auto-installed if missing)
    - Contributor role on target subscription

.EXAMPLE
    .\deploy.ps1

.EXAMPLE
    .\deploy.ps1 -StartOver
    Ignores any prior crashed-deploy state file and starts fresh.
#>

[CmdletBinding()]
param(
    [switch]$StartOver  # ignore any prior crashed-deploy state file
)

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'

# -----------------------------------------------------------------------------
# Move pwsh's working directory OUT of the package folder so that nothing in
# this process keeps a handle on it. Without this, the user can't delete the
# downloaded package folder while deploy.ps1 is running (or while it's at the
# final 'Read-Host "Press Enter to exit"' prompt). All path lookups below use
# $PSScriptRoot, so the actual working directory is irrelevant for correctness.
# -----------------------------------------------------------------------------
Set-Location $env:TEMP

# -----------------------------------------------------------------------------
# Tee everything to a timestamped log so the user has a permanent record after
# the console closes (helpful for diagnosing failures).
#
# Primary log lives inside the package folder ($PSScriptRoot\logs\) so it's
# right there with deploy.cmd while the script runs. On exit we copy it to
# %LOCALAPPDATA%\Contoso\deploy-logs\ for retention -- the user is expected
# to delete the downloaded package after a run, and the retained copy survives
# that.
# -----------------------------------------------------------------------------
$logName     = "deploy-{0}.log" -f (Get-Date -Format 'yyyyMMdd-HHmmss')
$logDir      = Join-Path $PSScriptRoot 'logs'
$retainDir   = Join-Path $env:LOCALAPPDATA 'Contoso\deploy-logs'
if (-not (Test-Path $logDir))    { New-Item -ItemType Directory -Path $logDir    -Force | Out-Null }
if (-not (Test-Path $retainDir)) { New-Item -ItemType Directory -Path $retainDir -Force | Out-Null }
$logPath    = Join-Path $logDir    $logName
$retainPath = Join-Path $retainDir $logName
try { Start-Transcript -Path $logPath -Append | Out-Null } catch { }
Write-Host "Logging to $logPath" -ForegroundColor DarkGray
Write-Host "  (copied to $retainPath on exit)" -ForegroundColor DarkGray

function Complete-Log {
    try { Stop-Transcript | Out-Null } catch { }
    try { if (Test-Path $logPath) { Copy-Item -LiteralPath $logPath -Destination $retainPath -Force -ErrorAction Stop } } catch { }
}

# -----------------------------------------------------------------------------
# Deploy state file -- crash detection + reattach context.
#
# Written after every Write-Step + at terminal states (completed/failed).
# Lives in $PSScriptRoot\logs\.deploy-state.json so it survives across
# re-runs from the same package but doesn't pollute LOCALAPPDATA.
#
# We do NOT do automatic per-step resume -- the script has hundreds of
# locals ($outputs, $workspaces, $fabricToken, etc.) that would all need
# rehydration from Azure/Fabric. Instead, on next run we DETECT the prior
# crash, show the user where we died and how long ago, and let them choose
# to continue (relying on the RG-exists / workspace-exists branches that
# already make most steps idempotent) or to teardown first.
#
# Use -StartOver to skip the prompt and overwrite the prior state.
# -----------------------------------------------------------------------------
$script:StateFile     = Join-Path $logDir '.deploy-state.json'
$script:DeployId      = [guid]::NewGuid().ToString('N').Substring(0,8)
$script:CurrentStepNo = 0
$script:CurrentStep   = ''
$script:DeployStartedAt = (Get-Date).ToString('o')

function Save-DeployState {
    param(
        [ValidateSet('running','completed','failed')][string]$Status = 'running',
        [string]$FailureReason = ''
    )
    try {
        $obj = [pscustomobject]@{
            deploy_id        = $script:DeployId
            started_at       = $script:DeployStartedAt
            updated_at       = (Get-Date).ToString('o')
            status           = $Status
            current_step_no  = $script:CurrentStepNo
            current_step     = $script:CurrentStep
            failure_reason   = $FailureReason
            log_path         = $logPath
            resource_group   = if ($config) { $config.RESOURCE_GROUP } else { '' }
            subscription_id  = if ($selectedSub) { $selectedSub.id } else { '' }
            tenant_id        = if ($selectedSub) { $selectedSub.tenantId } else { '' }
        }
        $obj | ConvertTo-Json | Set-Content -Path $script:StateFile -Encoding UTF8 -ErrorAction Stop
    } catch {
        # state file is advisory; never fail the deploy because we couldn't write it
    }
}

# trap fires on any uncaught throw. Without it the script exits before
# Stop-Transcript runs and the log copy never happens, so the user loses
# the post-crash log when they delete the package folder. Save-DeployState
# records the crash so the next run shows where we died.
trap { Save-DeployState -Status 'failed' -FailureReason $_.Exception.Message; Complete-Log; break }

# -----------------------------------------------------------------------------
# Prior-deploy state detection.
#
# If a prior deploy from this package crashed (or is still running in another
# console) the state file from $logDir tells us where. Show context so the
# user isn't blindly re-running into a half-built RG. Use -StartOver to skip.
#
# Must run BEFORE the first Save-DeployState call (Write-Step writes state),
# otherwise we read back the row we just wrote and warn about ourselves.
# -----------------------------------------------------------------------------
if ((Test-Path $script:StateFile) -and -not $StartOver) {
    try {
        $prior = Get-Content -Raw -Path $script:StateFile | ConvertFrom-Json
        $age = New-TimeSpan -Start ([datetime]::Parse($prior.updated_at)) -End (Get-Date)
        $ageStr = if ($age.TotalHours -ge 1) { "{0:N1}h ago" -f $age.TotalHours } else { "{0:N0}m ago" -f $age.TotalMinutes }
        Write-Host ''
        switch ($prior.status) {
            'completed' {
                Write-Host "Prior deploy from this package COMPLETED $ageStr (id=$($prior.deploy_id), RG=$($prior.resource_group))." -ForegroundColor Yellow
                Write-Host "Re-running will attempt to add to / refresh the existing deployment." -ForegroundColor Yellow
            }
            'failed' {
                Write-Host "Prior deploy from this package FAILED $ageStr at step $($prior.current_step_no):" -ForegroundColor Red
                Write-Host "    `"$($prior.current_step)`"" -ForegroundColor Red
                if ($prior.failure_reason) { Write-Host "    reason: $($prior.failure_reason)" -ForegroundColor DarkRed }
                Write-Host "    log:    $($prior.log_path)" -ForegroundColor DarkGray
                Write-Host "    RG:     $($prior.resource_group) (will be reattached if it still exists)" -ForegroundColor DarkGray
            }
            default {
                Write-Host "Prior deploy state shows STATUS=$($prior.status), last update $ageStr at step $($prior.current_step_no): `"$($prior.current_step)`"" -ForegroundColor Yellow
                Write-Host "Either another deploy is still running, or the prior run was killed (Ctrl-C / window closed)." -ForegroundColor Yellow
            }
        }
        Write-Host ''
        $ans = Read-Host "Continue? Re-run will re-detect existing resources where possible. [y/N]"
        if ($ans -notmatch '^(y|yes)$') {
            Write-Host "Aborted. Re-run with -StartOver to bypass this prompt, or run teardown.cmd to wipe the prior RG first." -ForegroundColor Yellow
            Complete-Log
            exit 0
        }
    } catch {
        Write-Host "    (could not parse prior state file: $_)" -ForegroundColor DarkGray
    }
}

# -----------------------------------------------------------------------------
# Helpers
# -----------------------------------------------------------------------------
# Section timing: Write-Step prints elapsed time for the PREVIOUS step before
# announcing the next one. Write-Done at the end prints the final section +
# total runtime. Avoids needing a stopwatch to see what's slow.
$script:__deployStart    = Get-Date
$script:__stepStart      = $null
$script:__stepLabel      = $null
function Write-Step($msg) {
    if ($script:__stepStart) {
        $elapsed = (Get-Date) - $script:__stepStart
        Write-Host ("    [time] {0} took {1:mm\:ss\.f}" -f $script:__stepLabel, $elapsed) -ForegroundColor DarkGray
    }
    Write-Host "==> $msg" -ForegroundColor Cyan
    $script:__stepStart = Get-Date
    $script:__stepLabel = $msg
    $script:CurrentStepNo++
    $script:CurrentStep = $msg
    Save-DeployState -Status 'running'
}
function Write-Done {
    param([switch]$NoTotal)
    if ($script:__stepStart) {
        $elapsed = (Get-Date) - $script:__stepStart
        Write-Host ("    [time] {0} took {1:mm\:ss\.f}" -f $script:__stepLabel, $elapsed) -ForegroundColor DarkGray
    }
    if (-not $NoTotal) {
        $total = (Get-Date) - $script:__deployStart
        Write-Host ("    [time] TOTAL deploy runtime: {0:hh\:mm\:ss}" -f $total) -ForegroundColor Yellow
    }
    $script:__stepStart = $null
}
function Write-Info($msg)    { Write-Host "    $msg" -ForegroundColor Gray }
function Write-Ok($msg)      { Write-Host "    [OK] $msg" -ForegroundColor Green }
function Write-Warn2($m)     { Write-Host "    [WARN] $m" -ForegroundColor Yellow }

# Tenant captured at sign-in; used by Invoke-AzWithRetry to run 'az login
# --tenant <X>' if silent refresh fails. Populated below after 'az login'.
$script:DeployTenantId = ''

# -----------------------------------------------------------------------------
# Invoke-AzWithRetry -- transparent retry wrapper for 'az' calls.
#
# Why: 'az' caches tokens but a long deploy (Bicep ~5min + Fabric ~30min +
# Purview ~20min) routinely crosses the 1hr access-token TTL. Continuous
# Access Evaluation (CAE) can also revoke tokens mid-deploy. Both surface
# as exit code 1 with stderr like "AADSTS70043 / TokenExpired / please run
# 'az login'". Without a wrapper, every late-deploy 'az' call is a coin
# flip and a crash means full teardown + restart.
#
# Behavior:
#   - run the scriptblock, capture stderr + LASTEXITCODE
#   - exit 0       -> return stdout
#   - token error  -> silent 'az account get-access-token' (cached refresh
#                     token), then interactive 'az login --tenant <X>' if
#                     that also fails. Re-runs the call. Capped at 2 token
#                     refreshes per call.
#   - 429/5xx/transport -> exp backoff (cap 30s), capped at 6 attempts.
#   - other       -> throw with stderr.
#
# Usage:
#   $sub = Invoke-AzWithRetry -Label 'az account show' { az account show -o json } | ConvertFrom-Json
#   Invoke-AzWithRetry -Label 'rg create' { az group create -n $rg -l $loc --output none } | Out-Null
#
# AllowNonZeroExit: pass when the caller treats non-zero as "not found" /
# "no rows" (e.g. 'az purview account list' against a sub with no perms).
# -----------------------------------------------------------------------------
function Invoke-AzWithRetry {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][scriptblock]$Script,
        [string]$Label = 'az call',
        [int]$MaxAttempts = 6,
        [switch]$AllowNonZeroExit
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
            $isTokenExpired = $stderr -match 'AADSTS70043|AADSTS50173|AADSTS500011|AADSTS50076|AADSTS50079|TokenExpired|Access token has expired|InvalidAuthenticationToken|expired or revoked|Continuous Access Evaluation|please run.*az login|Please run.*az login|run.*az login.*again'
            if ($isTokenExpired -and $tokenRefreshes -lt $maxTokenRefreshes) {
                $tokenRefreshes++
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

# -----------------------------------------------------------------------------
# Teardown emitter. Called twice during deploy:
#   1) right after RG create -- bare-minimum teardown (just delete the RG)
#   2) right after workspaces created -- full teardown (delete workspaces THEN RG)
# Second call overwrites the first. If deploy crashes between #1 and #2 no
# workspaces exist yet, so RG-only teardown is sufficient and correct.
# -----------------------------------------------------------------------------
function Write-Teardown {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Rg,
        [Parameter(Mandatory)][string]$Sub,
        [Parameter(Mandatory)][string]$Tenant,
        [string]$DeployedBy = '',
        [string]$Capacity = '',
        [object[]]$Workspaces = @(),
        [string]$SpAppId = '',
        [string]$GatewayId = '',
        [string[]]$ConnectionIds = @()
    )

    $teardownPath = Join-Path $script:teardownDir 'teardown.ps1'
    $wsLines = if ($Workspaces -and $Workspaces.Count -gt 0) {
        ($Workspaces | ForEach-Object { "    @{ Id = '$($_.id)'; Name = '$($_.displayName)' }" }) -join ",`r`n"
    } else { '' }
    $connLines = if ($ConnectionIds -and $ConnectionIds.Count -gt 0) {
        ($ConnectionIds | ForEach-Object { "    '$_'" }) -join ",`r`n"
    } else { '' }

    $teardownBody = @"
# Auto-generated by deploy.ps1 on $(Get-Date -Format o)
# Tears down EXACTLY the resources this deployment created. Hard-coded so the
# user doesn't have to remember anything. Other workspaces on the capacity are
# left alone.
#Requires -Version 7.0
`$ErrorActionPreference = 'Stop'

# Move pwsh's working directory OUT of the package folder so the user can
# delete it while teardown is running (or at the final prompt). All path
# lookups use `$PSScriptRoot, so cwd is irrelevant for correctness.
Set-Location `$env:TEMP

# Log to PSScriptRoot\logs\ (in the package folder, next to deploy.cmd) while
# teardown runs, then on exit copy to %LOCALAPPDATA%\Contoso\teardown-logs\ for
# retention after the user deletes the package folder.
`$logName     = "teardown-{0}.log" -f (Get-Date -Format 'yyyyMMdd-HHmmss')
`$logDir      = Join-Path `$PSScriptRoot 'logs'
`$retainDir   = Join-Path `$env:LOCALAPPDATA 'Contoso\teardown-logs'
if (-not (Test-Path `$logDir))    { New-Item -ItemType Directory -Path `$logDir    -Force | Out-Null }
if (-not (Test-Path `$retainDir)) { New-Item -ItemType Directory -Path `$retainDir -Force | Out-Null }
`$logPath    = Join-Path `$logDir    `$logName
`$retainPath = Join-Path `$retainDir `$logName
try { Start-Transcript -Path `$logPath -Append | Out-Null } catch { }
Write-Host "Logging to `$logPath" -ForegroundColor DarkGray
Write-Host "  (copied to `$retainPath on exit)" -ForegroundColor DarkGray

function Complete-Log {
    try { Stop-Transcript | Out-Null } catch { }
    try { if (Test-Path `$logPath) { Copy-Item -LiteralPath `$logPath -Destination `$retainPath -Force -ErrorAction Stop } } catch { }
}
trap { Complete-Log; break }

`$ResourceGroup = '$Rg'
`$Subscription  = '$Sub'
`$TenantId      = '$Tenant'
`$DeployedByUser = '$DeployedBy'  # account that ran deploy.ps1; teardown verifies match
`$CapacityName  = '$Capacity'
`$SpAppId       = '$SpAppId'
`$GatewayId     = '$GatewayId'
`$Workspaces = @(
$wsLines
)
`$ConnectionIds = @(
$connLines
)

# Absolute path to the deploy package this teardown was generated from.
# Same folder as this script (teardown.ps1 lives in the package root).
`$PackageRoot = `$PSScriptRoot
if (-not (Test-Path (Join-Path `$PackageRoot 'scripts\Fabric.ps1'))) {
    Write-Host "WARNING: deploy package looks incomplete at:" -ForegroundColor Yellow
    Write-Host "  `$PackageRoot" -ForegroundColor Yellow
    Write-Host "  Fabric REST + Purview teardown steps will be skipped." -ForegroundColor Yellow
    Write-Host "  Only the resource group delete will run." -ForegroundColor Yellow
    Write-Host ''
}

`$FabricHelperPath = Join-Path `$PackageRoot 'scripts\Fabric.ps1'
if (Test-Path `$FabricHelperPath) {
    . `$FabricHelperPath
}

# -----------------------------------------------------------------------------
# Tenant / subscription verification + existence preflight.
# Teardown is destructive and silent failures ("nothing to delete") are bad --
# if the user is signed into the wrong tenant we want to STOP and offer to
# re-auth, not pretend the deletion succeeded.
# -----------------------------------------------------------------------------
function Get-AzContext {
    try { az account show -o json 2>`$null | ConvertFrom-Json } catch { `$null }
}
function Test-FabricWorkspace {
    param(`$Token, `$Id)
    try { Invoke-FabricRest -Token `$Token -Method GET -Path "/workspaces/`$Id" | Out-Null; `$true } catch { `$false }
}
function Invoke-Preflight {
    `$ctx = Get-AzContext
    if (-not `$ctx) { return [pscustomobject]@{ Ok=`$false; Reason='not-logged-in'; Ctx=`$null; RgExists=`$false; WsExists=`$false; GraphOk=`$false } }
    `$rgExists = (az group exists --subscription `$ctx.id --name `$ResourceGroup) -eq 'true'
    `$wsExists = `$false
    try {
        `$fabTok = az account get-access-token --resource https://api.fabric.microsoft.com --query accessToken -o tsv 2>`$null
        if (`$fabTok -and `$Workspaces.Count -gt 0) {
            `$wsExists = Test-FabricWorkspace -Token `$fabTok -Id `$Workspaces[0].Id
        }
    } catch { }
    # Probe Microsoft Graph BEFORE any destructive work. Continuous Access
    # Evaluation can invalidate Graph tokens independently of ARM/Fabric
    # tokens, and the symptom is a mid-teardown failure on `az ad sp delete`
    # AFTER everything else has been ripped down (orphan SP, user has to
    # clean up manually). Catching it here forces the existing re-auth flow.
    `$graphOk = `$false
    `$graphErr = ''
    az ad signed-in-user show -o none 2>&1 | Out-Null
    if (`$LASTEXITCODE -eq 0) { `$graphOk = `$true } else { `$graphErr = 'graph-cae-or-perm' }
    `$tenantOk = (`$ctx.tenantId -eq `$TenantId)
    `$subOk    = (`$ctx.id       -eq `$Subscription)
    `$userOk   = (-not `$DeployedByUser) -or (`$ctx.user.name -eq `$DeployedByUser)
    `$ok = `$tenantOk -and `$subOk -and `$userOk -and `$graphOk -and (`$rgExists -or `$wsExists)
    [pscustomobject]@{ Ok=`$ok; Reason=`$graphErr; Ctx=`$ctx; TenantOk=`$tenantOk; SubOk=`$subOk; UserOk=`$userOk; RgExists=`$rgExists; WsExists=`$wsExists; GraphOk=`$graphOk }
}

`$pre = Invoke-Preflight
if (-not `$pre.Ok) {
    Write-Host ''
    Write-Host 'Preflight check FAILED -- not safe to proceed.' -ForegroundColor Red
    Write-Host ''
    Write-Host 'Expected:' -ForegroundColor Yellow
    if (`$DeployedByUser) { Write-Host "  Signed in as: `$DeployedByUser" }
    Write-Host "  Tenant:       `$TenantId"
    Write-Host "  Subscription: `$Subscription"
    Write-Host "  ResourceGrp:  `$ResourceGroup"
    Write-Host ''
    if (`$pre.Ctx) {
        Write-Host 'Currently signed in as:' -ForegroundColor Yellow
        Write-Host "  User:         `$(`$pre.Ctx.user.name)"
        Write-Host "  Tenant:       `$(`$pre.Ctx.tenantId)"
        Write-Host "  Subscription: `$(`$pre.Ctx.id) (`$(`$pre.Ctx.name))"
        Write-Host ''
        Write-Host 'Status:' -ForegroundColor Yellow
        Write-Host ("  Tenant match:           {0}" -f `$(if (`$pre.TenantOk) {'yes'} else {'NO'}))
        Write-Host ("  Subscription match:     {0}" -f `$(if (`$pre.SubOk)    {'yes'} else {'NO'}))
        if (`$DeployedByUser) {
            Write-Host ("  User match:             {0}" -f `$(if (`$pre.UserOk) {'yes'} else {"NO (deployed by `$DeployedByUser)"}))
        }
        Write-Host ("  Graph token valid:      {0}" -f `$(if (`$pre.GraphOk)  {'yes'} else {'NO (CAE challenge or missing perms -- needs re-login)'}))
        Write-Host ("  Resource group exists:  {0}" -f `$(if (`$pre.RgExists) {'yes'} else {'NO'}))
        Write-Host ("  Fabric workspace found: {0}" -f `$(if (`$pre.WsExists) {'yes'} else {'NO'}))
    } else {
        Write-Host 'Not signed in to Azure CLI.' -ForegroundColor Yellow
    }
    Write-Host ''
    Write-Host 'This usually means you are signed into the wrong tenant or subscription,'
    Write-Host 'or the deployment was already torn down.'
    Write-Host ''
    `$run = Read-Host "Run 'az login --tenant `$TenantId' now? [y/N]"
    if (`$run -match '^(y|yes)`$') {
        az logout 2>`$null | Out-Null
        az login --tenant `$TenantId | Out-Null
        if (`$LASTEXITCODE -ne 0) { Write-Host 'az login failed. Aborting.' -ForegroundColor Red; exit 1 }
        az account set --subscription `$Subscription | Out-Null
        if (`$LASTEXITCODE -ne 0) {
            Write-Host "Could not set subscription `$Subscription. Available subscriptions in this tenant:" -ForegroundColor Red
            az account list --query "[?tenantId=='`$TenantId'].{name:name,id:id}" -o table
            exit 1
        }
        `$pre = Invoke-Preflight
        if (-not `$pre.Ok) {
            Write-Host ''
            Write-Host 'Preflight still failing after re-auth. Nothing to delete (or wrong account). Aborting.' -ForegroundColor Red
            if (`$pre.Ctx) { Write-Host "  signed in as `$(`$pre.Ctx.user.name) / tenant=`$(`$pre.Ctx.tenantId) / sub=`$(`$pre.Ctx.id)" }
            Write-Host "  RG exists=`$(`$pre.RgExists)  Workspace exists=`$(`$pre.WsExists)"
            exit 1
        }
        Write-Host 'Re-auth succeeded; preflight passed.' -ForegroundColor Green
    } else {
        Write-Host 'Aborting.' -ForegroundColor Yellow; exit 1
    }
}

Write-Host ''
Write-Host 'About to PERMANENTLY DELETE:' -ForegroundColor Yellow
Write-Host "  Signed in as:   `$(`$pre.Ctx.user.name)"
Write-Host "  Tenant:         `$TenantId"
Write-Host "  Subscription:   `$Subscription (`$(`$pre.Ctx.name))"
Write-Host ''
Write-Host '  Fabric (REST API):' -ForegroundColor Yellow
if (`$Workspaces.Count -gt 0) {
    Write-Host '    Workspaces (and everything inside them -- lakehouses, mirror, eventhouse,'
    Write-Host '    KQL DB, eventstream, warehouse, semantic models, reports, data agents,'
    Write-Host '    notebooks, pipelines, folders, managed private endpoints):'
    foreach (`$w in `$Workspaces) { Write-Host "      - `$(`$w.Name) (`$(`$w.Id))" }
} else {
    Write-Host '    Workspaces: (none -- deploy crashed before workspaces were created)'
}
if (`$ConnectionIds.Count -gt 0) {
    Write-Host "    Cloud connections (`$(`$ConnectionIds.Count)): SQL mirror, ADLS shortcut, gold warehouse (gateway-bound)"
    foreach (`$cid in `$ConnectionIds) { Write-Host "      - `$cid" }
}
if (`$GatewayId) {
    Write-Host "    VNet data gateway: `$GatewayId"
}
Write-Host ''
Write-Host '  Microsoft Entra:' -ForegroundColor Yellow
if (`$SpAppId) {
    Write-Host "    Service principal (sp-fabric-mirror-...): `$SpAppId"
} else {
    Write-Host '    (no SP recorded)'
}
Write-Host ''
Write-Host '  Microsoft Purview governance (Unified Catalog + scans):' -ForegroundColor Yellow
`$purviewCtxPath = Join-Path `$PackageRoot 'governance\purview\context.json'
if (Test-Path `$purviewCtxPath) {
    try {
        `$pctx = Get-Content `$purviewCtxPath -Raw | ConvertFrom-Json
        Write-Host "    Account:       `$(`$pctx.purview.name)  (`$(`$pctx.purview.endpoint))"
        if (`$pctx.collection -and `$pctx.collection.name) {
            Write-Host "    Collection:    `$(`$pctx.collection.name)  (and all datamap entities under it)"
        }
        `$srcs = @()
        if (`$pctx.sources) { `$pctx.sources.PSObject.Properties | ForEach-Object { if (`$_.Value.name) { `$srcs += `$_.Value.name } } }
        if (`$srcs.Count -gt 0) { Write-Host "    Data sources:  `$(`$srcs -join ', ')" }
        `$scans = @()
        if (`$pctx.scans) { `$pctx.scans.PSObject.Properties | ForEach-Object { if (`$_.Value.name) { `$scans += `$_.Value.name } } }
        if (`$scans.Count -gt 0) { Write-Host "    Scans:         `$(`$scans -join ', ')" }
        `$domNames = @()
        if (`$pctx.governanceDomains) { `$pctx.governanceDomains.PSObject.Properties | ForEach-Object { if (`$_.Value.name) { `$domNames += `$_.Value.name } } }
        if (`$domNames.Count -gt 0) { Write-Host "    Domains (`$(`$domNames.Count)): `$(`$domNames -join ', ')" }
        if (`$pctx.glossaryTerms)      { Write-Host "    Glossary terms:           `$(@(`$pctx.glossaryTerms).Count)" }
        if (`$pctx.dataProducts)       { Write-Host "    Data products:            `$(@(`$pctx.dataProducts).Count)" }
        if (`$pctx.objectives)         { Write-Host "    Objectives + key results: `$(@(`$pctx.objectives).Count) objective(s)" }
        if (`$pctx.accessPolicies)     { Write-Host "    Term access policies:     `$(@(`$pctx.accessPolicies).Count)" }
        if (`$pctx.dpAccessPolicies)   { Write-Host "    DP access policies + approval workflows: `$(@(`$pctx.dpAccessPolicies).Count)" }
        if (`$pctx.criticalDataElements){ Write-Host "    Critical data elements (CDEs): `$(@(`$pctx.criticalDataElements).Count)" }
        Write-Host '    (all of the above will be deleted via Purview Unified Catalog APIs)' -ForegroundColor DarkGray
    } catch {
        Write-Host "    (could not parse context.json: `$_)" -ForegroundColor DarkYellow
        Write-Host '    teardown-purview.ps1 will run and delete whatever it can resolve.' -ForegroundColor DarkGray
    }
} else {
    Write-Host '    (no Purview context.json -- Purview recipe never ran for this deploy; nothing to delete)' -ForegroundColor DarkGray
}
Write-Host ''
Write-Host '  Azure resource group (and everything in it):' -ForegroundColor Yellow
Write-Host "    `$ResourceGroup"
if (`$CapacityName) { Write-Host "      - Fabric capacity:  `$CapacityName (F8)" }
Write-Host '      - Azure SQL Server + Database'
Write-Host '      - SQL Private Endpoint + private DNS zone'
Write-Host '      - ADLS Gen2 storage account'
Write-Host '      - Azure Functions app + plan + storage'
Write-Host '      - Application Insights'
Write-Host '      - VNet + subnets'
Write-Host ''
`$ans = Read-Host 'Type YES to proceed'
if (`$ans -ne 'YES') { Write-Host 'Cancelled.'; exit 0 }

az account set --subscription `$Subscription | Out-Null

# Purview teardown FIRST. Idempotent + self-skipping when the recipe never ran
# (e.g. subscription has no Purview account). Talks only to Purview APIs, so
# safe to run before tearing down Azure/Fabric resources.
`$purviewCtx = Join-Path `$PackageRoot 'governance\purview\context.json'
`$purviewTeardown = Join-Path `$PackageRoot 'governance\purview\teardown-purview.ps1'
if ((Test-Path `$purviewCtx) -and (Test-Path `$purviewTeardown)) {
    Write-Host ''
    Write-Host 'Purview governance teardown...' -ForegroundColor Cyan
    try { & `$purviewTeardown } catch { Write-Host "  Purview teardown error (continuing): `$_" -ForegroundColor DarkYellow }
} else {
    Write-Host '  (no Purview context found; skipping Purview teardown)' -ForegroundColor DarkGray
}

if (`$Workspaces.Count -gt 0) {
    if (-not (Get-Command Invoke-FabricRest -ErrorAction SilentlyContinue)) {
        Write-Host 'Skipping Fabric workspace teardown (Fabric.ps1 helper not available -- package folder was deleted).' -ForegroundColor DarkYellow
        Write-Host 'The resource group delete below will remove the capacity, which orphans the workspaces.' -ForegroundColor DarkYellow
        Write-Host 'Manually delete workspaces from https://app.fabric.microsoft.com afterward if needed.' -ForegroundColor DarkYellow
    } else {
    Write-Host 'Deleting workspace managed private endpoints (must precede workspace + RG delete)...' -ForegroundColor Cyan
    `$fabToken = (az account get-access-token --resource https://api.fabric.microsoft.com --query accessToken -o tsv)
    `$workspacesWithMpes = @()
    foreach (`$w in `$Workspaces) {
        try {
            `$mpes = (Invoke-FabricRest -Token `$fabToken -Method GET -Path "/workspaces/`$(`$w.Id)/managedPrivateEndpoints").Body.value
            if (-not `$mpes -or `$mpes.Count -eq 0) { continue }
            `$workspacesWithMpes += `$w
            foreach (`$m in `$mpes) {
                try {
                    Invoke-FabricRest -Token `$fabToken -Method DELETE -Path "/workspaces/`$(`$w.Id)/managedPrivateEndpoints/`$(`$m.id)" | Out-Null
                    Write-Host "  delete submitted: MPE `$(`$m.name) in `$(`$w.Name)" -ForegroundColor Green
                } catch {
                    Write-Host "  skip MPE `$(`$m.name) in `$(`$w.Name): `$_" -ForegroundColor DarkYellow
                }
            }
        } catch {
            Write-Host "  could not list MPEs in `$(`$w.Name): `$_" -ForegroundColor DarkYellow
        }
    }

    # MPE deletion is async on Fabric's side. Poll until each workspace reports zero MPEs (up to 5 min).
    if (`$workspacesWithMpes.Count -gt 0) {
        Write-Host '  Waiting for MPE deprovisioning to complete (up to 5 min)...' -ForegroundColor Cyan
        `$deadline = (Get-Date).AddMinutes(5)
        foreach (`$w in `$workspacesWithMpes) {
            while ((Get-Date) -lt `$deadline) {
                try {
                    `$remaining = (Invoke-FabricRest -Token `$fabToken -Method GET -Path "/workspaces/`$(`$w.Id)/managedPrivateEndpoints").Body.value
                    if (-not `$remaining -or `$remaining.Count -eq 0) {
                        Write-Host "    `$(`$w.Name): all MPEs gone" -ForegroundColor Green
                        break
                    }
                    Write-Host "    `$(`$w.Name): `$(`$remaining.Count) MPE(s) still deprovisioning..." -ForegroundColor DarkGray
                } catch {
                    Write-Host "    `$(`$w.Name): poll error: `$_" -ForegroundColor DarkYellow
                    break
                }
                Start-Sleep -Seconds 15
            }
        }
    }

    Write-Host 'Deleting Fabric workspaces...' -ForegroundColor Cyan
    `$failedWorkspaces = @()
    foreach (`$w in `$Workspaces) {
        `$deleted = `$false
        for (`$attempt = 1; `$attempt -le 6; `$attempt++) {
            try {
                Invoke-FabricRest -Token `$fabToken -Method DELETE -Path "/workspaces/`$(`$w.Id)" | Out-Null
                Write-Host "  deleted `$(`$w.Name)" -ForegroundColor Green
                `$deleted = `$true
                break
            } catch {
                `$errMsg = `$_.ToString()
                if (`$errMsg -match 'WorkspaceContainsManagedEndpoints' -and `$attempt -lt 6) {
                    Write-Host "  `$(`$w.Name): still has MPEs attached (attempt `$attempt/6), waiting 30s..." -ForegroundColor DarkYellow
                    Start-Sleep -Seconds 30
                    continue
                }
                Write-Host "  FAILED `$(`$w.Name): `$_" -ForegroundColor Red
                break
            }
        }
        if (-not `$deleted) { `$failedWorkspaces += `$w }
    }

    # CRITICAL: if any workspace failed to delete, abort BEFORE dropping the RG.
    # The RG contains the Fabric capacity; deleting it orphans the workspace
    # (Fabric MPE/workspace APIs require an attached capacity to function, so
    # the orphan can't be cleaned up via REST -- you'd need to spin up a new F2
    # to rescue it). Aborting here keeps the capacity alive so a teardown rerun
    # can finish the job.
    if (`$failedWorkspaces.Count -gt 0) {
        Write-Host ''
        Write-Host 'ABORTING TEARDOWN.' -ForegroundColor Red
        Write-Host 'The following Fabric workspace(s) failed to delete:' -ForegroundColor Red
        foreach (`$w in `$failedWorkspaces) { Write-Host "  - `$(`$w.Name) (`$(`$w.Id))" -ForegroundColor Red }
        Write-Host ''
        Write-Host 'The resource group (with the Fabric capacity) has NOT been touched.' -ForegroundColor Yellow
        Write-Host 'Wait ~5 min for MPE deprovisioning to settle, then re-run teardown.cmd.' -ForegroundColor Yellow
        Write-Host 'If it fails again, see the troubleshooting notes for orphan-workspace rescue.' -ForegroundColor Yellow
        Complete-Log
        Read-Host 'Press Enter to exit'
        exit 1
    }
    } # end else (Fabric helper available)
}

if (`$ConnectionIds.Count -gt 0 -and (Get-Command Invoke-FabricRest -ErrorAction SilentlyContinue)) {
    Write-Host 'Deleting Fabric cloud connections...' -ForegroundColor Cyan
    if (-not `$fabToken) { `$fabToken = (az account get-access-token --resource https://api.fabric.microsoft.com --query accessToken -o tsv) }
    foreach (`$cid in `$ConnectionIds) {
        try {
            Invoke-FabricRest -Token `$fabToken -Method DELETE -Path "/connections/`$cid" | Out-Null
            Write-Host "  deleted connection `$cid" -ForegroundColor Green
        } catch {
            Write-Host "  skip connection `${cid}: `$_" -ForegroundColor DarkYellow
        }
    }
}

if (`$GatewayId) {
    if (-not (Get-Command Invoke-FabricRest -ErrorAction SilentlyContinue)) {
        Write-Host "Skipping VNet data gateway delete (Fabric.ps1 not available -- package folder was deleted). Gateway id: `$GatewayId" -ForegroundColor DarkYellow
    } else {
    Write-Host 'Deleting Fabric VNet data gateway...' -ForegroundColor Cyan
    try {
        if (-not `$fabToken) { `$fabToken = (az account get-access-token --resource https://api.fabric.microsoft.com --query accessToken -o tsv) }
        Invoke-FabricRest -Token `$fabToken -Method DELETE -Path "/gateways/`$GatewayId" | Out-Null
        Write-Host "  deleted gateway `$GatewayId" -ForegroundColor Green
    } catch {
        Write-Host "  skip gateway `${GatewayId}: `$_" -ForegroundColor DarkYellow
    }
    }
}

if (`$SpAppId) {
    Write-Host 'Deleting service principal...' -ForegroundColor Cyan
    # Verify FIRST so we can distinguish "already gone" (200/404) from
    # "delete failed" (CAE token challenge, perm denied, etc). The previous
    # blanket 'skip (already gone or permission denied)' message lied when a
    # CAE InteractionRequired challenge killed the call -- the SP was still
    # there and silently orphaned.
    `$existsBefore = az ad sp show --id `$SpAppId -o none 2>`$null; `$showExit = `$LASTEXITCODE
    if (`$showExit -ne 0) {
        Write-Host "  SP `$SpAppId already gone" -ForegroundColor Green
    } else {
        `$delErr = az ad sp delete --id `$SpAppId 2>&1
        if (`$LASTEXITCODE -eq 0) {
            Write-Host "  deleted SP `$SpAppId" -ForegroundColor Green
        } else {
            Write-Host "  FAILED to delete SP `$SpAppId" -ForegroundColor Red
            Write-Host "    az output: `$delErr" -ForegroundColor Red
            Write-Host "    re-run 'az login --tenant `$TenantId' and then:" -ForegroundColor Yellow
            Write-Host "      az ad sp delete --id `$SpAppId" -ForegroundColor Yellow
        }
    }
}

Write-Host 'Deleting resource group (async)...' -ForegroundColor Cyan
Write-Host "  `$ResourceGroup" -ForegroundColor Green
# Capture stdout+stderr so submit failures (RG locked, permission denied,
# subscription disabled) actually surface instead of vanishing past --no-wait.
`$rgDelOutput = az group delete --name `$ResourceGroup --yes --no-wait 2>&1
if (`$LASTEXITCODE -ne 0) {
    Write-Host ''
    Write-Host 'Resource group delete submit FAILED. az CLI output:' -ForegroundColor Red
    Write-Host '----------------------------------------' -ForegroundColor Red
    `$rgDelOutput | ForEach-Object { Write-Host `$_ -ForegroundColor Red }
    Write-Host '----------------------------------------' -ForegroundColor Red
    Write-Host 'Resource group was NOT deleted. Investigate the error above and re-run teardown.' -ForegroundColor Yellow
    Complete-Log
    Read-Host 'Press Enter to exit'
    exit 1
}

Write-Host ''
Write-Host 'Teardown initiated. Resource group deletion runs in the background.' -ForegroundColor Green
Write-Host ''
Write-Host 'NOTE: The VNet (vnet-fabric-gw) may take up to ~1 hour to release after' -ForegroundColor Yellow
Write-Host '      the Fabric gateway deletion. If the resource group still exists after' -ForegroundColor Yellow
Write-Host '      1 hour, re-run:' -ForegroundColor Yellow
Write-Host "        az group delete --name `$ResourceGroup --yes" -ForegroundColor Yellow
Write-Host '      This is normal Azure behavior - the PowerPlatform service association' -ForegroundColor Yellow
Write-Host '      link on the gateway subnet releases asynchronously.' -ForegroundColor Yellow
Complete-Log
Read-Host 'Press Enter to exit'
"@
    Set-Content -Path $teardownPath -Value $teardownBody -Encoding UTF8

    # teardown.cmd is a tiny static launcher next to teardown.ps1 in the
    # package folder. Content never varies between Write-Teardown calls (it
    # just resolves teardown.ps1 via %~dp0), so write it once and skip on
    # subsequent calls.
    $teardownCmdPath = Join-Path $script:teardownPackageRoot 'teardown.cmd'
    if (-not (Test-Path $teardownCmdPath)) {
        $teardownCmdBody = @"
@echo off
REM Launcher: invokes pwsh 7 via -Command (NOT -File) so stdin/Read-Host work.
REM Double-click this OR run ``teardown.cmd`` from any shell.
REM %~dp0 = the folder containing this .cmd = the deploy package root. We
REM capture it BEFORE cd-ing away so the path is right regardless of cwd.
REM We cd to %TEMP% so neither cmd.exe nor the pwsh child holds the package
REM folder open as cwd -- that lets the user delete the package later.
set TEARDOWN_PS1=%~dp0teardown.ps1
cd /d %TEMP%
if not exist "%TEARDOWN_PS1%" (
    echo Teardown script not found at:
    echo   %TEARDOWN_PS1%
    echo.
    echo Either the deployment never completed, or teardown already ran and the
    echo script was cleaned up. If your resource group still exists you can
    echo delete it manually:
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

# -----------------------------------------------------------------------------
# Banner + config
# -----------------------------------------------------------------------------
Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "  Contoso Tech (Retail) - Azure Deployment" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host ""

$configPath = Join-Path $PSScriptRoot 'deployment.config'
if (-not (Test-Path $configPath)) {
    throw "deployment.config not found at $configPath - package may be corrupt"
}

$config = @{}
Get-Content $configPath | ForEach-Object {
    if ($_ -match '^([A-Z_]+)=(.+)$') { $config[$matches[1]] = $matches[2] }
}

Write-Step "Configuration"
$config.GetEnumerator() | Sort-Object Key | ForEach-Object {
    Write-Info ("{0,-18} = {1}" -f $_.Key, $_.Value)
}

# -----------------------------------------------------------------------------
# teardown.ps1 + teardown.cmd both live in the package folder (right next to
# deploy.cmd, where the user obviously looks for them).
#
# (Earlier we tried hosting teardown.ps1 in %LOCALAPPDATA% on the theory that
# OneDrive sync was racing Explorer-delete on the package folder. It wasn't.
# Real cause was stale Explorer windows on the Downloads folder holding
# phantom thumbnail/preview handles into the package subtree. Moving the
# script doesn't help that, so the script lives where it should: in the
# package, next to deploy.cmd.)
# -----------------------------------------------------------------------------
$script:teardownDir         = $PSScriptRoot
$script:teardownPackageRoot = $PSScriptRoot  # alias used by the emitted teardown.cmd writer

# -----------------------------------------------------------------------------
# Tooling checks
# -----------------------------------------------------------------------------
Write-Step "Verifying tooling"

# Each prereq is checked, and if missing the user is prompted to install.
# Decline => graceful exit so they can install manually and re-run.
function Confirm-InstallPrereq {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$InstallHint
    )
    Write-Host ""
    Write-Host "    [MISSING] $Name" -ForegroundColor Yellow
    Write-Host "    Install command: $InstallHint" -ForegroundColor DarkGray
    $ans = Read-Host "    Install $Name now? (y/n)"
    if ($ans -notmatch '^[Yy]') {
        Write-Host ""
        Write-Host "Can't proceed without $Name. Exiting deployment script." -ForegroundColor Red
        Complete-Log
        exit 1
    }
}

# ---- 1. Azure CLI ----------------------------------------------------------
if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    Confirm-InstallPrereq -Name 'Azure CLI (az)' -InstallHint 'winget install -e --id Microsoft.AzureCLI'
    Write-Info "Running: winget install -e --id Microsoft.AzureCLI"
    winget install -e --id Microsoft.AzureCLI --accept-source-agreements --accept-package-agreements
    if ($LASTEXITCODE -ne 0) { throw "Azure CLI install failed (exit $LASTEXITCODE). Install manually from https://aka.ms/installazurecli and re-run." }
    Write-Warn2 "Azure CLI installed. You must close this window and open a NEW pwsh session so 'az' is on PATH, then re-run deploy.ps1."
    Complete-Log
    exit 0
}
Write-Ok "Azure CLI present ($(az version --query '\"azure-cli\"' -o tsv))"

# ---- 2. Azure CLI extension: microsoft-fabric ------------------------------
# Used for `az fabric capacity resume/suspend` when the capacity is paused.
$fabExt = az extension list --query "[?name=='microsoft-fabric'].name | [0]" -o tsv 2>$null
if (-not $fabExt) {
    Confirm-InstallPrereq -Name "Azure CLI extension 'microsoft-fabric'" -InstallHint 'az extension add --name microsoft-fabric --allow-preview true'
    az config set extension.dynamic_install_allow_preview=true 2>$null | Out-Null
    az extension add --name microsoft-fabric --allow-preview true --yes 2>$null
    if ($LASTEXITCODE -ne 0) { throw "Failed to install microsoft-fabric az extension (exit $LASTEXITCODE)." }
}
Write-Ok "az extension 'microsoft-fabric' present"

# ---- 3. PowerShell module: ThreadJob ---------------------------------------
# PS7 ships Microsoft.PowerShell.ThreadJob built-in; older setups need the
# gallery 'ThreadJob' module. Start-ThreadJob is used heavily for parallelism.
if (-not (Get-Command Start-ThreadJob -ErrorAction SilentlyContinue)) {
    Confirm-InstallPrereq -Name "PowerShell module 'ThreadJob'" -InstallHint 'Install-Module -Name ThreadJob -Scope CurrentUser -Force'
    Install-Module -Name ThreadJob -Scope CurrentUser -Force -AllowClobber | Out-Null
    Import-Module ThreadJob -ErrorAction Stop
}
Write-Ok "Start-ThreadJob available"

# ---- 4. PowerShell module: SqlServer ---------------------------------------
# Needed for Invoke-Sqlcmd (applying schema.sql with AAD auth).
if (-not (Get-Module -ListAvailable -Name SqlServer)) {
    Confirm-InstallPrereq -Name "PowerShell module 'SqlServer'" -InstallHint 'Install-Module -Name SqlServer -Scope CurrentUser -Force'
    Install-Module -Name SqlServer -Scope CurrentUser -Force -AllowClobber | Out-Null
}
Import-Module SqlServer -DisableNameChecking
Write-Ok "SqlServer module loaded"

# ---- 5. Internet reachability ---------------------------------------------
try {
    Invoke-RestMethod -Uri 'https://api.ipify.org?format=json' -TimeoutSec 10 | Out-Null
} catch {
    throw "Can't reach the public internet (https://api.ipify.org). Deployment needs outbound HTTPS to Azure ARM, Microsoft Graph, Fabric, and Open-Meteo."
}
Write-Ok "Internet reachable"

# -----------------------------------------------------------------------------
# Azure sign-in
# -----------------------------------------------------------------------------
# Always run `az login` so the user picks the correct account+subscription
# for THIS deployment. Most users have a corporate account signed in that
# isn't valid for personal/customer Azure resources.
Write-Step "Azure sign-in"
Write-Info "A browser window will open. Sign in with the account and pick the"
Write-Info "subscription where these resources should be deployed."
Write-Host ""

az login --output none
if ($LASTEXITCODE -ne 0) { throw "az login failed" }

# Some tenants enforce CAE (Continuous Access Evaluation) on Microsoft Graph,
# which causes `az ad signed-in-user show` to fail with InteractionRequired
# even right after a fresh login -- because the local CLI token cache still
# has the stale CAE-flagged Graph token. We have to nuke the cache and
# re-login with an explicit Graph scope to get a clean Graph token.
az account get-access-token --resource https://graph.microsoft.com --output none 2>$null
$graphOk = ($LASTEXITCODE -eq 0)
if ($graphOk) {
    az ad signed-in-user show --output none 2>$null
    $graphOk = ($LASTEXITCODE -eq 0)
}
if (-not $graphOk) {
    Write-Info "Microsoft Graph token rejected by CAE. Clearing token cache and re-logging in..."
    az account clear --output none 2>$null
    az login --scope https://graph.microsoft.com/.default --output none
    if ($LASTEXITCODE -ne 0) { throw "az login (Graph scope) failed" }
}

# Whatever sub az left active after login is the one we use.
$selectedSub = az account show --output json | ConvertFrom-Json
if (-not $selectedSub) { throw "Could not read active subscription after az login" }

# Register tenant id so Invoke-AzWithRetry can re-auth autonomously if a 401
# / CAE challenge / TokenExpired hits later in the deploy. Without this it'd
# crash mid-deploy and force the user to teardown + restart.
$script:DeployTenantId = $selectedSub.tenantId

Write-Ok "Using account:      $($selectedSub.user.name)"
Write-Ok "Using subscription: $($selectedSub.name)"
Write-Info "Subscription ID: $($selectedSub.id)"
Write-Info "Tenant:          $($selectedSub.tenantId)"

# AAD object id of the signed-in user (becomes SQL admin)
$signedInUser = az ad signed-in-user show --output json | ConvertFrom-Json
if ($LASTEXITCODE -ne 0 -or -not $signedInUser) { throw "Failed to read signed-in user identity from Entra" }
$sqlAdminObjectId  = $signedInUser.id
$sqlAdminLoginName = $signedInUser.userPrincipalName
Write-Ok "Will grant SQL admin to: $sqlAdminLoginName"

# -----------------------------------------------------------------------------
# Prerequisite checks for the selected deploy mode (base vs. base + Purview).
# Every check has a remediation hint. Any failure aborts the script BEFORE any
# resources are created, so a misconfigured account doesn't leave a half-built
# RG behind.
# -----------------------------------------------------------------------------
$deployPurviewPlanned = ($config['DEPLOY_PURVIEW'] -eq 'true')
$modeLabel = if ($deployPurviewPlanned) { 'base + Purview governance' } else { 'base (Fabric data estate only)' }
Write-Step "Prerequisite checks (mode: $modeLabel)"

$prereqs = New-Object System.Collections.Generic.List[object]
function Start-Prereq($label) {
    # Print the check label immediately so the user sees progress as we work.
    Write-Host ("    ...    {0}" -f $label) -ForegroundColor DarkGray -NoNewline
    [System.Console]::Out.Flush()
}
function Add-Prereq($label, $ok, $detail, $remediation) {
    $prereqs.Add([pscustomobject]@{ Label=$label; Ok=$ok; Detail=$detail; Remediation=$remediation })
    # Overwrite the in-progress line with the verdict.
    Write-Host "`r" -NoNewline
    if ($ok) {
        Write-Host ("    [OK]   {0}" -f $label) -ForegroundColor Green
    } else {
        Write-Host ("    [FAIL] {0}" -f $label) -ForegroundColor Red
    }
    if ($detail) { Write-Host ("           {0}" -f $detail) -ForegroundColor DarkGray }
}

# --- Subscription RBAC: Owner OR (Contributor + User Access Administrator).
# Bicep creates roleAssignments (function MSI -> Storage roles, etc.), which
# requires either Owner or both Contributor+UAA at the assignment scope.
$rbacLabel = 'Subscription RBAC (Owner, or Contributor + User Access Administrator)'
Start-Prereq $rbacLabel
$subScope = "/subscriptions/$($selectedSub.id)"
$roles = @()
try {
    $roles = (az role assignment list --assignee $signedInUser.id --scope $subScope --include-inherited --query "[].roleDefinitionName" -o tsv 2>$null) -split "`r?`n" | Where-Object { $_ }
} catch {}
$hasOwner   = $roles -contains 'Owner'
$hasContrib = $roles -contains 'Contributor'
$hasUAA     = ($roles -contains 'User Access Administrator') -or ($roles -contains 'Role Based Access Control Administrator')
$rbacOk     = $hasOwner -or ($hasContrib -and $hasUAA)
Add-Prereq `
    $rbacLabel `
    $rbacOk `
    $(if ($roles.Count) { "have: $($roles -join ', ')" } else { 'no role assignments visible' }) `
    "Ask an Azure admin to grant your account 'Owner' on subscription $($selectedSub.id), or both 'Contributor' AND 'User Access Administrator'. The Bicep creates RBAC assignments and will fail without these."

# --- Resource providers. Auto-register any that are missing (idempotent;
# registration is async but Bicep handles in-flight Registering state).
$requiredProviders = @('Microsoft.Fabric','Microsoft.Insights','Microsoft.Network','Microsoft.PowerPlatform','Microsoft.Sql','Microsoft.Storage','Microsoft.Web')
$rpLabel = "Resource providers registered ($($requiredProviders -join ', '))"
Start-Prereq $rpLabel
$providerStates = @{}
try {
    $allProviders = az provider list --query "[].{ns:namespace,state:registrationState}" -o json 2>$null | ConvertFrom-Json
    foreach ($p in $allProviders) { $providerStates[$p.ns] = $p.state }
} catch {}
$toRegister = $requiredProviders | Where-Object { $providerStates[$_] -notin 'Registered','Registering' }
foreach ($p in $toRegister) {
    az provider register --namespace $p --output none 2>$null
}
if ($toRegister.Count -gt 0) {
    try {
        $allProviders = az provider list --query "[].{ns:namespace,state:registrationState}" -o json 2>$null | ConvertFrom-Json
        $providerStates = @{}
        foreach ($p in $allProviders) { $providerStates[$p.ns] = $p.state }
    } catch {}
}
$notRegistered = $requiredProviders | Where-Object { $providerStates[$_] -notin 'Registered','Registering' }
Add-Prereq `
    $rpLabel `
    ($notRegistered.Count -eq 0) `
    $(if ($notRegistered.Count -eq 0) { 'all registered or registering' } else { "not registered: $($notRegistered -join ', ')" }) `
    "If auto-registration failed, an account with Contributor on the subscription must run: az provider register --namespace <NS>"

# --- Microsoft Fabric tenant access (token + capacity list).
$fabricLabel = 'Microsoft Fabric tenant access'
Start-Prereq $fabricLabel
$fabricOk = $false
$fabricDetail = ''
try {
    $fabTokTest = az account get-access-token --resource https://api.fabric.microsoft.com --query accessToken -o tsv 2>$null
    if ($LASTEXITCODE -eq 0 -and $fabTokTest) {
        $capProbe = Invoke-RestMethod -Uri 'https://api.fabric.microsoft.com/v1/capacities' -Headers @{ Authorization = "Bearer $fabTokTest" }
        $fabricOk = $true
        $fabricDetail = "Fabric API reachable; tenant has $($capProbe.value.Count) capacity(ies) visible"
    } else {
        $fabricDetail = 'Could not acquire Fabric API token'
    }
} catch {
    $fabricDetail = "Fabric API call failed: $($_.Exception.Message)"
}
Add-Prereq `
    $fabricLabel `
    $fabricOk `
    $fabricDetail `
    "Your tenant admin must enable Microsoft Fabric in the Fabric admin portal (Tenant settings -> Microsoft Fabric -> Users can create Fabric items). https://learn.microsoft.com/fabric/admin/fabric-switch"

# --- Target resource group is not mid-delete. If the user kicked off teardown
# and immediately re-ran deploy with the same RG name, the RG sits in
# provisioningState=Deleting for several minutes -- any az group create / Bicep
# call against it will fail with a confusing error. Catch it here.
$rgLabel = "Target resource group '$($config.RESOURCE_GROUP)' is not mid-delete"
Start-Prereq $rgLabel
$rgState = $null
$rgOk = $true
$rgDetail = 'does not exist yet (will be created) or exists in a usable state'
try {
    $rgShow = az group show --name $config.RESOURCE_GROUP -o json 2>$null
    if ($LASTEXITCODE -eq 0 -and $rgShow) {
        $rgObj = $rgShow | ConvertFrom-Json
        $rgState = $rgObj.properties.provisioningState
        if ($rgState -eq 'Deleting') {
            $rgOk = $false
            $rgDetail = "RG exists in provisioningState=Deleting (a teardown is still in progress)"
        } else {
            $rgDetail = "RG already exists in provisioningState=$rgState (deploy will reuse it)"
        }
    }
} catch {}
Add-Prereq `
    $rgLabel `
    $rgOk `
    $rgDetail `
    "Wait a few minutes for the previous teardown to finish, then re-run. Or pick a different RG name in your deployment.config (RESOURCE_GROUP=...)."

# --- Purview-only prereqs ---
if ($deployPurviewPlanned) {
    $pvAcctLabel = 'Microsoft Purview account in this subscription'
    Start-Prereq $pvAcctLabel
    $pvAccounts = az purview account list -o json 2>$null | ConvertFrom-Json
    if (-not $pvAccounts -or $pvAccounts.Count -eq 0) {
        $pvAccounts = az resource list --resource-type 'Microsoft.Purview/accounts' -o json 2>$null | ConvertFrom-Json
    }
    $pvExists = ($pvAccounts -and $pvAccounts.Count -ge 1)
    $pv = if ($pvExists) { $pvAccounts | Select-Object -First 1 } else { $null }
    Add-Prereq `
        $pvAcctLabel `
        $pvExists `
        $(if ($pvExists) { "found: $($pv.name) (RG=$($pv.resourceGroup))" } else { 'no Microsoft.Purview/accounts in subscription' }) `
        "Create a Purview account in this subscription via the Azure portal (Create resource -> Microsoft Purview), then complete the Unified Catalog upgrade. The deploy will NOT create one for you."

    if ($pvExists) {
        $pvEndpoint = "https://$($pv.name).purview.azure.com"
        $pvTok = az account get-access-token --resource https://purview.azure.net --query accessToken -o tsv 2>$null
        $pvHdr = @{ Authorization = "Bearer $pvTok" }
        $pvJsonHdr = $pvHdr.Clone()
        $pvJsonHdr['Content-Type'] = 'application/json'

        # Unified Catalog probe
        $ucLabel = 'Purview Unified Catalog (new experience) enabled'
        Start-Prereq $ucLabel
        $ucOk = $false
        try {
            $null = Invoke-RestMethod -Method GET -Uri "$pvEndpoint/datagovernance/catalog/businessdomains" -Headers $pvHdr
            $ucOk = $true
        } catch {}
        Add-Prereq `
            $ucLabel `
            $ucOk `
            $(if ($ucOk) { 'businessdomains endpoint returns 200' } else { 'businessdomains endpoint not reachable; account on legacy data map only' }) `
            "Open https://purview.microsoft.com, switch to the '$($pv.name)' account, and complete the 'Upgrade to the new Purview experience' flow."

        # Collection Admin on root (PUT then DELETE a deploycheck collection).
        # Purview collection names: 3-63 chars, alphanumeric + hyphen only (no underscores).
        $collLabel = "Purview Collection Admin on root collection ($($pv.name))"
        Start-Prereq $collLabel
        $collOk = $false
        $collErr = ''
        $collName = 'deploycheck' + ([guid]::NewGuid().ToString('N').Substring(0,8))
        try {
            $putBody = '{"name":"' + $collName + '","friendlyName":"' + $collName + '","parentCollection":{"type":"CollectionReference","referenceName":"' + $pv.name + '"}}'
            $null = Invoke-RestMethod -Method PUT -Uri "$pvEndpoint/account/collections/$collName`?api-version=2019-11-01-preview" -Headers $pvJsonHdr -Body $putBody
            $collOk = $true
        } catch {
            $collErr = $_.Exception.Message
        }
        if ($collOk) {
            try { Invoke-RestMethod -Method DELETE -Uri "$pvEndpoint/account/collections/$collName`?api-version=2019-11-01-preview" -Headers $pvHdr | Out-Null } catch {}
        }
        Add-Prereq `
            $collLabel `
            $collOk `
            $(if ($collOk) { 'created + deleted test collection successfully' } else { "create test collection failed: $collErr" }) `
            "Open the Purview governance portal -> Data Map -> Collections -> root '$($pv.name)' -> Role assignments. Add your account as 'Collection admins'."

        # Domain Admin (POST then DELETE a deploycheck businessdomain)
        $domLabel = 'Purview Data Catalog Admin (create + delete business domains)'
        Start-Prereq $domLabel
        $domOk = $false
        $domErr = ''
        $domName = 'deploycheck-' + ([guid]::NewGuid().ToString('N').Substring(0,8))
        try {
            $domBody = '{"name":"' + $domName + '","type":"DataDomain","description":"preflight test","status":"Draft"}'
            $domResp = Invoke-RestMethod -Method POST -Uri "$pvEndpoint/datagovernance/catalog/businessdomains" -Headers $pvJsonHdr -Body $domBody
            $domOk = $true
            if ($domResp.id) {
                try { Invoke-RestMethod -Method DELETE -Uri "$pvEndpoint/datagovernance/catalog/businessdomains/$($domResp.id)" -Headers $pvHdr | Out-Null } catch {}
            }
        } catch {
            $domErr = $_.Exception.Message
        }
        Add-Prereq `
            $domLabel `
            $domOk `
            $(if ($domOk) { 'created + deleted test domain successfully' } else { "create test domain failed: $domErr" }) `
            "In the Purview governance portal -> Settings -> Roles and permissions, add your account to the 'Data Governance Administrator' role at the root domain."
    }
}

# --- Render checklist + abort on any failure ---
Write-Host ''
$failedPrereqs = @($prereqs | Where-Object { -not $_.Ok })
if ($failedPrereqs.Count -gt 0) {
    Write-Host ''
    Write-Host "Preflight FAILED -- $($failedPrereqs.Count) prerequisite(s) not met. Nothing has been created yet." -ForegroundColor Red
    foreach ($f in $failedPrereqs) {
        Write-Host ''
        Write-Host "  X $($f.Label)" -ForegroundColor Red
        Write-Host "    Fix: $($f.Remediation)" -ForegroundColor Yellow
    }
    Write-Host ''
    Write-Host 'Resolve the above and re-run deploy.cmd.' -ForegroundColor Cyan
    exit 1
}
Write-Ok "All prerequisites met"

# Public IP for firewall
try {
    $clientIp = (Invoke-RestMethod -Uri 'https://api.ipify.org?format=json').ip
    Write-Ok "Detected public IP: $clientIp"
} catch {
    throw "Could not detect public IP. Check internet connectivity."
}

# -----------------------------------------------------------------------------
# Resource group
# -----------------------------------------------------------------------------
Write-Step "Resource Group: $($config.RESOURCE_GROUP) in $($config.LOCATION)"

$rgExistsRaw = az group exists --name $config.RESOURCE_GROUP 2>&1
if ($LASTEXITCODE -ne 0) {
    throw "Failed to check resource group existence: $rgExistsRaw"
}
$rgExists = $rgExistsRaw | ConvertFrom-Json

if ($rgExists) {
    Write-Ok "Resource group already exists"
} else {
    az group create --name $config.RESOURCE_GROUP --location $config.LOCATION --output none
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to create resource group '$($config.RESOURCE_GROUP)'. You may not have Contributor on this subscription."
    }
    Write-Ok "Resource group created"
}

# Emit minimal teardown immediately. If deploy crashes from here on, the user
# has a working teardown.cmd that deletes the RG. Overwritten with full version
# after workspaces are created.
Write-Teardown -Rg $config.RESOURCE_GROUP -Sub $selectedSub.id -Tenant $selectedSub.tenantId -DeployedBy $selectedSub.user.name
Write-Info "teardown.ps1 + teardown.cmd written (RG-only; refreshed after workspaces exist)"

# -----------------------------------------------------------------------------
# Single Bicep deployment - Fabric capacity + storage + sql + function (3-5 min).
# Previously this was split into two bicep deploys (capacity first, then the
# rest) so we could pre-create Fabric workspaces + workspace identity +
# tenant-setting grant during the slow main bicep. That tenant-setting grant
# was only needed for cross-workspace InvokePipeline activities, which we no
# longer use (pl_initial_load uses same-workspace ExecutePipeline). With
# the grant gone there's no Entra propagation window to overlap, so we can
# deploy everything in one shot.
# -----------------------------------------------------------------------------
Write-Step "Deploying Bicep: Fabric capacity + storage + sql + function (this can take 3-5 minutes)"

$bicepPath = Join-Path $PSScriptRoot 'infra' 'main.bicep'
if (-not (Test-Path $bicepPath)) {
    throw "Bicep template not found at $bicepPath"
}

$deploymentName = "contoso-retail-$(Get-Date -Format 'yyyyMMddHHmmss')"

# Capture stdout AND stderr so we can surface the real error to the user.
# Without 2>&1 the az error JSON goes to stderr and gets swallowed when stdout
# is assigned to a variable; user just sees "Bicep deployment failed (exit 1)"
# with no clue what actually failed.
$deployOutput = az deployment group create `
    --name $deploymentName `
    --resource-group $config.RESOURCE_GROUP `
    --template-file $bicepPath `
    --parameters `
        resourcePrefix=$($config.RESOURCE_PREFIX) `
        location=$($config.LOCATION) `
        sqlAdminObjectId=$sqlAdminObjectId `
        sqlAdminLoginName=$sqlAdminLoginName `
        clientIpAddress=$clientIp `
    --output json 2>&1

if ($LASTEXITCODE -ne 0) {
    Write-Host ""
    Write-Host "Bicep deployment failed. az CLI output:" -ForegroundColor Red
    Write-Host "----------------------------------------" -ForegroundColor Red
    $deployOutput | ForEach-Object { Write-Host $_ -ForegroundColor Red }
    Write-Host "----------------------------------------" -ForegroundColor Red
    Write-Host "Fetching deployment operation errors from ARM..." -ForegroundColor Yellow
    az deployment operation group list `
        --resource-group $config.RESOURCE_GROUP `
        --name $deploymentName `
        --query "[?properties.provisioningState=='Failed'].{Resource:properties.targetResource.resourceName, Type:properties.targetResource.resourceType, Code:properties.statusMessage.error.code, Message:properties.statusMessage.error.message}" `
        --output table 2>&1 | ForEach-Object { Write-Host $_ -ForegroundColor Yellow }
    throw "Bicep deployment failed (exit $LASTEXITCODE)"
}

$deployJson = $deployOutput | Out-String
$deploy = $deployJson | ConvertFrom-Json
$outputs = $deploy.properties.outputs
$fabricCapacityName = $outputs.fabricCapacityName.value
$uniqueSuffix       = $outputs.uniqueSuffix.value
Write-Ok "Bicep deployment succeeded"
Write-Info "SQL Server:       $($outputs.sqlServerFqdn.value)"
Write-Info "SQL Database:     $($outputs.sqlDatabaseName.value)"
Write-Info "Storage Acct:     $($outputs.storageAccount.value)"
Write-Info "Fabric Capacity:  $fabricCapacityName"

# Refresh teardown so the capacity gets named even if we crash before workspaces.
Write-Teardown -Rg $config.RESOURCE_GROUP -Sub $selectedSub.id -Tenant $selectedSub.tenantId -DeployedBy $selectedSub.user.name -Capacity $fabricCapacityName

# -----------------------------------------------------------------------------
# Fabric workspaces + bronze workspace identity (post-bicep now that capacity
# lands in the same deploy).
# -----------------------------------------------------------------------------
. (Join-Path $PSScriptRoot 'scripts' 'Fabric.ps1')

# Register tenant so Invoke-FabricRest can run 'az login --tenant <X>' on its
# own if a 401 hits mid-deploy and the cached refresh token has also died.
# Without this we'd abort the deploy and force the user to restart from zero.
Set-FabricTenant -TenantId $selectedSub.tenantId

Write-Step "Acquiring Fabric API token"
$fabricToken = Get-FabricToken
Write-Ok "Fabric token acquired"

Write-Step "Resolving Fabric capacity GUID for '$fabricCapacityName'"
# Bicep just provisioned the capacity; Fabric tenant may take a few seconds to see it.
$capacityId = $null
for ($i = 1; $i -le 12; $i++) {
    try {
        $capacityId = Get-FabricCapacityGuidFromArmId -Token $fabricToken -CapacityName $fabricCapacityName
        break
    } catch {
        if ($i -eq 12) { throw }
        Write-Info "Capacity not visible yet (attempt $i/12); waiting 10s..."
        Start-Sleep -Seconds 10
    }
}
Write-Ok "Fabric capacity GUID: $capacityId"

$workspaceNames = @(
    @{ Suffix = '1-bronze'; Description = 'Contoso Retail - Bronze (raw ingest + sim)' },
    @{ Suffix = '2-silver'; Description = 'Contoso Retail - Silver (conformed/cleansed)' },
    @{ Suffix = '3-gold';   Description = 'Contoso Retail - Gold (star schema warehouse)' }
)

# Workspace naming: cts-rtl-<n>-<layer>-<suffix> keeps the layer visible in the
# Fabric workspace picker (which truncates around char 18-20).
$workspaces = @{}
Write-Step "Creating Fabric workspaces (bronze/silver/gold in parallel)"
$wsJobs = foreach ($ws in $workspaceNames) {
    $wsName = "cts-rtl-$($ws.Suffix)-$uniqueSuffix"
    Start-ThreadJob -ScriptBlock {
        param($tok, $capId, $name, $desc, $fabricPs1, $tid)
        . $fabricPs1
        Set-FabricTenant -TenantId $tid
        New-FabricWorkspace -Token $tok -Name $name -CapacityId $capId -Description $desc
    } -ArgumentList $fabricToken, $capacityId, $wsName, $ws.Description, (Join-Path (Join-Path $PSScriptRoot 'scripts') 'Fabric.ps1'), $selectedSub.tenantId -Name "ws-$($ws.Suffix)"
}
$wsJobs | Wait-Job | Out-Null
for ($i = 0; $i -lt $workspaceNames.Count; $i++) {
    $created = Receive-Job -Job $wsJobs[$i]
    Remove-Job -Job $wsJobs[$i]
    $workspaces[$workspaceNames[$i].Suffix] = $created
    Write-Ok "  $($workspaceNames[$i].Suffix): $($created.displayName) (id=$($created.id))"
}

# Create workspace folders up front so every item create call can drop the
# item directly into the right folder via the folderId body field. Avoids
# rate-limited post-hoc /items/{id}/move calls. Bronze keeps top-level
# orchestrators + data sources at root; silver tucks the full-load curation
# notebooks into full_load/. Gold is intentionally flat.
Write-Step "Creating workspace folders (bronze/silver)"
$bronzeFolders = @{}
foreach ($n in 'initial_load','incremental_load','ingest','seed') {
    $bronzeFolders[$n] = (New-FabricFolder -Token $fabricToken -WorkspaceId $workspaces['1-bronze'].id -DisplayName $n).id
    Write-Ok "  bronze/$n = $($bronzeFolders[$n])"
}
$silverFolders = @{}
$silverFolders['full_load'] = (New-FabricFolder -Token $fabricToken -WorkspaceId $workspaces['2-silver'].id -DisplayName 'full_load').id
Write-Ok "  silver/full_load = $($silverFolders['full_load'])"
$silverFolders['shared']    = (New-FabricFolder -Token $fabricToken -WorkspaceId $workspaces['2-silver'].id -DisplayName 'shared').id
Write-Ok "  silver/shared    = $($silverFolders['shared'])"

# Refresh teardown with workspace IDs so a mid-deploy crash from here on
# tears down workspaces AND the RG (workspaces are tenant-scoped, not in RG).
Write-Teardown -Rg $config.RESOURCE_GROUP -Sub $selectedSub.id -Tenant $selectedSub.tenantId -DeployedBy $selectedSub.user.name -Capacity $fabricCapacityName -Workspaces $workspaces.Values
Write-Info "teardown.ps1 refreshed with 3 workspace IDs"

# Provision bronze workspace identity. Used by KQL ingest grant, Fabric SQL
# connection to the gold warehouse, and OneLake/ADLS shortcut auth.
Write-Step "Provisioning workspace identity for the bronze workspace"
$wsIdentity = Enable-FabricWorkspaceIdentity -Token $fabricToken -WorkspaceId $workspaces['1-bronze'].id
Write-Ok "  identity appId=$($wsIdentity.applicationId)"
Write-Info "  Entra display name: $($wsIdentity.displayName)"

# -----------------------------------------------------------------------------
# Apply schema (async). Schema apply takes ~24s and nothing in the next phase
# (bronze lakehouse, storage RBAC) touches SQL, so kick it in the background
# and join right before the workspace-identity SQL grants block needs it.
# -----------------------------------------------------------------------------
Write-Step "Kicking off schema.sql apply in background"

$schemaPath = Join-Path $PSScriptRoot 'schema' 'schema.sql'
if (-not (Test-Path $schemaPath)) {
    throw "Schema file not found at $schemaPath"
}

$schemaAccessToken = (az account get-access-token --resource 'https://database.windows.net/' --output json | ConvertFrom-Json).accessToken
$schemaJob = Start-ThreadJob -Name 'schema-apply' -ScriptBlock {
    param($srv, $db, $tok, $path)
    Import-Module SqlServer -DisableNameChecking
    Invoke-Sqlcmd -ServerInstance $srv -Database $db -AccessToken $tok -InputFile $path -QueryTimeout 120 -ErrorAction Stop
} -ArgumentList $outputs.sqlServerFqdn.value, $outputs.sqlDatabaseName.value, $schemaAccessToken, $schemaPath
Write-Ok "schema apply job started (will be awaited before SQL grants)"

# -----------------------------------------------------------------------------
# Bronze lakehouse.
# -----------------------------------------------------------------------------
Write-Step "Creating bronze lakehouse"
$bronzeLh = New-FabricLakehouse -Token $fabricToken -WorkspaceId $workspaces['1-bronze'].id -Name 'contoso_retail_bronze'
Write-Ok "  bronze lakehouse id=$($bronzeLh.id)"

# Grant the workspace identity Storage Blob Data Reader on the storage account
# so the ADLS shortcut connection can read raw/. RBAC propagation also overlaps
# the seed run. Fire as ThreadJob -- the submit takes ~18s round-trip and
# nothing between here and ADLS shortcut create needs the role.
Write-Step "Granting workspace identity 'Storage Blob Data Reader' on storage account (background)"
$storageId = Invoke-AzWithRetry -Label 'az storage account show' { az storage account show --name $outputs.storageAccount.value --resource-group $config.RESOURCE_GROUP --query id -o tsv }
if (-not $storageId) { throw "Failed to resolve storage account resource id" }
$blobReaderJob = Start-ThreadJob -Name 'storage-blob-reader-grant' -ScriptBlock {
    param($spId, $scope)
    az role assignment create `
        --assignee-object-id $spId `
        --assignee-principal-type ServicePrincipal `
        --role 'Storage Blob Data Reader' `
        --scope $scope `
        --output none 2>&1 | Out-Null
    "OK"
} -ArgumentList $wsIdentity.servicePrincipalId, $storageId
Write-Ok "  grant job started (propagating during downstream work)"

# -----------------------------------------------------------------------------
# Pre-seed SQL+Fabric mirror prep. Done BEFORE the seed (rather than after)
# so that the 5-15min seed runtime doubles as settling time for:
#   - workspace identity propagation into Azure SQL (CREATE USER session bind)
#   - Fabric mirror service warming its token cache for the new SQL user
#   - SAMI Contributor RBAC propagation in Fabric
# Without this lead time the mirror engine's first connect-to-SQL races the
# Entra cache and SQL kills the session with the generic "A severe error
# occurred on the current command" message -- all 18 tables mark Failed on
# the same requestId. Doing it pre-seed eliminates that race in practice.
# Mirror item itself is still created AFTER seed (so the initial snapshot
# captures populated tables instead of empties).
# -----------------------------------------------------------------------------
Write-Step "Waiting for schema apply to finish (required before SQL grants)"
$schemaJob | Wait-Job | Out-Null
$schemaState = $schemaJob.State
$schemaErr = Receive-Job -Job $schemaJob -ErrorAction SilentlyContinue 2>&1
Remove-Job -Job $schemaJob
if ($schemaState -ne 'Completed') { throw "Schema apply failed (state=$schemaState): $schemaErr" }
Write-Ok "schema applied successfully"

Write-Step "Granting workspace identity SQL access + enabling change tracking"
# Workspace identity AAD propagation can lag 30-60s after provisioning. Retry
# CREATE USER until Entra has propagated. db_owner is the simplest grant that
# satisfies both the initial mirror snapshot and ongoing change-tracking reads.
$sqlToken = (az account get-access-token --resource 'https://database.windows.net/' --output json | ConvertFrom-Json).accessToken
# Workspace identity SP: pass both display name (friendly) and the SP's Entra
# object id. WITH OBJECT_ID='<spOid>' tells Azure SQL to bind by Entra object
# id directly instead of doing a Graph lookup by display name. This dodges
# both (a) propagation lag (Graph lookup by name can take several minutes to
# see a brand-new SP) and (b) duplicate-display-name errors from orphan SPs
# left over from prior deployments to the same RG.
# NOTE: OBJECT_ID wants the servicePrincipalId (Entra SP objectId), NOT the
# applicationId. Fabric returns both on workspaceIdentity.
$wsName = $wsIdentity.displayName
$wsOid  = $wsIdentity.servicePrincipalId

# Service principal for the Fabric VNet Data Gateway SQL connection. Mirror's
# gateway-bound connection rejects WorkspaceIdentity credentials
# (DMTS_InvalidCredentialTypeError), so we mint a dedicated SP and grant it
# the same db_owner role. Created here -- BEFORE the SQL grant block -- so a
# single Invoke-Sqlcmd grants both principals in one trip.
Write-Step "Creating service principal for Fabric gateway connection"
$spName = "sp-fabric-mirror-$($outputs.uniqueSuffix.value)"
$spJson = Invoke-AzWithRetry -Label 'az ad sp create-for-rbac' { az ad sp create-for-rbac --display-name $spName --years 1 --role Reader --scopes "/subscriptions/$($selectedSub.id)" -o json 2>$null }
if (-not $spJson) { throw "az ad sp create-for-rbac failed for $spName" }
$sp = $spJson | ConvertFrom-Json
$spAppId  = $sp.appId
$spSecret = $sp.password
# Resolve SP objectId (Entra propagation lag: retry up to 90s).
$spOid = $null
$spOidDeadline = (Get-Date).AddSeconds(90)
while ((Get-Date) -lt $spOidDeadline) {
    $spOid = Invoke-AzWithRetry -Label 'az ad sp show' -AllowNonZeroExit { az ad sp show --id $spAppId --query id -o tsv 2>$null }
    if ($spOid) { break }
    Start-Sleep -Seconds 5
}
if (-not $spOid) { throw "Could not resolve objectId for SP appId=$spAppId after 90s" }
Write-Ok "  SP $spName created (appId=$spAppId, oid=$spOid)"

# Persist SP appId in teardown so it can be deleted on tear-down.
Write-Teardown -Rg $config.RESOURCE_GROUP -Sub $selectedSub.id -Tenant $selectedSub.tenantId -DeployedBy $selectedSub.user.name -Capacity $fabricCapacityName -Workspaces $workspaces.Values -SpAppId $spAppId

$ctSql = @"
IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name = N'$wsName')
    CREATE USER [$wsName] FROM EXTERNAL PROVIDER WITH OBJECT_ID='$wsOid';
ALTER ROLE db_owner ADD MEMBER [$wsName];

IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name = N'$spName')
    CREATE USER [$spName] FROM EXTERNAL PROVIDER WITH OBJECT_ID='$spOid';
ALTER ROLE db_owner ADD MEMBER [$spName];

IF NOT EXISTS (SELECT 1 FROM sys.change_tracking_databases WHERE database_id = DB_ID())
    ALTER DATABASE CURRENT SET CHANGE_TRACKING = ON (CHANGE_RETENTION = 2 DAYS, AUTO_CLEANUP = ON);

DECLARE @t sysname, @s sysname, @sql nvarchar(max);
DECLARE c CURSOR FOR
    SELECT s.name, t.name
    FROM sys.tables t JOIN sys.schemas s ON s.schema_id = t.schema_id
    WHERE s.name = 'retail'
      AND NOT EXISTS (SELECT 1 FROM sys.change_tracking_tables ct WHERE ct.object_id = t.object_id);
OPEN c; FETCH NEXT FROM c INTO @s, @t;
WHILE @@FETCH_STATUS = 0
BEGIN
    SET @sql = N'ALTER TABLE [' + @s + N'].[' + @t + N'] ENABLE CHANGE_TRACKING WITH (TRACK_COLUMNS_UPDATED = OFF);';
    EXEC sp_executesql @sql;
    FETCH NEXT FROM c INTO @s, @t;
END
CLOSE c; DEALLOCATE c;
"@

$ctDeadline = (Get-Date).AddSeconds(600)
while ($true) {
    try {
        Invoke-Sqlcmd `
            -ServerInstance $outputs.sqlServerFqdn.value `
            -Database $outputs.sqlDatabaseName.value `
            -AccessToken $sqlToken `
            -Query $ctSql `
            -QueryTimeout 180 `
            -ErrorAction Stop
        break
    } catch {
        if ($_.Exception.Message -match 'Principal .* could not be (resolved|found)|not found in the directory|is not a valid object id|Msg 37545' -and (Get-Date) -lt $ctDeadline) {
            Write-Info "  workspace identity / SP not yet visible in Entra; retrying in 15s..."
            Start-Sleep -Seconds 15
            continue
        }
        throw
    }
}
Write-Ok "  SQL grants applied for workspace identity + SP; change tracking enabled on retail.* tables"

# -----------------------------------------------------------------------------
# Fabric VNet Data Gateway + gateway-bound SQL connection (Service Principal).
# Replaces the previous WorkspaceIdentity SQL connection. Once this connection
# is healthy, mirror traffic flows through the gateway -> customer-side PE ->
# SQL, so publicNetworkAccess on the SQL server can be Disabled.
# -----------------------------------------------------------------------------
Write-Step "Creating Fabric VNet Data Gateway in $($outputs.vnetName.value)/$($outputs.gatewaySubnetName.value)"
$gateway = New-FabricVNetGateway `
    -Token $fabricToken `
    -DisplayName "gw-vnet-$($outputs.uniqueSuffix.value)" `
    -CapacityId $capacityId `
    -SubscriptionId $selectedSub.id `
    -ResourceGroupName $config.RESOURCE_GROUP `
    -VirtualNetworkName $outputs.vnetName.value `
    -SubnetName $outputs.gatewaySubnetName.value
Write-Ok "  gateway id=$($gateway.id)"

# Persist gateway id for teardown immediately after create (so a crash mid-deploy still cleans up).
Write-Teardown -Rg $config.RESOURCE_GROUP -Sub $selectedSub.id -Tenant $selectedSub.tenantId -DeployedBy $selectedSub.user.name -Capacity $fabricCapacityName -Workspaces $workspaces.Values -SpAppId $spAppId -GatewayId $gateway.id

Write-Step "Creating gateway-bound SQL connection (SP auth)"
$conn = New-FabricSqlGatewayConnection `
    -Token $fabricToken `
    -DisplayName "contoso_retail_sql ($($outputs.sqlServerFqdn.value))" `
    -GatewayId $gateway.id `
    -SqlServerFqdn $outputs.sqlServerFqdn.value `
    -DatabaseName $outputs.sqlDatabaseName.value `
    -TenantId $selectedSub.tenantId `
    -ServicePrincipalAppId $spAppId `
    -ServicePrincipalSecret $spSecret
Write-Ok "  connection id=$($conn.id)"

Write-Teardown -Rg $config.RESOURCE_GROUP -Sub $selectedSub.id -Tenant $selectedSub.tenantId -DeployedBy $selectedSub.user.name -Capacity $fabricCapacityName -Workspaces $workspaces.Values -SpAppId $spAppId -GatewayId $gateway.id -ConnectionIds @($conn.id)

# Mirror requires the Azure SQL logical server's system-assigned managed
# identity (SAMI) to have write access on the mirror item so the snapshot
# engine can push data into OneLake. UI-driven mirror creation grants this
# automatically; REST does NOT. Without this grant, tables stay "Initialized"
# forever, status="Running", no error. Adding the SAMI as a workspace
# Contributor covers all current and future mirror items in the workspace.
Write-Step "Granting Azure SQL server SAMI Contributor on bronze workspace (required for mirroring)"
$sqlSamiPid = Invoke-AzWithRetry -Label 'az sql server show (SAMI pid)' { az sql server show -g $config.RESOURCE_GROUP -n $outputs.sqlServerName.value --query identity.principalId -o tsv }
if (-not $sqlSamiPid) { throw "Azure SQL server has no system-assigned managed identity" }
Add-FabricWorkspaceRoleAssignment `
    -Token $fabricToken `
    -WorkspaceId $workspaces['1-bronze'].id `
    -PrincipalId $sqlSamiPid `
    -PrincipalType 'ServicePrincipal' `
    -Role 'Contributor'
Write-Ok "  granted Contributor to SQL SAMI $sqlSamiPid (propagating during seed run)"

# -----------------------------------------------------------------------------
# Workspace Managed Private Endpoint (bronze -> Azure SQL) for Spark notebook
# JDBC writes (seed, simulate-incremental). Independent of the VNet gateway:
# gateway carries mirror traffic, MPE carries Spark traffic. Must be Approved
# + Succeeded BEFORE the seed notebook runs.
#
# Kicked off in the BACKGROUND here -- MPE provisioning + customer-side PE
# approval takes ~4 min, but it has no dependencies on the Fabric scaffolding
# that follows (silver lakehouse, notebook uploads, pipelines, eventhouse,
# KQL DB, eventstream). Those run in parallel, then we Wait-Job for MPE just
# before disabling SQL public network access.
# -----------------------------------------------------------------------------
Write-Step "Starting workspace Managed Private Endpoint create to SQL (background; ~4 min)"
$sqlServerResId = Invoke-AzWithRetry -Label 'az sql server show (resId)' { az sql server show -g $config.RESOURCE_GROUP -n $outputs.sqlServerName.value --query id -o tsv }
$mpeName = "mpe-sql-$($outputs.uniqueSuffix.value)"
$fabricPs1Path = Join-Path (Join-Path $PSScriptRoot 'scripts') 'Fabric.ps1'
$mpeJob = Start-ThreadJob -Name 'mpe-create' -ScriptBlock {
    param($tok, $wsId, $name, $resId, $fabricPs1, $tid)
    . $fabricPs1
    Set-FabricTenant -TenantId $tid
    New-FabricWorkspaceManagedPrivateEndpoint `
        -Token $tok `
        -WorkspaceId $wsId `
        -Name $name `
        -TargetResourceId $resId `
        -TargetSubresourceType 'sqlServer' `
        -RequestMessage 'Auto-approved by contoso deploy.ps1'
} -ArgumentList $fabricToken, $workspaces['1-bronze'].id, $mpeName, $sqlServerResId, $fabricPs1Path, $selectedSub.tenantId
Write-Ok "  MPE create job started ($mpeName)"

# -----------------------------------------------------------------------------
# All public-network operations are done. Mirror uses the gateway, Spark uses
# the MPE. Flip publicNetworkAccess=Disabled now (instead of waiting until
# end-of-deploy) so the rest of the deploy validates the zero-touch network
# path, and so customer policy can't break us if it flips PNA mid-deploy.
# Also drop the deployer-IP firewall rule so subsequent runs from a different
# IP don't leave stale rules behind.
# -----------------------------------------------------------------------------
Write-Step "Waiting for MPE create to finish (required before PNA can be disabled)"
$mpeJob | Wait-Job | Out-Null
$mpe = Receive-Job -Job $mpeJob
$mpeState = $mpeJob.State
Remove-Job -Job $mpeJob
if ($mpeState -ne 'Completed' -or -not $mpe) { throw "MPE create job ended in state '$mpeState' (result=$mpe)" }
Write-Ok "  MPE $mpeName Approved + Succeeded (id=$($mpe.id))"

Write-Step "Disabling SQL publicNetworkAccess (zero-touch network path from here on)"
Invoke-AzWithRetry -Label 'az sql server update (PNA=Disabled)' { az sql server update -g $config.RESOURCE_GROUP -n $outputs.sqlServerName.value --set publicNetworkAccess=Disabled --output none } | Out-Null
Invoke-AzWithRetry -Label 'az sql firewall-rule delete (AllowDeployerClient)' -AllowNonZeroExit { az sql server firewall-rule delete -g $config.RESOURCE_GROUP -s $outputs.sqlServerName.value -n AllowDeployerClient --yes 2>$null } | Out-Null
Write-Ok "  publicNetworkAccess=Disabled"

# -----------------------------------------------------------------------------
# Upload seed / simulate-incremental / weather notebooks in parallel.
# Each ThreadJob bakes placeholder values into the .ipynb source, writes a
# temp file, and POSTs to Fabric. Three independent REST calls = three
# threads. Saves ~22s vs the sequential loop.
#
# Bake pattern: .ipynb is JSON, so quotes in cell source are escaped as \".
# We replace the escaped empty-string defaults with escaped real values to
# keep JSON valid. Notebooks keep empty-string defaults so they can still be
# run interactively in the Fabric portal.
# -----------------------------------------------------------------------------
$fabricPs1Path = Join-Path (Join-Path $PSScriptRoot 'scripts') 'Fabric.ps1'

$bakeAndUpload = {
    param($tok, $wsId, $name, $srcPath, $replacements, $fabricPs1, $folderId, $tid)
    . $fabricPs1
    Set-FabricTenant -TenantId $tid
    $src = Get-Content -Raw -Path $srcPath
    foreach ($k in $replacements.Keys) { $src = $src.Replace($k, $replacements[$k]) }
    $tmp = Join-Path ([System.IO.Path]::GetTempPath()) "$name.baked.$([guid]::NewGuid()).ipynb"
    Set-Content -Path $tmp -Value $src -NoNewline -Encoding utf8
    try {
        if ($folderId) {
            New-FabricNotebookFromFile -Token $tok -WorkspaceId $wsId -Name $name -NotebookPath $tmp -FolderId $folderId
        } else {
            New-FabricNotebookFromFile -Token $tok -WorkspaceId $wsId -Name $name -NotebookPath $tmp
        }
    } finally {
        Remove-Item $tmp -ErrorAction SilentlyContinue
    }
}

# silver_curated lakehouse is created EARLY (before seed) so the seed notebook
# can materialize empty placeholder Delta tables in it. Those placeholders let
# the gold-workspace silver_curated shortcut lakehouse create OneLake shortcuts
# to all silver_curated paths at deploy time, before any silver_curated_*
# notebook has ever run. Silver notebooks later replace the placeholders via
# overwriteSchema.
Write-Step "Creating silver lakehouse 'contoso_retail_silver_curated' (seed primes placeholders into it)"
$silverCuratedLh = New-FabricLakehouse `
    -Token $fabricToken `
    -WorkspaceId $workspaces['2-silver'].id `
    -Name 'contoso_retail_silver_curated'
Write-Ok "  id=$($silverCuratedLh.id)"

Write-Step "Uploading seed / sim-incremental / weather notebooks in parallel"
$seedNbPath = Join-Path $PSScriptRoot 'fabric' 'notebooks' 'seed' '00_seed_historical_data.ipynb'
$simNbPath  = Join-Path $PSScriptRoot 'fabric' 'notebooks' 'incremental_load' '10_simulate_incremental_activity.ipynb'
$wxNbPath   = Join-Path $PSScriptRoot 'fabric' 'notebooks' 'ingest' 'ingest_weather.ipynb'

$seedJobUpload = Start-ThreadJob -Name 'nb-upload-seed' -ScriptBlock $bakeAndUpload -ArgumentList `
    $fabricToken, $workspaces['1-bronze'].id, '00_seed_historical_data', $seedNbPath, @{
        'sql_server_fqdn   = \"\"'             = "sql_server_fqdn   = \`"$($outputs.sqlServerFqdn.value)\`""
        'sql_database_name = \"contoso_retail\"' = "sql_database_name = \`"$($outputs.sqlDatabaseName.value)\`""
        'storage_account   = \"\"'             = "storage_account   = \`"$($outputs.storageAccount.value)\`""
        'raw_container     = \"raw\"'          = "raw_container     = \`"$($outputs.rawContainer.value)\`""
        'bronze_workspace_id = \"\"'           = "bronze_workspace_id = \`"$($workspaces['1-bronze'].id)\`""
        'bronze_lakehouse_id = \"\"'           = "bronze_lakehouse_id = \`"$($bronzeLh.id)\`""
        'silver_curated_workspace_id = \"\"'   = "silver_curated_workspace_id = \`"$($workspaces['2-silver'].id)\`""
        'silver_curated_lakehouse_id = \"\"'   = "silver_curated_lakehouse_id = \`"$($silverCuratedLh.id)\`""
    }, $fabricPs1Path, $bronzeFolders['seed'], $selectedSub.tenantId

$simJobUpload = Start-ThreadJob -Name 'nb-upload-sim' -ScriptBlock $bakeAndUpload -ArgumentList `
    $fabricToken, $workspaces['1-bronze'].id, '10_simulate_incremental_activity', $simNbPath, @{
        'sql_server_fqdn   = \"\"'             = "sql_server_fqdn   = \`"$($outputs.sqlServerFqdn.value)\`""
        'sql_database_name = \"contoso_retail\"' = "sql_database_name = \`"$($outputs.sqlDatabaseName.value)\`""
        'subscription_id   = \"\"'             = "subscription_id   = \`"$($selectedSub.id)\`""
        'resource_group    = \"\"'             = "resource_group    = \`"$($config.RESOURCE_GROUP)\`""
    }, $fabricPs1Path, $bronzeFolders['incremental_load'], $selectedSub.tenantId

$wxJobUpload = Start-ThreadJob -Name 'nb-upload-weather' -ScriptBlock $bakeAndUpload -ArgumentList `
    $fabricToken, $workspaces['1-bronze'].id, 'ingest_weather', $wxNbPath, @{
        'workspace_id = \"\"' = "workspace_id = \`"$($workspaces['1-bronze'].id)\`""
        'lakehouse_id = \"\"' = "lakehouse_id = \`"$($bronzeLh.id)\`""
    }, $fabricPs1Path, $bronzeFolders['ingest'], $selectedSub.tenantId

@($seedJobUpload, $simJobUpload, $wxJobUpload) | Wait-Job | Out-Null
$seedNb = Receive-Job -Job $seedJobUpload; Remove-Job -Job $seedJobUpload
$simNb  = Receive-Job -Job $simJobUpload;  Remove-Job -Job $simJobUpload
$wxNb   = Receive-Job -Job $wxJobUpload;   Remove-Job -Job $wxJobUpload
if (-not $seedNb -or -not $simNb -or -not $wxNb) { throw "One or more notebook uploads failed (seed=$($null -ne $seedNb), sim=$($null -ne $simNb), wx=$($null -ne $wxNb))" }
Write-Ok "  seed id=$($seedNb.id)"
Write-Ok "  sim  id=$($simNb.id)"
Write-Ok "  wx   id=$($wxNb.id)"

# Create the wrapping pipeline. Stores the notebook id + workspace id in the
# pipeline definition so it can be scheduled or invoked from the orchestration
# pipeline without further parameter wiring.
Write-Step "Creating data pipeline 'pl_bronze_weather_ingest'"
$wxPlPath = Join-Path $PSScriptRoot 'fabric' 'pipelines' 'ingest' 'pl_bronze_weather_ingest' 'pipeline-content.json'
$wxPl = New-FabricDataPipelineFromFile `
    -Token $fabricToken `
    -WorkspaceId $workspaces['1-bronze'].id `
    -Name 'pl_bronze_weather_ingest' `
    -DefinitionPath $wxPlPath `
    -Replacements @{
        '__WEATHER_NOTEBOOK_ID__'  = $wxNb.id
        '__BRONZE_WORKSPACE_ID__'  = $workspaces['1-bronze'].id
    } `
    -FolderId $bronzeFolders['ingest']
Write-Ok "  pipeline id=$($wxPl.id)"

# Orchestration pipeline that bronze layer kicks off for the full initial load.
# Currently fans out only to pl_bronze_weather_ingest; future child pipelines
# (sql backfill, ref data, etc.) get added as additional ExecutePipeline
# activities in the same JSON.
Write-Step "Creating data pipeline 'pl_bronze_initial_load'"
$initPlPath = Join-Path $PSScriptRoot 'fabric' 'pipelines' 'initial_load' 'pl_bronze_initial_load' 'pipeline-content.json'
$initPl = New-FabricDataPipelineFromFile `
    -Token $fabricToken `
    -WorkspaceId $workspaces['1-bronze'].id `
    -Name 'pl_bronze_initial_load' `
    -DefinitionPath $initPlPath `
    -Replacements @{
        '__BRONZE_WORKSPACE_ID__' = $workspaces['1-bronze'].id
        '__WEATHER_PIPELINE_ID__' = $wxPl.id
    } `
    -FolderId $bronzeFolders['initial_load']
Write-Ok "  pipeline id=$($initPl.id)"

Write-Step "Creating data pipeline 'pl_bronze_incremental_load'"
$bronzeIncPlPath = Join-Path $PSScriptRoot 'fabric' 'pipelines' 'incremental_load' 'pl_bronze_incremental_load' 'pipeline-content.json'
$bronzeIncPl = New-FabricDataPipelineFromFile `
    -Token $fabricToken `
    -WorkspaceId $workspaces['1-bronze'].id `
    -Name 'pl_bronze_incremental_load' `
    -DefinitionPath $bronzeIncPlPath `
    -Replacements @{
        '__BRONZE_WORKSPACE_ID__' = $workspaces['1-bronze'].id
        '__WEATHER_PIPELINE_ID__' = $wxPl.id
    } `
    -FolderId $bronzeFolders['incremental_load']
Write-Ok "  pipeline id=$($bronzeIncPl.id)"

# -----------------------------------------------------------------------------
# Real-time clickstream backbone (Eventhouse + KQL DB + Eventstream).
# Moved AHEAD of the seed run so we can fan out three independent long ops
# in parallel: seed notebook (~2:20), backfill notebook (~2:40), function
# deploy (~1:30). Without this, seed was forced to be sequential before the
# eventhouse existed, costing ~2:20 of wall-clock.
#
# CRITICAL: the destination table + ingestion mapping MUST be baked into the
# KQL database definition (DatabaseSchema.kql) at CREATION time. If we create
# the DB empty and add the table later via Kusto mgmt API, the table doesn't
# get registered in Fabric's catalog, the auto-provisioning of the Kusto pull
# data connection never fires, and the eventstream destination stays in
# "Warning" forever with 0 rows ingested. See:
# https://learn.microsoft.com/fabric/real-time-intelligence/event-streams/api-kusto-pull-destination
# -----------------------------------------------------------------------------
Write-Step "Creating Eventhouse 'contoso_retail_events_eh' for real-time clickstream"
$eventhouse = New-FabricEventhouse `
    -Token $fabricToken `
    -WorkspaceId $workspaces['1-bronze'].id `
    -Name 'contoso_retail_events_eh' `
    -Description 'Contoso retail real-time event store'
Write-Ok "  eventhouse id=$($eventhouse.id)"

Write-Step "Creating KQL database 'contoso_retail_events' (with Clickstream table + mapping baked in)"
$schemaKql = @'
.create-merge table Clickstream (
    event_id: string,
    event_ts: datetime,
    event_type: string,
    customer_id: long,
    product_id: long,
    session_id: string,
    device: string,
    channel: string,
    page_url: string
)

.create-or-alter table Clickstream ingestion json mapping 'clickstream_json_map'
```
[
    {"column":"event_id","Properties":{"Path":"$.event_id"}},
    {"column":"event_ts","Properties":{"Path":"$.event_ts"}},
    {"column":"event_type","Properties":{"Path":"$.event_type"}},
    {"column":"customer_id","Properties":{"Path":"$.customer_id"}},
    {"column":"product_id","Properties":{"Path":"$.product_id"}},
    {"column":"session_id","Properties":{"Path":"$.session_id"}},
    {"column":"device","Properties":{"Path":"$.device"}},
    {"column":"channel","Properties":{"Path":"$.channel"}},
    {"column":"page_url","Properties":{"Path":"$.page_url"}}
]
```
'@
$kqldb = New-FabricKqlDatabaseWithSchema `
    -Token $fabricToken `
    -WorkspaceId $workspaces['1-bronze'].id `
    -Name 'contoso_retail_events' `
    -EventhouseItemId $eventhouse.id `
    -SchemaKql $schemaKql `
    -Description 'Clickstream events landing zone'
$kustoUri = $kqldb.properties.queryServiceUri
if (-not $kustoUri) { throw "KQL DB queryServiceUri not returned" }
Write-Ok "  kqldb id=$($kqldb.id) uri=$kustoUri"

Write-Step "Granting workspace identity Ingestor+Viewer on KQL database"
Grant-FabricKqlDatabaseWorkspaceIdentityAccess `
    -QueryServiceUri $kustoUri `
    -DatabaseName 'contoso_retail_events' `
    -WorkspaceIdentityAppId $wsIdentity.applicationId `
    -TenantId $selectedSub.tenantId
Write-Ok "  workspace identity granted ingestor+viewer"

# Creating an Eventhouse auto-provisions a default child KQL DB named after
# the eventhouse (e.g. 'contoso_retail_events_eh'). We don't use that one --
# our schema'd 'contoso_retail_events' DB above is what Eventstream and the
# backfill notebook target. Delete the empty default to keep the workspace
# tidy. Safe: nothing references it.
Write-Step "Removing auto-created default KQL database 'contoso_retail_events_eh'"
try {
    $kqlList = (Invoke-FabricRest -Token $fabricToken -Method GET -Path "/workspaces/$($workspaces['1-bronze'].id)/kqlDatabases").Body
    $defaultDb = $kqlList.value | Where-Object { $_.displayName -eq 'contoso_retail_events_eh' } | Select-Object -First 1
    if ($defaultDb) {
        Invoke-FabricRest -Token $fabricToken -Method DELETE -Path "/workspaces/$($workspaces['1-bronze'].id)/kqlDatabases/$($defaultDb.id)" | Out-Null
        Write-Ok "  removed default KQL DB id=$($defaultDb.id)"
    } else {
        Write-Info "  no default KQL DB found (already removed or naming changed)"
    }
} catch {
    Write-Info "  (non-fatal) failed to remove default KQL DB: $_"
}

Write-Step "Baking Kusto cluster URI into 01_seed_clickstream_backfill and uploading"
$cbNbPath = Join-Path $PSScriptRoot 'fabric' 'notebooks' 'seed' '01_seed_clickstream_backfill.ipynb'
$cbBaked = (Get-Content -Raw -Path $cbNbPath).Replace(
    'kusto_cluster_uri = \"\"',
    "kusto_cluster_uri = \`"$kustoUri\`""
)
$cbBakedPath = Join-Path ([System.IO.Path]::GetTempPath()) "01_seed_clickstream_backfill.baked.$([guid]::NewGuid()).ipynb"
Set-Content -Path $cbBakedPath -Value $cbBaked -NoNewline -Encoding utf8
$cbNb = New-FabricNotebookFromFile `
    -Token $fabricToken `
    -WorkspaceId $workspaces['1-bronze'].id `
    -Name '01_seed_clickstream_backfill' `
    -NotebookPath $cbBakedPath `
    -FolderId $bronzeFolders['seed']
Remove-Item $cbBakedPath -ErrorAction SilentlyContinue
Write-Ok "  baked notebook id=$($cbNb.id)"

Write-Step "Creating Eventstream 'clickstream_es' (CustomEndpoint -> Eventhouse DirectIngestion)"
$es = New-FabricEventstreamWithEventhouseDest `
    -Token $fabricToken `
    -WorkspaceId $workspaces['1-bronze'].id `
    -Name 'clickstream_es' `
    -KqlDatabaseItemId $kqldb.id `
    -TableName 'Clickstream' `
    -MappingRuleName 'clickstream_json_map' `
    -Description 'Clickstream ingestion stream'
Write-Ok "  eventstream id=$($es.eventstreamId) source=$($es.sourceName) dest=$($es.connectionName)"

Write-Step "Fetching CustomEndpoint source SAS connection string"
$eventstreamConnStr = Get-FabricEventstreamSourceConnectionString `
    -Token $fabricToken `
    -WorkspaceId $workspaces['1-bronze'].id `
    -EventstreamId $es.eventstreamId `
    -SourceId $es.sourceId
Write-Ok "  source conn string retrieved ($($eventstreamConnStr.Length) chars)"

# Wire EVENTHUB_CONNECTION_STRING BEFORE OneDeploy. Setting it after the
# deploy triggers a host restart that races the post-deploy
# syncfunctiontriggers call: sync hits the host mid-restart, registers 0
# functions in the metadata blob, scale controller reads 0, host never
# cold-starts, timer never fires, Clickstream stays empty. Set up front so
# the post-deploy sync is the ONLY thing changing host state.
Write-Step "Wiring EVENTHUB_CONNECTION_STRING into Function app settings (pre-deploy)"
Invoke-AzWithRetry -Label 'az functionapp config appsettings set' {
    az functionapp config appsettings set `
        --name $outputs.functionAppName.value `
        --resource-group $config.RESOURCE_GROUP `
        --settings "EVENTHUB_CONNECTION_STRING=$eventstreamConnStr" `
        --output none
} | Out-Null
Write-Ok "  EVENTHUB_CONNECTION_STRING set"

# -----------------------------------------------------------------------------
# 3-way parallel: seed notebook || backfill notebook || function deploy.
# SQL DB is at GP_S_Gen5_8 (min 1.0) so seed has burst headroom; scale-down
# runs --no-wait AFTER seed finishes. Backfill writes into the KQL DB created
# above. Function deploy is independent of both.
# Critical path now = max(seed, backfill) + SQL mirror tail (~20s) instead of
# seed + backfill + func sequential.
# -----------------------------------------------------------------------------
$fabricPs1Path = Join-Path (Join-Path $PSScriptRoot 'scripts') 'Fabric.ps1'

Write-Step "Starting seed notebook in background"
$seedJob = Start-ThreadJob -Name 'seed-nb' -ScriptBlock {
    param($tok, $wsId, $nbId, $fabricPs1, $tid)
    . $fabricPs1
    Set-FabricTenant -TenantId $tid
    Invoke-FabricNotebook -Token $tok -WorkspaceId $wsId -NotebookId $nbId -TimeoutSeconds 3600 -PollSeconds 20
} -ArgumentList $fabricToken, $workspaces['1-bronze'].id, $seedNb.id, $fabricPs1Path, $selectedSub.tenantId
Write-Ok "  seed job started"

Write-Step "Starting clickstream backfill notebook in background (~2M events into KQL; usually 3-6 min, can spike to 15-20 min on Fabric Spark cold start)"
$cbJob = Start-ThreadJob -Name 'backfill-nb' -ScriptBlock {
    param($tok, $wsId, $nbId, $fabricPs1, $tid)
    . $fabricPs1
    Set-FabricTenant -TenantId $tid
    Invoke-FabricNotebook -Token $tok -WorkspaceId $wsId -NotebookId $nbId -TimeoutSeconds 1800 -PollSeconds 20
} -ArgumentList $fabricToken, $workspaces['1-bronze'].id, $cbNb.id, $fabricPs1Path, $selectedSub.tenantId
$cbStarted = Get-Date
$cbNotebookId = $cbNb.id
$cbWorkspaceId = $workspaces['1-bronze'].id
Write-Ok "  backfill job started"

Write-Step "Starting Function App deploy in background (OneDeploy, AAD auth)"
$funcSrc  = Join-Path $PSScriptRoot 'functions\clickstream_emitter'
$funcZip  = Join-Path $env:TEMP "clickstream_emitter_$([guid]::NewGuid().ToString('N')).zip"
if (Test-Path $funcZip) { Remove-Item $funcZip -Force }
Compress-Archive -Path (Join-Path $funcSrc '*') -DestinationPath $funcZip -Force
Write-Info "  zipped -> $funcZip"

$funcAppName = $outputs.functionAppName.value
$funcJob = Start-ThreadJob -Name 'func-deploy' -ScriptBlock {
    param($funcAppName, $funcZip)
    $tok = az account get-access-token --resource https://management.azure.com --query accessToken -o tsv
    if (-not $tok) { throw "Failed to get ARM token for OneDeploy" }
    $publishUri = "https://$funcAppName.scm.azurewebsites.net/api/publish?type=zip&RemoteBuild=true&Deployer=deploy.ps1"
    $deployResp = Invoke-WebRequest -Uri $publishUri `
        -Method POST `
        -Headers @{ Authorization = "Bearer $tok" } `
        -InFile $funcZip `
        -ContentType 'application/zip' `
        -TimeoutSec 300 `
        -UseBasicParsing
    $statusUri = $deployResp.Headers.Location
    if ($statusUri -is [array]) { $statusUri = $statusUri[0] }
    if (-not $statusUri) { throw "OneDeploy did not return a Location header" }
    $deadline = (Get-Date).AddMinutes(10)
    do {
        Start-Sleep -Seconds 10
        try { $st = Invoke-RestMethod -Uri $statusUri -Headers @{ Authorization = "Bearer $tok" } -TimeoutSec 60 }
        catch { Write-Output "    poll error: $($_.Exception.Message)"; continue }
        Write-Output ("    status={0} complete={1}" -f $st.status, $st.complete)
    } while (-not $st.complete -and (Get-Date) -lt $deadline)
    if (-not $st.complete) { throw "Function deploy timed out after 10 min" }
    if ($st.status -ne 4)  { throw "Function deploy failed (status=$($st.status), see $($st.log_url))" }
    "OK"
} -ArgumentList $funcAppName, $funcZip
Write-Ok "  function deploy job started"

Write-Step "Waiting for seed notebook to finish (SQL mirror needs initial data)"
$seedJob | Wait-Job | Out-Null
$jobResult = Receive-Job -Job $seedJob
$seedState = $seedJob.State
Remove-Job -Job $seedJob
if ($seedState -ne 'Completed') { throw "Seed notebook thread job ended in state '$seedState'" }
Write-Ok "Seed notebook completed (status=$($jobResult.status))"

Write-Step "Kicking off SQL DB scale-down to idle-cheap SKU (GP_S_Gen5_4) -- fire-and-forget"
# --no-wait: Azure scales the DB asynchronously; the deploy doesn't depend on
# the new SKU being active to continue (seed already drained the burst headroom
# we needed at Gen5_8). Saves ~50s of wall-clock.
try {
    Invoke-AzWithRetry -Label 'az sql db update (scale-down)' {
        az sql db update `
            --name $outputs.sqlDatabaseName.value `
            --server $outputs.sqlServerName.value `
            --resource-group $config.RESOURCE_GROUP `
            --edition GeneralPurpose `
            --family Gen5 `
            --capacity 4 `
            --min-capacity 0.5 `
            --compute-model Serverless `
            --no-wait `
            --output none
    } | Out-Null
    Write-Ok "  scale-down submitted (will complete in background)"
} catch {
    Write-Info "  (non-fatal) SQL scale-down submit failed; please scale back manually: $_"
}

# -----------------------------------------------------------------------------
# SQL Mirror item + ADLS Shortcut (AFTER seed so initial snapshot is meaningful)
# SQL grants, CT, Fabric connection, and SAMI Contributor were all done BEFORE
# the seed so they've had 5-15min to settle in Entra / Fabric token caches.
# -----------------------------------------------------------------------------
# Refresh Fabric token in case the seed run took close to the 1h expiry
$fabricToken = Get-FabricToken

Write-Step "Kicking off Mirrored Database create in background (snapshot starts during downstream work)"
# Mirror create takes ~24s (POST + Wait-FabricOperation + startMirroring retry
# loop). None of the next steps (ADLS shortcut, backfill wait, func deploy
# wait, eventhub wire, sync triggers, silver_raw lakehouse) need the mirror.
# Run it in parallel; join right before we start polling for mirror tables.
$mirrorJob = Start-ThreadJob -Name 'mirror-create' -ScriptBlock {
    param($tok, $wsId, $connId, $fabricPs1, $tid)
    . $fabricPs1
    Set-FabricTenant -TenantId $tid
    New-FabricMirroredAzureSqlDatabase -Token $tok -WorkspaceId $wsId -Name 'contoso_retail_sql_mirror' -ConnectionId $connId
} -ArgumentList $fabricToken, $workspaces['1-bronze'].id, $conn.id, $fabricPs1Path, $selectedSub.tenantId
Write-Ok "  mirror create job started"

Write-Step "Creating ADLS shortcut from bronze lakehouse Files/raw -> $($outputs.storageAccount.value)/raw"
# Make sure the Storage Blob Data Reader grant submit completed (RBAC plane
# write -- distinct from propagation, which we've been overlapping with seed).
$blobReaderJob | Wait-Job | Out-Null
Receive-Job -Job $blobReaderJob | Out-Null
$blobReaderState = $blobReaderJob.State
Remove-Job -Job $blobReaderJob
if ($blobReaderState -ne 'Completed') { throw "Storage Blob Data Reader grant job ended in state '$blobReaderState'" }
$adlsConn = New-FabricAdlsGen2Connection `
    -Token $fabricToken `
    -DisplayName "contoso_retail_adls ($($outputs.storageAccount.value))" `
    -StorageAccountName $outputs.storageAccount.value `
    -WorkspaceId $workspaces['1-bronze'].id
Write-Ok "  adls connection id=$($adlsConn.id)"

Write-Teardown -Rg $config.RESOURCE_GROUP -Sub $selectedSub.id -Tenant $selectedSub.tenantId -DeployedBy $selectedSub.user.name -Capacity $fabricCapacityName -Workspaces $workspaces.Values -SpAppId $spAppId -GatewayId $gateway.id -ConnectionIds @($conn.id, $adlsConn.id)

$shortcut = New-FabricAdlsShortcut `
    -Token $fabricToken `
    -WorkspaceId $workspaces['1-bronze'].id `
    -LakehouseId $bronzeLh.id `
    -ShortcutName 'raw' `
    -StorageAccountName $outputs.storageAccount.value `
    -Container $outputs.rawContainer.value `
    -ConnectionId $adlsConn.id
Write-Ok "  shortcut created at Files/raw"

# -----------------------------------------------------------------------------
# Drain the backfill notebook + function deploy thread jobs that were started
# in parallel with the seed. By this point SQL mirror has been kicked off, so
# we're free to wait on the other two long ops.
# -----------------------------------------------------------------------------
Write-Step "Waiting for clickstream backfill notebook to finish"
# Heartbeat loop: prints elapsed every 30s so the user can tell the deploy is
# alive vs. wedged. The notebook itself blocks on Spark cold-start (often) +
# Kusto queued ingest (occasionally slow). Soft-warn at 8 min with a link to
# the portal run. Hard ceiling is the TimeoutSeconds=1800 (30 min) inside the
# thread job; we exit this loop when the job ends regardless.
$cbWarnedSlow = $false
$cbPortalUrl = "https://app.fabric.microsoft.com/groups/$cbWorkspaceId/synapsenotebooks/$cbNotebookId"
while ($cbJob.State -eq 'Running' -or $cbJob.State -eq 'NotStarted') {
    Start-Sleep -Seconds 30
    $elapsed = (Get-Date) - $cbStarted
    $mins = [int]$elapsed.TotalMinutes
    $secs = $elapsed.Seconds
    Write-Info ("  [waiting] {0}m{1:00}s elapsed, job state={2}" -f $mins, $secs, $cbJob.State)
    if (-not $cbWarnedSlow -and $elapsed.TotalMinutes -ge 8) {
        Write-Host "  [warn] backfill is running longer than usual (>8 min). This is almost always a transient Fabric Spark cold-start or KQL queued-ingest backlog -- deploy will keep waiting." -ForegroundColor Yellow
        Write-Host ("         portal: $cbPortalUrl") -ForegroundColor Yellow
        $cbWarnedSlow = $true
    }
}
$cbJob | Wait-Job | Out-Null
$cbResult = Receive-Job -Job $cbJob
$cbState = $cbJob.State
Remove-Job -Job $cbJob
if ($cbState -ne 'Completed') { throw "Clickstream backfill thread job ended in state '$cbState' after $([int]((Get-Date) - $cbStarted).TotalMinutes)m. This is almost always transient -- re-run deploy. Portal: $cbPortalUrl" }
Write-Ok "  backfill notebook completed (status=$($cbResult.status), elapsed=$([int]((Get-Date) - $cbStarted).TotalMinutes)m$(((Get-Date) - $cbStarted).Seconds.ToString('00'))s)"

Write-Step "Waiting for Function App deploy job to finish"
$funcJob | Wait-Job | Out-Null
Receive-Job -Job $funcJob | ForEach-Object { Write-Info $_ }
$funcState = $funcJob.State
Remove-Job -Job $funcJob
Remove-Item $funcZip -ErrorAction SilentlyContinue
if ($funcState -ne 'Completed') { throw "Function deploy thread job ended in state '$funcState'" }
Write-Ok "  function deployed -> https://$($outputs.functionHostname.value)"

# Flex Consumption does NOT auto-discover triggers in a freshly-uploaded
# package: scale controller reads function metadata from a control-plane
# blob, not the running host. syncfunctiontriggers writes that blob from
# the deployed package. A single call can race the host (returns 200 but
# registers 0 functions), so we sync-and-verify in a loop: call sync, poll
# `functionapp function list` until non-empty, retry up to 5 times.
# EVENTHUB_CONNECTION_STRING was already set pre-deploy so there's no
# settings-change restart racing this loop.
Write-Step "Syncing function triggers (Flex Consumption requires explicit sync + verify after OneDeploy)"
$syncUri = "https://management.azure.com/subscriptions/$($selectedSub.id)/resourceGroups/$($config.RESOURCE_GROUP)/providers/Microsoft.Web/sites/$($outputs.functionAppName.value)/syncfunctiontriggers?api-version=2022-03-01"
$fnCount = 0
for ($attempt = 1; $attempt -le 5; $attempt++) {
    Invoke-AzWithRetry -Label "az rest syncfunctiontriggers (attempt $attempt)" { az rest --method post --uri $syncUri --output none } | Out-Null
    Start-Sleep -Seconds 15
    $fnList = az functionapp function list --name $outputs.functionAppName.value --resource-group $config.RESOURCE_GROUP --output json 2>$null | ConvertFrom-Json
    $fnCount = if ($fnList) { @($fnList).Count } else { 0 }
    Write-Info "  attempt $attempt -> $fnCount function(s) registered"
    if ($fnCount -gt 0) { break }
}
if ($fnCount -eq 0) { throw "Function triggers never registered after 5 sync attempts -- emitter will not fire" }
Write-Ok "  $fnCount trigger(s) registered"
Write-Info "  emitter fires every 30s -> Fabric Eventstream '$($es.sourceName)' -> Eventhouse 'Clickstream' table"

# -----------------------------------------------------------------------------
# Silver + Gold scaffolding (empty containers only -- notebooks/pipelines/
# shortcuts come in a later phase). Token may be close to expiry by now.
# -----------------------------------------------------------------------------
$fabricToken = Get-FabricToken

Write-Step "Creating silver lakehouse 'contoso_retail_silver_raw' (shortcut target)"
$silverRawLh = New-FabricLakehouse `
    -Token $fabricToken `
    -WorkspaceId $workspaces['2-silver'].id `
    -Name 'contoso_retail_silver_raw'
Write-Ok "  id=$($silverRawLh.id)"

# Kick off the gold warehouse create in parallel; it's independent of the
# mirror, shortcuts, and silver_raw. Lands while we wait on mirror polling
# (~1:46) + create shortcuts. Joined before banner.
Write-Step "Starting gold warehouse create in background"
$goldWhJob = Start-ThreadJob -Name 'gold-wh' -ScriptBlock {
    param($tok, $wsId, $fabricPs1, $tid)
    . $fabricPs1
    Set-FabricTenant -TenantId $tid
    New-FabricWarehouse -Token $tok -WorkspaceId $wsId -Name 'contoso_retail_gold' -Description 'Contoso Retail gold star schema (dim_* / fact_*)'
} -ArgumentList $fabricToken, $workspaces['3-gold'].id, $fabricPs1Path, $selectedSub.tenantId
Write-Ok "  gold warehouse job started"

# silver_raw shortcuts: pure-passthrough views of the bronze-side sources so
# silver notebooks can read everything from one schema-qualified namespace
# (dbo.*) without caring which bronze item the data physically lives in.
#
# - 4 mirror tables (customers/products/orders/order_items) under retail/ in
#   the SQL Mirror item -> dbo.<n> in silver_raw
# - weather Delta in the bronze lakehouse -> dbo.weather
#
# Clickstream stays NATIVE in KQL (real-time query path) and is intentionally
# NOT shortcut'd here. Silver notebooks that need clickstream query the
# eventhouse directly.
#
# Fabric DOES validate shortcut targets at create time, so:
#  1. Poll the mirror via DFS until all 4 expected tables exist
#  2. weather Delta was materialized by the seed notebook's appended
#     init cell -- nothing to do here for it.
Write-Step "Waiting for Mirrored Database create job to finish"
$mirrorJob | Wait-Job | Out-Null
$mirror = Receive-Job -Job $mirrorJob
$mirrorState = $mirrorJob.State
Remove-Job -Job $mirrorJob
if ($mirrorState -ne 'Completed' -or -not $mirror) { throw "Mirror create job ended in state '$mirrorState'" }
Write-Ok "  mirrored db id=$($mirror.id) (initial snapshot starting)"

Write-Step "Waiting for SQL mirror to replicate retail.* tables"
$storTok = (az account get-access-token --resource 'https://storage.azure.com' --query accessToken -o tsv)
if (-not $storTok) { throw "Failed to get storage token for mirror polling" }
$hdr = @{ Authorization = "Bearer $storTok" }
$mirrorReadyDeadline = (Get-Date).AddMinutes(10)
$mirrorTables = @('customers','products','orders','order_items','stores','customer_segments','categories','brands','employees','job_titles','inventory','payments','promotions','returns','reviews','shipments','suppliers','warehouses')
$mirrorStatusPath = "/workspaces/$($workspaces['1-bronze'].id)/mirroredDatabases/$($mirror.id)/getTablesMirroringStatus"
$mirrorStopPath  = "/workspaces/$($workspaces['1-bronze'].id)/mirroredDatabases/$($mirror.id)/stopMirroring"
$mirrorStartPath = "/workspaces/$($workspaces['1-bronze'].id)/mirroredDatabases/$($mirror.id)/startMirroring"
$mirrorRestartsRemaining = 1
while ($true) {
    # Ask Fabric for per-table mirroring status. Failed tables on first start
    # almost always come from the mirror engine's first SQL connect racing
    # Entra/SQL token cache propagation (all 18 tables fail with the same
    # requestId). Stop+start the mirror once to force a fresh connect with
    # caches populated; that recovers cleanly in practice. If it fails again,
    # surface the error.
    try {
        $statusResp = Invoke-FabricRest -Token $fabricToken -Method POST -Path $mirrorStatusPath
        $rows = @($statusResp.Body.data)
        $failed = $rows | Where-Object { $_.status -eq 'Failed' -or $_.error }
        if ($failed) {
            $msg = ($failed | ForEach-Object {
                $errTxt = if ($_.error) { ($_.error | ConvertTo-Json -Compress -Depth 4) } else { '(no error detail)' }
                "$($_.sourceSchemaName).$($_.sourceTableName) -> $($_.status): $errTxt"
            }) -join "; "
            if ($mirrorRestartsRemaining -gt 0) {
                Write-Info "  mirror reported Failed tables; restarting once to clear token-cache race"
                Write-Info "  first failure: $($failed[0].sourceTableName) -> $($failed[0].error.message)"
                $mirrorRestartsRemaining--
                try { Invoke-FabricRest -Token $fabricToken -Method POST -Path $mirrorStopPath | Out-Null } catch { Write-Info "  (stopMirroring threw: $_)" }
                Start-Sleep -Seconds 20
                Invoke-FabricRest -Token $fabricToken -Method POST -Path $mirrorStartPath | Out-Null
                Write-Info "  restart submitted; resuming poll"
                Start-Sleep -Seconds 30
                continue
            }
            throw "SQL mirror reported failures after restart: $msg"
        }
    } catch {
        if ($_.Exception.Message -match 'SQL mirror reported failures') { throw }
        # Fabric service-side transient (e.g. error 9001 "service has encountered
        # an error") on getTablesMirroringStatus. Treated like per-table Failed:
        # one stop+start restart usually clears it.
        if ($_.Exception.Message -match '9001|service has encountered an error' -and $mirrorRestartsRemaining -gt 0) {
            Write-Info "  mirror status API returned service error; restarting once"
            Write-Info "  detail: $($_.Exception.Message)"
            $mirrorRestartsRemaining--
            try { Invoke-FabricRest -Token $fabricToken -Method POST -Path $mirrorStopPath | Out-Null } catch { Write-Info "  (stopMirroring threw: $_)" }
            Start-Sleep -Seconds 20
            Invoke-FabricRest -Token $fabricToken -Method POST -Path $mirrorStartPath | Out-Null
            Write-Info "  restart submitted; resuming poll"
            Start-Sleep -Seconds 30
            continue
        }
        # otherwise keep polling DFS
    }

    $missing = @()
    foreach ($t in $mirrorTables) {
        $u = "https://onelake.dfs.fabric.microsoft.com/$($workspaces['1-bronze'].id)?resource=filesystem&recursive=false&directory=$($mirror.id)/Tables/retail/$t"
        try {
            $r = Invoke-RestMethod -Uri $u -Headers $hdr -ErrorAction Stop
            if (-not $r.paths -or $r.paths.Count -eq 0) { $missing += $t }
        } catch { $missing += $t }
    }
    if ($missing.Count -eq 0) { break }
    if ((Get-Date) -ge $mirrorReadyDeadline) { throw "Mirror tables still not present after 10m: $($missing -join ', ')" }
    Write-Info "  waiting on: $($missing -join ', ')"
    Start-Sleep -Seconds 15
}
Write-Ok "  all $($mirrorTables.Count) mirror tables present in OneLake"

Write-Step "Creating silver_raw shortcuts (Tables/dbo)"
# Mirror fact tables (4) + reference tables (4) needed by silver_curated enrichment.
# Weather (1) is shortcutted from the bronze lakehouse, not the SQL mirror.
$silverShortcuts = @(
    @{ name='customers';         targetItem=$mirror.id;   targetPath='Tables/retail/customers' }
    @{ name='products';          targetItem=$mirror.id;   targetPath='Tables/retail/products' }
    @{ name='orders';            targetItem=$mirror.id;   targetPath='Tables/retail/orders' }
    @{ name='order_items';       targetItem=$mirror.id;   targetPath='Tables/retail/order_items' }
    @{ name='stores';            targetItem=$mirror.id;   targetPath='Tables/retail/stores' }
    @{ name='customer_segments'; targetItem=$mirror.id;   targetPath='Tables/retail/customer_segments' }
    @{ name='categories';        targetItem=$mirror.id;   targetPath='Tables/retail/categories' }
    @{ name='brands';            targetItem=$mirror.id;   targetPath='Tables/retail/brands' }
    @{ name='employees';         targetItem=$mirror.id;   targetPath='Tables/retail/employees' }
    @{ name='job_titles';        targetItem=$mirror.id;   targetPath='Tables/retail/job_titles' }
    @{ name='inventory';         targetItem=$mirror.id;   targetPath='Tables/retail/inventory' }
    @{ name='payments';          targetItem=$mirror.id;   targetPath='Tables/retail/payments' }
    @{ name='promotions';        targetItem=$mirror.id;   targetPath='Tables/retail/promotions' }
    @{ name='returns';           targetItem=$mirror.id;   targetPath='Tables/retail/returns' }
    @{ name='reviews';           targetItem=$mirror.id;   targetPath='Tables/retail/reviews' }
    @{ name='shipments';         targetItem=$mirror.id;   targetPath='Tables/retail/shipments' }
    @{ name='suppliers';         targetItem=$mirror.id;   targetPath='Tables/retail/suppliers' }
    @{ name='warehouses';        targetItem=$mirror.id;   targetPath='Tables/retail/warehouses' }
    @{ name='weather';           targetItem=$bronzeLh.id; targetPath='Tables/dbo/weather' }
)
foreach ($s in $silverShortcuts) {
    New-FabricOneLakeShortcut `
        -Token $fabricToken `
        -HostWorkspaceId $workspaces['2-silver'].id `
        -HostItemId $silverRawLh.id `
        -ShortcutPath 'Tables/dbo' `
        -ShortcutName $s.name `
        -TargetWorkspaceId $workspaces['1-bronze'].id `
        -TargetItemId $s.targetItem `
        -TargetPath $s.targetPath | Out-Null
    Write-Ok "  dbo.$($s.name) -> $($s.targetPath)"
}

# -----------------------------------------------------------------------------
# Gold workspace: silver_curated shortcut lakehouse + shortcuts to the real
# silver_curated lakehouse in the silver workspace. Same name on both sides,
# different workspaces -- 3-part name resolution from the gold warehouse stays
# inside the gold workspace, so sprocs that read
# `contoso_retail_silver_curated.dbo.<t>` resolve to this shortcut lakehouse.
# Avoids cross-workspace Spark connector auth in every sproc.
# Seed notebook already materialized empty placeholder Deltas in silver_curated
# so these shortcuts resolve at create time, before any silver_curated_*
# notebook has ever run.
# -----------------------------------------------------------------------------
Write-Step "Creating shortcut lakehouse 'contoso_retail_silver_curated' in gold workspace"
$goldSilverCuratedLh = New-FabricLakehouse `
    -Token $fabricToken `
    -WorkspaceId $workspaces['3-gold'].id `
    -Name 'contoso_retail_silver_curated'
Write-Ok "  id=$($goldSilverCuratedLh.id)"

Write-Step "Creating shortcuts in gold silver_curated (Tables/dbo -> silver workspace silver_curated)"
$goldShortcuts = @(
    'customer','product','order','order_line','store','employee',
    'weather_daily','session','session_event',
    'supplier','warehouse','promotion',
    'inventory','payment','return','review','shipment'
)
foreach ($t in $goldShortcuts) {
    New-FabricOneLakeShortcut `
        -Token $fabricToken `
        -HostWorkspaceId $workspaces['3-gold'].id `
        -HostItemId $goldSilverCuratedLh.id `
        -ShortcutPath 'Tables/dbo' `
        -ShortcutName $t `
        -TargetWorkspaceId $workspaces['2-silver'].id `
        -TargetItemId $silverCuratedLh.id `
        -TargetPath "Tables/dbo/$t" | Out-Null
    Write-Ok "  dbo.$t -> silver_curated/Tables/dbo/$t"
}

# Lakehouse SQL analytics endpoint does NOT auto-discover shortcut tables --
# without an explicit metadata refresh, the gold warehouse sprocs that read
# from contoso_retail_silver_curated.dbo.<t> fail with "Invalid object name".
# Re-GET the lakehouse to pick up sqlEndpointProperties.id (the list endpoint
# omits it), then POST refreshMetadata. Returns synchronously with per-table
# sync status.
Write-Step "Refreshing gold-workspace silver_curated SQL analytics endpoint metadata (discovers shortcut tables)"
$goldSilverCuratedFull = (Invoke-FabricRest -Token $fabricToken -Method GET -Path "/workspaces/$($workspaces['3-gold'].id)/lakehouses/$($goldSilverCuratedLh.id)").Body
$goldSilverCuratedSepId = $goldSilverCuratedFull.properties.sqlEndpointProperties.id
if (-not $goldSilverCuratedSepId) { throw "gold silver_curated lakehouse has no sqlEndpointProperties.id" }
$refreshResp = Invoke-FabricRest -Token $fabricToken -Method POST -Path "/workspaces/$($workspaces['3-gold'].id)/sqlEndpoints/$goldSilverCuratedSepId/refreshMetadata?preview=true" -Body @{}
$refreshResults = $refreshResp.Body
$failedTables = @($refreshResults | Where-Object { $_.status -notin @('Success','NotRun') })
if ($failedTables.Count -gt 0) {
    throw "gold silver_curated SQL endpoint refresh failed for: $(($failedTables | ForEach-Object { $_.tableName }) -join ', ')"
}
Write-Ok "  refreshed $($refreshResults.Count) tables"

# Same refresh dance for the silver_curated, bronze lakehouse and bronze
# SQL-mirror SEPs so analyst SQL queries (and the SQL endpoint web UI) see
# the populated tables immediately after deploy. Without this, SELECT * FROM
# silver_curated.dbo.weather_daily returns 0 rows until a SEP refresh runs,
# even though OneLake has all the data. NotRun statuses are fine (means no
# delta to sync) -- only Failed is an error.
Write-Step "Refreshing silver_curated / bronze LH / bronze mirror SQL endpoints"
$silverCuratedFull = (Invoke-FabricRest -Token $fabricToken -Method GET -Path "/workspaces/$($workspaces['2-silver'].id)/lakehouses/$($silverCuratedLh.id)").Body
$silverCuratedSepId = $silverCuratedFull.properties.sqlEndpointProperties.id
$bronzeLhFull = (Invoke-FabricRest -Token $fabricToken -Method GET -Path "/workspaces/$($workspaces['1-bronze'].id)/lakehouses/$($bronzeLh.id)").Body
$bronzeLhSepId = $bronzeLhFull.properties.sqlEndpointProperties.id
$bronzeMirrorFull = (Invoke-FabricRest -Token $fabricToken -Method GET -Path "/workspaces/$($workspaces['1-bronze'].id)/mirroredDatabases/$($mirror.id)").Body
$bronzeMirrorSepId = $bronzeMirrorFull.properties.sqlEndpointProperties.id
foreach ($sep in @(
    @{ name='silver_curated'; wsId=$workspaces['2-silver'].id; sepId=$silverCuratedSepId }
    @{ name='bronze_lh';      wsId=$workspaces['1-bronze'].id; sepId=$bronzeLhSepId }
    @{ name='bronze_mirror';  wsId=$workspaces['1-bronze'].id; sepId=$bronzeMirrorSepId }
)) {
    if (-not $sep.sepId) { Write-Info "  $($sep.name): no SEP id, skipping"; continue }
    $r = Invoke-FabricRest -Token $fabricToken -Method POST -Path "/workspaces/$($sep.wsId)/sqlEndpoints/$($sep.sepId)/refreshMetadata?preview=true" -Body @{}
    $f = @($r.Body | Where-Object { $_.status -notin @('Success','NotRun') })
    if ($f.Count -gt 0) { Write-Info "  $($sep.name): $($f.Count) Failed tables (continuing)" }
    Write-Ok "  $($sep.name): $($r.Body.Count) tables"
}

# Tiny helper notebook in the SILVER workspace that re-runs the same
# refreshMetadata call against the gold-workspace silver_curated SEP. The gold
# pipelines invoke it cross-workspace as their first activity so the dim/fact
# sprocs always see the latest silver_curated schema (silver notebooks write
# with overwriteSchema=true). Bakes gold_workspace_id + silver_curated_sep_id
# into the source so the notebook needs no params at activity time. Uses
# notebookutils.credentials.getToken so it runs as the invoking identity.
# Lives in silver because it's an engineering artifact, not a gold deliverable.
Write-Step "Uploading _refresh_silver_curated_sep notebook to silver workspace"
$refreshNbSrc = Join-Path $PSScriptRoot 'fabric' 'notebooks' 'silver_promotion' 'shared' '_refresh_silver_curated_sep.ipynb'
$refreshNbBaked = Join-Path ([System.IO.Path]::GetTempPath()) "_refresh_silver_curated_sep.baked.$([guid]::NewGuid()).ipynb"
$refreshNbSource = Get-Content -Raw -Path $refreshNbSrc
$refreshNbSource = $refreshNbSource.Replace('gold_workspace_id = \"\"', "gold_workspace_id = \`"$($workspaces['3-gold'].id)\`"").Replace('silver_curated_sep_id = \"\"', "silver_curated_sep_id = \`"$goldSilverCuratedSepId\`"")
Set-Content -Path $refreshNbBaked -Value $refreshNbSource -NoNewline -Encoding utf8
try {
    $refreshNb = New-FabricNotebookFromFile -Token $fabricToken -WorkspaceId $workspaces['2-silver'].id -Name '_refresh_silver_curated_sep' -NotebookPath $refreshNbBaked -FolderId $silverFolders['shared']
} finally {
    Remove-Item $refreshNbBaked -ErrorAction SilentlyContinue
}
Write-Ok "  notebook id=$($refreshNb.id)"

# -----------------------------------------------------------------------------
# Gold warehouse: wait for create, apply DDL + sprocs, then create the
# Fabric SQL connection that the gold pipeline activities reference.
# -----------------------------------------------------------------------------
Write-Step "Waiting for gold warehouse create to finish"
$goldWhJob | Wait-Job | Out-Null
$goldWh = Receive-Job -Job $goldWhJob
$goldWhState = $goldWhJob.State
Remove-Job -Job $goldWhJob
if ($goldWhState -ne 'Completed' -or -not $goldWh) { throw "gold warehouse job ended in state '$goldWhState'" }
Write-Ok "  id=$($goldWh.id)"

# Warehouse SQL endpoint hostname lives on the warehouse item properties, but
# the list endpoint doesn't always populate it -- GET the item directly.
$goldWhFull = (Invoke-FabricRest -Token $fabricToken -Method GET -Path "/workspaces/$($workspaces['3-gold'].id)/warehouses/$($goldWh.id)").Body
$goldWhServer = $goldWhFull.properties.connectionString
if (-not $goldWhServer) { throw "gold warehouse has no properties.connectionString -- cannot apply DDL. Full body: $($goldWhFull | ConvertTo-Json -Depth 6)" }
Write-Info "  endpoint: $goldWhServer"

Write-Step "Applying gold warehouse DDL + sprocs (schema.sql + sprocs/*.sql)"
# Refresh token in case time has passed; warehouse uses the same
# database.windows.net resource as Azure SQL.
$whAccessToken = (az account get-access-token --resource 'https://database.windows.net/' --output json | ConvertFrom-Json).accessToken
if (-not $whAccessToken) { throw "Failed to get database.windows.net token for warehouse DDL apply" }
Import-Module SqlServer -DisableNameChecking
$whSchemaPath = Join-Path $PSScriptRoot 'fabric' 'warehouse' 'schema.sql'
Invoke-Sqlcmd -ServerInstance $goldWhServer -Database 'contoso_retail_gold' -AccessToken $whAccessToken -InputFile $whSchemaPath -QueryTimeout 120 -ErrorAction Stop
Write-Ok "  schema.sql applied"
$sprocFiles = Get-ChildItem -Path (Join-Path $PSScriptRoot 'fabric' 'warehouse' 'sprocs') -Filter '*.sql' | Sort-Object Name
foreach ($f in $sprocFiles) {
    Invoke-Sqlcmd -ServerInstance $goldWhServer -Database 'contoso_retail_gold' -AccessToken $whAccessToken -InputFile $f.FullName -QueryTimeout 120 -ErrorAction Stop
    Write-Ok "  $($f.Name)"
}

# -----------------------------------------------------------------------------
# Grant bronze workspace identity Contributor on silver + gold -- needed BEFORE
# the Fabric SQL connection create so the WorkspaceIdentity credential bound
# to bronze WI can authenticate against the gold warehouse, and before the
# silver/gold pipelines run their TridentNotebook + SqlServerStoredProcedure
# activities.
# -----------------------------------------------------------------------------
Write-Step "Granting bronze workspace identity Contributor on silver + gold workspaces"
Add-FabricWorkspaceRoleAssignment `
    -Token $fabricToken `
    -WorkspaceId $workspaces['2-silver'].id `
    -PrincipalId $wsIdentity.servicePrincipalId `
    -PrincipalType 'ServicePrincipal' `
    -Role 'Contributor'
Add-FabricWorkspaceRoleAssignment `
    -Token $fabricToken `
    -WorkspaceId $workspaces['3-gold'].id `
    -PrincipalId $wsIdentity.servicePrincipalId `
    -PrincipalType 'ServicePrincipal' `
    -Role 'Contributor'
Write-Ok "  bronze WI is Contributor on silver + gold"

Write-Step "Creating Fabric SQL connection to gold warehouse (WorkspaceIdentity = bronze WI)"
$goldWhConn = New-FabricSqlConnection `
    -Token $fabricToken `
    -DisplayName "contoso_retail_gold_wh ($($goldWh.id))" `
    -SqlServerFqdn $goldWhServer `
    -DatabaseName 'contoso_retail_gold' `
    -WorkspaceId $workspaces['1-bronze'].id
Write-Ok "  connection id=$($goldWhConn.id)"

Write-Teardown -Rg $config.RESOURCE_GROUP -Sub $selectedSub.id -Tenant $selectedSub.tenantId -DeployedBy $selectedSub.user.name -Capacity $fabricCapacityName -Workspaces $workspaces.Values -SpAppId $spAppId -GatewayId $gateway.id -ConnectionIds @($conn.id, $adlsConn.id, $goldWhConn.id)

# -----------------------------------------------------------------------------
# Silver curated notebooks. Read silver_raw shortcuts + Eventhouse Clickstream
# table, write normalized Delta tables under silver_curated/Tables/dbo/. Schema
# enabled lakehouses require the dbo prefix or tables won't show up in the SQL
# endpoint.
# -----------------------------------------------------------------------------
Write-Step "Uploading silver_curated full-load notebooks (retail / weather / clickstream / hr / ops) in parallel"
$silverNbDir = Join-Path $PSScriptRoot 'fabric' 'notebooks' 'silver_promotion' 'full_load'
$silverWsId  = $workspaces['2-silver'].id
$silverParams = @{
    'silver_raw_workspace_id     = \"\"' = "silver_raw_workspace_id     = \`"$silverWsId\`""
    'silver_raw_lakehouse_id     = \"\"' = "silver_raw_lakehouse_id     = \`"$($silverRawLh.id)\`""
    'silver_curated_workspace_id = \"\"' = "silver_curated_workspace_id = \`"$silverWsId\`""
    'silver_curated_lakehouse_id = \"\"' = "silver_curated_lakehouse_id = \`"$($silverCuratedLh.id)\`""
}
$silverClickstreamParams = @{
    'kusto_cluster_uri           = \"\"' = "kusto_cluster_uri           = \`"$kustoUri\`""
    'silver_curated_workspace_id = \"\"' = "silver_curated_workspace_id = \`"$silverWsId\`""
    'silver_curated_lakehouse_id = \"\"' = "silver_curated_lakehouse_id = \`"$($silverCuratedLh.id)\`""
}
$silverRetailJob = Start-ThreadJob -Name 'nb-upload-silver-retail' -ScriptBlock $bakeAndUpload -ArgumentList `
    $fabricToken, $silverWsId, 'silver_curated_retail_full', (Join-Path $silverNbDir 'silver_curated_retail_full.ipynb'), $silverParams, $fabricPs1Path, $silverFolders['full_load'], $selectedSub.tenantId
$silverWeatherJob = Start-ThreadJob -Name 'nb-upload-silver-weather' -ScriptBlock $bakeAndUpload -ArgumentList `
    $fabricToken, $silverWsId, 'silver_curated_weather_full', (Join-Path $silverNbDir 'silver_curated_weather_full.ipynb'), $silverParams, $fabricPs1Path, $silverFolders['full_load'], $selectedSub.tenantId
$silverClickstreamJob = Start-ThreadJob -Name 'nb-upload-silver-clickstream' -ScriptBlock $bakeAndUpload -ArgumentList `
    $fabricToken, $silverWsId, 'silver_curated_clickstream_full', (Join-Path $silverNbDir 'silver_curated_clickstream_full.ipynb'), $silverClickstreamParams, $fabricPs1Path, $silverFolders['full_load'], $selectedSub.tenantId
$silverHrJob = Start-ThreadJob -Name 'nb-upload-silver-hr' -ScriptBlock $bakeAndUpload -ArgumentList `
    $fabricToken, $silverWsId, 'silver_curated_hr_full', (Join-Path $silverNbDir 'silver_curated_hr_full.ipynb'), $silverParams, $fabricPs1Path, $silverFolders['full_load'], $selectedSub.tenantId
$silverOpsJob = Start-ThreadJob -Name 'nb-upload-silver-ops' -ScriptBlock $bakeAndUpload -ArgumentList `
    $fabricToken, $silverWsId, 'silver_curated_ops_full', (Join-Path $silverNbDir 'silver_curated_ops_full.ipynb'), $silverParams, $fabricPs1Path, $silverFolders['full_load'], $selectedSub.tenantId

@($silverRetailJob, $silverWeatherJob, $silverClickstreamJob, $silverHrJob, $silverOpsJob) | Wait-Job | Out-Null
$silverRetailNb      = Receive-Job -Job $silverRetailJob;      Remove-Job -Job $silverRetailJob
$silverWeatherNb     = Receive-Job -Job $silverWeatherJob;     Remove-Job -Job $silverWeatherJob
$silverClickstreamNb = Receive-Job -Job $silverClickstreamJob; Remove-Job -Job $silverClickstreamJob
$silverHrNb          = Receive-Job -Job $silverHrJob;          Remove-Job -Job $silverHrJob
$silverOpsNb         = Receive-Job -Job $silverOpsJob;         Remove-Job -Job $silverOpsJob
if (-not $silverRetailNb -or -not $silverWeatherNb -or -not $silverClickstreamNb -or -not $silverHrNb -or -not $silverOpsNb) {
    throw "One or more silver notebook uploads failed (retail=$($null -ne $silverRetailNb), weather=$($null -ne $silverWeatherNb), clickstream=$($null -ne $silverClickstreamNb), hr=$($null -ne $silverHrNb), ops=$($null -ne $silverOpsNb))"
}
Write-Ok "  silver_curated_retail_full      id=$($silverRetailNb.id)"
Write-Ok "  silver_curated_weather_full     id=$($silverWeatherNb.id)"
Write-Ok "  silver_curated_clickstream_full id=$($silverClickstreamNb.id)"
Write-Ok "  silver_curated_hr_full          id=$($silverHrNb.id)"
Write-Ok "  silver_curated_ops_full         id=$($silverOpsNb.id)"

# -----------------------------------------------------------------------------
# Silver orchestration pipelines. Live in the BRONZE workspace (alongside the
# top-level orchestrators) so the medallion full/incremental pipelines can
# call them with same-workspace ExecutePipeline -- no cross-workspace
# InvokePipeline + connection auth path (that path 403/'unable to acquire
# user token's on fresh workspace identities and there's no way to prime it).
# The silver_curated_* notebooks themselves still live in the silver
# workspace; these pipelines call them cross-workspace via TridentNotebook,
# which works because the bronze WI is Contributor on silver (granted below).
# -----------------------------------------------------------------------------
Write-Step "Creating data pipeline 'pl_silver_initial_load' in bronze workspace"
$silverPlPath = Join-Path $PSScriptRoot 'fabric' 'pipelines' 'initial_load' 'pl_silver_initial_load' 'pipeline-content.json'
$silverPl = New-FabricDataPipelineFromFile `
    -Token $fabricToken `
    -WorkspaceId $workspaces['1-bronze'].id `
    -Name 'pl_silver_initial_load' `
    -DefinitionPath $silverPlPath `
    -Replacements @{
        '__SILVER_WORKSPACE_ID__'              = $silverWsId
        '__SILVER_RETAIL_NOTEBOOK_ID__'        = $silverRetailNb.id
        '__SILVER_WEATHER_NOTEBOOK_ID__'       = $silverWeatherNb.id
        '__SILVER_CLICKSTREAM_NOTEBOOK_ID__'   = $silverClickstreamNb.id
        '__SILVER_HR_NOTEBOOK_ID__'            = $silverHrNb.id
        '__SILVER_OPS_NOTEBOOK_ID__'           = $silverOpsNb.id
    } `
    -FolderId $bronzeFolders['initial_load']
Write-Ok "  pipeline id=$($silverPl.id)"

Write-Step "Creating data pipeline 'pl_silver_incremental_load' in bronze workspace"
$silverIncPlPath = Join-Path $PSScriptRoot 'fabric' 'pipelines' 'incremental_load' 'pl_silver_incremental_load' 'pipeline-content.json'
$silverIncPl = New-FabricDataPipelineFromFile `
    -Token $fabricToken `
    -WorkspaceId $workspaces['1-bronze'].id `
    -Name 'pl_silver_incremental_load' `
    -DefinitionPath $silverIncPlPath `
    -Replacements @{
        '__SILVER_WORKSPACE_ID__'              = $silverWsId
        '__SILVER_RETAIL_NOTEBOOK_ID__'        = $silverRetailNb.id
        '__SILVER_WEATHER_NOTEBOOK_ID__'       = $silverWeatherNb.id
        '__SILVER_CLICKSTREAM_NOTEBOOK_ID__'   = $silverClickstreamNb.id
        '__SILVER_HR_NOTEBOOK_ID__'            = $silverHrNb.id
        '__SILVER_OPS_NOTEBOOK_ID__'           = $silverOpsNb.id
    } `
    -FolderId $bronzeFolders['incremental_load']
Write-Ok "  pipeline id=$($silverIncPl.id)"

# -----------------------------------------------------------------------------
# Gold pipelines. Live in bronze (same reason as silver pipelines). Every
# activity is a SqlServerStoredProcedure call against contoso_retail_gold via
# the Fabric SQL connection bound to the bronze workspace identity. Initial
# load runs all 6 dim sprocs in parallel then fans out 4 fact sprocs (each
# depending only on the dims it joins to). Sprocs are DROP + CTAS from the
# contoso_retail_silver_curated shortcut lakehouse in the gold workspace, so
# re-runs are idempotent (incremental == initial).
# -----------------------------------------------------------------------------
Write-Step "Creating data pipeline 'pl_gold_initial_load' in bronze workspace"
$goldPlPath = Join-Path $PSScriptRoot 'fabric' 'pipelines' 'initial_load' 'pl_gold_initial_load' 'pipeline-content.json'
$goldPl = New-FabricDataPipelineFromFile `
    -Token $fabricToken `
    -WorkspaceId $workspaces['1-bronze'].id `
    -Name 'pl_gold_initial_load' `
    -DefinitionPath $goldPlPath `
    -Replacements @{
        '__WAREHOUSE_CONNECTION_ID__'    = $goldWhConn.id
        '__GOLD_WORKSPACE_ID__'          = $workspaces['3-gold'].id
        '__SILVER_WORKSPACE_ID__'        = $silverWsId
        '__REFRESH_SEP_NOTEBOOK_ID__'    = $refreshNb.id
    } `
    -FolderId $bronzeFolders['initial_load']
Write-Ok "  pipeline id=$($goldPl.id)"

Write-Step "Creating data pipeline 'pl_gold_incremental_load' in bronze workspace"
$goldIncPlPath = Join-Path $PSScriptRoot 'fabric' 'pipelines' 'incremental_load' 'pl_gold_incremental_load' 'pipeline-content.json'
$goldIncPl = New-FabricDataPipelineFromFile `
    -Token $fabricToken `
    -WorkspaceId $workspaces['1-bronze'].id `
    -Name 'pl_gold_incremental_load' `
    -DefinitionPath $goldIncPlPath `
    -Replacements @{
        '__WAREHOUSE_CONNECTION_ID__'    = $goldWhConn.id
        '__GOLD_WORKSPACE_ID__'          = $workspaces['3-gold'].id
        '__SILVER_WORKSPACE_ID__'        = $silverWsId
        '__REFRESH_SEP_NOTEBOOK_ID__'    = $refreshNb.id
    } `
    -FolderId $bronzeFolders['incremental_load']
Write-Ok "  pipeline id=$($goldIncPl.id)"

# -----------------------------------------------------------------------------
# Top-level medallion orchestrators. Live in bronze; all child pipelines also
# live in bronze, so every activity is same-workspace ExecutePipeline. The
# silver child pipelines reach across to the silver workspace at the notebook
# level (TridentNotebook), which only needs RBAC -- not a connection.
# -----------------------------------------------------------------------------
Write-Step "Creating data pipeline 'pl_initial_load' in bronze workspace"
$fullPlPath = Join-Path $PSScriptRoot 'fabric' 'pipelines' 'pl_initial_load' 'pipeline-content.json'
$fullPl = New-FabricDataPipelineFromFile `
    -Token $fabricToken `
    -WorkspaceId $workspaces['1-bronze'].id `
    -Name 'pl_initial_load' `
    -DefinitionPath $fullPlPath `
    -Replacements @{
        '__BRONZE_INITIAL_LOAD_PIPELINE_ID__'  = $initPl.id
        '__SILVER_INITIAL_LOAD_PIPELINE_ID__'  = $silverPl.id
        '__GOLD_INITIAL_LOAD_PIPELINE_ID__'    = $goldPl.id
    }
Write-Ok "  pipeline id=$($fullPl.id)"

Write-Step "Creating data pipeline 'pl_incremental_load' in bronze workspace"
$fullIncPlPath = Join-Path $PSScriptRoot 'fabric' 'pipelines' 'pl_incremental_load' 'pipeline-content.json'
$fullIncPl = New-FabricDataPipelineFromFile `
    -Token $fabricToken `
    -WorkspaceId $workspaces['1-bronze'].id `
    -Name 'pl_incremental_load' `
    -DefinitionPath $fullIncPlPath `
    -Replacements @{
        '__BRONZE_INCREMENTAL_LOAD_PIPELINE_ID__'  = $bronzeIncPl.id
        '__SILVER_INCREMENTAL_LOAD_PIPELINE_ID__'  = $silverIncPl.id
        '__GOLD_INCREMENTAL_LOAD_PIPELINE_ID__'    = $goldIncPl.id
        '__SIM_NOTEBOOK_ID__'                      = $simNb.id
        '__BRONZE_WORKSPACE_ID__'                  = $workspaces['1-bronze'].id
        '__MIRROR_ITEM_ID__'                       = $mirror.id
    }
Write-Ok "  pipeline id=$($fullIncPl.id)"

# -----------------------------------------------------------------------------
# Gold workspace folders: Retail / HR. Keeps the workspace tidy as the number
# of semantic models, reports, and data agents grows. Datastores
# (warehouse, lakehouse, SQLEndpoint) stay at root.
# -----------------------------------------------------------------------------
Write-Step "Creating gold workspace folders (Retail / HR)"
$goldFolders = @{}
$goldFolders['Retail'] = (New-FabricFolder -Token $fabricToken -WorkspaceId $workspaces['3-gold'].id -DisplayName 'Retail').id
Write-Ok "  gold/Retail = $($goldFolders['Retail'])"
$goldFolders['HR']     = (New-FabricFolder -Token $fabricToken -WorkspaceId $workspaces['3-gold'].id -DisplayName 'HR').id
Write-Ok "  gold/HR     = $($goldFolders['HR'])"

# -----------------------------------------------------------------------------
# Semantic models (TMDL, DirectLake on the gold warehouse)
# Split intentionally: Retail Sales (orders/sales/payments/etc.) vs.
# HR & Workforce (dim_employee). Separate audiences, separate RLS surfaces,
# very different refresh / size profiles.
# -----------------------------------------------------------------------------
Write-Step "Creating semantic model 'Retail Sales' in gold workspace"
$smSubs = @{
    '__WAREHOUSE_SQL_ENDPOINT__' = $goldWhServer
    '__WAREHOUSE_NAME__'         = 'contoso_retail_gold'
}
$smRoot = Join-Path $PSScriptRoot 'fabric' 'semantic_models'
$smRetail = New-FabricSemanticModel `
    -Token $fabricToken `
    -WorkspaceId $workspaces['3-gold'].id `
    -Name 'Retail Sales' `
    -DefinitionRoot (Join-Path $smRoot 'sm_retail_sales') `
    -Replacements $smSubs `
    -FolderId $goldFolders['Retail']
Write-Ok "  id=$($smRetail.id)"

Write-Step "Creating semantic model 'HR & Workforce' in gold workspace"
$smHr = New-FabricSemanticModel `
    -Token $fabricToken `
    -WorkspaceId $workspaces['3-gold'].id `
    -Name 'HR & Workforce' `
    -DefinitionRoot (Join-Path $smRoot 'sm_hr_workforce') `
    -Replacements $smSubs `
    -FolderId $goldFolders['HR']
Write-Ok "  id=$($smHr.id)"

# -----------------------------------------------------------------------------
# Reports (PBIR-Legacy) -- two per semantic model, wired via byConnection.
# Source: fabric/reports/<slug>/  (regenerate with tools/build-reports.ps1).
# -----------------------------------------------------------------------------
$reportsRoot = Join-Path $PSScriptRoot 'fabric' 'reports'
$reports = @(
    @{ slug='rpt_sales_overview';   name='Retail - Sales Overview';     smId=$smRetail.id; folderId=$goldFolders['Retail'] }
    @{ slug='rpt_sales_operations'; name='Retail - Operations';         smId=$smRetail.id; folderId=$goldFolders['Retail'] }
    @{ slug='rpt_hr_workforce';     name='HR - Workforce Overview';     smId=$smHr.id;     folderId=$goldFolders['HR']     }
    @{ slug='rpt_hr_attrition';     name='HR - Attrition & Tenure';     smId=$smHr.id;     folderId=$goldFolders['HR']     }
)
foreach ($rpt in $reports) {
    Write-Step "Creating report '$($rpt.name)' in gold workspace"
    $r = New-FabricReport `
        -Token $fabricToken `
        -WorkspaceId $workspaces['3-gold'].id `
        -Name $rpt.name `
        -DefinitionRoot (Join-Path $reportsRoot $rpt.slug) `
        -Replacements @{ '__SEMANTIC_MODEL_ID__' = $rpt.smId } `
        -FolderId $rpt.folderId
    Write-Ok "  id=$($r.id)"
}

# -----------------------------------------------------------------------------
# Data Agents -- one per semantic model. Built from the model's TMSL
# (lineageTags -> element ids), placed in the matching folder.
# -----------------------------------------------------------------------------
Write-Step "Creating Fabric Data Agents (Retail Sales / HR & Workforce)"
& (Join-Path $PSScriptRoot 'tools' 'deploy-data-agents.ps1') `
    -DeploymentRoot $PSScriptRoot `
    -WorkspaceId   $workspaces['3-gold'].id `
    -RetailFolderId $goldFolders['Retail'] `
    -HrFolderId     $goldFolders['HR']
Write-Ok "  data agents deployed"

# -----------------------------------------------------------------------------
# Done (checkpoint 1: bronze-only, ready for manual silver/gold build-out)
# -----------------------------------------------------------------------------
Write-Done -NoTotal
Write-Host ""
Write-Host ""
Write-Host "============================================================" -ForegroundColor Green
Write-Host "  Deployment Complete" -ForegroundColor Green
Write-Host "============================================================" -ForegroundColor Green
Write-Host ""
Write-Host "Connect to your database:" -ForegroundColor Yellow
Write-Host "  Server:   $($outputs.sqlServerFqdn.value)"
Write-Host "  Database: $($outputs.sqlDatabaseName.value)"
Write-Host "  Auth:     Microsoft Entra ID (your account)"
Write-Host ""
Write-Host "Storage account:" -ForegroundColor Yellow
Write-Host "  Account:    $($outputs.storageAccount.value)"
Write-Host "  DFS URL:    $($outputs.storageDfsEndpoint.value)"
Write-Host "  Containers: $($outputs.rawContainer.value), $($outputs.curatedContainer.value)"
Write-Host ""
Write-Host "Fabric workspaces (capacity '$fabricCapacityName'):" -ForegroundColor Yellow
Write-Host "  Bronze: $($workspaces['1-bronze'].displayName)   (id=$($workspaces['1-bronze'].id))"
Write-Host "  Silver: $($workspaces['2-silver'].displayName)   (id=$($workspaces['2-silver'].id))"
Write-Host "  Gold:   $($workspaces['3-gold'].displayName)     (id=$($workspaces['3-gold'].id))"
Write-Host ""
Write-Host "Bronze workspace contents:" -ForegroundColor Yellow
Write-Host "  Lakehouse:        contoso_retail_bronze"
Write-Host "  Seed notebook:    00_seed_historical_data (already executed)"
Write-Host "  Weather notebook: ingest_weather             (run by pl_bronze_weather_ingest; incremental backfill+catchup)"
Write-Host "  Pipeline:         pl_bronze_weather_ingest"
Write-Host "  Pipeline:         pl_bronze_initial_load     (bronze orchestrator -- runs pl_bronze_weather_ingest today; more child pipelines TBD)"
Write-Host "  Pipeline:         pl_bronze_incremental_load (same wiring; idempotent re-run / schedule entry point)"
Write-Host "  Pipeline:         pl_silver_initial_load     (fans out the five silver_curated_* notebooks in the silver workspace)"
Write-Host "  Pipeline:         pl_silver_incremental_load (same fan-out; idempotent re-run / schedule entry point)"
Write-Host "  Pipeline:         pl_gold_initial_load       (19 activities: SEP refresh -> 9 dim sprocs in parallel -> 9 fact sprocs)"
Write-Host "  Pipeline:         pl_gold_incremental_load   (same DROP+CTAS sprocs; re-run IS the incremental path)"
Write-Host "  Pipeline:         pl_initial_load            (TOP-LEVEL medallion orchestrator -- bronze initial -> silver initial -> gold initial)"
Write-Host "  Pipeline:         pl_incremental_load        (TOP-LEVEL incremental orchestrator -- bronze incremental -> silver incremental -> gold incremental)"
Write-Host "  Mirrored DB:      contoso_retail_sql_mirror (initial snapshot in progress)"
Write-Host "  Shortcut:         Files/raw -> $($outputs.storageAccount.value)/raw"
Write-Host ""
Write-Host "Silver workspace contents:" -ForegroundColor Yellow
Write-Host "  Lakehouse (raw):     contoso_retail_silver_raw      (shortcuts: dbo.customers, dbo.products, dbo.orders, dbo.order_items, dbo.stores, dbo.customer_segments, dbo.categories, dbo.brands, dbo.employees, dbo.job_titles, dbo.inventory, dbo.payments, dbo.promotions, dbo.returns, dbo.reviews, dbo.shipments, dbo.suppliers, dbo.warehouses, dbo.weather)"
Write-Host "  Lakehouse (curated): contoso_retail_silver_curated  (silver_curated_* notebook write target; 17 empty placeholder Deltas materialized by seed for shortcut bootstrap)"
Write-Host "  Notebooks (silver_promotion/full_load/): silver_curated_retail_full (customer/product/order/order_line/store with cross-source enrichment),"
Write-Host "                                           silver_curated_weather_full (weather_daily with derived flags),"
Write-Host "                                           silver_curated_clickstream_full (session + session_event from Eventhouse),"
Write-Host "                                           silver_curated_hr_full (employee denormalized with title/store/manager + tenure/age/salary bands),"
Write-Host "                                           silver_curated_ops_full (inventory/payment/promotion/return/review/shipment/supplier/warehouse passthrough + derived flags)"
Write-Host "  Notebooks (silver_promotion/shared/): _refresh_silver_curated_sep (refreshes the gold-workspace shortcut SEP; invoked by both pl_gold_* pipelines cross-workspace)"
Write-Host "  (silver_curated_* notebooks are invoked cross-workspace by the pl_silver_* pipelines that live in the bronze workspace.)"
Write-Host ""
Write-Host "Gold workspace contents:" -ForegroundColor Yellow
Write-Host "  Lakehouse:        contoso_retail_silver_curated (shortcut lakehouse -- 17 Tables/dbo shortcuts into the silver-workspace silver_curated; sprocs read from here via 3-part name)"
Write-Host "  Warehouse:        contoso_retail_gold"
Write-Host "    Dimensions:     dim_date (fiscal year starts July 1), dim_customer, dim_product, dim_store, dim_channel, dim_employee, dim_supplier, dim_warehouse, dim_promotion"
Write-Host "    Facts:          fact_orders, fact_sales, fact_weather_daily, fact_sessions, fact_inventory, fact_payments, fact_returns, fact_reviews, fact_shipments"
Write-Host "    Sprocs:         sp_RecreateDim* (x9), sp_RecreateFact* (x9) -- all DROP TABLE IF EXISTS + CTAS from silver_curated.dbo.*"
Write-Host "    (Populated by pl_gold_initial_load -- or pl_initial_load. Empty placeholder rows until silver_curated runs at least once.)"
Write-Host "  Semantic models:  Retail Sales (orders/sales/payments/shipments/returns/reviews/inventory; DirectLake)"
Write-Host "                    HR & Workforce (dim_employee with headcount/attrition/tenure/payroll measures; DirectLake)"
Write-Host "  Reports:          Retail - Sales Overview, Retail - Operations"
Write-Host "                    HR - Workforce Overview, HR - Attrition & Tenure"
Write-Host ""
Write-Host "Streaming source:" -ForegroundColor Yellow
Write-Host "  Eventhouse:       contoso_retail_events_eh    (default KQL DB removed; events live in 'contoso_retail_events')"
Write-Host "  KQL DB / table:   contoso_retail_events / Clickstream"
Write-Host "  Eventstream:      clickstream_es (CustomEndpoint -> Eventhouse DirectIngestion)"
Write-Host "  Emitter:          $($outputs.functionAppName.value) (fires every 30s, ~50 events/fire)"
Write-Host ""

# -----------------------------------------------------------------------------
# Auto-run pl_initial_load FIRST (if enabled) so the Next Steps banner can
# point the user at live status + reports instead of "go run it yourself".
#
# When DEPLOY_PURVIEW=true, we then run Purview pre-data phases (collection,
# RBAC, register sources, SQL+ADLS scans, domains, glossary, term rels, term
# policies) in foreground while pl_initial_load runs in parallel. Once the
# medallion finishes we poll-wait, then run the post-data phases (Fabric scan,
# data products, OKRs, DP access policies, CDEs) which all need populated
# Fabric assets.
# -----------------------------------------------------------------------------
$autoRun       = ($config['AUTO_RUN_INITIAL_LOAD'] -eq 'true')
$deployPurview = $deployPurviewPlanned

# Purview Fabric scan can't run on empty lakehouses. Force auto-run if Purview
# was requested but auto-run was not (web UI already enforces this; this is the
# belt-and-suspenders for hand-edited deployment.config or stale packages).
if ($deployPurview -and -not $autoRun) {
    Write-Info "DEPLOY_PURVIEW=true forces AUTO_RUN_INITIAL_LOAD=true (Fabric scan needs populated lakehouses)"
    $autoRun = $true
}

$autoRunSubmitted     = $false
$pipelineJobStatusUri = $null
$bronzeWsUrl  = "https://app.fabric.microsoft.com/groups/$($workspaces['1-bronze'].id)"
$goldWsUrl    = "https://app.fabric.microsoft.com/groups/$($workspaces['3-gold'].id)"
$pipelineUrl  = "https://app.fabric.microsoft.com/groups/$($workspaces['1-bronze'].id)/pipelines/$($fullPl.id)"
$monitorUrl   = "https://app.fabric.microsoft.com/monitoringhub"

if ($autoRun) {
    Write-Step "Triggering pl_initial_load (id=$($fullPl.id)) -- AUTO_RUN_INITIAL_LOAD=true"
    try {
        $kickToken = Get-FabricToken
        # Capture the job-status URI from the Location header so we can poll
        # later if DEPLOY_PURVIEW=true; otherwise it stays fire-and-forget.
        $kick = Invoke-FabricRest -Token $kickToken -Method POST `
            -Path "/workspaces/$($workspaces['1-bronze'].id)/items/$($fullPl.id)/jobs/instances?jobType=Pipeline"
        $pipelineJobStatusUri = if ($kick.OperationLocation) { $kick.OperationLocation } else { $null }
        Write-Ok "pl_initial_load run submitted (runs ~30-60 min in the background)"
        $autoRunSubmitted = $true
    } catch {
        Write-Host "Failed to submit pl_initial_load: $_" -ForegroundColor Red
        Write-Host "  Trigger it manually from the Fabric portal: $pipelineUrl" -ForegroundColor Yellow
    }
} else {
    Write-Info "AUTO_RUN_INITIAL_LOAD=false -- skipping initial load. You'll run pl_initial_load yourself from the Fabric portal."
}
Write-Host ""

# Purview pre-data phases run NOW, in parallel with pl_initial_load. SQL/ADLS
# data is already populated by the seed notebook, so 09's scans find their
# source data even while the Fabric medallion is still building.
if ($deployPurview) {
    Write-Step "Purview governance -- pre-data phases (collection, RBAC, SQL+ADLS scans, domains, terms)"
    try {
        & (Join-Path $PSScriptRoot 'governance' 'purview' 'run-all.ps1') `
            -ResourceGroup $config.RESOURCE_GROUP `
            -Mode PreData
        Write-Ok "Purview pre-data phases complete"
    } catch {
        Write-Host "Purview pre-data error (continuing): $_" -ForegroundColor DarkYellow
    }
    Write-Host ""
}

# Block on pl_initial_load completion before the Fabric scan (post-data phase
# 10). The Fabric scan walks Fabric workspaces and surfaces lakehouse tables /
# warehouse tables / semantic models as datamap entities; without a populated
# medallion the scan returns mostly empty placeholders and phase 13/18 can't
# wire their `fabric_*` and `powerbi_dataset` assets.
if ($deployPurview -and $autoRunSubmitted -and $pipelineJobStatusUri) {
    Write-Step "Waiting for pl_initial_load to finish before Fabric scan..."
    $waitDeadline = (Get-Date).AddMinutes(90)
    $lastStatus   = $null
    while ((Get-Date) -lt $waitDeadline) {
        try {
            $waitToken = Get-FabricToken
            $st = Invoke-FabricRest -Token $waitToken -Method GET -Path $pipelineJobStatusUri
            $s  = $st.Body.status
            if ($s -ne $lastStatus) {
                Write-Host "  pl_initial_load status: $s" -ForegroundColor DarkGray
                $lastStatus = $s
            }
            if ($s -in 'Completed','Succeeded') {
                Write-Ok "pl_initial_load completed ($s)"
                break
            }
            if ($s -in 'Failed','Cancelled','Deduped') {
                Write-Host "  pl_initial_load ended with status '$s' -- running Fabric scan anyway (best-effort)" -ForegroundColor DarkYellow
                break
            }
        } catch {
            Write-Host "  poll error (will retry): $_" -ForegroundColor DarkYellow
        }
        Start-Sleep -Seconds 60
    }
    if ((Get-Date) -ge $waitDeadline) {
        Write-Host "  pl_initial_load did not finish within 90 min -- proceeding with Fabric scan anyway (may find empty lakehouses)" -ForegroundColor DarkYellow
    }
    Write-Host ""
}

# Purview post-data phases: Fabric scan, data products (wires `fabric_*` and
# `powerbi_dataset` assets surfaced by the Fabric scan), OKRs (link to DPs),
# DP access policies (depend on DPs), CDEs + column links (walk scan columns).
if ($deployPurview) {
    Write-Step "Purview governance -- post-data phases (Fabric scan, data products, OKRs, DP policies, CDEs)"
    try {
        & (Join-Path $PSScriptRoot 'governance' 'purview' 'run-all.ps1') `
            -ResourceGroup $config.RESOURCE_GROUP `
            -Mode PostData
        Write-Ok "Purview post-data phases complete"
    } catch {
        Write-Host "Purview post-data error (continuing): $_" -ForegroundColor DarkYellow
    }
    Write-Host ""
}

Write-Host "Next steps:" -ForegroundColor Gray
if ($deployPurview -and $autoRunSubmitted) {
    Write-Host "  - Your initial medallion load + Purview governance build are DONE (we waited for pl_initial_load before running the Fabric scan)." -ForegroundColor Gray
    Write-Host "  - Open the GOLD workspace to find your reports + data agents:" -ForegroundColor Gray
    Write-Host "      $goldWsUrl" -ForegroundColor Blue
    Write-Host "      (Retail/ folder: Sales Overview, Operations Pulse. HR/ folder: Workforce, Attrition.)" -ForegroundColor DarkGray
    Write-Host "  - Open Purview to explore the governance layer (collection, domains, glossary, data products, OKRs, CDEs):" -ForegroundColor Gray
    Write-Host "      https://web.purview.azure.com/" -ForegroundColor Blue
    Write-Host "  - Chat with the data agents for natural-language Q&A over the gold semantic models." -ForegroundColor Gray
    Write-Host "  - Trigger pl_incremental_load any time to backfill from the last sync up to NOW (whether that's an hour or 5 months) and watch it propagate through the medallion." -ForegroundColor Gray
} elseif ($autoRunSubmitted) {
    Write-Host "  - Your initial medallion load is RUNNING. Watch it in the Fabric Monitor hub:" -ForegroundColor Gray
    Write-Host "      $monitorUrl" -ForegroundColor Blue
    Write-Host "      (~30-60 min: bronze SQL mirror snapshot -> silver curated notebooks -> gold warehouse sprocs -> Direct Lake refresh)" -ForegroundColor DarkGray
    Write-Host "  - When it's done, open the GOLD workspace to find your reports + data agents:" -ForegroundColor Gray
    Write-Host "      $goldWsUrl" -ForegroundColor Blue
    Write-Host "      (Retail/ folder: Sales Overview, Operations Pulse. HR/ folder: Workforce, Attrition.)" -ForegroundColor DarkGray
    Write-Host "  - Chat with the data agents for natural-language Q&A over the gold semantic models." -ForegroundColor Gray
    Write-Host "  - Trigger pl_incremental_load any time to backfill from the last sync up to NOW (whether that's an hour or 5 months) and watch it propagate through the medallion." -ForegroundColor Gray
} else {
    Write-Host "  - Open the bronze workspace and run pl_initial_load to populate bronze + silver + gold:" -ForegroundColor Gray
    Write-Host "      $pipelineUrl" -ForegroundColor Blue
    Write-Host "      (or kick it off from the Fabric portal: $bronzeWsUrl)" -ForegroundColor DarkGray
    Write-Host "  - Once it finishes (~30-60 min), open the gold workspace for reports + data agents:" -ForegroundColor Gray
    Write-Host "      $goldWsUrl" -ForegroundColor Blue
}
Write-Host "  - PAUSE the Fabric capacity in the Azure portal when you're not actively demoing to save cost." -ForegroundColor Gray
Write-Host ""

# -----------------------------------------------------------------------------
# teardown.ps1 + teardown.cmd were already emitted to the package folder
# during deploy: teardown.cmd written once on the first Write-Teardown call
# (right after RG create), teardown.ps1 refreshed on each call as more state
# was created. Both live next to deploy.cmd. Nothing to do here.
# -----------------------------------------------------------------------------

Write-Host "Teardown:" -ForegroundColor Cyan
Write-Host "  Double-click teardown.cmd next to deploy.cmd when you're ready to tear it all down." -ForegroundColor Gray
Write-Host ""

# Final timing: flush the last step (Purview post-data) and print TOTAL runtime
# now that Purview pre+post-data phases are done (Purview can add 20-30 min to
# total deploy time, and the early TOTAL print before Purview underreported).
Write-Done
Write-Host ""

# Stop the transcript explicitly so the log file handle is released before
# pwsh exits (otherwise it stays locked briefly and blocks user deletion of
# the package folder), then copy it out to %LOCALAPPDATA% for retention.
Save-DeployState -Status 'completed'
Complete-Log

# Pause so the user sees the success message before the window closes.
# (Most users launch via deploy.cmd which double-clicks shut on exit otherwise.)
Read-Host "Press Enter to exit"

