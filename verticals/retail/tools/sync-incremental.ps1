# Sync just the simulator notebook + pl_incremental_load pipeline against the
# already-deployed live environment. Skips the full deploy/teardown cycle.
#
# Usage (from the deployment dir that has deployment.config + scripts/Fabric.ps1):
#   pwsh -File .\tools\sync-incremental.ps1
#
# What it does:
#   1. Reads deployment.config to learn the RG.
#   2. Queries Azure for SQL server FQDN + sub id.
#   3. Discovers the bronze workspace (cts-rtl-1-bronze-*) + the items inside it
#      that the new sim notebook + new pl_incremental_load definition need.
#   4. Re-uploads (updateDefinition) the simulator notebook with the SQL
#      connection params baked in (same substitution pattern as deploy.ps1).
#   5. Re-uploads (updateDefinition) pl_incremental_load with the new
#      "Simulate synthetic OLTP activity" first step + mirror IDs wired in.

[CmdletBinding()]
param(
    [string]$DeploymentRoot = $PSScriptRoot
)

$ErrorActionPreference = 'Stop'

# Resolve to the deployment root (one level up if invoked from tools/).
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

# --- Azure context --------------------------------------------------------
$sub = az account show --output json | ConvertFrom-Json
if (-not $sub) { throw "az account show failed -- run 'az login'" }
Write-Host "Subscription:   $($sub.name) ($($sub.id))" -ForegroundColor Cyan

$sqlServer = az sql server list -g $rg --query "[0].fullyQualifiedDomainName" -o tsv
if (-not $sqlServer) { throw "No SQL server in resource group $rg" }
$sqlDb = az sql db list -g $rg --server ($sqlServer.Split('.')[0]) --query "[?name!='master'] | [0].name" -o tsv
if (-not $sqlDb) { throw "No user SQL database on $sqlServer" }
Write-Host "SQL server:     $sqlServer" -ForegroundColor Cyan
Write-Host "SQL database:   $sqlDb" -ForegroundColor Cyan

# --- Fabric: discover bronze workspace + items ----------------------------
$tok = Get-FabricToken
$ws  = (Invoke-FabricRest -Token $tok -Method GET -Path '/workspaces').Body.value `
    | Where-Object { $_.displayName -like 'cts-rtl-1-bronze-*' } `
    | Select-Object -First 1
if (-not $ws) { throw "No workspace matching cts-rtl-1-bronze-* found" }
Write-Host "Bronze ws:      $($ws.displayName) ($($ws.id))" -ForegroundColor Cyan
$bronzeWsId = $ws.id

# Mirror item id (needed by sim notebook poll cell)
$mirror = (Invoke-FabricRest -Token $tok -Method GET -Path "/workspaces/$bronzeWsId/mirroredDatabases").Body.value `
    | Where-Object { $_.displayName -eq 'contoso_retail_sql_mirror' } | Select-Object -First 1
if (-not $mirror) { throw "Mirror 'contoso_retail_sql_mirror' not found in bronze workspace" }
Write-Host "Mirror:         $($mirror.displayName) ($($mirror.id))" -ForegroundColor Cyan

# Pipeline ids needed to substitute into pl_incremental_load
$pipelines = (Invoke-FabricRest -Token $tok -Method GET -Path "/workspaces/$bronzeWsId/dataPipelines").Body.value
function Get-PipelineId($name) {
    $p = $pipelines | Where-Object { $_.displayName -eq $name } | Select-Object -First 1
    if (-not $p) { throw "Pipeline '$name' not found in bronze workspace" }
    return $p.id
}
$bronzeIncId = Get-PipelineId 'pl_bronze_incremental_load'
$silverIncId = Get-PipelineId 'pl_silver_incremental_load'
$goldIncId   = Get-PipelineId 'pl_gold_incremental_load'

# Pre-flight: pl_bronze_incremental_load in the repo is weather-only (matches
# what's already deployed), so we DON'T re-upload it. If you want to redeploy
# it anyway, do it manually with New-FabricDataPipelineFromFile.

# --- 1. Sim notebook ------------------------------------------------------
Write-Host ""
Write-Host "[1/2] Re-uploading 10_simulate_incremental_activity" -ForegroundColor Yellow
$simNbPath = Join-Path $DeploymentRoot 'fabric' 'notebooks' 'incremental_load' '10_simulate_incremental_activity.ipynb'
if (-not (Test-Path $simNbPath)) { throw "Sim notebook not found at $simNbPath" }

$src = Get-Content -Raw -Path $simNbPath
$subs = @{
    'sql_server_fqdn   = \"\"'             = "sql_server_fqdn   = \`"$sqlServer\`""
    'sql_database_name = \"contoso_retail\"' = "sql_database_name = \`"$sqlDb\`""
    'subscription_id   = \"\"'             = "subscription_id   = \`"$($sub.id)\`""
    'resource_group    = \"\"'             = "resource_group    = \`"$rg\`""
}
foreach ($k in $subs.Keys) { $src = $src.Replace($k, $subs[$k]) }
$tmp = Join-Path ([System.IO.Path]::GetTempPath()) "sim.baked.$([guid]::NewGuid()).ipynb"
Set-Content -Path $tmp -Value $src -NoNewline -Encoding utf8
try {
    $simNb = New-FabricNotebookFromFile -Token $tok -WorkspaceId $bronzeWsId `
        -Name '10_simulate_incremental_activity' -NotebookPath $tmp
} finally {
    Remove-Item $tmp -ErrorAction SilentlyContinue
}
Write-Host "  sim notebook id=$($simNb.id) (updated in place)" -ForegroundColor Green

# --- 2. pl_incremental_load pipeline -------------------------------------
Write-Host ""
Write-Host "[2/2] Re-uploading pl_incremental_load" -ForegroundColor Yellow
$plPath = Join-Path $DeploymentRoot 'fabric' 'pipelines' 'pl_incremental_load' 'pipeline-content.json'
if (-not (Test-Path $plPath)) { throw "Pipeline JSON not found at $plPath" }

$pl = New-FabricDataPipelineFromFile `
    -Token $tok `
    -WorkspaceId $bronzeWsId `
    -Name 'pl_incremental_load' `
    -DefinitionPath $plPath `
    -Replacements @{
        '__BRONZE_INCREMENTAL_LOAD_PIPELINE_ID__'  = $bronzeIncId
        '__SILVER_INCREMENTAL_LOAD_PIPELINE_ID__'  = $silverIncId
        '__GOLD_INCREMENTAL_LOAD_PIPELINE_ID__'    = $goldIncId
        '__SIM_NOTEBOOK_ID__'                      = $simNb.id
        '__BRONZE_WORKSPACE_ID__'                  = $bronzeWsId
        '__MIRROR_ITEM_ID__'                       = $mirror.id
    }
Write-Host "  pipeline id=$($pl.id) (updated in place)" -ForegroundColor Green

Write-Host ""
Write-Host "Done. Open pl_incremental_load in Fabric and run it to test:" -ForegroundColor Green
Write-Host "  https://app.fabric.microsoft.com/groups/$bronzeWsId/pipelines/$($pl.id)" -ForegroundColor Cyan
