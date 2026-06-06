# Phase 13: create Unified Catalog data products with linked assets + terms.
# Endpoint: /datagovernance/catalog/dataproducts (no api-version)
# Shape: name, type='Dataset', description, businessUse (both HTML), domain, contacts.owner[],
#        endorsed, status='Draft'|'Published'
# Relationships:
#   POST /dataproducts/{id}/relationships?entityType=DataAsset  body { entityId, relationshipType='Related' }
#   POST /dataproducts/{id}/relationships?entityType=Term       same body
# GET relationships requires entityType query param.
#
# Asset GUIDs are looked up by qualifiedName via /datamap/api/search/query.

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\_lib.ps1"
$ctx = Read-Context

$endpoint = $ctx.purview.endpoint
if (-not $ctx.governanceDomains) { throw "Run 11-governance-domains.ps1 first" }
if (-not $ctx.glossaryTerms)     { throw "Run 12-glossary-terms.ps1 first" }

$retailDomainId = $ctx.governanceDomains.retail.id
$hrDomainId     = $ctx.governanceDomains.retailHr.id
foreach ($pair in @(@{k='retail';id=$retailDomainId}, @{k='retailHr';id=$hrDomainId})) {
  if (-not $pair.id -or $pair.id -eq '00000000-0000-0000-0000-000000000000') {
    throw "governanceDomains.$($pair.k).id is missing or zero-GUID in context.json -- re-run 11-governance-domains.ps1"
  }
}

# Build term name -> id map
$termByName = @{}
foreach ($t in $ctx.glossaryTerms) { $termByName[$t.name] = $t.id }

$ownerId = (az ad signed-in-user show --query id -o tsv)
if (-not $ownerId) { throw "Could not resolve signed-in user objectId" }

$tok = Get-PurviewToken
$headers = @{ Authorization = "Bearer $tok"; 'Content-Type' = 'application/json' }

# Helper: resolve asset GUID by qualifiedName
function Get-AssetIdByQN {
  param([string]$qualifiedName, [string]$entityType)
  $body = @{
    keywords = $qualifiedName
    limit = 10
  } | ConvertTo-Json -Depth 5
  $r = Invoke-RestWithRetry -Method POST `
    -Uri "$endpoint/datamap/api/search/query?api-version=2023-09-01" `
    -Headers $headers -Body $body
  $hit = $r.value | Where-Object { $_.qualifiedName -eq $qualifiedName -and (-not $entityType -or $_.entityType -eq $entityType) } | Select-Object -First 1
  if (-not $hit) {
    Write-Warning "No asset found for QN=$qualifiedName entityType=$entityType"
    return $null
  }
  return $hit.id
}

# Helper: get-or-create Unified Catalog DataAsset for a given datamap entity.
# Catalog assets are separate from datamap entities; you must explicitly onboard.
$script:catalogAssetCache = $null
function Get-OrCreateCatalogAsset {
  param([string]$datamapAssetId, [string]$displayName)
  if (-not $script:catalogAssetCache) {
    $all = (Invoke-RestWithRetry -Uri "$endpoint/datagovernance/catalog/dataassets" -Headers $headers).value
    $script:catalogAssetCache = @{}
    foreach ($a in $all) {
      if ($a.source.assetId) { $script:catalogAssetCache[$a.source.assetId] = $a.id }
    }
  }
  if ($script:catalogAssetCache.ContainsKey($datamapAssetId)) {
    return $script:catalogAssetCache[$datamapAssetId]
  }
  $b = @{
    name = $displayName
    type = 'General'
    source = @{ type = 'PurviewDataMap'; assetId = $datamapAssetId }
  } | ConvertTo-Json -Depth 5
  $resp = Invoke-RestWithRetry -Method POST `
    -Uri "$endpoint/datagovernance/catalog/dataassets" `
    -Headers $headers -Body $b
  $script:catalogAssetCache[$datamapAssetId] = $resp.id
  return $resp.id
}

