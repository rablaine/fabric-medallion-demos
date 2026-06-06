# Phase 12: create glossary terms scoped to governance domains.
# Endpoint: /datagovernance/catalog/terms (NO api-version)
# Term shape: name, description, domain={domainId}, contacts.owner=[{id=ownerObjectId}], status='Draft'|'Published'
# DELETE on /terms/{id} returns 204.

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\_lib.ps1"
$ctx = Read-Context

$endpoint = $ctx.purview.endpoint
if (-not $ctx.governanceDomains) { throw "Run 11-governance-domains.ps1 first" }

$retailDomainId = $ctx.governanceDomains.retail.id
$hrDomainId     = $ctx.governanceDomains.retailHr.id
foreach ($pair in @(@{k='retail';id=$retailDomainId}, @{k='retailHr';id=$hrDomainId})) {
  if (-not $pair.id -or $pair.id -eq '00000000-0000-0000-0000-000000000000') {
    throw "governanceDomains.$($pair.k).id is missing or zero-GUID in context.json -- re-run 11-governance-domains.ps1"
  }
}

# Resolve current user's objectId as term owner
$ownerId = (az ad signed-in-user show --query id -o tsv)
if (-not $ownerId) { throw "Could not resolve signed-in user objectId" }

$terms = @(
  # --- Contoso-Retail-datj77 domain ---
  [pscustomobject]@{ Domain = $retailDomainId; Name = 'SKU';            Description = 'Stock Keeping Unit. Unique identifier assigned to each distinct product Contoso sells, used for inventory tracking and POS scanning.' }
  [pscustomobject]@{ Domain = $retailDomainId; Name = 'Store';          Description = 'A physical Contoso retail location where merchandise is displayed, sold, and inventoried. Each store has a unique store_id used across sales, ops, and HR data.' }
  [pscustomobject]@{ Domain = $retailDomainId; Name = 'Sale';           Description = 'A completed customer purchase transaction. Each sale comprises one or more SKUs, a payment method, a store, and a timestamp. Primary revenue event for the business.' }
  [pscustomobject]@{ Domain = $retailDomainId; Name = 'Customer';       Description = 'Any individual who has made at least one purchase from Contoso. Customers may be anonymous (cash sales) or known (loyalty members linked via customer_id).' }
  # Synonym term (linked to Sale via phase 14 relationships)
  [pscustomobject]@{ Domain = $retailDomainId; Name = 'Transaction';    Description = 'Industry-standard term for a completed point-of-sale event. Used interchangeably with "Sale" in finance and POS contexts.' }
  # --- Contoso-Retail-HR-datj77 domain ---
  [pscustomobject]@{ Domain = $hrDomainId;     Name = 'Employee';       Description = 'A person on the Contoso payroll, whether full-time, part-time, or seasonal. Identified by employee_id and linked to a home store and reporting manager.' }
  [pscustomobject]@{ Domain = $hrDomainId;     Name = 'Tenure';         Description = 'Length of continuous employment with Contoso, measured in months from hire_date to today (or to termination_date for separated employees).' }
  [pscustomobject]@{ Domain = $hrDomainId;     Name = 'Attrition';      Description = 'Voluntary or involuntary departure of an employee. Tracked monthly per store and aggregated to attrition_rate = separations / avg_headcount.' }
  # Synonym terms (linked to Employee + Attrition via phase 14 relationships)
  [pscustomobject]@{ Domain = $hrDomainId;     Name = 'Associate';      Description = 'Front-line retail employee terminology. Used interchangeably with "Employee" in store operations and customer-facing communications.' }
  [pscustomobject]@{ Domain = $hrDomainId;     Name = 'Turnover';       Description = 'HR-industry synonym for attrition. The rate at which employees leave and are replaced over a period.' }
)

$tok = Get-PurviewToken
$headers = @{ Authorization = "Bearer $tok"; 'Content-Type' = 'application/json' }

# Idempotency: list existing terms once
$existing = (Invoke-RestWithRetry -Uri "$endpoint/datagovernance/catalog/terms" -Headers $headers).value
$byNameDomain = @{}
foreach ($t in $existing) { $byNameDomain["$($t.domain)|$($t.name)"] = $t }

$created = @()
foreach ($spec in $terms) {
  $key = "$($spec.Domain)|$($spec.Name)"
  if ($byNameDomain.ContainsKey($key)) {
    Write-Host "Term exists: $($spec.Name) (domain=$($spec.Domain.Substring(0,8))...) id=$($byNameDomain[$key].id)"
    $created += $byNameDomain[$key]
    continue
  }
  $body = @{
    name        = $spec.Name
    description = $spec.Description
    domain      = $spec.Domain
    contacts    = @{ owner = @(@{ id = $ownerId }) }
    status      = 'Published'
  }
  $resp = Invoke-RestWithRetry -Method POST `
    -Uri "$endpoint/datagovernance/catalog/terms" `
    -Headers $headers -Body ($body | ConvertTo-Json -Depth 10)
  Write-Host "Created: $($resp.name) (domain=$($resp.domain.Substring(0,8))...) id=$($resp.id)"
  $created += $resp
}

# Persist
if (-not $ctx.PSObject.Properties['glossaryTerms']) {
  $ctx | Add-Member -NotePropertyName glossaryTerms -NotePropertyValue @()
}
$ctx.glossaryTerms = @($created | ForEach-Object {
  [ordered]@{ id = $_.id; name = $_.name; domain = $_.domain }
})
($ctx | ConvertTo-Json -Depth 10) | Set-Content "$PSScriptRoot\context.json" -Encoding UTF8

Write-Host ""
Write-Host "Done. $($created.Count) glossary terms in 2 domains."
