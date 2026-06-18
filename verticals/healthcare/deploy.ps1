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
    [string] $Location        = "southcentralus",
    [string] $ResourcePrefix  = "contoso",
    [string] $FhirServiceName = "fhirr4",
    [string] $ImportContainer = "fhirimport",
    [string] $ExportContainer = "fhirexport",
    [string] $SeedDir         = (Join-Path $PSScriptRoot "data\fhir-seed"),
    [string] $FabricWorkspace = "cts-health-analytics",
    [string] $FabricLocation  = "westus3",
    [switch] $SkipExport,
    [switch] $SkipFabric
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$InfraDir     = Join-Path $PSScriptRoot "infra"
$StorageBicep = Join-Path $InfraDir "storage.bicep"
$FhirBicep    = Join-Path $InfraDir "fhir.bicep"
$FabricBicep  = Join-Path $InfraDir "fabric.bicep"
$FabricPs1    = Join-Path $PSScriptRoot "scripts\Fabric.ps1"

# ---------------------------------------------------------------------------
# Timing harness
# ---------------------------------------------------------------------------
$script:Timings = [System.Collections.Generic.List[object]]::new()
$script:DeploySw = [System.Diagnostics.Stopwatch]::StartNew()

function Invoke-Phase {
    param(
        [Parameter(Mandatory)][string]      $Name,
        [Parameter(Mandatory)][scriptblock] $Body
    )
    $ts = (Get-Date).ToString("HH:mm:ss")
    Write-Host ""
    Write-Host ("==== [{0}] {1} ====" -f $ts, $Name) -ForegroundColor Cyan
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
# FHIR data-plane helpers (FhirUrl is known only after fhir.bicep finishes)
# ---------------------------------------------------------------------------
function Get-FhirToken {
    az account get-access-token --resource $script:FhirUrl --query accessToken -o tsv
}

function Invoke-Fhir {
    # Thin REST wrapper that always uses a fresh-ish token and surfaces status.
    param(
        [Parameter(Mandatory)][string] $Method,
        [Parameter(Mandatory)][string] $Path,        # e.g. "/`$import" or "/_operations/import/1"
        [string] $Body,
        [hashtable] $ExtraHeaders
    )
    $headers = @{ Authorization = "Bearer $(Get-FhirToken)" }
    if ($ExtraHeaders) { $ExtraHeaders.GetEnumerator() | ForEach-Object { $headers[$_.Key] = $_.Value } }
    $uri = "$script:FhirUrl$Path"
    $args = @{ Uri = $uri; Headers = $headers; Method = $Method; SkipHttpErrorCheck = $true }
    if ($Body) { $args.Body = $Body; $headers["Content-Type"] = "application/fhir+json" }
    Invoke-WebRequest @args
}

function ConvertFrom-FhirContent {
    param($Response)
    $c = $Response.Content
    $text = if ($c -is [byte[]]) { [System.Text.Encoding]::UTF8.GetString($c) } else { [string]$c }
    if ([string]::IsNullOrWhiteSpace($text)) { return $null }
    return $text | ConvertFrom-Json
}

# ---------------------------------------------------------------------------
# Phases
# ---------------------------------------------------------------------------
Write-Host "Provisioning healthcare estate in '$ResourceGroup' ($Location)"
if (-not (Test-Path $SeedDir))      { throw "Seed dir not found: $SeedDir" }
if (-not (Test-Path $StorageBicep)) { throw "Missing $StorageBicep" }
if (-not (Test-Path $FhirBicep))    { throw "Missing $FhirBicep" }

Invoke-Phase "00 Preflight" {
    $acct = az account show --query "{sub:name, tenant:tenantId}" -o json | ConvertFrom-Json
    Write-Host "subscription: $($acct.sub)"
    az extension show -n healthcareapis -o none 2>$null
    if ($LASTEXITCODE -ne 0) {
        az extension add -n healthcareapis -o none
    }
    $providers = @("Microsoft.HealthcareApis", "Microsoft.Storage")
    if (-not $SkipFabric) { $providers += "Microsoft.Fabric" }
    foreach ($ns in $providers) {
        $state = az provider show --namespace $ns --query registrationState -o tsv
        if ($state -ne "Registered") {
            Write-Host "registering provider $ns ..."
            az provider register --namespace $ns --wait
        }
    }
    $script:Me     = az ad signed-in-user show --query id -o tsv
    $script:MeUpn  = az ad signed-in-user show --query userPrincipalName -o tsv
    $script:Tenant = $acct.tenant
    Write-Host "deployer objectId: $($script:Me)"
    Write-Host "deployer UPN:      $($script:MeUpn)"
}

Invoke-Phase "01 Resource group" {
    az group create -n $ResourceGroup -l $Location -o none
}

Invoke-Phase "02 Storage (bicep, sync)" {
    $name = "contoso-health-storage-$(Get-Date -Format 'yyyyMMddHHmmss')"
    # Keep stdout (JSON) clean: let az warnings/errors flow to the console via
    # stderr instead of merging them into the output we parse.
    $out = az deployment group create --name $name --resource-group $ResourceGroup `
        --template-file $StorageBicep `
        --parameters resourcePrefix=$ResourcePrefix location=$Location deployerObjectId=$script:Me `
        --query properties.outputs -o json
    if ($LASTEXITCODE -ne 0) { throw "storage deploy failed (exit $LASTEXITCODE)" }
    $o = ($out | Out-String | ConvertFrom-Json)
    $script:StorageAccount = $o.storageAccountName.value
    Write-Host "storage account: $($script:StorageAccount)"
}

Invoke-Phase "03 Launch FHIR (bicep, async)" {
    # --no-wait returns immediately so the seed upload can overlap the ~6 min
    # FHIR service create. Import/export + auth config are baked into the
    # template, so there is no separate post-create config step.
    $script:FhirDeployName = "contoso-health-fhir-$(Get-Date -Format 'yyyyMMddHHmmss')"
    az deployment group create --no-wait --name $script:FhirDeployName --resource-group $ResourceGroup `
        --template-file $FhirBicep `
        --parameters resourcePrefix=$ResourcePrefix location=$Location deployerObjectId=$script:Me fhirServiceName=$FhirServiceName `
        -o none
    Write-Host "FHIR deployment '$($script:FhirDeployName)' launched (running in background)."
}

if (-not $SkipFabric) {
    Invoke-Phase "03b Launch Fabric capacity (async)" {
        # F2 capacity provisions in parallel with FHIR + seed upload. The
        # analytics workspace is created post-deploy (phase 08) once the
        # capacity is visible in the Fabric tenant - workspaces are a Fabric
        # (not ARM) resource, so Bicep stops at the capacity.
        #
        # NOTE: $FabricLocation is deliberately separate from $Location. AHDS
        # (FHIR) only exists in a few regions (southcentralus here), while
        # Fabric capacity quota is granted per-region and may live elsewhere.
        # A cross-region OneLake shortcut reads the FHIR $export fine, so the
        # capacity goes wherever the subscription has Fabric quota.
        $script:FabricDeployName = "contoso-health-fabric-$(Get-Date -Format 'yyyyMMddHHmmss')"
        az deployment group create --no-wait --name $script:FabricDeployName --resource-group $ResourceGroup `
            --template-file $FabricBicep `
            --parameters resourcePrefix=$ResourcePrefix location=$FabricLocation adminUserPrincipalName=$script:MeUpn `
            -o none
        Write-Host "Fabric capacity deployment '$($script:FabricDeployName)' launched (running in background)."
    }
}

Invoke-Phase "04 Upload seed (parallel to FHIR)" {
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

Invoke-Phase "05 Wait for FHIR deployment" {
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
    $o = az deployment group show -n $script:FhirDeployName -g $ResourceGroup --query properties.outputs -o json | ConvertFrom-Json
    $script:FhirUrl = $o.fhirServiceUrl.value
    $script:FhirMsi = $o.fhirPrincipalId.value
    Write-Host "FHIR endpoint: $($script:FhirUrl)"
    Write-Host "FHIR MSI principalId: $($script:FhirMsi)"
}

Invoke-Phase "06 FHIR `$import" {
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

    # Retry kickoff: deployer data-plane / MSI->storage role assignments may still be settling.
    $contentLocation = $null
    for ($attempt = 1; $attempt -le 10; $attempt++) {
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

    # Poll to completion.
    $opPath = $contentLocation.Substring($script:FhirUrl.Length)
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
            break
        }
        elseif ($p.StatusCode -eq 202) {
            Write-Host "  ... import running"
        }
        else {
            $detail = (ConvertFrom-FhirContent $p | ConvertTo-Json -Depth 5 -Compress)
            throw "import poll failed: HTTP $($p.StatusCode): $detail"
        }
    }
}

if (-not $SkipExport) {
    Invoke-Phase "07 FHIR `$export" {
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
    Invoke-Phase "08 Fabric workspace" {
        # Wait for the capacity deployment (usually done well before now since it
        # launched in parallel with FHIR), then create the analytics workspace
        # bound to it via the Fabric REST API.
        while ($true) {
            $state = az deployment group show -n $script:FabricDeployName -g $ResourceGroup --query properties.provisioningState -o tsv 2>$null
            if ($state -eq "Succeeded") { break }
            if ($state -eq "Failed" -or $state -eq "Canceled") { throw "Fabric capacity deployment $state" }
            Write-Host "  ... Fabric capacity provisioning ($state)"
            Start-Sleep -Seconds 15
        }
        $o = az deployment group show -n $script:FabricDeployName -g $ResourceGroup --query properties.outputs -o json | ConvertFrom-Json
        $script:FabricCapacityName = $o.capacityName.value
        Write-Host "Fabric capacity: $($script:FabricCapacityName)"

        . $FabricPs1
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
    }
}

Write-TimingSummary
Write-Host ""
Write-Host "FHIR endpoint: $($script:FhirUrl)" -ForegroundColor Green
Write-Host "Storage:       $($script:StorageAccount)" -ForegroundColor Green
if (-not $SkipFabric) {
    Write-Host "Fabric cap.:   $($script:FabricCapacityName) (F2)" -ForegroundColor Green
    Write-Host "Workspace:     $FabricWorkspace (id=$($script:FabricWorkspaceId))" -ForegroundColor Green
}
Write-Host "Done." -ForegroundColor Green
