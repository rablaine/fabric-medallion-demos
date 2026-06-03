# Sync the two semantic models (Retail Sales + HR & Workforce) against the
# already-deployed live environment. Skips the full deploy/teardown cycle.
#
# Usage (from a deployment dir that has deployment.config + scripts/Fabric.ps1
# + fabric/semantic_models/):
#   pwsh -File .\tools\sync-semantic-models.ps1
#
# What it does:
#   1. Reads deployment.config for RG.
#   2. Discovers the gold workspace (cts-rtl-3-gold-*) and the
#      contoso_retail_gold warehouse, including its SQL connection string.
#   3. Uploads (or updates in place) the Retail Sales + HR & Workforce
#      semantic models pointing at that warehouse via DirectLake.

[CmdletBinding()]
param(
    [string]$DeploymentRoot = $PSScriptRoot
)

$ErrorActionPreference = 'Stop'

if ((Split-Path -Leaf $DeploymentRoot) -eq 'tools') {
    $DeploymentRoot = Split-Path -Parent $DeploymentRoot
}

$configPath = Join-Path $DeploymentRoot 'deployment.config'
if (-not (Test-Path $configPath)) { throw "deployment.config not found at $configPath" }
$config = @{}
Get-Content $configPath | ForEach-Object {
    if ($_ -match '^([A-Z_]+)=(.+)$') { $config[$matches[1]] = $matches[2] }
}
$rg = $config['RESOURCE_GROUP']
if (-not $rg) { throw "RESOURCE_GROUP missing from deployment.config" }
Write-Host "Resource group: $rg" -ForegroundColor Cyan

. (Join-Path (Join-Path $DeploymentRoot 'scripts') 'Fabric.ps1')

# --- Fabric: discover gold workspace + warehouse --------------------------
$tok = Get-FabricToken
$ws = (Invoke-FabricRest -Token $tok -Method GET -Path '/workspaces').Body.value `
    | Where-Object { $_.displayName -like 'cts-rtl-3-gold-*' } `
    | Select-Object -First 1
if (-not $ws) { throw "No workspace matching cts-rtl-3-gold-* found" }
$goldWsId = $ws.id
Write-Host "Gold ws:        $($ws.displayName) ($goldWsId)" -ForegroundColor Cyan

$wh = (Invoke-FabricRest -Token $tok -Method GET -Path "/workspaces/$goldWsId/warehouses").Body.value `
    | Where-Object { $_.displayName -eq 'contoso_retail_gold' } | Select-Object -First 1
if (-not $wh) { throw "Warehouse 'contoso_retail_gold' not found in gold workspace" }
Write-Host "Warehouse:      $($wh.displayName) ($($wh.id))" -ForegroundColor Cyan

# The warehouse REST response carries the SQL endpoint connection string.
$whFull = (Invoke-FabricRest -Token $tok -Method GET -Path "/workspaces/$goldWsId/warehouses/$($wh.id)").Body
$sqlEndpoint = $whFull.properties.connectionString
if (-not $sqlEndpoint) {
    # Older API shape -- fall back to sqlEndpointProperties.
    $sqlEndpoint = $whFull.properties.sqlEndpointProperties.connectionString
}
if (-not $sqlEndpoint) { throw "Could not resolve warehouse SQL endpoint from API response" }
$whName = $whFull.displayName
Write-Host "SQL endpoint:   $sqlEndpoint" -ForegroundColor Cyan

$subs = @{
    '__WAREHOUSE_SQL_ENDPOINT__' = $sqlEndpoint
    '__WAREHOUSE_NAME__'         = $whName
}

# --- Push both models -----------------------------------------------------
$smRoot = Join-Path $DeploymentRoot 'fabric' 'semantic_models'

Write-Host ""
Write-Host "[1/2] Retail Sales semantic model" -ForegroundColor Yellow
$retail = New-FabricSemanticModel `
    -Token $tok -WorkspaceId $goldWsId `
    -Name 'Retail Sales' `
    -DefinitionRoot (Join-Path $smRoot 'sm_retail_sales') `
    -Replacements $subs
Write-Host "  id=$($retail.id)" -ForegroundColor Green

Write-Host ""
Write-Host "[2/2] HR & Workforce semantic model" -ForegroundColor Yellow
$hr = New-FabricSemanticModel `
    -Token $tok -WorkspaceId $goldWsId `
    -Name 'HR & Workforce' `
    -DefinitionRoot (Join-Path $smRoot 'sm_hr_workforce') `
    -Replacements $subs
Write-Host "  id=$($hr.id)" -ForegroundColor Green

Write-Host ""
Write-Host "Done. Open the gold workspace in Fabric to verify." -ForegroundColor Green
