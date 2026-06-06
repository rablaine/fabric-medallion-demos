# Phase 18: create Critical Data Elements (CDEs) scoped to our governance domains
# and link each to the relevant glossary term(s) and physical data column(s).
#
# API:
#   POST   /datagovernance/catalog/criticaldataelements
#     body: { name, dataType: 'Text'|'Number'|'DateTime'|'Boolean',
#             description, domain, status: 'Draft'|'Published',
#             contacts: { owner: [{id}] } }
#     -> { id, ... }
#   GET    /datagovernance/catalog/criticaldataelements -> { value:[...], count }
#   POST   /datagovernance/catalog/criticaldataelements/{id}/relationships?entityType=Term
#     body: { entityId, relationshipType: 'Related' }
#     (Allowed entityTypes from server: CriticalDataColumn, Term, DataColumn.
#      DataProduct <-> CDE linkage is currently broken in the API — DP allows
#      entityType=CriticalDataElement, but POSTing 400s with a contradictory
#      error message. We link CDE -> Term + DataColumn only.)
#
# Column linking:
#   POST   /datagovernance/catalog/dataColumns/ingest
#     body: { requests:[{ dataMapAssetId, dataMapColumnId }] }
#     -> [{ id, source:{ type:'DataMap', assetId, columnId } }]
#   POST   /datagovernance/catalog/criticaldataelements/{id}/relationships?entityType=DataColumn
#     body: { entityId, relationshipType: 'Related' }
#   POST   /datagovernance/catalog/dataAssets/{catalogAssetId}/relationships?entityType=DataColumn
#     body: { entityId, relationshipType: 'Related' }
#     (Optional. Adds the column to the asset's column list in portal UI.
#      Only possible when the column's datamap parent is itself a catalog asset.)
#
# Portal forces a CDE->Draft round-trip to add columns; REST does not require it.
#
# Idempotency: matches existing CDEs by (domain, name); matches column ingests by
# (dataMapAssetId, dataMapColumnId); matches relationships by entityId.

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\_lib.ps1"
$ctx = Read-Context

if (-not $ctx.governanceDomains) { throw "Run 11-governance-domains.ps1 first" }
if (-not $ctx.glossaryTerms)     { throw "Run 12-glossary-terms.ps1 first" }

$endpoint     = $ctx.purview.endpoint
$retailDomain = $ctx.governanceDomains.retail.id
$hrDomain     = $ctx.governanceDomains.retailHr.id

$ownerId = (az ad signed-in-user show --query id -o tsv)
if (-not $ownerId) { throw "Could not resolve signed-in user objectId" }

# Term lookup
$termIdByName = @{}
foreach ($t in $ctx.glossaryTerms) { $termIdByName[$t.name] = $t.id }

