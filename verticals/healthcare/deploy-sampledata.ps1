<#
.SYNOPSIS
  Assisted sample-data flow for the Contoso Healthcare data estate.

.DESCRIPTION
  A LIGHTER alternative to deploy.ps1 (the full FHIR-first flow). Instead of
  standing up Azure Health Data Services + FHIR + storage and wiring a OneLake
  shortcut, this flow uses the Microsoft Fabric Healthcare data solutions
  built-in SAMPLE dataset as the data source.

  What it automates:
    1. Resource group.
    2. Microsoft Fabric F8 capacity (infra/capacity.bicep).
    3. Fabric analytics workspace bound to that capacity.
    4. Healthcare data solutions item (empty shell, via REST).
    5. PAUSE - you deploy "Data Foundations" AND check "Sample data" from the
       Fabric portal wizard (these are portal-only; no REST API exists).
    6. On resume: stage the curated Clinical FHIR-NDJSON sample files from the
       lakehouse SampleData folder into the HDS Ingest folder (so the standard
       Ingest -> Process -> bronze -> silver pipeline derives sourceSystem from
       the Ingest namespace, exactly the way the docs intend).
    7. Patch the config notebook with the scipy runtime-repair cell.
    8. Wait for the Spark environment to publish, then optionally kick off the
       ingestion pipeline (bronze -> silver).

  WHY stage into Ingest (not repoint at SampleData): HDS derives the
  sourceSystem from the Ingest namespace folder during the raw->process move.
  Pointing the pipeline straight at Files/SampleData bypasses that move, leaving
  sourceSystem = NULL, which makes the silver flatten step throw
  "source_system is None". Staging into Ingest/Clinical/FHIR-NDJSON/FHIR-HDS is
  the validated, by-the-book happy path.

  WHY a curated file list: the shipped sample set includes RiskAssessment
  resources with no meta.lastUpdated, which HDS bronze validation quarantines
  ("Last Updated does not exist"). The doc-prescribed curated list omits
  RiskAssessment, so ingestion runs clean.

.NOTES
  Requires: az CLI (logged in) and rights to create a resource group + Fabric
  capacity. No healthcareapis extension is needed (no AHDS in this flow).
#>
[CmdletBinding()]
param(
    [string] $ResourceGroup  = "rg-contoso-health-sampledata",
    [string] $Location       = "westus3",
    [string] $ResourcePrefix = "contoso",
    [string] $FabricWorkspace = "contoso-health-sampledata",
    [switch] $SkipFabric
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

# ---------------------------------------------------------------------------
# deployment.config (written by the web package builder) carries the user's
# choices into the downloaded package. Region is pinned to a region with Fabric
# capacity quota (West US 3, same as the FHIR flow) regardless of config input.
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
    # LOCATION from the config is intentionally ignored (pinned below).
}
$Location = "westus3"

# Transcript so a full run is auditable from the package folder.
$LogDir = Join-Path $PSScriptRoot "logs"
New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
$TranscriptPath = Join-Path $LogDir ("deploy-sampledata-{0}.log" -f (Get-Date -Format "yyyyMMdd-HHmmss"))
try { Start-Transcript -Path $TranscriptPath | Out-Null } catch {}

$InfraDir      = Join-Path $PSScriptRoot "infra"
$CapacityBicep = Join-Path $InfraDir "capacity.bicep"
$FabricPs1     = Join-Path $PSScriptRoot "scripts\Fabric.ps1"

# Dot-source the Fabric REST helpers at SCRIPT scope so every phase can see
# Get-FabricToken / New-FabricWorkspace / Get-FabricCapacityGuid / etc.
if (-not $SkipFabric) {
    if (-not (Test-Path $FabricPs1)) { throw "Missing $FabricPs1" }
    . $FabricPs1
}

