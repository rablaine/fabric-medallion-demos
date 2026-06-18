<#
.SYNOPSIS
  Deploys the Contoso Healthcare data estate (Azure Health Data Services FHIR R4)
  and populates it from the baked-in synthetic seed via the bulk $import method.

.DESCRIPTION
  Validated, idempotent-ish provisioning of the Azure side of the healthcare
  demo:
    RG -> AHDS workspace -> FHIR R4 service -> ADLS Gen2 (+ import/export
    containers) -> RBAC -> enable $import/$export -> upload seed -> $import ->
    $export.

  Population uses server-side bulk $import (reads NDJSON from blob) instead of
  per-resource REST PUT — minutes instead of ~12 minutes for ~13k resources.

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
    [string] $WorkspaceName   = "hdscontosohealth",      # alphanumeric only
    [string] $FhirServiceName = "fhirr4",
    [string] $StorageAccount  = "stcontosohealthpoc",     # 3-24 lc alphanumeric, globally unique
    [string] $ImportContainer = "fhirimport",
    [string] $ExportContainer = "fhirexport",
    [string] $SeedDir         = (Join-Path $PSScriptRoot "data\fhir-seed"),
    [int]    $RbacPropagationSeconds = 60,
    [switch] $SkipExport
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

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
# Helpers
# ---------------------------------------------------------------------------
$FhirUrl = "https://$WorkspaceName-$FhirServiceName.fhir.azurehealthcareapis.com"