# Retail workspace IDs from context
$bronzeWs = ($ctx.retail.workspaces | Where-Object { $_.displayName -like '*bronze*' }).id
$silverWs = ($ctx.retail.workspaces | Where-Object { $_.displayName -like '*silver*' }).id
$goldWs   = ($ctx.retail.workspaces | Where-Object { $_.displayName -like '*gold*'   }).id
$sqlFqdn  = $ctx.retail.sqlServer.fqdn

# Resolve Fabric item IDs by displayName + type (per workspace). Phase 00
# enumerates workspace items into context.json so we never have to hard-code
# GUIDs that change on every fresh deploy. Each helper returns the GUID or
# $null (with a warning) so the data product is still created with whatever
# assets we CAN resolve.
function Get-WsItemId {
    param(
        [object[]]$Workspaces,
        [string]$WorkspaceDisplayMatch,  # substring match, e.g. 'bronze'
        [string]$ItemDisplayName,
        [string[]]$ItemTypes              # accept any of these types
    )
    $ws = $Workspaces | Where-Object { $_.displayName -like "*$WorkspaceDisplayMatch*" } | Select-Object -First 1
    if (-not $ws) {
        Write-Warning "Workspace matching '*$WorkspaceDisplayMatch*' not found in context"
        return $null
    }
    $hit = $ws.items | Where-Object { $_.displayName -eq $ItemDisplayName -and $ItemTypes -contains $_.type } | Select-Object -First 1
    if (-not $hit) {
        Write-Warning "Item '$ItemDisplayName' (type in: $($ItemTypes -join ',')) not found in workspace '$($ws.displayName)'"
        return $null
    }
    return $hit.id
}

# Item names this recipe creates (kept in sync with deploy.ps1 / Fabric.ps1).
# For Fabric Lakehouses the Purview Fabric scan registers the asset under the
# SQLEndpoint item GUID, NOT the Lakehouse item GUID, even though the QN looks
# like .../lakewarehouses/<guid>. So we resolve the SQLEndpoint sibling that
# Fabric auto-creates alongside each lakehouse.
$bronzeLakehouseId   = Get-WsItemId -Workspaces $ctx.retail.workspaces -WorkspaceDisplayMatch 'bronze' -ItemDisplayName 'contoso_retail_bronze'        -ItemTypes 'SQLEndpoint'
$silverCuratedLhId   = Get-WsItemId -Workspaces $ctx.retail.workspaces -WorkspaceDisplayMatch 'silver' -ItemDisplayName 'contoso_retail_silver_curated' -ItemTypes 'SQLEndpoint'
$goldWarehouseId     = Get-WsItemId -Workspaces $ctx.retail.workspaces -WorkspaceDisplayMatch 'gold'   -ItemDisplayName 'contoso_retail_gold'           -ItemTypes 'Warehouse'
$kqlDbId             = Get-WsItemId -Workspaces $ctx.retail.workspaces -WorkspaceDisplayMatch 'bronze' -ItemDisplayName 'contoso_retail_events'         -ItemTypes 'KQLDatabase'
$retailSemModelId    = Get-WsItemId -Workspaces $ctx.retail.workspaces -WorkspaceDisplayMatch 'gold'   -ItemDisplayName 'Retail Sales'                  -ItemTypes 'SemanticModel'
$hrSemModelId        = Get-WsItemId -Workspaces $ctx.retail.workspaces -WorkspaceDisplayMatch 'gold'   -ItemDisplayName 'HR & Workforce'                -ItemTypes 'SemanticModel'

# Build the asset list for a product, filtering out any nulls (so a missing
# item just drops that asset link rather than throwing).
function New-AssetList {
    param([object[]]$Assets)
    $Assets | Where-Object { $_.qn }
}

