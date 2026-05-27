# =============================================================================
# Upload + (optionally) run a Fabric notebook against a deployed environment.
#
# Why this exists:
#   During iterative development we don't want to re-run deploy.ps1 just to
#   pick up a notebook edit. This script bakes the env-specific resource
#   names into the notebook source and uploads (or updates in place) into the
#   bronze workspace, then optionally fires it off and waits for completion.
#
# Discovery:
#   Takes a resource group name and discovers everything else from Azure +
#   Fabric. Pass -WorkspaceName to override if your workspace is renamed.
#
# Examples:
#   # Upload + run the tick notebook against rg-contoso-retail17
#   .\tools\run-fabric-notebook.ps1 -ResourceGroup rg-contoso-retail17 `
#       -NotebookPath .\fabric\notebooks\10_tick_incremental_data.ipynb -Run
#
#   # Just upload (no run)
#   .\tools\run-fabric-notebook.ps1 -ResourceGroup rg-contoso-retail17 `
#       -NotebookPath .\fabric\notebooks\10_tick_incremental_data.ipynb
# =============================================================================

[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $ResourceGroup,
    [Parameter(Mandatory)] [string] $NotebookPath,
    [string] $WorkspaceName,           # auto-discovered if omitted
    [string] $NotebookName,            # defaults to file basename minus extension
    [switch] $Run,                     # if set, executes after upload and waits
    [int]    $TimeoutSeconds = 3600
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot   # tools/ -> verticals/retail/
. (Join-Path $repoRoot 'scripts' 'Fabric.ps1')

function Write-Step($m) { Write-Host "==> $m" -ForegroundColor Cyan }
function Write-Ok($m)   { Write-Host "    [OK] $m" -ForegroundColor Green }
function Write-Info($m) { Write-Host "    $m" -ForegroundColor Gray }

if (-not (Test-Path $NotebookPath)) { throw "Notebook not found: $NotebookPath" }
if (-not $NotebookName) {
    $NotebookName = [System.IO.Path]::GetFileNameWithoutExtension($NotebookPath)
}

# -----------------------------------------------------------------------------
# Discover environment from Azure
# -----------------------------------------------------------------------------
Write-Step "Discovering resources in $ResourceGroup"
$subId = az account show --query id -o tsv
if (-not $subId) { throw "az not logged in -- run 'az login' first" }
Write-Ok "Subscription: $subId"

$sqlServer = az sql server list -g $ResourceGroup --query "[0]" -o json | ConvertFrom-Json
if (-not $sqlServer) { throw "No SQL server found in $ResourceGroup" }
$sqlDb = az sql db list -g $ResourceGroup --server $sqlServer.name --query "[?name != 'master'] | [0]" -o json | ConvertFrom-Json
if (-not $sqlDb) { throw "No SQL database found on $($sqlServer.name)" }
Write-Ok "SQL: $($sqlServer.fullyQualifiedDomainName) / $($sqlDb.name)"

$storage = az storage account list -g $ResourceGroup --query "[?starts_with(name, 'contoso')] | [0]" -o json | ConvertFrom-Json
if (-not $storage) { throw "No storage account found in $ResourceGroup" }
Write-Ok "Storage: $($storage.name)"

$capacity = az resource list -g $ResourceGroup --resource-type 'Microsoft.Fabric/capacities' --query "[0]" -o json | ConvertFrom-Json
if (-not $capacity) { throw "No Fabric capacity found in $ResourceGroup" }
Write-Ok "Capacity: $($capacity.name)"

# -----------------------------------------------------------------------------
# Find the bronze workspace
# -----------------------------------------------------------------------------
$fabricToken = Get-FabricToken
if (-not $WorkspaceName) {
    # Default convention: contoso-retail-1-bronze-<suffix>; discover by capacity
    $capacityGuid = Get-FabricCapacityGuidFromArmId -Token $fabricToken -CapacityName $capacity.name
    $ws = Invoke-FabricRest -Token $fabricToken -Method GET -Path "/workspaces"
    $candidate = $ws.Body.value | Where-Object { $_.capacityId -eq $capacityGuid -and $_.displayName -like '*1-bronze*' } | Select-Object -First 1
    if (-not $candidate) { throw "Could not find a 1-bronze workspace on capacity $($capacity.name)" }
    $WorkspaceName = $candidate.displayName
}
$workspace = Get-FabricWorkspaceByName -Token $fabricToken -Name $WorkspaceName
if (-not $workspace) { throw "Workspace not found: $WorkspaceName" }
Write-Ok "Workspace: $WorkspaceName (id=$($workspace.id))"

# -----------------------------------------------------------------------------
# Bake env-specific values into the notebook source
# -----------------------------------------------------------------------------
Write-Step "Baking resource names into $NotebookName"
$src = Get-Content -Raw -Path $NotebookPath

# Map every empty-string placeholder we know about. Each table entry is
# (search pattern, replacement) -- escaped for JSON since .ipynb embeds source
# as JSON strings (so quotes are \" and we substitute against that form).
$replacements = @(
    @('sql_server_fqdn   = \"\"',              "sql_server_fqdn   = \`"$($sqlServer.fullyQualifiedDomainName)\`""),
    @('sql_database_name = \"contoso_retail\"', "sql_database_name = \`"$($sqlDb.name)\`""),
    @('subscription_id   = \"\"',              "subscription_id   = \`"$subId\`""),
    @('resource_group    = \"\"',              "resource_group    = \`"$ResourceGroup\`""),
    # The seed notebook variant -- harmless if absent
    @('storage_account   = \"\"',              "storage_account   = \`"$($storage.name)\`""),
    @('raw_container     = \"raw\"',           "raw_container     = \`"raw\`"")
)
foreach ($r in $replacements) {
    if ($src.Contains($r[0])) {
        $src = $src.Replace($r[0], $r[1])
        Write-Info "  substituted: $($r[0].Substring(0,[Math]::Min(40,$r[0].Length)))..."
    }
}

$baked = Join-Path ([System.IO.Path]::GetTempPath()) "$NotebookName.baked.$([guid]::NewGuid().ToString('N')).ipynb"
Set-Content -Path $baked -Value $src -NoNewline -Encoding utf8

# -----------------------------------------------------------------------------
# Upload (creates new or updates existing)
# -----------------------------------------------------------------------------
Write-Step "Uploading to workspace"
$nb = New-FabricNotebookFromFile `
    -Token $fabricToken `
    -WorkspaceId $workspace.id `
    -Name $NotebookName `
    -NotebookPath $baked
Remove-Item $baked -ErrorAction SilentlyContinue
Write-Ok "Notebook id=$($nb.id)"

# -----------------------------------------------------------------------------
# Optionally run it
# -----------------------------------------------------------------------------
if ($Run) {
    Write-Step "Running notebook (timeout ${TimeoutSeconds}s)"
    $result = Invoke-FabricNotebook `
        -Token $fabricToken `
        -WorkspaceId $workspace.id `
        -NotebookId $nb.id `
        -TimeoutSeconds $TimeoutSeconds `
        -PollSeconds 15
    Write-Ok "Status: $($result.status)"
    if ($result.PSObject.Properties['exitValue'] -and $result.exitValue) {
        Write-Host ""
        Write-Host "Notebook returned:" -ForegroundColor Yellow
        Write-Host $result.exitValue
    }
}
else {
    Write-Info "Skipping run -- pass -Run to execute"
}