# ---------------------------------------------------------------------------
# Timing harness
# ---------------------------------------------------------------------------
$script:Timings  = [System.Collections.Generic.List[object]]::new()
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
    $ts  = (Get-Date).ToString("HH:mm:ss")
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
            @{ N = "Pct"; E = { "{0,5:N1}%" -f (($_.Seconds / [math]::Max($total, 0.1)) * 100) } } |
        Format-Table -AutoSize | Out-Host
    Write-Host ("TOTAL: {0}s ({1:N1} min)" -f $total, ($total / 60)) -ForegroundColor Green
}

# ---------------------------------------------------------------------------
# az CLI hardening: retry transient (429 / 5xx / transport) errors with
# exponential backoff, and recover from expired tokens (silent refresh, then
# interactive 'az login --tenant'). Mirrors deploy.ps1's helper.
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
            $isCaeChallenge = $stderr -match 'InteractionRequired|TokenCreatedWithOutdatedPolicies|Continuous access evaluation resulted in challenge|AADSTS50076|AADSTS50079|AADSTS50173'
            $isTokenExpired = $stderr -match 'AADSTS70043|AADSTS50173|AADSTS500011|AADSTS50076|AADSTS50079|TokenExpired|Access token has expired|InvalidAuthenticationToken|expired or revoked|Continuous Access Evaluation|please run.*az login|Please run.*az login|run.*az login.*again'
            if (($isCaeChallenge -or $isTokenExpired) -and $tokenRefreshes -lt $maxTokenRefreshes) {
                $tokenRefreshes++
                if ($isCaeChallenge) {
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
# Fabric REST helpers (call Invoke-FabricRest from scripts\Fabric.ps1).
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

# Wait for an HDS Spark Environment to finish PUBLISHING (first publish installs
# the HDS libraries, ~5-10 min). The ingestion notebooks fail until it's done.
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
# OneLake data-plane helpers (DFS list + Blob server-side copy).
# ---------------------------------------------------------------------------
function Get-OneLakeStorageToken {
    (Invoke-AzWithRetry -Label 'onelake storage token' {
        az account get-access-token --resource https://storage.azure.com --query accessToken -o tsv
    } | Out-String).Trim()
}

function Get-OneLakePaths {
    # Lists a OneLake directory via the DFS endpoint. $Directory is relative to
    # the workspace filesystem, e.g. "<itemId>/Files/SampleData/...". Returns the
    # 'paths' array ([] if the directory is empty / missing).
    param(
        [Parameter(Mandatory)][string] $Token,
        [Parameter(Mandatory)][string] $WorkspaceId,
        [Parameter(Mandatory)][string] $Directory,
        [bool] $Recursive = $false
    )
    $rec = $Recursive.ToString().ToLower()
    $uri = "https://onelake.dfs.fabric.microsoft.com/$WorkspaceId" + "?resource=filesystem&recursive=$rec&directory=$Directory"
    $hdr = @{ Authorization = "Bearer $Token"; 'x-ms-version' = '2021-06-08' }
    try {
        $resp = Invoke-RestMethod -Uri $uri -Headers $hdr -Method GET
        if ($resp.PSObject.Properties.Name -contains 'paths' -and $resp.paths) { return @($resp.paths) }
        return @()
    }
    catch {
        # 404 = directory doesn't exist yet (e.g. sample data not deployed).
        if ($_.Exception.Response -and [int]$_.Exception.Response.StatusCode -eq 404) { return @() }
        throw
    }
}

function Copy-OneLakeBlob {
    # Server-side copy within the same OneLake account (synchronous for same
    # account). $SourcePath / $DestPath are relative to the workspace, e.g.
    # "<itemId>/Files/...". Returns the response.
    param(
        [Parameter(Mandatory)][string] $Token,
        [Parameter(Mandatory)][string] $WorkspaceId,
        [Parameter(Mandatory)][string] $SourcePath,
        [Parameter(Mandatory)][string] $DestPath
    )
    $src = "https://onelake.blob.fabric.microsoft.com/$WorkspaceId/$SourcePath"
    $dst = "https://onelake.blob.fabric.microsoft.com/$WorkspaceId/$DestPath"
    $hdr = @{
        Authorization      = "Bearer $Token"
        'x-ms-version'     = '2021-06-08'
        'x-ms-copy-source' = $src
    }
    return Invoke-WebRequest -Uri $dst -Method PUT -Headers $hdr -UseBasicParsing
}

function Get-FhirResourceType {
    # Maps an NDJSON file name to its FHIR resource type. Handles a timestamp
    # infix (Location.1741068704008.ndjson -> Location) and a shard suffix
    # (Encounter-1.ndjson -> Encounter).
    param([Parameter(Mandatory)][string] $FileName)
    $n = $FileName -replace '\.ndjson$', ''   # strip extension
    $n = $n.Split('.')[0]                      # strip timestamp infix
    $n = $n -replace '-\d+$', ''               # strip shard suffix
    return $n
}

# ---------------------------------------------------------------------------
# Teardown emitter. Deletes EXACTLY what this flow created: the Fabric workspace
# (if one was created), then the resource group (which holds the F8 capacity).
# Emitted right after the RG exists so an abort during the manual pause still
# leaves a working teardown on disk (the F8 capacity is already billing by then).
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
        [string] $Capacity = ''
    )
    $teardownPath = Join-Path $PSScriptRoot 'teardown.ps1'
    $teardownBody = @"
# Auto-generated by deploy-sampledata.ps1 on $(Get-Date -Format o)
# Tears down EXACTLY what the assisted sample-data flow created: the Fabric
# workspace (if one was created), then the resource group (F8 capacity). Other
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
if (`$ctx -and `$ctx.id -ne `$Subscription) { az account set --subscription `$Subscription 2>`$null | Out-Null }

Write-Host ''
Write-Host 'About to PERMANENTLY DELETE:' -ForegroundColor Yellow
Write-Host "  Subscription: `$Subscription"
Write-Host "  Tenant:       `$TenantId"
if (`$WorkspaceId) { Write-Host "  Fabric ws:    `$WorkspaceName (`$WorkspaceId)" }
Write-Host "  Resource grp: `$ResourceGroup (F8 capacity)"
Write-Host ''
`$ans = Read-Host 'Type YES to proceed'
if (`$ans -ne 'YES') { Write-Host 'Cancelled.'; try { Stop-Transcript | Out-Null } catch {}; exit 0 }

# Fabric workspace FIRST, resource group SECOND. The RG holds the F8 capacity;
# if the RG is dropped before the workspace, the capacity vanishes and Fabric
# can't delete the (now capacity-less) workspace. So if the workspace delete
# fails we ABORT and leave the RG intact for a rerun.
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
            Write-Host "Workspace delete attempt `$attempt/6 failed: `$msg" -ForegroundColor DarkYellow
            if (`$attempt -lt 6) { Start-Sleep -Seconds `$wait; `$wait = [Math]::Min(120, `$wait * 2) }
        }
    }
    if (-not `$wsDeleted) {
        Write-Host 'Could not delete the workspace after retries. Leaving the resource group' -ForegroundColor Red
        Write-Host '(F8 capacity) in place so you can retry - dropping it now would orphan the' -ForegroundColor Red
        Write-Host 'workspace. Delete the workspace by hand, then rerun this teardown.' -ForegroundColor Red
        try { Stop-Transcript | Out-Null } catch {}
        Read-Host 'Press Enter to exit'
        exit 1
    }
}

Write-Host "Deleting resource group `$ResourceGroup ..." -ForegroundColor Yellow
az group delete --name `$ResourceGroup --yes --no-wait
Write-Host "Resource group delete requested (running in the background)." -ForegroundColor Green
try { Stop-Transcript | Out-Null } catch {}
Write-Host 'Teardown complete.' -ForegroundColor Green
"@
    Set-Content -Path $teardownPath -Value $teardownBody -Encoding utf8

    # teardown.cmd launcher (written once; cd to TEMP so the package folder is
    # never the working directory and can be deleted right after).
    $teardownCmd = Join-Path $PSScriptRoot 'teardown.cmd'
    if (-not (Test-Path $teardownCmd)) {
        $cmdBody = @"
@echo off
set SCRIPT_DIR=%~dp0
cd /d %TEMP%
pwsh -NoLogo -NoProfile -ExecutionPolicy Bypass -Command "& '%SCRIPT_DIR%teardown.ps1'"
echo.
echo Press any key to close this window.
pause >nul
"@
        Set-Content -Path $teardownCmd -Value $cmdBody -Encoding ascii
    }
}

# ===========================================================================
# PHASES
# ===========================================================================

Invoke-Phase "00 Preflight" -EstSeconds 12 {
    $acct = (Invoke-AzWithRetry -Label 'az account show' { az account show --query "{sub:name, tenant:tenantId, id:id}" -o json }) | ConvertFrom-Json
    Write-Host "subscription: $($acct.sub)"
    $script:Tenant         = $acct.tenant
    $script:SubId          = $acct.id
    $script:DeployTenantId = $acct.tenant

    $providers = @("Microsoft.Fabric")
    foreach ($ns in $providers) {
        $state = Invoke-AzWithRetry -Label "az provider show $ns" { az provider show --namespace $ns --query registrationState -o tsv }
        if ($state -ne "Registered") {
            Write-Host "registering provider $ns ..."
            Invoke-AzWithRetry -Label "az provider register $ns" { az provider register --namespace $ns --wait } | Out-Null
        }
    }

    # Identify the deployer WITHOUT calling MS Graph: decode oid / upn from the
    # ARM access token claims (avoids a CAE-prone Graph round-trip).
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
# this point (incl. the manual portal pause) still leaves a working teardown on
# disk to stop the F8 capacity bill.
Write-Teardown -Rg $ResourceGroup -Sub $script:SubId -Tenant $script:Tenant -DeployedBy $script:MeUpn
Write-Host "teardown.cmd written (RG-only; refreshed once the Fabric workspace exists)." -ForegroundColor DarkGray

if ($SkipFabric) {
    Write-Host ""
    Write-Host "-SkipFabric set: stopped after the resource group. Nothing else to do." -ForegroundColor Yellow
    Write-TimingSummary
    try { Stop-Transcript | Out-Null } catch {}
    return
}

Invoke-Phase "02 Fabric capacity (bicep, sync)" -EstSeconds 60 {
    $name = "contoso-health-capacity-$(Get-Date -Format 'yyyyMMddHHmmss')"
    $out = Invoke-AzWithRetry -Label 'capacity bicep deploy' {
        az deployment group create --name $name --resource-group $ResourceGroup `
            --template-file $CapacityBicep `
            --parameters resourcePrefix=$ResourcePrefix location=$Location adminUserPrincipalName=$script:MeUpn `
            --query properties.outputs -o json
    }
    $o = ($out | Out-String | ConvertFrom-Json)
    $script:FabricCapacityName = $o.capacityName.value
    Write-Host "Fabric capacity: $($script:FabricCapacityName) (F8)"
}

