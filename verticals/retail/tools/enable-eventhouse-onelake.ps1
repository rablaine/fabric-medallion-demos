# =============================================================================
# Enable OneLake availability (one-logical-copy mirroring) on the Clickstream
# table in the bronze Eventhouse so the silver layer can shortcut to it as a
# Delta table. Approx ~1hr replication lag from KQL -> OneLake Delta.
#
# Docs: https://learn.microsoft.com/fabric/real-time-intelligence/one-logical-copy
# =============================================================================

[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $ResourceGroup,
    [string] $WorkspaceName,
    [string] $KqlDatabaseName = 'contoso_retail_events',
    [string] $TableName       = 'Clickstream'
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $repoRoot 'scripts' 'Fabric.ps1')

function Write-Step($m) { Write-Host "==> $m" -ForegroundColor Cyan }
function Write-Ok($m)   { Write-Host "    [OK] $m" -ForegroundColor Green }
function Write-Info($m) { Write-Host "    $m" -ForegroundColor Gray }

Write-Step "Discovering Fabric workspace from $ResourceGroup"
$capacity = az resource list -g $ResourceGroup --resource-type 'Microsoft.Fabric/capacities' --query "[0]" -o json | ConvertFrom-Json
if (-not $capacity) { throw "No Fabric capacity found in $ResourceGroup" }

$fabricToken = Get-FabricToken
if (-not $WorkspaceName) {
    $capacityGuid = Get-FabricCapacityGuidFromArmId -Token $fabricToken -CapacityName $capacity.name
    $ws = Invoke-FabricRest -Token $fabricToken -Method GET -Path "/workspaces"
    $candidate = $ws.Body.value | Where-Object { $_.capacityId -eq $capacityGuid -and $_.displayName -like '*1-bronze*' } | Select-Object -First 1
    if (-not $candidate) { throw "Could not find a 1-bronze workspace on capacity $($capacity.name)" }
    $WorkspaceName = $candidate.displayName
}
Write-Ok "Workspace: $WorkspaceName"

$wsObj = Get-FabricWorkspaceByName -Token $fabricToken -Name $WorkspaceName
if (-not $wsObj) { throw "Workspace '$WorkspaceName' not found" }

Write-Step "Finding KQL database '$KqlDatabaseName'"
$kqlList = (Invoke-FabricRest -Token $fabricToken -Method GET -Path "/workspaces/$($wsObj.id)/kqlDatabases").Body
$kqldb = $kqlList.value | Where-Object { $_.displayName -eq $KqlDatabaseName } | Select-Object -First 1
if (-not $kqldb) { throw "KQL database '$KqlDatabaseName' not found in workspace '$WorkspaceName'" }
$detail = (Invoke-FabricRest -Token $fabricToken -Method GET -Path "/workspaces/$($wsObj.id)/kqlDatabases/$($kqldb.id)").Body
$queryUri = $detail.properties.queryServiceUri
if (-not $queryUri) { throw "queryServiceUri missing on $KqlDatabaseName" }
Write-Ok "queryServiceUri: $queryUri"

Write-Step "Enabling OneLake mirroring policy on table '$TableName'"
$csl = ".alter-merge table ['$TableName'] policy mirroring dataformat=parquet with (IsEnabled=true)"
Invoke-KustoMgmt -QueryServiceUri $queryUri -DatabaseName $KqlDatabaseName -Csl $csl | Out-Null
Write-Ok "policy applied"

Write-Step "Verifying policy"
$showCsl = ".show table ['$TableName'] policy mirroring"
$r = Invoke-KustoMgmt -QueryServiceUri $queryUri -DatabaseName $KqlDatabaseName -Csl $showCsl
# v1 response: $r.Tables[0].Rows
$rows = if ($r.Tables) { $r.Tables[0].Rows } else { $r.tables[0].rows }
if ($rows) {
    foreach ($row in $rows) { Write-Info ("  " + ($row -join " | ")) }
} else {
    Write-Info "  (no policy rows returned)"
}

Write-Step "Enabling workspace-level OneLake availability on the KQL DB (UI toggle equivalent)"
# Also flip the KQL DB-level OneLake availability so the Delta tables show up
# as items shortcuttable from other workspaces. This is the same property the
# Fabric portal exposes as 'OneLake availability' on the KQL DB.
$patchBody = @{ properties = @{ oneLakeStandardStoragePeriod = 'P365D'; oneLakeCachingPeriod = 'P31D' } } | ConvertTo-Json -Depth 5
# Note: the public API surface for OneLake availability per-DB is limited; the
# table-level mirroring policy above is what actually publishes Delta to OneLake.
# This DB-level patch is best-effort; ignore failures.
try {
    Invoke-FabricRest -Token $fabricToken -Method PATCH -Path "/workspaces/$($wsObj.id)/kqlDatabases/$($kqldb.id)" -Body $patchBody | Out-Null
    Write-Ok "DB properties patched"
} catch {
    Write-Info "  (DB-level patch skipped: $_)"
}

Write-Host ""
Write-Host "Done. OneLake Delta copy of $TableName will appear under the KQL DB's OneLake folder within ~1 hour." -ForegroundColor Green
Write-Host "From silver, shortcut to: OneLake -> $WorkspaceName -> $KqlDatabaseName -> Tables -> $TableName" -ForegroundColor Green
