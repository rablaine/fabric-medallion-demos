# Phase 15: create governance OKRs (Objectives + Key Results) linked to data products.
#
# API:
#   POST /datagovernance/catalog/objectives
#     body: { definition, domain, targetDate (ISO Z), contacts.owner[], status }
#     -> { id, ... }
#   POST /datagovernance/catalog/objectives/{id}/keyresults
#     body: { definition, domainId, progress, goal, max, status: 'OnTrack'|'AtRisk'|'OffTrack' }
#   POST /datagovernance/catalog/objectives/{id}/relationships?entityType=DataProduct
#     body: { entityId, relationshipType: 'Related' }
#
# Idempotency: matches existing objectives by (domain, definition).

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\_lib.ps1"
$ctx = Read-Context

$endpoint = $ctx.purview.endpoint
if (-not $ctx.governanceDomains) { throw "Run 11-governance-domains.ps1 first" }
if (-not $ctx.dataProducts)      { throw "Run 13-data-products.ps1 first" }

$retailDomain = $ctx.governanceDomains.retail.id
$hrDomain     = $ctx.governanceDomains.retailHr.id

# Resolve current user as owner
$ownerId = (az ad signed-in-user show --query id -o tsv)
if (-not $ownerId) { throw "Could not resolve signed-in user objectId" }

# DP id lookup by name
$dpByName = @{}
foreach ($dp in $ctx.dataProducts) { $dpByName[$dp.name] = $dp.id }

# Fiscal-year target date for demo realism
$targetDate = "2026-12-31T06:00:00Z"

# Objective definitions. KRs and linked DP names live alongside.
$objectives = @(
  [pscustomobject]@{
    Domain     = $retailDomain
    Definition = "Grow comparable-store revenue 8% year-over-year while protecting gross margin."
    LinkedDPs  = @('Sales','Customer 360')
    KeyResults = @(
      @{ Definition = 'Lift weekly comp-store sales to $1.2M average per store by Q4.';     Progress = 65; Goal = 100; Max = 100; Status = 'OnTrack' }
      @{ Definition = 'Hold gross margin >= 42% across all merchandising categories.';      Progress = 80; Goal = 100; Max = 100; Status = 'OnTrack' }
      @{ Definition = 'Increase repeat-customer share of revenue from 38% to 45%.';         Progress = 40; Goal = 100; Max = 100; Status = 'AtRisk'  }
    )
  },
  [pscustomobject]@{
    Domain     = $retailDomain
    Definition = "Reduce inventory shrink and stockouts through better SKU-level visibility."
    LinkedDPs  = @('Inventory')
    KeyResults = @(
      @{ Definition = 'Cut shrink rate from 1.8% of revenue to below 1.2%.';                Progress = 55; Goal = 100; Max = 100; Status = 'OnTrack' }
      @{ Definition = 'Reduce out-of-stock incidents on top 500 SKUs by 50%.';              Progress = 30; Goal = 100; Max = 100; Status = 'AtRisk'  }
    )
  },
  [pscustomobject]@{
    Domain     = $hrDomain
    Definition = "Improve workforce stability across retail stores by reducing voluntary attrition."
    LinkedDPs  = @('Workforce')
    KeyResults = @(
      @{ Definition = 'Drive voluntary attrition from 24% to below 18% annualized.';        Progress = 50; Goal = 100; Max = 100; Status = 'OnTrack' }
      @{ Definition = 'Raise 90-day new-hire retention from 72% to 85%.';                   Progress = 75; Goal = 100; Max = 100; Status = 'OnTrack' }
      @{ Definition = 'Increase median tenure of store associates from 14 to 20 months.';   Progress = 35; Goal = 100; Max = 100; Status = 'AtRisk'  }
    )
  }
)

$tok = Get-PurviewToken
$h = @{ Authorization = "Bearer $tok"; 'Content-Type' = 'application/json' }