# CDE specs. Each links to one or more glossary terms and physical columns.
# LinkedColumns entries are matched by asset name + column name; the script
# resolves datamap GUIDs via Atlas and ingests catalog DataColumn entities.
$specs = @(
  [pscustomobject]@{
    Name        = 'Customer ID'
    DataType    = 'Text'
    Domain      = $retailDomain
    Description = 'Globally unique identifier for a customer record. Used to join customer-facing data across Sales, Customer 360, loyalty, and support systems.'
    LinkedTerms = @('Customer')
    LinkedColumns = @(
      @{ Asset='customers'; Column='customer_id' }
      @{ Asset='orders';    Column='customer_id' }
      @{ Asset='DimUsers';  Column='UserId' }
      @{ Asset='Customer';  Column='CustomerID' }
    )
  },
  [pscustomobject]@{
    Name        = 'SKU Number'
    DataType    = 'Text'
    Domain      = $retailDomain
    Description = 'Stock Keeping Unit identifier. Unique per merchandised item; primary key for inventory, pricing, and sales analytics.'
    LinkedTerms = @('SKU')
    LinkedColumns = @(
      @{ Asset='products'; Column='sku' }
    )
  },
  [pscustomobject]@{
    Name        = 'Store ID'
    DataType    = 'Text'
    Domain      = $retailDomain
    Description = 'Identifier for a physical or virtual store location. Required for sales, inventory, and workforce reporting at store granularity.'
    LinkedTerms = @('Store')
    LinkedColumns = @(
      @{ Asset='orders';    Column='store_id' }
      @{ Asset='DimKiosks'; Column='KioskId' }
      @{ Asset='dim_store'; Column='Store ID' }
    )
  },
  [pscustomobject]@{
    Name        = 'Transaction Amount'
    DataType    = 'Number'
    Domain      = $retailDomain
    Description = 'Net monetary value of a single sales transaction, in local currency, after discounts and before tax.'
    LinkedTerms = @('Sale','Transaction')
    LinkedColumns = @(
      @{ Asset='orders';        Column='total_amount' }
      @{ Asset='FactPurchases'; Column='TotalPrice' }
    )
  },
  [pscustomobject]@{
    Name        = 'Employee ID'
    DataType    = 'Text'
    Domain      = $hrDomain
    Description = 'Globally unique identifier for an employee. Primary key for workforce data; used to join HR, payroll, and scheduling systems.'
    LinkedTerms = @('Employee','Associate')
    LinkedColumns = @(
      @{ Asset='orders';       Column='employee_id' }
      @{ Asset='dim_employee'; Column='Employee ID' }
    )
  },
  [pscustomobject]@{
    Name        = 'Hire Date'
    DataType    = 'DateTime'
    Domain      = $hrDomain
    Description = 'Date an employee was hired into the organization. Used to compute tenure and drive attrition / retention metrics.'
    LinkedTerms = @('Tenure')
    LinkedColumns = @(
      @{ Asset='dim_employee'; Column='Hire Date' }
    )
  }
)

$tok = Get-PurviewToken
$h   = @{ Authorization = "Bearer $tok"; 'Content-Type' = 'application/json' }

# Pull existing CDEs once for idempotency
$existing = (Invoke-RestWithRetry -Uri "$endpoint/datagovernance/catalog/criticaldataelements" -Headers $h).value

# --- column resolution support ---------------------------------------------
# Pull all catalog dataAssets once (gives us catalogAssetId + datamap assetId)
$catalogAssets = (Invoke-RestWithRetry -Uri "$endpoint/datagovernance/catalog/dataassets" -Headers $h).value
# Index by lowercase asset name -> @{ catId; dmId }
$catalogAssetByName = @{}
foreach ($a in $catalogAssets) {
    $k = $a.name.ToLower()
    if (-not $catalogAssetByName.ContainsKey($k)) {
        $catalogAssetByName[$k] = @{ catId = $a.id; dmId = $a.source.assetId }
    }
}

# For PowerBI dataset child tables (e.g. dim_employee inside HR & Workforce),
# walk the dataset relationshipAttributes.tables to discover datamap table GUIDs.
# Maps table name -> datamap assetId (the table guid itself).
$datasetTableByName = @{}
foreach ($a in $catalogAssets | Where-Object { $_.source.assetType -eq 'powerbi_dataset' }) {
    $ds = Invoke-RestWithRetry -Uri "$endpoint/catalog/api/atlas/v2/entity/guid/$($a.source.assetId)" -Headers $h
    foreach ($t in $ds.entity.relationshipAttributes.tables) {
        $tk = $t.displayText.ToLower()
        if (-not $datasetTableByName.ContainsKey($tk)) { $datasetTableByName[$tk] = $t.guid }
    }
}

# Cache: datamap assetId -> @{ columnName -> columnGuid }
$columnsByAsset = @{}
function Get-DataMapColumns([string]$assetGuid) {
    if ($script:columnsByAsset.ContainsKey($assetGuid)) { return $script:columnsByAsset[$assetGuid] }
    $e = Invoke-RestWithRetry -Uri "$endpoint/catalog/api/atlas/v2/entity/guid/$assetGuid" -Headers $h
    $m = @{}
    foreach ($p in $e.referredEntities.PSObject.Properties) {
        $ent = $p.Value
        if ($ent.typeName -match 'column') { $m[$ent.attributes.name] = $ent.guid }
    }
    $script:columnsByAsset[$assetGuid] = $m
    return $m
}

