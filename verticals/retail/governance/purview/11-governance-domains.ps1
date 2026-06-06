# Phase 11: create Unified Catalog governance domains.
# API quirks:
#  - Endpoint: /datagovernance/catalog/businessdomains (NO api-version param — server rejects all versions)
#  - Types: 'LineOfBusiness' (top-level), 'DataDomain' (typically nested), plus other variants
#  - Status: 'Draft' on create, must PATCH to 'Published' separately if needed
#  - DELETE returns 204
#
# Creates 2 domains:
#   Contoso-Retail-datj77       (LineOfBusiness, top-level)
#   Contoso-Retail-HR-datj77    (DataDomain, child of Retail)

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\_lib.ps1"
$ctx = Read-Context

$endpoint = $ctx.purview.endpoint
$suffix   = $ctx.collection.suffix

$domains = @(
  [pscustomobject]@{
    LocalKey    = 'retail'
    Name        = "Contoso-Retail-$suffix"
    Type        = 'LineOfBusiness'
    Description = 'Contoso retail demo vertical — sales, inventory, customer, operations data.'
    ParentLocal = $null
  },
  [pscustomobject]@{
    LocalKey    = 'retailHr'
    Name        = "Contoso-Retail-HR-$suffix"
    Type        = 'LineOfBusiness'
    Description = 'HR + workforce data for Contoso retail vertical. Personnel records, attrition, tenure.'
    ParentLocal = $null
  }
)

$tok = Get-PurviewToken
$headers = @{ Authorization = "Bearer $tok"; 'Content-Type' = 'application/json' }

# Fetch existing for idempotency
$existing = (Invoke-RestWithRetry -Uri "$endpoint/datagovernance/catalog/businessdomains" -Headers $headers).value
$byName = @{}
foreach ($d in $existing) { $byName[$d.name] = $d }

