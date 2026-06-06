# Teardown ALL Purview artifacts created by this recipe, in dependency order.
# Reverse of phases 11/12/13/10/08/07/06/03.
# Safe to run multiple times — uses GET-then-DELETE pattern; missing items are skipped.
# Does NOT touch SQL, ADLS, Fabric workspaces, or RBAC on Azure resources.

[CmdletBinding()]
param(
  [switch]$IncludeRbac    # If set, also revoke Purview MSI roles on SQL + ADLS
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\_lib.ps1"
$ctx = Read-Context

$endpoint = $ctx.purview.endpoint
$tok = Get-PurviewToken
$headers = @{ Authorization = "Bearer $tok"; 'Content-Type' = 'application/json' }

function Try-Delete {
  param([string]$Url, [string]$Label)
  try {
    $r = Invoke-WebRequest -Method DELETE -Uri $Url -Headers $headers -SkipHttpErrorCheck
    if ($r.StatusCode -in 200,204) { Write-Host "  [del]  $Label" }
    elseif ($r.StatusCode -eq 404) { Write-Host "  [miss] $Label" -ForegroundColor DarkGray }
    else { Write-Warning "  [$($r.StatusCode)] $Label -- $([System.Text.Encoding]::UTF8.GetString([byte[]]$r.Content))" }
  } catch {
    Write-Warning "  [err] $Label : $($_.Exception.Message)"
  }
}

# UC entities (terms, domains, data products) can't be deleted while Published.
# PATCH to Draft, then DELETE.
function Try-DraftDelete {
  param([string]$BaseUrl, [string]$Label)
  Invoke-WebRequest -Method PATCH -Uri $BaseUrl -Headers $headers -Body '{"status":"Draft"}' -SkipHttpErrorCheck | Out-Null
  Try-Delete $BaseUrl $Label
}

# Unlink all relationships from a data product before delete.
function Unlink-DataProduct {
  param([string]$DpId)
  foreach ($et in 'DataAsset','Term','CriticalDataElement','Objective') {
    $rels = (Invoke-RestWithRetry -Uri "$endpoint/datagovernance/catalog/dataproducts/$DpId/relationships?entityType=$et" -Headers $headers -SkipHttpErrorCheck).value
    foreach ($r in $rels) {
      if (-not $r.entityId) { continue }
      Invoke-WebRequest -Method DELETE -Uri "$endpoint/datagovernance/catalog/dataproducts/$DpId/relationships?entityType=$et&entityId=$($r.entityId)" -Headers $headers -SkipHttpErrorCheck | Out-Null
    }
  }
}

# Strip term-term relationships in BOTH directions for every pair in the supplied
# list. Phase 14 only POSTs one direction but Purview's referential-integrity
# check sees the inverse edge too; GET /relationships?entityType=Term silently
# returns 0 for the inverse side, so a one-sided strip leaves a hidden rel that
# blocks term DELETE with "Referenced by Term: [...]" 400s.
function Strip-TermRels-Bidirectional {
  param([object[]]$Terms)
  foreach ($a in $Terms) {
    foreach ($b in $Terms) {
      if ($a.id -eq $b.id) { continue }
      foreach ($rt in 'Synonym','Related') {
        Invoke-WebRequest -Method DELETE -Uri "$endpoint/datagovernance/catalog/terms/$($a.id)/relationships?entityType=Term&entityId=$($b.id)&relationshipType=$rt" -Headers $headers -SkipHttpErrorCheck | Out-Null
      }
    }
  }
}

# --- 0. DP access policies. Must go BEFORE data product delete.
# Workflow delete happens AFTER data product delete (see phase 1c) because the workflow
# DELETE returns 400/16014 ("data product is currently published") while the DP exists.
Write-Host "=== DP access policies ===" -ForegroundColor Cyan
if ($ctx.dpAccessPolicies -and $ctx.tenantId) {
  $tenantApi = "https://$($ctx.tenantId)-api.purview-service.microsoft.com"
  foreach ($p in $ctx.dpAccessPolicies) {
    $polUrl = "$tenantApi/datagovernance/dataaccess/dataProducts/$($p.dpId)/policySets/applied?api-version=2023-10-01-preview"
    Try-Delete $polUrl "DP policy '$($p.dpName)' (policySetId=$($p.policySetId))"
  }
}

# --- 1. Objectives (OKRs). MUST run BEFORE data products because DPs are
# linked to objectives and the API blocks DP delete with "Referenced by:
# Objective" 400. Strip DP/Term/CDE rels from each objective, delete its key
# results explicitly (cascade doesn't fire), then DraftDelete the objective.
Write-Host "=== Objectives ===" -ForegroundColor Cyan
$targetDomainIds = @()
if ($ctx.governanceDomains) {
  if ($ctx.governanceDomains.retail)   { $targetDomainIds += $ctx.governanceDomains.retail.id }
  if ($ctx.governanceDomains.retailHr) { $targetDomainIds += $ctx.governanceDomains.retailHr.id }
}
if ($ctx.objectives) {
  foreach ($o in $ctx.objectives) {
    foreach ($et in 'DataProduct','Term','CriticalDataElement') {
      $rels = (Invoke-RestWithRetry -Uri "$endpoint/datagovernance/catalog/objectives/$($o.id)/relationships?entityType=$et" -Headers $headers -SkipHttpErrorCheck).value
      foreach ($r in $rels) {
        if (-not $r.entityId) { continue }
        Invoke-WebRequest -Method DELETE -Uri "$endpoint/datagovernance/catalog/objectives/$($o.id)/relationships?entityType=$et&entityId=$($r.entityId)" -Headers $headers -SkipHttpErrorCheck | Out-Null
      }
    }
    $krs = (Invoke-RestWithRetry -Uri "$endpoint/datagovernance/catalog/objectives/$($o.id)/keyResults" -Headers $headers -SkipHttpErrorCheck).value
    foreach ($kr in $krs) {
      Try-Delete "$endpoint/datagovernance/catalog/objectives/$($o.id)/keyResults/$($kr.id)" "  KR '$($kr.definition.Substring(0,[Math]::Min(40,$kr.definition.Length)))...'"
    }
    Try-DraftDelete "$endpoint/datagovernance/catalog/objectives/$($o.id)" "objective '$($o.definition.Substring(0,[Math]::Min(50,$o.definition.Length)))...'"
  }
}

# --- 2. Data products (now that objectives are gone the DP delete is unblocked) ---
Write-Host "=== Data products ===" -ForegroundColor Cyan
$existingDps = (Invoke-RestWithRetry -Uri "$endpoint/datagovernance/catalog/dataproducts" -Headers $headers).value
$targetDpNames = @('Sales','Customer 360','Inventory','Workforce')
foreach ($dp in $existingDps) {
  if ($targetDpNames -contains $dp.name -and $targetDomainIds -contains $dp.domain) {
    Unlink-DataProduct -DpId $dp.id
    Try-DraftDelete "$endpoint/datagovernance/catalog/dataproducts/$($dp.id)" "data product '$($dp.name)'"
  }
}

# --- 2b. DP workflows. Must run AFTER data product delete (workflow DELETE 400s while DP exists). ---
Write-Host "=== DP workflows ===" -ForegroundColor Cyan
if ($ctx.dpAccessPolicies -and $ctx.tenantId) {
  $tenantApi = "https://$($ctx.tenantId)-api.purview-service.microsoft.com"
  foreach ($p in $ctx.dpAccessPolicies) {
    if ($p.workflowId) {
      $wfUrl = "$tenantApi/datagovernance/dataaccess/workflows/$($p.workflowId)"
      Try-Delete $wfUrl "DP workflow '$($p.dpName)' (id=$($p.workflowId))"
    }
  }
}

# --- 3. Access policies on terms (do this BEFORE term delete) ---
Write-Host "=== Term access policies ===" -ForegroundColor Cyan
if ($ctx.accessPolicies -and $ctx.tenantId) {
  $tenantApi = "https://$($ctx.tenantId)-api.purview-service.microsoft.com"
  foreach ($p in $ctx.accessPolicies) {
    $purl = "$tenantApi/datagovernance/dataaccess/terms/$($p.termId)/policySets/applied?api-version=2023-10-01-preview"
    Try-Delete $purl "access policy on term '$($p.term)' (policySetId=$($p.policySetId))"
  }
}

# --- 4. Critical Data Elements + ingested DataColumns.
# MUST run BEFORE catalog asset delete because each DataColumn references its
# parent asset, and the asset delete is blocked while DataColumns exist.
Write-Host "=== Critical Data Elements ===" -ForegroundColor Cyan
if ($ctx.criticalDataElements) {
  foreach ($c in $ctx.criticalDataElements) {
    # Unlink term relationships
    $rels = (Invoke-RestWithRetry -Uri "$endpoint/datagovernance/catalog/criticaldataelements/$($c.id)/relationships?entityType=Term" -Headers $headers -SkipHttpErrorCheck).value
    foreach ($r in $rels) {
      if (-not $r.entityId) { continue }
      Invoke-WebRequest -Method DELETE -Uri "$endpoint/datagovernance/catalog/criticaldataelements/$($c.id)/relationships?entityType=Term&entityId=$($r.entityId)&relationshipType=Related" -Headers $headers -SkipHttpErrorCheck | Out-Null
    }
    # Unlink DataColumn relationships
    $colRels = @((Invoke-RestWithRetry -Uri "$endpoint/datagovernance/catalog/criticaldataelements/$($c.id)/relationships?entityType=DataColumn" -Headers $headers -SkipHttpErrorCheck).value)
    foreach ($r in $colRels) {
      if (-not $r.entityId) { continue }
      Invoke-WebRequest -Method DELETE -Uri "$endpoint/datagovernance/catalog/criticaldataelements/$($c.id)/relationships?entityType=DataColumn&entityId=$($r.entityId)&relationshipType=Related" -Headers $headers -SkipHttpErrorCheck | Out-Null
    }
    Try-DraftDelete "$endpoint/datagovernance/catalog/criticaldataelements/$($c.id)" "CDE '$($c.name)'"

    # Delete the ingested catalog DataColumn entities + their asset->column rels
    if ($c.linkedColumns) {
      foreach ($lc in $c.linkedColumns) {
        if ($lc.catalogAssetId) {
          Invoke-WebRequest -Method DELETE -Uri "$endpoint/datagovernance/catalog/dataassets/$($lc.catalogAssetId)/relationships?entityType=DataColumn&entityId=$($lc.catalogColumnId)&relationshipType=Related" -Headers $headers -SkipHttpErrorCheck | Out-Null
        }
        $d = Invoke-WebRequest -Method DELETE -Uri "$endpoint/datagovernance/catalog/datacolumns/$($lc.catalogColumnId)" -Headers $headers -SkipHttpErrorCheck
        Write-Host "  [deleted] DataColumn $($lc.asset).$($lc.column) ($($lc.catalogColumnId)) -> $($d.StatusCode)" -ForegroundColor DarkGray
      }
    }
  }
}

# --- 5. Catalog DataAssets onboarded for our data products ---
# Only delete catalog assets whose source.fqn contains one of our retail SQL/ADLS/Fabric IDs.
Write-Host "=== Catalog data assets ===" -ForegroundColor Cyan
$ourSubstrings = @()
if ($ctx.retail.sqlServer.fqdn) { $ourSubstrings += $ctx.retail.sqlServer.fqdn }
if ($ctx.retail.adls.name)      { $ourSubstrings += $ctx.retail.adls.name }
foreach ($ws in $ctx.retail.workspaces) { $ourSubstrings += $ws.id }

$allAssets = (Invoke-RestWithRetry -Uri "$endpoint/datagovernance/catalog/dataassets" -Headers $headers).value
foreach ($a in $allAssets) {
  $fqn = $a.source.fqn
  if (-not $fqn) { continue }
  foreach ($s in $ourSubstrings) {
    if ($fqn -like "*$s*") {
      # Strip any residual DataColumn / CriticalDataColumn refs first
      foreach ($et in 'DataColumn','CriticalDataColumn','Term') {
        $rels = @((Invoke-RestWithRetry -Uri "$endpoint/datagovernance/catalog/dataassets/$($a.id)/relationships?entityType=$et" -Headers $headers -SkipHttpErrorCheck).value)
        foreach ($r in $rels) {
          if (-not $r.entityId) { continue }
          Invoke-WebRequest -Method DELETE -Uri "$endpoint/datagovernance/catalog/dataassets/$($a.id)/relationships?entityType=$et&entityId=$($r.entityId)&relationshipType=Related" -Headers $headers -SkipHttpErrorCheck | Out-Null
        }
      }
      Try-Delete "$endpoint/datagovernance/catalog/dataassets/$($a.id)" "catalog asset '$($a.name)'"
      break
    }
  }
}

# --- 6. Glossary terms.
# Phase 14 only POSTs forward Term rels but Purview's referential-integrity check
# also enforces the inverse direction; GET /relationships returns 0 for the
# auto-created inverse, so we must DELETE both directions for every pair before
# the terms become deletable. Retry up to 5 passes for cyclic cleanup.
Write-Host "=== Glossary terms ===" -ForegroundColor Cyan
if ($ctx.glossaryTerms) {
  $termObjs = $ctx.glossaryTerms | ForEach-Object { @{ id = $_.id; name = $_.name } }
  Strip-TermRels-Bidirectional -Terms $termObjs
  for ($pass = 1; $pass -le 5; $pass++) {
    $allTerms = (Invoke-RestWithRetry -Uri "$endpoint/datagovernance/catalog/terms" -Headers $headers).value
    $remaining = @($allTerms | Where-Object { $targetDomainIds -contains $_.domain })
    if ($remaining.Count -eq 0) { break }
    Write-Host "  pass $pass : $($remaining.Count) terms remaining" -ForegroundColor DarkGray
    foreach ($t in $remaining) {
      Try-DraftDelete "$endpoint/datagovernance/catalog/terms/$($t.id)" "term '$($t.name)'"
    }
  }
}

# --- 4. Governance domains (must be empty of products + terms first) ---
Write-Host "=== Governance domains ===" -ForegroundColor Cyan
if ($ctx.governanceDomains) {
  # Delete child first (HR is child of Retail)
  if ($ctx.governanceDomains.retailHr) {
    Try-DraftDelete "$endpoint/datagovernance/catalog/businessdomains/$($ctx.governanceDomains.retailHr.id)" "domain '$($ctx.governanceDomains.retailHr.name)'"
  }
  if ($ctx.governanceDomains.retail) {
    Try-DraftDelete "$endpoint/datagovernance/catalog/businessdomains/$($ctx.governanceDomains.retail.id)" "domain '$($ctx.governanceDomains.retail.name)'"
  }
}

# --- 5. Scans + sources (datamap) ---
Write-Host "=== Scans and sources (datamap) ===" -ForegroundColor Cyan
# Fabric: new shape is { source:{name,kind,createdByUs}, scan:{name,collection} }.
# Old shape was { name, collection }. Handle both for back-compat with old context.json.
if ($ctx.scans.fabric -and -not $ctx.scans.fabric.skipped) {
  $fb = $ctx.scans.fabric
  $fbSourceName = if ($fb.source) { $fb.source.name } else { 'FabricInstance' }
  $fbScanName   = if ($fb.scan)   { $fb.scan.name }   else { $fb.name }
  $fbCreatedByUs = if ($fb.source) { [bool]$fb.source.createdByUs } else { $false }
  if ($fbScanName) {
    Try-Delete "$endpoint/scan/datasources/$fbSourceName/scans/$fbScanName`?api-version=2022-02-01-preview" "fabric scan '$fbScanName'"
  }
  if ($fbCreatedByUs) {
    Try-Delete "$endpoint/scan/datasources/$fbSourceName`?api-version=2022-02-01-preview" "fabric source '$fbSourceName'"
  } else {
    Write-Host "  [keep] fabric source '$fbSourceName' (not created by us)" -ForegroundColor DarkGray
  }
}
if ($ctx.scans.sql) {
  Try-Delete "$endpoint/scan/datasources/$($ctx.dataSources.sql)/scans/$($ctx.scans.sql)?api-version=2022-02-01-preview" "sql scan '$($ctx.scans.sql)'"
}
if ($ctx.scans.adls) {
  Try-Delete "$endpoint/scan/datasources/$($ctx.dataSources.adls)/scans/$($ctx.scans.adls)?api-version=2022-02-01-preview" "adls scan '$($ctx.scans.adls)'"
}
if ($ctx.dataSources.sql) {
  Try-Delete "$endpoint/scan/datasources/$($ctx.dataSources.sql)?api-version=2022-02-01-preview" "sql source '$($ctx.dataSources.sql)'"
}
if ($ctx.dataSources.adls) {
  Try-Delete "$endpoint/scan/datasources/$($ctx.dataSources.adls)?api-version=2022-02-01-preview" "adls source '$($ctx.dataSources.adls)'"
}

# --- 6b. Atlas datamap entities under our collection.
# SQL/ADLS scans populate the Atlas data map with tables, columns, schemas,
# DBs, storage accounts, etc. These persist after scan+source delete and block
# collection delete with "is being referenced by assets and can't be deleted."
# Bulk-delete every GUID returned by the collection-scoped search.
Write-Host "=== Atlas datamap entities in collection ===" -ForegroundColor Cyan
if ($ctx.collection.name) {
  $searchBody = @{ keywords = '*'; filter = @{ collectionId = $ctx.collection.name }; limit = 1000 } | ConvertTo-Json -Depth 5 -Compress
  try {
    $searchResp = Invoke-RestWithRetry -Method POST -Uri "$endpoint/datamap/api/search/query?api-version=2024-03-01-preview" -Headers $headers -Body $searchBody
    $guids = @($searchResp.value | ForEach-Object { $_.id } | Where-Object { $_ })
    if ($guids.Count -gt 0) {
      Write-Host "  bulk-deleting $($guids.Count) datamap entities"
      $bulkUrl = "$endpoint/datamap/api/atlas/v2/entity/bulk?guid=" + ($guids -join '&guid=')
      Invoke-WebRequest -Method DELETE -Uri $bulkUrl -Headers $headers -SkipHttpErrorCheck | Out-Null
    } else {
      Write-Host "  no datamap entities in collection" -ForegroundColor DarkGray
    }
  } catch {
    Write-Warning "  Atlas search/delete failed: $($_.Exception.Message)"
  }
}

# --- 7. Collection ---
Write-Host "=== Collection ===" -ForegroundColor Cyan
if ($ctx.collection.name) {
  Try-Delete "$endpoint/account/collections/$($ctx.collection.name)?api-version=2019-11-01-preview" "collection '$($ctx.collection.name)'"
}

# --- 7. Optional: revoke RBAC ---
if ($IncludeRbac) {
  Write-Host "=== RBAC (--IncludeRbac) ===" -ForegroundColor Cyan
  $msi = $ctx.purview.systemAssignedPrincipalId
  foreach ($scope in @($ctx.retail.sqlServer.resourceId, $ctx.retail.adls.resourceId)) {
    if (-not $scope) { continue }
    Write-Host "  revoking roles on $scope for MSI $msi"
    $assigns = az role assignment list --assignee $msi --scope $scope -o json 2>$null | ConvertFrom-Json
    foreach ($a in $assigns) {
      az role assignment delete --ids $a.id 2>&1 | Out-Null
      Write-Host "    [del] role $($a.roleDefinitionName)"
    }
  }
}

# --- 8. Strip Purview-related fields from context.json ---
Write-Host "=== Cleaning context.json ===" -ForegroundColor Cyan
foreach ($p in 'governanceDomains','glossaryTerms','dataProducts','objectives','accessPolicies','dpAccessPolicies','criticalDataElements','scans','dataSources','collection') {
  if ($ctx.PSObject.Properties[$p]) { $ctx.PSObject.Properties.Remove($p) }
}
($ctx | ConvertTo-Json -Depth 10) | Set-Content "$PSScriptRoot\context.json" -Encoding UTF8

Write-Host ""
Write-Host "Teardown complete. SQL/ADLS/Fabric resources untouched." -ForegroundColor Green
if (-not $IncludeRbac) {
  Write-Host "(Purview MSI RBAC on SQL/ADLS retained. Pass -IncludeRbac to also revoke.)" -ForegroundColor DarkGray
}