function Get-FhirToken {
    az account get-access-token --resource $FhirUrl --query accessToken -o tsv
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
    $uri = "$FhirUrl$Path"
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
Write-Host "FHIR endpoint will be: $FhirUrl"
if (-not (Test-Path $SeedDir)) { throw "Seed dir not found: $SeedDir" }

Invoke-Phase "00 Preflight" {
    $acct = az account show --query "{sub:name, tenant:tenantId}" -o json | ConvertFrom-Json
    Write-Host "subscription: $($acct.sub)"
    az extension show -n healthcareapis -o none 2>$null
    if ($LASTEXITCODE -ne 0) {
        az extension add -n healthcareapis -o none
    }
    foreach ($ns in @("Microsoft.HealthcareApis", "Microsoft.Storage")) {
        $state = az provider show --namespace $ns --query registrationState -o tsv
        if ($state -ne "Registered") {
            Write-Host "registering provider $ns ..."
            az provider register --namespace $ns --wait
        }
    }
    $script:Me = az ad signed-in-user show --query id -o tsv
    Write-Host "deployer objectId: $($script:Me)"
}

Invoke-Phase "01 Resource group" {
    az group create -n $ResourceGroup -l $Location -o none
}

Invoke-Phase "02 AHDS workspace" {
    az healthcareapis workspace create -g $ResourceGroup -n $WorkspaceName -l $Location -o none
}

Invoke-Phase "03 FHIR R4 service" {
    $tenant = az account show --query tenantId -o tsv
    az healthcareapis workspace fhir-service create `
        -g $ResourceGroup --workspace-name $WorkspaceName --fhir-service-name $FhirServiceName `
        --kind fhir-R4 -l $Location --identity-type SystemAssigned `
        --authentication-configuration `
            authority="https://login.microsoftonline.com/$tenant" `
            audience="$FhirUrl" `
        -o none
}

Invoke-Phase "04 FHIR RBAC (deployer)" {
    $script:FhirId = az healthcareapis workspace fhir-service show `
        -g $ResourceGroup --workspace-name $WorkspaceName --fhir-service-name $FhirServiceName --query id -o tsv
    $script:FhirMsi = az healthcareapis workspace fhir-service show `
        -g $ResourceGroup --workspace-name $WorkspaceName --fhir-service-name $FhirServiceName --query identity.principalId -o tsv
    Write-Host "FHIR MSI principalId: $($script:FhirMsi)"
    # Deployer needs data-plane access to kick off $import / $export.
    az role assignment create --assignee $script:Me --role "FHIR Data Contributor" --scope $script:FhirId -o none
}

Invoke-Phase "05 Storage + containers" {
    az storage account create -n $StorageAccount -g $ResourceGroup -l $Location `
        --sku Standard_LRS --kind StorageV2 --enable-hierarchical-namespace true -o none
    $script:StorageId = az storage account show -n $StorageAccount -g $ResourceGroup --query id -o tsv
}

Invoke-Phase "06 Storage RBAC (MSI + deployer)" {
    # FHIR MSI reads import blobs / writes export blobs; deployer uploads the seed.
    az role assignment create --assignee $script:FhirMsi --role "Storage Blob Data Contributor" --scope $script:StorageId -o none
    az role assignment create --assignee $script:Me      --role "Storage Blob Data Contributor" --scope $script:StorageId -o none
}

Invoke-Phase "07 Enable import/export config" {
    # No CLI flags; patch resource properties directly (shared-key auth may be
    # disabled by policy, so $import/$export use the MSI + the integration store).
    az resource update --ids $script:FhirId --api-version 2024-03-31 `
        --set properties.exportConfiguration.storageAccountName=$StorageAccount `
              properties.importConfiguration.integrationDataStore=$StorageAccount `
              properties.importConfiguration.enabled=true `
              properties.importConfiguration.initialImportMode=false `
        -o none
}

Invoke-Phase "08 RBAC propagation wait" {
    # Role assignments are eventually consistent; $import fails if the MSI can't
    # yet read the blobs, or if the deployer's data-plane role hasn't landed.
    Write-Host "waiting ${RbacPropagationSeconds}s for role assignments to propagate ..."
    Start-Sleep -Seconds $RbacPropagationSeconds
}

Invoke-Phase "09 Create containers" {
    # auth-mode login (shared key may be disabled). Idempotent.
    az storage fs create -n $ImportContainer --account-name $StorageAccount --auth-mode login -o none 2>$null
    az storage fs create -n $ExportContainer --account-name $StorageAccount --auth-mode login -o none 2>$null
}

Invoke-Phase "10 Upload seed to blob" {
    az storage blob upload-batch --account-name $StorageAccount --auth-mode login `
        -d $ImportContainer -s $SeedDir --pattern "*.ndjson" --overwrite -o none
    $script:Blobs = az storage blob list --account-name $StorageAccount --auth-mode login -c $ImportContainer `
        --query "[].name" -o json | ConvertFrom-Json
    Write-Host "uploaded $($script:Blobs.Count) NDJSON files"
}

Invoke-Phase "11 FHIR `$import" {
    # Build Parameters: one input entry per blob (type parsed from file name).
    $inputs = @()
    foreach ($b in $script:Blobs) {
        $type = [System.IO.Path]::GetFileNameWithoutExtension($b)
        $inputs += @{
            name = "input"
            part = @(
                @{ name = "type"; valueString = $type }
                @{ name = "url";  valueUri = "https://$StorageAccount.blob.core.windows.net/$ImportContainer/$b" }
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

    # Kick off (retry: data-plane / MSI RBAC may still be settling).
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
    $opPath = $contentLocation.Substring($FhirUrl.Length)
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
    Invoke-Phase "12 FHIR `$export" {
        $r = Invoke-Fhir -Method Get -Path "/`$export?_container=$ExportContainer" -ExtraHeaders @{ Accept = "application/fhir+json"; Prefer = "respond-async" }
        if ($r.StatusCode -ne 202) {
            $detail = (ConvertFrom-FhirContent $r | ConvertTo-Json -Depth 5 -Compress)
            throw "`$export did not start: HTTP $($r.StatusCode): $detail"
        }
        $contentLocation = $r.Headers["Content-Location"]
        if ($contentLocation -is [array]) { $contentLocation = $contentLocation[0] }
        Write-Host "export operation: $contentLocation"
        $opPath = $contentLocation.Substring($FhirUrl.Length)
        while ($true) {
            Start-Sleep -Seconds 10
            $p = Invoke-Fhir -Method Get -Path $opPath
            if ($p.StatusCode -eq 200) {
                $j = ConvertFrom-FhirContent $p
                $folder = ($j.output | Select-Object -First 1).url
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

Write-TimingSummary
Write-Host ""
Write-Host "FHIR endpoint: $FhirUrl" -ForegroundColor Green
Write-Host "Done." -ForegroundColor Green