$created = @{}
foreach ($spec in $domains) {
  $body = @{
    name        = $spec.Name
    type        = $spec.Type
    description = $spec.Description
    status      = 'Draft'
  }
  if ($spec.ParentLocal) {
    $parentId = $created[$spec.ParentLocal].id
    if (-not $parentId) { throw "Parent '$($spec.ParentLocal)' not yet created" }
    $body.parentId = $parentId
  }
  if ($byName.ContainsKey($spec.Name)) {
    Write-Host "Domain '$($spec.Name)' already exists (id=$($byName[$spec.Name].id), status=$($byName[$spec.Name].status))"
    $created[$spec.LocalKey] = $byName[$spec.Name]
  } else {
    $resp = Invoke-RestWithRetry -Method POST `
      -Uri "$endpoint/datagovernance/catalog/businessdomains" `
      -Headers $headers -Body ($body | ConvertTo-Json -Depth 10)
    Write-Host "Created '$($resp.name)' type=$($resp.type) id=$($resp.id) status=$($resp.status)"
    $created[$spec.LocalKey] = $resp
  }
  # Ensure Published so terms/data products can be Published under it.
  # NOTE: PATCH response may only echo the updated fields (no id/name/type), so
  # we GET the full object after PATCH instead of trusting the PATCH body --
  # otherwise the id silently becomes null and downstream phases hit a
  # zero-GUID lookup error.
  if ($created[$spec.LocalKey].status -ne 'Published') {
    $domId = $created[$spec.LocalKey].id
    Invoke-RestWithRetry -Method PATCH `
      -Uri "$endpoint/datagovernance/catalog/businessdomains/$domId" `
      -Headers $headers -Body (@{ status = 'Published' } | ConvertTo-Json) | Out-Null
    $refreshed = Invoke-RestWithRetry -Method GET `
      -Uri "$endpoint/datagovernance/catalog/businessdomains/$domId" -Headers $headers
    Write-Host "  -> Published"
    $created[$spec.LocalKey] = $refreshed
  }
  if (-not $created[$spec.LocalKey].id) {
    throw "Domain '$($spec.Name)' has no id after create/publish -- aborting before context.json gets corrupted"
  }
}

# --- Data estate mapping ---------------------------------------------------
# Each governance domain links to one or more "data estates", each containing
# related collections. Portal exposes this as the "Data estate mappings" tab.
# API: PUT /datagovernance/catalog/businessdomains/{id} with full body including
# new `domains` array. PUT is a full replace, so we GET first and merge.
#
# Estate mapping shape:
#   domains: [{
#     name: <purview account name>,
#     friendlyName: 'Cloud Platforms',
#     relatedCollections: [{
#       name: <collection refName>,
#       friendlyName: <collection friendly>,
#       parentCollection: { type:'CollectionReference', refName: <parent> }
#     }]
#   }]
$purviewAccount = ([uri]$endpoint).Host.Split('.')[0]
$col = $ctx.collection
$mapping = @(@{
    name             = $purviewAccount
    friendlyName     = 'Cloud Platforms'
    relatedCollections = @(@{
        name             = $col.name
        friendlyName     = $col.friendlyName
        parentCollection = @{ type = 'CollectionReference'; refName = $purviewAccount }
    })
})

foreach ($k in 'retail','retailHr') {
    $d = $created[$k]
    $current = Invoke-RestWithRetry -Uri "$endpoint/datagovernance/catalog/businessdomains/$($d.id)" -Headers $headers
    $existingMapping = $current.domains
    $needsUpdate = $true
    if ($existingMapping) {
        $hit = $existingMapping | Where-Object { $_.name -eq $purviewAccount }
        if ($hit) {
            $rc = $hit.relatedCollections | Where-Object { $_.name -eq $col.name }
            if ($rc) { $needsUpdate = $false }
        }
    }
    if (-not $needsUpdate) {
        Write-Host "  [exists]  estate mapping on '$($d.name)' -> collection '$($col.name)'" -ForegroundColor DarkGray
        continue
    }
    $putBody = [ordered]@{
        status          = $current.status
        type            = $current.type
        id              = $current.id
        name            = $current.name
        systemData      = $current.systemData
        description     = $current.description
        isRestricted    = if ($null -ne $current.isRestricted) { $current.isRestricted } else { $false }
        isStagingDomain = if ($null -ne $current.isStagingDomain) { $current.isStagingDomain } else { $false }
        domains         = $mapping
    }
    if ($current.parentId) { $putBody.parentId = $current.parentId }
    $put = Invoke-RestWithRetry -Method PUT `
        -Uri "$endpoint/datagovernance/catalog/businessdomains/$($d.id)" `
        -Headers $headers -Body ($putBody | ConvertTo-Json -Depth 10)
    Write-Host "  [linked]  estate mapping on '$($d.name)' -> collection '$($col.name)'" -ForegroundColor Green
}

# Persist to context.json.
# NOTE: use PSCustomObject (NOT [ordered]@{}). ConvertTo-Json serializes an
# OrderedDictionary by its dictionary entries, not by NoteProperties added
# via Add-Member, so an [ordered]@{} container would emit `{}` and silently
# drop every domain id.
if (-not $ctx.PSObject.Properties['governanceDomains']) {
  $ctx | Add-Member -NotePropertyName governanceDomains -NotePropertyValue ([pscustomobject]@{})
}
foreach ($k in $created.Keys) {
  $d = $created[$k]
  $val = [pscustomobject]@{ id = $d.id; name = $d.name; type = $d.type }
  if ($ctx.governanceDomains.PSObject.Properties[$k]) {
    $ctx.governanceDomains.PSObject.Properties[$k].Value = $val
  } else {
    $ctx.governanceDomains | Add-Member -NotePropertyName $k -NotePropertyValue $val
  }
}
($ctx | ConvertTo-Json -Depth 10) | Set-Content "$PSScriptRoot\context.json" -Encoding UTF8

Write-Host ""
Write-Host "Done. Governance domains:"
$created.Values | ForEach-Object { Write-Host "  $($_.name)  ($($_.type), id=$($_.id))" }
