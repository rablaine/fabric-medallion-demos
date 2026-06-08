# Phase 10: define + run Fabric (Power BI) tenant scan. OPTIONAL phase.
# Skipped (not failed) if no Fabric source registered in Purview.
#
# Source discovery: auto-find by kind ('Fabric' or 'PowerBI'), name is irrelevant.
# Persists fabric.source.name + fabric.source.createdByUs in context.json so
# teardown knows whether to delete the source.
#
# Quirks:
#  - Scan MUST live in source's collection. API blocks others.
#  - 'workspaces' filter ignored - scan is always tenant-wide. Our retail
#    workspaces are filtered post-scan via search.
#  - Trigger uses POST /run (singular), NOT PUT /runs/{runId} (returns 500).
#  - Purview MSI must be in Fabric "service principals read-only admin APIs" group.
#    See PREREQS.md.

[CmdletBinding()]
param(
  [int]$TimeoutMinutes = 45,
  [switch]$SkipRun
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\_lib.ps1"
$ctx = Read-Context

$endpoint = $ctx.purview.endpoint
$suffix   = $ctx.collection.suffix
$scanName = "scan-fabric-retail-$suffix"

# --- Discover Fabric source by kind (any name) ---
$sources = Invoke-PurviewRest -Method GET -Url "$endpoint/scan/datasources?api-version=2022-02-01-preview"
$fabricSrc = $sources.value | Where-Object { $_.kind -in @('Fabric','PowerBI') } | Select-Object -First 1

if (-not $fabricSrc) {
  Write-Host "No Fabric/PowerBI source registered in Purview. Skipping Fabric scan." -ForegroundColor Yellow
  Write-Host "To enable: register Fabric tenant source in Purview portal (see PREREQS.md section 5)." -ForegroundColor DarkGray
  # Persist skip state so teardown knows there's nothing to clean.
  if (-not $ctx.scans.PSObject.Properties['fabric']) {
    $ctx.scans | Add-Member -NotePropertyName fabric -NotePropertyValue ([ordered]@{
      skipped = $true
    })
    ($ctx | ConvertTo-Json -Depth 10) | Set-Content "$PSScriptRoot\context.json" -Encoding UTF8
  }
  return
}

$srcName = $fabricSrc.name
$srcCollection = $fabricSrc.properties.collection.referenceName
Write-Host "Fabric source: $srcName (kind=$($fabricSrc.kind), collection=$srcCollection)"

# We never create the Fabric source ourselves (requires Fabric admin + portal flow).
# Flag it so teardown leaves it alone.
$createdByUs = $false

# --- Define scan (idempotent) ---
$existing = Invoke-PurviewRest -Method GET `
  -Url "$endpoint/scan/datasources/$srcName/scans/$scanName`?api-version=2022-02-01-preview"

if ($existing) {
  Write-Host "Scan '$scanName' already exists."
} else {
  $body = @{
    name = $scanName
    kind = 'PowerBIMsi'
    properties = @{
      includePersonalWorkspaces = $false
      collection = @{ type = 'CollectionReference'; referenceName = $srcCollection }
    }
  }
  Invoke-PurviewRest -Method PUT `
    -Url "$endpoint/scan/datasources/$srcName/scans/$scanName`?api-version=2022-02-01-preview" `
    -Body $body | Out-Null
  Write-Host "Created scan '$scanName' in collection $srcCollection"
}

# Persist scan + source info (replace any existing fabric entry so flag updates).
$fabricInfo = [ordered]@{
  source = [ordered]@{
    name        = $srcName
    kind        = $fabricSrc.kind
    createdByUs = $createdByUs
  }
  scan = [ordered]@{
    name       = $scanName
    collection = $srcCollection
  }
}
if ($ctx.scans.PSObject.Properties['fabric']) {
  $ctx.scans.PSObject.Properties.Remove('fabric')
}
$ctx.scans | Add-Member -NotePropertyName fabric -NotePropertyValue $fabricInfo
($ctx | ConvertTo-Json -Depth 10) | Set-Content "$PSScriptRoot\context.json" -Encoding UTF8

if ($SkipRun) { Write-Host "Skipping run."; return }

# --- Trigger via POST /run (singular). PUT /runs/{guid} returns 500. ---
$tok = Get-PurviewToken
$runResp = Invoke-RestWithRetry -Method POST `
  -Uri "$endpoint/scan/datasources/$srcName/scans/$scanName/run?api-version=2022-02-01-preview" `
  -Headers @{Authorization = "Bearer $tok"} `
  -ContentType 'application/json' `
  -Body '{"scanLevel":"Full"}'
$runId = $runResp.scanResultId
Write-Host "Triggered Fabric scan, runId=$runId status=$($runResp.status)"

# --- Poll. Refresh token each iteration (scan can run > token lifetime). ---
$terminal = @('Succeeded','Failed','Canceled','PartialSucceeded','TransientFailure','Quarantined','CompletedWithExceptions')
$deadline = (Get-Date).AddMinutes($TimeoutMinutes)
$last = ''
while ((Get-Date) -lt $deadline) {
  Start-Sleep 30
  $tok = Get-PurviewToken
  try {
    $r = Invoke-RestWithRetry `
      -Uri "$endpoint/scan/datasources/$srcName/scans/$scanName/runs/$runId`?api-version=2022-02-01-preview" `
      -Headers @{Authorization = "Bearer $tok"}
    if ($r.status -ne $last) {
      Write-Host "[$(Get-Date -F HH:mm:ss)] status=$($r.status) discovered=$($r.assetsDiscovered) schema=$($r.assetsSchemaParsed) err=$($r.errorMessage)"
      $last = $r.status
    }
    if ($terminal -contains $r.status) {
      Write-Host ""
      Write-Host "Final: $($r.status) discovered=$($r.assetsDiscovered) schemaParsed=$($r.assetsSchemaParsed)"
      # Verify our 3 retail workspaces ingested.
      Write-Host ""
      Write-Host "Verifying retail workspaces in catalog..."
      foreach ($ws in $ctx.retail.workspaces) {
        $sb = @{ keywords = $ws.displayName; limit = 1 } | ConvertTo-Json
        $sr = Invoke-RestWithRetry -Method POST `
          -Uri "$endpoint/datamap/api/search/query?api-version=2023-09-01" `
          -Headers @{Authorization = "Bearer $tok"} `
          -ContentType 'application/json' -Body $sb
        Write-Host "  $($ws.displayName): $($sr.'@search.count') assets"
      }
      return
    }
  } catch {
    Write-Host "poll: $($_.Exception.Message)"
  }
}
throw "Fabric scan did not reach terminal status within $TimeoutMinutes min"