# Resolve @{Asset; Column} -> @{ dmAssetId; dmColumnId; catalogAssetId(or $null) }
function Resolve-ColumnRef($ref) {
    $assetKey = $ref.Asset.ToLower()
    $dmAssetId = $null
    $catalogAssetId = $null
    if ($script:catalogAssetByName.ContainsKey($assetKey)) {
        $dmAssetId      = $script:catalogAssetByName[$assetKey].dmId
        $catalogAssetId = $script:catalogAssetByName[$assetKey].catId
    } elseif ($script:datasetTableByName.ContainsKey($assetKey)) {
        $dmAssetId = $script:datasetTableByName[$assetKey]
    } else {
        Write-Warning "  asset '$($ref.Asset)' not found in catalog or any powerbi dataset"
        return $null
    }
    $cols = Get-DataMapColumns $dmAssetId
    if (-not $cols.ContainsKey($ref.Column)) {
        Write-Warning "  column '$($ref.Column)' not found on asset '$($ref.Asset)' (dm=$dmAssetId)"
        return $null
    }
    return @{ dmAssetId = $dmAssetId; dmColumnId = $cols[$ref.Column]; catalogAssetId = $catalogAssetId }
}

$created = @()
foreach ($spec in $specs) {
    $hit = $existing | Where-Object { $_.domain -eq $spec.Domain -and $_.name -eq $spec.Name } | Select-Object -First 1
    if ($hit) {
        Write-Host "[exists]  CDE '$($spec.Name)' id=$($hit.id)" -ForegroundColor DarkGray
        $cde = $hit
    } else {
        $body = @{
            name        = $spec.Name
            dataType    = $spec.DataType
            description = $spec.Description
            domain      = $spec.Domain
            status      = 'Published'
            contacts    = @{ owner = @(@{ id = $ownerId }) }
        } | ConvertTo-Json -Depth 6
        $cde = Invoke-RestWithRetry -Method POST -Uri "$endpoint/datagovernance/catalog/criticaldataelements" -Headers $h -Body $body
        Write-Host "[created] CDE '$($spec.Name)' ($($spec.DataType)) id=$($cde.id)" -ForegroundColor Green
    }

    # Link to terms (idempotent)
    $existingRels = (Invoke-RestWithRetry -Uri "$endpoint/datagovernance/catalog/criticaldataelements/$($cde.id)/relationships?entityType=Term" -Headers $h).value
    foreach ($termName in $spec.LinkedTerms) {
        $termId = $termIdByName[$termName]
        if (-not $termId) {
            Write-Warning "  Term '$termName' not in context.json, skipping"
            continue
        }
        if ($existingRels | Where-Object { $_.entityId -eq $termId }) {
            Write-Host "  [linked]  -> term '$termName' (exists)" -ForegroundColor DarkGray
            continue
        }
        $linkBody = @{ entityId = $termId; relationshipType = 'Related' } | ConvertTo-Json
        $r = Invoke-WebRequest -Method POST -Uri "$endpoint/datagovernance/catalog/criticaldataelements/$($cde.id)/relationships?entityType=Term" -Headers $h -Body $linkBody -SkipHttpErrorCheck
        if ($r.StatusCode -notin 200,201) {
            $b = if ($r.RawContentStream.Length) { [System.Text.Encoding]::UTF8.GetString($r.RawContentStream.ToArray()) } else { '' }
            throw "Link CDE->Term failed for '$($spec.Name)' -> '$termName': $($r.StatusCode) $b"
        }
        Write-Host "  [linked]  -> term '$termName'" -ForegroundColor Green
    }

    # Link to physical columns: ingest -> CDE rel -> (optional) asset rel
    $existingColRels = @((Invoke-RestWithRetry -Uri "$endpoint/datagovernance/catalog/criticaldataelements/$($cde.id)/relationships?entityType=DataColumn" -Headers $h).value)
    $linkedColumnsOut = @()
    foreach ($ref in $spec.LinkedColumns) {
        $r = Resolve-ColumnRef $ref
        if (-not $r) { continue }

        # Ingest (idempotent server-side: same datamap col returns the same catalog id)
        $ingestBody = @{ requests = @(@{ dataMapAssetId = $r.dmAssetId; dataMapColumnId = $r.dmColumnId }) } | ConvertTo-Json -Depth 5
        $ingestResp = Invoke-RestWithRetry -Method POST -Uri "$endpoint/datagovernance/catalog/dataColumns/ingest" -Headers $h -Body $ingestBody
        $catalogColumnId = $ingestResp[0].id

        if ($existingColRels | Where-Object { $_.entityId -eq $catalogColumnId }) {
            Write-Host "  [linked]  -> column $($ref.Asset).$($ref.Column) (exists)" -ForegroundColor DarkGray
        } else {
            $linkBody = @{ entityId = $catalogColumnId; description = ''; relationshipType = 'Related' } | ConvertTo-Json
            $lr = Invoke-WebRequest -Method POST -Uri "$endpoint/datagovernance/catalog/criticaldataelements/$($cde.id)/relationships?entityType=DataColumn" -Headers $h -Body $linkBody -SkipHttpErrorCheck
            if ($lr.StatusCode -notin 200,201) {
                $b = if ($lr.RawContentStream.Length) { [System.Text.Encoding]::UTF8.GetString($lr.RawContentStream.ToArray()) } else { '' }
                throw "Link CDE->DataColumn failed for '$($spec.Name)' -> $($ref.Asset).$($ref.Column): $($lr.StatusCode) $b"
            }
            Write-Host "  [linked]  -> column $($ref.Asset).$($ref.Column)" -ForegroundColor Green
        }

        # Asset rel (best-effort): only when the column's parent is itself a catalog asset
        if ($r.catalogAssetId) {
            $assetRels = @((Invoke-RestWithRetry -Uri "$endpoint/datagovernance/catalog/dataassets/$($r.catalogAssetId)/relationships?entityType=DataColumn" -Headers $h).value)
            if (-not ($assetRels | Where-Object { $_.entityId -eq $catalogColumnId })) {
                $linkBody = @{ entityId = $catalogColumnId; description = ''; relationshipType = 'Related' } | ConvertTo-Json
                $ar = Invoke-WebRequest -Method POST -Uri "$endpoint/datagovernance/catalog/dataassets/$($r.catalogAssetId)/relationships?entityType=DataColumn" -Headers $h -Body $linkBody -SkipHttpErrorCheck
                if ($ar.StatusCode -notin 200,201) {
                    $b = if ($ar.RawContentStream.Length) { [System.Text.Encoding]::UTF8.GetString($ar.RawContentStream.ToArray()) } else { '' }
                    Write-Warning "    asset->column link failed ($($ar.StatusCode)): $b"
                }
            }
        }

        $linkedColumnsOut += [ordered]@{
            asset           = $ref.Asset
            column          = $ref.Column
            dataMapAssetId  = $r.dmAssetId
            dataMapColumnId = $r.dmColumnId
            catalogColumnId = $catalogColumnId
            catalogAssetId  = $r.catalogAssetId
        }
    }

    $created += [ordered]@{
        id            = $cde.id
        name          = $spec.Name
        dataType      = $spec.DataType
        domain        = $spec.Domain
        linkedTerms   = $spec.LinkedTerms
        linkedColumns = $linkedColumnsOut
    }
}

# Persist to context.json
if ($ctx.PSObject.Properties['criticalDataElements']) { $ctx.PSObject.Properties.Remove('criticalDataElements') }
$ctx | Add-Member -NotePropertyName criticalDataElements -NotePropertyValue $created
($ctx | ConvertTo-Json -Depth 10) | Set-Content "$PSScriptRoot\context.json" -Encoding UTF8

Write-Host ""
Write-Host "Done. $($created.Count) CDEs in context.json."