# --- Data product specs ---
$products = @(
  [pscustomobject]@{
    Name        = 'Sales'
    Domain      = $retailDomainId
    Description = 'Aggregated sales transactions across all Contoso stores. Combines POS records, online orders, and returns into a single curated dataset suitable for revenue analysis and BI dashboards.'
    BusinessUse = 'Daily, weekly, and monthly revenue reporting. Store-level performance comparisons. Promo lift analysis. Returns rate tracking. Used by Finance, Merchandising, and Store Ops teams.'
    Assets = New-AssetList @(
      @{ qn = $(if ($retailSemModelId)  { "https://app.powerbi.com/groups/$goldWs/datasets/$retailSemModelId" });          type = 'powerbi_dataset' }
      @{ qn = $(if ($goldWarehouseId)   { "https://app.fabric.microsoft.com/groups/$goldWs/datawarehouses/$goldWarehouseId" }); type = 'fabric_data_warehouse' }
      @{ qn = "mssql://$sqlFqdn/contoso_retail/retail/orders";       type = 'azure_sql_table' }
    )
    Terms = @('SKU','Sale','Customer','Store')
  },
  [pscustomobject]@{
    Name        = 'Customer 360'
    Domain      = $retailDomainId
    Description = 'Unified customer profile that joins loyalty membership, transaction history, and engagement signals across in-store and digital channels. Anonymous shoppers are bucketed by visit patterns when no loyalty ID is present.'
    BusinessUse = 'Customer segmentation, lifetime value modeling, churn prediction, and personalized marketing. Used by Marketing, CRM, and Data Science teams.'
    Assets = New-AssetList @(
      @{ qn = $(if ($silverCuratedLhId) { "https://app.fabric.microsoft.com/groups/$silverWs/lakewarehouses/$silverCuratedLhId" }); type = 'fabric_lake_warehouse' }
      @{ qn = "mssql://$sqlFqdn/contoso_retail/retail/orders";       type = 'azure_sql_table' }
    )
    Terms = @('Customer','Sale')
  },
  [pscustomobject]@{
    Name        = 'Inventory'
    Domain      = $retailDomainId
    Description = 'SKU-level inventory positions across stores and warehouses, refreshed nightly from the bronze ingestion layer plus a real-time event stream (Kusto) for in-day stockout detection.'
    BusinessUse = 'Replenishment planning, stockout alerts, shrinkage analysis, supplier scorecards. Used by Supply Chain, Merchandising, and Store Ops.'
    Assets = New-AssetList @(
      @{ qn = $(if ($bronzeLakehouseId) { "https://app.fabric.microsoft.com/groups/$bronzeWs/lakewarehouses/$bronzeLakehouseId" }); type = 'fabric_lake_warehouse' }
      @{ qn = $(if ($kqlDbId)           { "https://app.fabric.microsoft.com/groups/$bronzeWs/databases/$kqlDbId" });                type = 'fabric_kusto_database' }
      @{ qn = "mssql://$sqlFqdn/contoso_retail/retail/products";    type = 'azure_sql_table' }
      @{ qn = "mssql://$sqlFqdn/contoso_retail/retail/suppliers";   type = 'azure_sql_table' }
    )
    Terms = @('SKU','Store')
  },
  [pscustomobject]@{
    Name        = 'Workforce'
    Domain      = $hrDomainId
    Description = 'Employee headcount, tenure, attrition, and labor cost per store. Sourced from the HR ledger and the silver-curated workforce dataset. Refreshes daily.'
    BusinessUse = 'Workforce planning, attrition coaching, labor budget vs actual, manager performance reviews. Used by HR Business Partners and Store Operations leadership.'
    Assets = New-AssetList @(
      @{ qn = $(if ($hrSemModelId) { "https://app.powerbi.com/groups/$goldWs/datasets/$hrSemModelId" }); type = 'powerbi_dataset' }
    )
    Terms = @('Employee','Tenure','Attrition')
  }
)

# Pre-fetch existing data products for idempotency
$existing = (Invoke-RestWithRetry -Uri "$endpoint/datagovernance/catalog/dataproducts" -Headers $headers).value
$byNameDomain = @{}
foreach ($p in $existing) { $byNameDomain["$($p.domain)|$($p.name)"] = $p }