# List existing objectives across both domains for idempotency
$existing = @()
foreach ($d in @($retailDomain, $hrDomain)) {
  $r = (Invoke-RestWithRetry -Uri "$endpoint/datagovernance/catalog/objectives?domain=$d" -Headers $h).value
  if ($r) { $existing += $r }
}

$createdObjectives = @()
foreach ($spec in $objectives) {
  $hit = $existing | Where-Object { $_.domain -eq $spec.Domain -and $_.definition.Trim() -eq $spec.Definition.Trim() } | Select-Object -First 1
  if ($hit) {
    Write-Host "[exists]    objective '$($spec.Definition.Substring(0,[Math]::Min(60,$spec.Definition.Length)))...' id=$($hit.id)" -ForegroundColor DarkGray
    $obj = $hit
  } else {
    $body = @{
      definition = $spec.Definition
      domain     = $spec.Domain
      targetDate = $targetDate
      contacts   = @{ owner = @(@{ id = $ownerId }) }
      status     = 'Published'
    } | ConvertTo-Json -Depth 6
    $obj = Invoke-RestWithRetry -Method POST -Uri "$endpoint/datagovernance/catalog/objectives" -Headers $h -Body $body
    Write-Host "[created]   objective id=$($obj.id)" -ForegroundColor Green
  }

  # Key results (idempotent by definition match)
  $existingKrs = (Invoke-RestWithRetry -Uri "$endpoint/datagovernance/catalog/objectives/$($obj.id)/keyresults" -Headers $h).value
  foreach ($kr in $spec.KeyResults) {
    if ($existingKrs | Where-Object { $_.definition.Trim() -eq $kr.Definition.Trim() }) {
      Write-Host "  [exists]  kr '$($kr.Definition.Substring(0,[Math]::Min(50,$kr.Definition.Length)))...'" -ForegroundColor DarkGray
      continue
    }
    $krBody = @{
      definition = $kr.Definition
      domainId   = $spec.Domain
      progress   = $kr.Progress
      goal       = $kr.Goal
      max        = $kr.Max
      status     = $kr.Status
    } | ConvertTo-Json
    $krResp = Invoke-RestWithRetry -Method POST -Uri "$endpoint/datagovernance/catalog/objectives/$($obj.id)/keyresults" -Headers $h -Body $krBody
    Write-Host "  [created] kr ($($kr.Status), $($kr.Progress)/$($kr.Goal))" -ForegroundColor Green
  }

  # Link DPs (idempotent)
  $existingRels = (Invoke-RestWithRetry -Uri "$endpoint/datagovernance/catalog/objectives/$($obj.id)/relationships?entityType=DataProduct" -Headers $h).value
  foreach ($dpName in $spec.LinkedDPs) {
    $dpId = $dpByName[$dpName]
    if (-not $dpId) {
      Write-Warning "  DP '$dpName' not in context.json, skipping link"
      continue
    }
    if ($existingRels | Where-Object { $_.entityId -eq $dpId }) {
      Write-Host "  [linked]  -> DP '$dpName' (exists)" -ForegroundColor DarkGray
      continue
    }
    $linkBody = @{ entityId = $dpId; relationshipType = 'Related' } | ConvertTo-Json
    Invoke-RestWithRetry -Method POST -Uri "$endpoint/datagovernance/catalog/objectives/$($obj.id)/relationships?entityType=DataProduct" -Headers $h -Body $linkBody | Out-Null
    Write-Host "  [linked]  -> DP '$dpName'" -ForegroundColor Green
  }

  $createdObjectives += [ordered]@{
    id         = $obj.id
    domain     = $spec.Domain
    definition = $spec.Definition
  }
}

# Persist to context.json
if ($ctx.PSObject.Properties['objectives']) { $ctx.PSObject.Properties.Remove('objectives') }
$ctx | Add-Member -NotePropertyName objectives -NotePropertyValue $createdObjectives
($ctx | ConvertTo-Json -Depth 10) | Set-Content "$PSScriptRoot\context.json" -Encoding UTF8

Write-Host ""
Write-Host "Done. $($createdObjectives.Count) objectives in context.json."