Invoke-Phase "03 Fabric workspace" -EstSeconds 34 {
    Set-FabricTenant -TenantId $script:Tenant
    $tok = Get-FabricToken

    # Capacity may take a few seconds to surface in the Fabric tenant after ARM
    # reports Succeeded.
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
        -Description "Contoso Healthcare - sample-data medallion (HDS Healthcare data solutions)"
    $script:FabricWorkspaceId = $ws.id
    Write-Host "workspace: $($ws.displayName) (id=$($ws.id))"
}

# Refresh the teardown now that the workspace exists, so teardown deletes the
# workspace before dropping the resource group.
if ($script:FabricWorkspaceId) {
    Write-Teardown -Rg $ResourceGroup -Sub $script:SubId -Tenant $script:Tenant -DeployedBy $script:MeUpn `
        -WorkspaceId $script:FabricWorkspaceId -WorkspaceName $FabricWorkspace -Capacity $script:FabricCapacityName
    Write-Host "teardown.ps1 refreshed with the Fabric workspace id." -ForegroundColor DarkGray
}

Invoke-Phase "04 Create Healthcare data solutions item" -EstSeconds 10 {
    # The HDS item is createable via REST (empty shell). Its 'foundations'
    # children (lakehouses, notebooks, pipelines) can only be provisioned by the
    # portal setup wizard - see phase 05.
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

Invoke-Phase "05 Deploy Data Foundations + Sample data (portal, manual)" -EstSeconds 240 {
    # No supported REST API deploys HDS foundations OR loads the sample dataset;
    # both are portal-only wizard steps. Pause, hand the user the direct link,
    # and resume once the key children + sample data exist.
    $wsUrl = "https://app.fabric.microsoft.com/groups/$($script:FabricWorkspaceId)/list"
    $hdsLabel = if ($script:HdsName) { $script:HdsName } else { "${ResourcePrefix}healthcare" }
    $wizardUrl = if ($script:HdsItemId) {
        "https://app.fabric.microsoft.com/groups/$($script:FabricWorkspaceId)/health-data-manager/$($script:HdsItemId)/wizard?experience=power-bi"
    }
    else { $wsUrl }
    Write-Host ""
    Write-Host "  ============================================================" -ForegroundColor Yellow
    Write-Host "  ACTION REQUIRED - deploy Data Foundations WITH sample data:" -ForegroundColor Yellow
    Write-Host "    1. (optional) Open your Fabric workspace '$FabricWorkspace':" -ForegroundColor Yellow
    Write-Host "       $wsUrl" -ForegroundColor Yellow
    Write-Host "    2. Open the setup wizard for '$hdsLabel' (already started):" -ForegroundColor Yellow
    Write-Host "       $wizardUrl" -ForegroundColor Yellow
    Write-Host "    3. Step through the wizard:" -ForegroundColor Yellow
    Write-Host "         a. 'Data Foundations' is checked by default        -> Next" -ForegroundColor Yellow
    Write-Host "         b. *** CHECK the 'Sample data' box ***             -> Next" -ForegroundColor Yellow
    Write-Host "            (this is the OPPOSITE of the FHIR flow - here we" -ForegroundColor Yellow
    Write-Host "             WANT the built-in synthetic sample dataset)" -ForegroundColor Yellow
    Write-Host "         c. No additional capabilities                      -> Next" -ForegroundColor Yellow
    Write-Host "         d. No settings to configure                        -> Next" -ForegroundColor Yellow
    Write-Host "         e. Check the box to accept the terms of service    -> Deploy" -ForegroundColor Yellow
    Write-Host "    4. Wait for it to finish (do NOT close the portal tab while it runs)." -ForegroundColor Yellow
    Write-Host "       NOTE: the spinner does NOT auto-update. If it's still" -ForegroundColor Yellow
    Write-Host "       spinning past ~3 min, REFRESH the page - it's likely done." -ForegroundColor Yellow
    Write-Host "  ============================================================" -ForegroundColor Yellow
    Write-Host ""

    # Loop until foundations is deployed (bronze lakehouse + ingestion pipeline
    # exist). They can close the terminal to bail out.
    while ($true) {
        Read-Host "When Data Foundations (with sample data) has finished deploying, press Enter to continue (or close this window to exit)"
        $tok = Get-FabricToken
        $items = Get-FabricItems -Token $tok -WorkspaceId $script:FabricWorkspaceId
        $script:BronzeLakehouse = $items | Where-Object { $_.type -eq 'Lakehouse'    -and $_.displayName -match 'bronze' } | Select-Object -First 1
        $script:IngestPipeline  = $items | Where-Object { $_.type -eq 'DataPipeline' -and $_.displayName -match 'ingest' } | Select-Object -First 1
        $script:AdminLakehouse  = $items | Where-Object { $_.type -eq 'Lakehouse'    -and $_.displayName -match 'admin'  } | Select-Object -First 1
        $script:ConfigNotebook  = $items | Where-Object { $_.type -eq 'Notebook'     -and $_.displayName -match 'config' } | Select-Object -First 1
        $script:HdsEnvironment  = $items | Where-Object { $_.type -eq 'Environment' } | Select-Object -First 1
        if ($script:BronzeLakehouse -and $script:IngestPipeline) { break }
        Write-Host ""
        Write-Host "  [!] Data Foundations doesn't look deployed yet - I can't see the bronze" -ForegroundColor Yellow
        Write-Host "      lakehouse / ingestion pipeline in the workspace. Finish the wizard" -ForegroundColor Yellow
        Write-Host "      (click Deploy), wait for it to complete, then press Enter to recheck." -ForegroundColor Yellow
        Write-Host ""
    }

    if ($script:BronzeLakehouse) { Write-Host "bronze lakehouse:   $($script:BronzeLakehouse.displayName) (id=$($script:BronzeLakehouse.id))" }
    if ($script:IngestPipeline)  { Write-Host "ingestion pipeline: $($script:IngestPipeline.displayName) (id=$($script:IngestPipeline.id))" }
    if ($script:AdminLakehouse)  { Write-Host "admin lakehouse:    $($script:AdminLakehouse.displayName) (id=$($script:AdminLakehouse.id))" }
    if ($script:ConfigNotebook)  { Write-Host "config notebook:    $($script:ConfigNotebook.displayName) (id=$($script:ConfigNotebook.id))" }
    else { Write-Host "  [!] No config notebook found - can't auto-inject the scipy repair cell." -ForegroundColor Yellow }
    if ($script:HdsEnvironment)  { Write-Host "spark environment:  $($script:HdsEnvironment.displayName) (id=$($script:HdsEnvironment.id))" }
    else { Write-Host "  [!] No Spark environment found - can't wait for publishing before ingestion." -ForegroundColor Yellow }
}

Invoke-Phase "06 Stage curated sample data into Ingest" -EstSeconds 90 {
    # HDS derives sourceSystem from the Ingest NAMESPACE folder during the
    # raw->process move. Stage the curated Clinical FHIR-NDJSON sample files from
    # the lakehouse SampleData folder into Ingest/Clinical/FHIR-NDJSON/FHIR-HDS so
    # the standard pipeline (Ingest -> Process -> bronze -> silver) stamps
    # sourceSystem = FHIR-HDS. The pipeline's default source_path_pattern
    # (Files/Process/Clinical/FHIR-NDJSON) is left untouched - DO NOT repoint it
    # at SampleData (that bypasses the move and leaves sourceSystem NULL).
    if (-not $script:BronzeLakehouse) {
        Write-Host "  [!] No bronze lakehouse discovered; skipping staging. Deploy foundations + sample data, then rerun." -ForegroundColor Yellow
        return
    }

    # Doc-prescribed curated resource types (RiskAssessment excluded by omission:
    # its shipped resources lack meta.lastUpdated and HDS bronze validation
    # quarantines them).
    $curated = @('Encounter', 'Condition', 'MedicationRequest', 'Observation', 'Patient',
                 'Practitioner', 'PractitionerRole', 'Procedure', 'CarePlan', 'Goal', 'Location', 'Appointment')

    $ws       = $script:FabricWorkspaceId
    $bronzeId = $script:BronzeLakehouse.id
    $stok     = Get-OneLakeStorageToken

    # The HDS sample dataset lands under Files/SampleData/Clinical/FHIR-NDJSON/
    # FHIR-HDS/<dataset>/ (e.g. 51KSyntheticPatients). List recursively and pick
    # every *.ndjson so we're robust to the dataset folder name.
    $sampleRoot = "$bronzeId/Files/SampleData/Clinical/FHIR-NDJSON/FHIR-HDS"
    $allPaths   = Get-OneLakePaths -Token $stok -WorkspaceId $ws -Directory $sampleRoot -Recursive $true
    $ndjson     = @($allPaths | Where-Object {
        $isDir = $false
        if ($_.PSObject.Properties.Name -contains 'isDirectory') { $isDir = ($_.isDirectory -eq $true -or $_.isDirectory -eq 'true') }
        (-not $isDir) -and ($_.name -match '\.ndjson$')
    })

    if ($ndjson.Count -eq 0) {
        Write-Host "  [!] No sample NDJSON found under Files/SampleData/Clinical/FHIR-NDJSON/FHIR-HDS." -ForegroundColor Yellow
        Write-Host "      Make sure you checked the 'Sample data' box in the foundations wizard," -ForegroundColor Yellow
        Write-Host "      wait for it to finish loading, then rerun this script." -ForegroundColor Yellow
        return
    }

    $destDir = "$bronzeId/Files/Ingest/Clinical/FHIR-NDJSON/FHIR-HDS"
    $ok = 0; $skip = 0; $fail = 0
    foreach ($p in $ndjson) {
        $leaf = $p.name.Substring($p.name.LastIndexOf('/') + 1)
        $rt   = Get-FhirResourceType $leaf
        if ($curated -notcontains $rt) { $skip++; continue }
        try {
            $resp   = Copy-OneLakeBlob -Token $stok -WorkspaceId $ws -SourcePath $p.name -DestPath "$destDir/$leaf"
            $status = $resp.Headers['x-ms-copy-status']
            Write-Host ("  [OK {0}] {1}  ({2})" -f $resp.StatusCode, $leaf, $rt) -ForegroundColor DarkGray
            $ok++
        }
        catch {
            Write-Host ("  [FAIL] {0}  {1}" -f $leaf, $_.Exception.Message) -ForegroundColor Yellow
            $fail++
        }
    }
    Write-Host ("  staged {0} curated file(s) into Ingest/Clinical/FHIR-NDJSON/FHIR-HDS (skipped {1} non-curated, {2} failed)." -f $ok, $skip, $fail) -ForegroundColor Green
    if ($ok -eq 0) { Write-Host "  [!] Nothing staged - ingestion will have no input. Check the messages above." -ForegroundColor Yellow }
}

Invoke-Phase "07 Patch config notebook (scipy fix)" -EstSeconds 20 {
    # TEMPORARY: Fabric Runtime 1.3 HDS env ships scipy .py over an older
    # _rotation.so; the hds/dtt import dies until a forced scipy reinstall.
    # Inject the repair cell into the *_config notebook right after the
    # parameters cell so it runs before any HDS import. Idempotent.
    if (-not $script:ConfigNotebook) {
        Write-Host "  [!] No *_config notebook discovered; skipping scipy repair injection." -ForegroundColor Yellow
        return
    }
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
            $updBody = @{ definition = @{ format = 'ipynb'; parts = $parts } }
            $ud = Invoke-FabricRest -Token $tok -Method POST -Path "/workspaces/$($script:FabricWorkspaceId)/notebooks/$nbId/updateDefinition?format=ipynb&updateMetadata=false" -Body $updBody
            if ($ud.Status -eq 202 -and $ud.OperationLocation) { Wait-FabricOperation -Token $tok -OperationUrl $ud.OperationLocation | Out-Null }
            Write-Host "  injected scipy repair cell into '$($script:ConfigNotebook.displayName)'" -ForegroundColor Green
        }
    }
    catch {
        Write-Host "  [!] Could not patch the config notebook with the scipy fix: $($_.Exception.Message)" -ForegroundColor Yellow
    }
}

Invoke-Phase "08 Ingestion pipeline" {
    if (-not $script:IngestPipeline) {
        Write-Host "  [!] No ingestion pipeline discovered; run it from the portal once foundations is deployed." -ForegroundColor Yellow
        return
    }
    $pipeUrl = "https://app.fabric.microsoft.com/groups/$($script:FabricWorkspaceId)/pipelines/$($script:IngestPipeline.id)"

    # Wait for the Spark environment to finish publishing BEFORE we prompt -
    # ingestion notebooks fail until it's done.
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

Write-TimingSummary
Write-Host ""
if (-not $SkipFabric) {
    Write-Host "Fabric cap.:   $($script:FabricCapacityName) (F8)" -ForegroundColor Green
    Write-Host "Workspace:     $FabricWorkspace (id=$($script:FabricWorkspaceId))" -ForegroundColor Green
}
Write-Host "Teardown:      run teardown.cmd from this folder to delete everything." -ForegroundColor Green
Write-Host "Done." -ForegroundColor Green
try { Stop-Transcript | Out-Null } catch {}