$resolved = @()
foreach ($spec in $products) {
  $key = "$($spec.Domain)|$($spec.Name)"
  if ($byNameDomain.ContainsKey($key)) {
    $dp = $byNameDomain[$key]
    Write-Host "Data product exists: $($spec.Name) (id=$($dp.id), status=$($dp.status))"
  } else {
    $body = @{
      name        = $spec.Name
      type        = 'Dataset'
      description = $spec.Description
      businessUse = $spec.BusinessUse
      domain      = $spec.Domain
      contacts    = @{ owner = @(@{ id = $ownerId; description = 'Owner' }) }
      endorsed    = $true
      status      = 'Draft'
    }
    $dp = Invoke-RestWithRetry -Method POST `
      -Uri "$endpoint/datagovernance/catalog/dataproducts" `
      -Headers $headers -Body ($body | ConvertTo-Json -Depth 10)
    Write-Host "Created data product: $($dp.name) (id=$($dp.id))"
  }

  # Link assets (idempotent: GET existing first)
  $linkedAssets = (Invoke-RestWithRetry -Uri "$endpoint/datagovernance/catalog/dataproducts/$($dp.id)/relationships?entityType=DataAsset" -Headers $headers).value | ForEach-Object { $_.entityId }
  foreach ($a in $spec.Assets) {
    $datamapId = Get-AssetIdByQN -qualifiedName $a.qn -entityType $a.type
    if (-not $datamapId) { continue }
    # Derive display name from qn tail or asset type
    $dispName = ($a.qn -split '/')[-1]
    if ($a.qn -match '/datasets/' -or $a.qn -match '/datawarehouses/' -or $a.qn -match '/lakewarehouses/' -or $a.qn -match '/databases/') {
      # Fabric/PowerBI: use type-prefixed friendly name
      $hit = (Invoke-RestWithRetry -Method POST -Uri "$endpoint/datamap/api/search/query?api-version=2023-09-01" -Headers $headers -Body (@{keywords=$a.qn;limit=1}|ConvertTo-Json)).value[0]
      if ($hit) { $dispName = $hit.name }
    }
    $catalogId = Get-OrCreateCatalogAsset -datamapAssetId $datamapId -displayName $dispName
    if ($linkedAssets -contains $catalogId) {
      Write-Host "  [asset] already linked: $dispName"
      continue
    }
    $b = @{ entityId = $catalogId; relationshipType = 'Related' } | ConvertTo-Json
    Invoke-RestWithRetry -Method POST `
      -Uri "$endpoint/datagovernance/catalog/dataproducts/$($dp.id)/relationships?entityType=DataAsset" `
      -Headers $headers -Body $b | Out-Null
    Write-Host "  [asset] linked: $dispName"
  }

  # Link terms
  $linkedTerms = (Invoke-RestWithRetry -Uri "$endpoint/datagovernance/catalog/dataproducts/$($dp.id)/relationships?entityType=Term" -Headers $headers).value | ForEach-Object { $_.entityId }
  foreach ($tname in $spec.Terms) {
    $tid = $termByName[$tname]
    if (-not $tid) { Write-Warning "  Term '$tname' not found in context"; continue }
    if ($linkedTerms -contains $tid) {
      Write-Host "  [term] already linked: $tname"
      continue
    }
    $b = @{ entityId = $tid; relationshipType = 'Related' } | ConvertTo-Json
    Invoke-RestWithRetry -Method POST `
      -Uri "$endpoint/datagovernance/catalog/dataproducts/$($dp.id)/relationships?entityType=Term" `
      -Headers $headers -Body $b | Out-Null
    Write-Host "  [term] linked: $tname"
  }

  # Publish data product
  if ($dp.status -ne 'Published') {
    $upd = Invoke-RestWithRetry -Method PATCH `
      -Uri "$endpoint/datagovernance/catalog/dataproducts/$($dp.id)" `
      -Headers $headers -Body (@{ status = 'Published' } | ConvertTo-Json)
    Write-Host "  -> Published"
    $dp = $upd
  }

  $resolved += $dp
}

# Persist
if (-not $ctx.PSObject.Properties['dataProducts']) {
  $ctx | Add-Member -NotePropertyName dataProducts -NotePropertyValue @()
}
$ctx.dataProducts = @($resolved | ForEach-Object {
  [ordered]@{ id = $_.id; name = $_.name; domain = $_.domain; status = $_.status }
})
($ctx | ConvertTo-Json -Depth 10) | Set-Content "$PSScriptRoot\context.json" -Encoding UTF8

Write-Host ""
Write-Host "Done. $($resolved.Count) data products published."
