# Phase 14: link glossary terms with Synonym + Related relationships.
# Endpoint: POST /datagovernance/catalog/terms/{id}/relationships?entityType=Term
#   body: { entityId, relationshipType: 'Synonym'|'Related' }
#   response 200 -> { entityId, relationshipType, systemData }
# DELETE: ?entityType=Term&entityId={otherId} -> 204
#
# Notes:
# - Relationships are uni-directional in the API but Purview UI shows them
#   bi-directionally. Posting A->B is enough; no need to also post B->A.
# - Synonym ideally same-domain; Related can cross domains.
# - Idempotent: GETs existing relationships first, skips if link present.

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\_lib.ps1"
$ctx = Read-Context

$endpoint = $ctx.purview.endpoint
if (-not $ctx.glossaryTerms) { throw "Run 12-glossary-terms.ps1 first" }

# Build name -> id lookup
$termByName = @{}
foreach ($t in $ctx.glossaryTerms) { $termByName[$t.name] = $t.id }

# Validate all referenced terms exist
$required = @('SKU','Store','Sale','Customer','Transaction','Employee','Tenure','Attrition','Associate','Turnover')
foreach ($n in $required) {
  if (-not $termByName.ContainsKey($n)) {
    throw "Term '$n' missing from glossary. Re-run phase 12."
  }
}

# Relationship definitions. Each link is unidirectional (From -> To).
$links = @(
  # --- Synonyms (same-domain by convention) ---
  @{ From = 'Sale';      To = 'Transaction'; Type = 'Synonym' }
  @{ From = 'Employee';  To = 'Associate';   Type = 'Synonym' }
  @{ From = 'Attrition'; To = 'Turnover';    Type = 'Synonym' }

  # --- Related within Retail domain ---
  @{ From = 'Sale';      To = 'SKU';         Type = 'Related' }
  @{ From = 'Sale';      To = 'Store';       Type = 'Related' }
  @{ From = 'Sale';      To = 'Customer';    Type = 'Related' }
  @{ From = 'Customer';  To = 'Store';       Type = 'Related' }

  # --- Related within HR domain ---
  @{ From = 'Attrition'; To = 'Tenure';      Type = 'Related' }
  @{ From = 'Attrition'; To = 'Employee';    Type = 'Related' }

  # --- Cross-domain Related (HR <-> Retail) ---
  @{ From = 'Employee';  To = 'Store';       Type = 'Related' }
)

$tok = Get-PurviewToken
$headers = @{ Authorization = "Bearer $tok"; 'Content-Type' = 'application/json' }

# Cache existing relationships per source term so we only fetch each list once.
$relCache = @{}
function Get-TermRels {
  param([string]$TermId)
  if (-not $relCache.ContainsKey($TermId)) {
    $r = Invoke-RestWithRetry -Uri "$endpoint/datagovernance/catalog/terms/$TermId/relationships?entityType=Term" -Headers $headers
    $relCache[$TermId] = @($r.value)
  }
  return $relCache[$TermId]
}

$created = 0
$skipped = 0
foreach ($l in $links) {
  $fromId = $termByName[$l.From]
  $toId   = $termByName[$l.To]
  $existing = Get-TermRels $fromId
  $hit = $existing | Where-Object { $_.entityId -eq $toId -and $_.relationshipType -eq $l.Type }
  if ($hit) {
    Write-Host "[skip] $($l.From) -[$($l.Type)]-> $($l.To) (exists)" -ForegroundColor DarkGray
    $skipped++
    continue
  }
  $body = @{ entityId = $toId; relationshipType = $l.Type } | ConvertTo-Json
  $resp = Invoke-RestWithRetry -Method POST `
    -Uri "$endpoint/datagovernance/catalog/terms/$fromId/relationships?entityType=Term" `
    -Headers $headers -Body $body
  Write-Host "[new]  $($l.From) -[$($l.Type)]-> $($l.To)" -ForegroundColor Green
  $created++
}

Write-Host ""
Write-Host "Done. $created relationships created, $skipped already existed."
