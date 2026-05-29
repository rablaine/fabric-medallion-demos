#Requires -Version 7.0
<#
.SYNOPSIS
    Deploys the Contoso Tech (Retail) data estate to Azure.

.DESCRIPTION
    Phase 1 deployment:
      1. Verifies Azure CLI auth and tooling
      2. Creates resource group
      3. Deploys Bicep (Azure SQL + ADLS Gen2 Storage)
      4. Applies schema.sql to the database

.PREREQUISITES
    - PowerShell 7+
    - Azure CLI (az) installed and authenticated (`az login`)
    - SqlServer PowerShell module (auto-installed if missing)
    - Contributor role on target subscription

.EXAMPLE
    .\deploy.ps1
#>

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'

# -----------------------------------------------------------------------------
# Tee everything to a timestamped log under logs/ so the user has a permanent
# record after the console closes (helpful for diagnosing failures).
# Start-Transcript captures Write-Host output and Read-Host prompts both.
# -----------------------------------------------------------------------------
$logDir = Join-Path $PSScriptRoot 'logs'
if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
$logPath = Join-Path $logDir ("deploy-{0}.log" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
try { Start-Transcript -Path $logPath -Append | Out-Null } catch { }
Write-Host "Logging to $logPath" -ForegroundColor DarkGray

# -----------------------------------------------------------------------------
# Helpers
# -----------------------------------------------------------------------------
# Section timing: Write-Step prints elapsed time for the PREVIOUS step before
# announcing the next one. Write-Done at the end prints the final section +
# total runtime. Avoids needing a stopwatch to see what's slow.
$script:__deployStart    = Get-Date
$script:__stepStart      = $null
$script:__stepLabel      = $null
function Write-Step($msg) {
    if ($script:__stepStart) {
        $elapsed = (Get-Date) - $script:__stepStart
        Write-Host ("    [time] {0} took {1:mm\:ss\.f}" -f $script:__stepLabel, $elapsed) -ForegroundColor DarkGray
    }
    Write-Host "==> $msg" -ForegroundColor Cyan
    $script:__stepStart = Get-Date
    $script:__stepLabel = $msg
}
function Write-Done {
    if ($script:__stepStart) {
        $elapsed = (Get-Date) - $script:__stepStart
        Write-Host ("    [time] {0} took {1:mm\:ss\.f}" -f $script:__stepLabel, $elapsed) -ForegroundColor DarkGray
    }
    $total = (Get-Date) - $script:__deployStart
    Write-Host ("    [time] TOTAL deploy runtime: {0:hh\:mm\:ss}" -f $total) -ForegroundColor Yellow
    $script:__stepStart = $null
}
function Write-Info($msg)    { Write-Host "    $msg" -ForegroundColor Gray }
function Write-Ok($msg)      { Write-Host "    [OK] $msg" -ForegroundColor Green }
function Write-Warn2($m)     { Write-Host "    [WARN] $m" -ForegroundColor Yellow }

# -----------------------------------------------------------------------------
# Banner + config
# -----------------------------------------------------------------------------
Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "  Contoso Tech (Retail) - Azure Deployment" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host ""

$configPath = Join-Path $PSScriptRoot 'deployment.config'
if (-not (Test-Path $configPath)) {
    throw "deployment.config not found at $configPath - package may be corrupt"
}

$config = @{}
Get-Content $configPath | ForEach-Object {
    if ($_ -match '^([A-Z_]+)=(.+)$') { $config[$matches[1]] = $matches[2] }
}

Write-Step "Configuration"
$config.GetEnumerator() | Sort-Object Key | ForEach-Object {
    Write-Info ("{0,-18} = {1}" -f $_.Key, $_.Value)
}

# -----------------------------------------------------------------------------
# Tooling checks
# -----------------------------------------------------------------------------
Write-Step "Verifying tooling"

if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    throw "Azure CLI (az) not found in PATH. Install from https://aka.ms/installazurecli"
}
Write-Ok "Azure CLI present"

# -----------------------------------------------------------------------------
# Azure sign-in
# -----------------------------------------------------------------------------
# Always run `az login` so the user picks the correct account+subscription
# for THIS deployment. Most users have a corporate account signed in that
# isn't valid for personal/customer Azure resources.
Write-Step "Azure sign-in"
Write-Info "A browser window will open. Sign in with the account and pick the"
Write-Info "subscription where these resources should be deployed."
Write-Host ""

az login --output none
if ($LASTEXITCODE -ne 0) { throw "az login failed" }

# Some tenants enforce CAE (Continuous Access Evaluation) on Microsoft Graph,
# which causes `az ad signed-in-user show` to fail with InteractionRequired
# even right after a fresh login -- because the local CLI token cache still
# has the stale CAE-flagged Graph token. We have to nuke the cache and
# re-login with an explicit Graph scope to get a clean Graph token.
az account get-access-token --resource https://graph.microsoft.com --output none 2>$null
$graphOk = ($LASTEXITCODE -eq 0)
if ($graphOk) {
    az ad signed-in-user show --output none 2>$null
    $graphOk = ($LASTEXITCODE -eq 0)
}
if (-not $graphOk) {
    Write-Info "Microsoft Graph token rejected by CAE. Clearing token cache and re-logging in..."
    az account clear --output none 2>$null
    az login --scope https://graph.microsoft.com/.default --output none
    if ($LASTEXITCODE -ne 0) { throw "az login (Graph scope) failed" }
}

# Whatever sub az left active after login is the one we use.
$selectedSub = az account show --output json | ConvertFrom-Json
if (-not $selectedSub) { throw "Could not read active subscription after az login" }

Write-Ok "Using account:      $($selectedSub.user.name)"
Write-Ok "Using subscription: $($selectedSub.name)"
Write-Info "Subscription ID: $($selectedSub.id)"
Write-Info "Tenant:          $($selectedSub.tenantId)"

# AAD object id of the signed-in user (becomes SQL admin)
$signedInUser = az ad signed-in-user show --output json | ConvertFrom-Json
if ($LASTEXITCODE -ne 0 -or -not $signedInUser) { throw "Failed to read signed-in user identity from Entra" }
$sqlAdminObjectId  = $signedInUser.id
$sqlAdminLoginName = $signedInUser.userPrincipalName
Write-Ok "Will grant SQL admin to: $sqlAdminLoginName"

# Public IP for firewall
try {
    $clientIp = (Invoke-RestMethod -Uri 'https://api.ipify.org?format=json').ip
    Write-Ok "Detected public IP: $clientIp"
} catch {
    throw "Could not detect public IP. Check internet connectivity."
}

# SqlServer module for applying schema
if (-not (Get-Module -ListAvailable -Name SqlServer)) {
    Write-Info "Installing SqlServer PowerShell module (CurrentUser scope)..."
    Install-Module -Name SqlServer -Scope CurrentUser -Force -AllowClobber | Out-Null
}
Import-Module SqlServer -DisableNameChecking
Write-Ok "SqlServer module loaded"

# -----------------------------------------------------------------------------
# Resource group
# -----------------------------------------------------------------------------
Write-Step "Resource Group: $($config.RESOURCE_GROUP) in $($config.LOCATION)"

$rgExistsRaw = az group exists --name $config.RESOURCE_GROUP 2>&1
if ($LASTEXITCODE -ne 0) {
    throw "Failed to check resource group existence: $rgExistsRaw"
}
$rgExists = $rgExistsRaw | ConvertFrom-Json

if ($rgExists) {
    Write-Ok "Resource group already exists"
} else {
    az group create --name $config.RESOURCE_GROUP --location $config.LOCATION --output none
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to create resource group '$($config.RESOURCE_GROUP)'. You may not have Contributor on this subscription."
    }
    Write-Ok "Resource group created"
}

# -----------------------------------------------------------------------------
# Bicep deployment
# -----------------------------------------------------------------------------
Write-Step "Deploying Bicep (this can take 3-5 minutes)"

$bicepPath = Join-Path $PSScriptRoot 'infra' 'main.bicep'
if (-not (Test-Path $bicepPath)) {
    throw "Bicep template not found at $bicepPath"
}

$deploymentName = "contoso-retail-$(Get-Date -Format 'yyyyMMddHHmmss')"

$deployJson = az deployment group create `
    --name $deploymentName `
    --resource-group $config.RESOURCE_GROUP `
    --template-file $bicepPath `
    --parameters `
        resourcePrefix=$($config.RESOURCE_PREFIX) `
        location=$($config.LOCATION) `
        sqlAdminObjectId=$sqlAdminObjectId `
        sqlAdminLoginName=$sqlAdminLoginName `
        clientIpAddress=$clientIp `
    --output json

if ($LASTEXITCODE -ne 0) {
    throw "Bicep deployment failed (exit $LASTEXITCODE)"
}

$deploy = $deployJson | ConvertFrom-Json
$outputs = $deploy.properties.outputs
Write-Ok "Bicep deployment succeeded"
Write-Info "SQL Server:       $($outputs.sqlServerFqdn.value)"
Write-Info "SQL Database:     $($outputs.sqlDatabaseName.value)"
Write-Info "Storage Acct:     $($outputs.storageAccount.value)"
Write-Info "Fabric Capacity:  $($outputs.fabricCapacityName.value)"

# -----------------------------------------------------------------------------
# Apply schema
# -----------------------------------------------------------------------------
Write-Step "Applying schema.sql to database"

$schemaPath = Join-Path $PSScriptRoot 'schema' 'schema.sql'
if (-not (Test-Path $schemaPath)) {
    throw "Schema file not found at $schemaPath"
}

# Get AAD access token for SQL
$tokenJson = az account get-access-token --resource 'https://database.windows.net/' --output json | ConvertFrom-Json
$accessToken = $tokenJson.accessToken

Invoke-Sqlcmd `
    -ServerInstance $outputs.sqlServerFqdn.value `
    -Database $outputs.sqlDatabaseName.value `
    -AccessToken $accessToken `
    -InputFile $schemaPath `
    -QueryTimeout 120 `
    -ErrorAction Stop

Write-Ok "Schema applied successfully"

# -----------------------------------------------------------------------------
# Fabric bootstrap (workspaces, lakehouses, notebooks, pipelines, seed run)
# -----------------------------------------------------------------------------
. (Join-Path $PSScriptRoot 'scripts' 'Fabric.ps1')

Write-Step "Acquiring Fabric API token"
$fabricToken = Get-FabricToken
Write-Ok "Fabric token acquired"

Write-Step "Resolving Fabric capacity GUID for '$($outputs.fabricCapacityName.value)'"
# Bicep just provisioned the capacity; Fabric tenant may take a few seconds to see it.
$capacityId = $null
for ($i = 1; $i -le 12; $i++) {
    try {
        $capacityId = Get-FabricCapacityGuidFromArmId -Token $fabricToken -CapacityName $outputs.fabricCapacityName.value
        break
    } catch {
        if ($i -eq 12) { throw }
        Write-Info "Capacity not visible yet (attempt $i/12); waiting 10s..."
        Start-Sleep -Seconds 10
    }
}
Write-Ok "Fabric capacity GUID: $capacityId"

$workspaceNames = @(
    @{ Suffix = '1-bronze'; Description = 'Contoso Retail - Bronze (raw ingest + sim)' },
    @{ Suffix = '2-silver'; Description = 'Contoso Retail - Silver (conformed/cleansed)' },
    @{ Suffix = '3-gold';   Description = 'Contoso Retail - Gold (star schema warehouse)' }
)

# Workspace naming: cts-rtl-<n>-<layer>-<suffix> keeps the layer visible in the
# Fabric workspace picker (which truncates around char 18-20).
#   cts  = contoso (brand)
#   rtl  = retail (vertical)
#   1/2/3 = bronze/silver/gold (sorts in medallion order)
#   suffix = uniqueSuffix from infra so multiple deploys can co-exist
$workspaces = @{}
# Parallel workspace creation: three independent REST POSTs that each wait on
# Fabric's async create. Running them concurrently via ThreadJob trims ~16s
# off the sequential loop. Each thread re-imports Fabric.ps1 because runspaces
# don't inherit the parent's loaded functions.
Write-Step "Creating Fabric workspaces (bronze/silver/gold in parallel)"
$wsJobs = foreach ($ws in $workspaceNames) {
    $wsName = "cts-rtl-$($ws.Suffix)-$($outputs.uniqueSuffix.value)"
    Start-ThreadJob -ScriptBlock {
        param($tok, $capId, $name, $desc, $fabricPs1)
        . $fabricPs1
        New-FabricWorkspace -Token $tok -Name $name -CapacityId $capId -Description $desc
    } -ArgumentList $fabricToken, $capacityId, $wsName, $ws.Description, (Join-Path (Join-Path $PSScriptRoot 'scripts') 'Fabric.ps1') -Name "ws-$($ws.Suffix)"
}
$wsJobs | Wait-Job | Out-Null
for ($i = 0; $i -lt $workspaceNames.Count; $i++) {
    $created = Receive-Job -Job $wsJobs[$i]
    Remove-Job -Job $wsJobs[$i]
    $workspaces[$workspaceNames[$i].Suffix] = $created
    Write-Ok "  $($workspaceNames[$i].Suffix): $($created.displayName) (id=$($created.id))"
}

Write-Step "Creating bronze lakehouse"
$bronzeLh = New-FabricLakehouse -Token $fabricToken -WorkspaceId $workspaces['1-bronze'].id -Name 'contoso_retail_bronze'
Write-Ok "  bronze lakehouse id=$($bronzeLh.id)"

# -----------------------------------------------------------------------------
# Provision workspace identity EARLY so Entra propagation happens in the
# background while the seed notebook is running (10-20 min). By the time we
# need to CREATE USER FROM EXTERNAL PROVIDER below, the SP is visible.
# -----------------------------------------------------------------------------
Write-Step "Provisioning workspace identity for the bronze workspace"
$wsIdentity = Enable-FabricWorkspaceIdentity -Token $fabricToken -WorkspaceId $workspaces['1-bronze'].id
Write-Ok "  identity appId=$($wsIdentity.applicationId)"
Write-Info "  Entra display name: $($wsIdentity.displayName) (propagating during seed run)"

# Grant the workspace identity Storage Blob Data Reader on the storage account
# so the ADLS shortcut connection can read raw/. RBAC propagation also overlaps
# the seed run.
Write-Step "Granting workspace identity 'Storage Blob Data Reader' on storage account"
$storageId = az storage account show --name $outputs.storageAccount.value --resource-group $config.RESOURCE_GROUP --query id -o tsv
if ($LASTEXITCODE -ne 0 -or -not $storageId) { throw "Failed to resolve storage account resource id" }
az role assignment create `
    --assignee-object-id $wsIdentity.servicePrincipalId `
    --assignee-principal-type ServicePrincipal `
    --role 'Storage Blob Data Reader' `
    --scope $storageId `
    --output none 2>&1 | Out-Null
# Ignore "already exists" (exit 0 on success, non-zero with RoleAssignmentExists is fine too)
Write-Ok "  role assignment requested (propagating during seed run)"

# -----------------------------------------------------------------------------
# Upload + run seed notebook (populates Azure SQL + ADLS raw)
# -----------------------------------------------------------------------------
Write-Step "Uploading seed notebook 00_seed_historical_data"
$seedNbPath = Join-Path $PSScriptRoot 'fabric' 'notebooks' '00_seed_historical_data.ipynb'

# Bake the resource names into the notebook source before upload.
# Cleaner than Fabric's RunNotebook parameter injection (which inserts an
# extra cell and is finicky). The notebook keeps empty-string defaults for
# ad-hoc interactive re-runs in the portal.
#
# .ipynb is JSON, so quotes in cell source are escaped as \". We replace the
# escaped empty-string defaults with escaped real values to keep JSON valid.
$seedNbSrc = Get-Content -Raw -Path $seedNbPath
$seedNbSrc = $seedNbSrc.Replace(
    'sql_server_fqdn   = \"\"',
    "sql_server_fqdn   = \`"$($outputs.sqlServerFqdn.value)\`""
).Replace(
    'sql_database_name = \"contoso_retail\"',
    "sql_database_name = \`"$($outputs.sqlDatabaseName.value)\`""
).Replace(
    'storage_account   = \"\"',
    "storage_account   = \`"$($outputs.storageAccount.value)\`""
).Replace(
    'raw_container     = \"raw\"',
    "raw_container     = \`"$($outputs.rawContainer.value)\`""
)
$bakedNbPath = Join-Path ([System.IO.Path]::GetTempPath()) "00_seed_historical_data.baked.$([guid]::NewGuid()).ipynb"
Set-Content -Path $bakedNbPath -Value $seedNbSrc -NoNewline -Encoding utf8

$seedNb = New-FabricNotebookFromFile `
    -Token $fabricToken `
    -WorkspaceId $workspaces['1-bronze'].id `
    -Name '00_seed_historical_data' `
    -NotebookPath $bakedNbPath
Remove-Item $bakedNbPath -ErrorAction SilentlyContinue
Write-Ok "  notebook id=$($seedNb.id)"

# Upload the simulate-incremental notebook too. It uses the same placeholder pattern as the
# seed (sql_server_fqdn / sql_database_name / subscription_id / resource_group
# start as empty strings) so we can bake values in the same way. simulate-incremental is NOT
# run as part of deploy -- it's meant to be triggered later (manually or by a
# scheduled pipeline) to fill the gap between the seed and "now".
Write-Step "Uploading simulate-incremental notebook 10_simulate_incremental_activity"
$simNbPath = Join-Path $PSScriptRoot 'fabric' 'notebooks' '10_simulate_incremental_activity.ipynb'
$simNbSrc = Get-Content -Raw -Path $simNbPath
$simNbSrc = $simNbSrc.Replace(
    'sql_server_fqdn   = \"\"',
    "sql_server_fqdn   = \`"$($outputs.sqlServerFqdn.value)\`""
).Replace(
    'sql_database_name = \"contoso_retail\"',
    "sql_database_name = \`"$($outputs.sqlDatabaseName.value)\`""
).Replace(
    'subscription_id   = \"\"',
    "subscription_id   = \`"$($selectedSub.id)\`""
).Replace(
    'resource_group    = \"\"',
    "resource_group    = \`"$($config.RESOURCE_GROUP)\`""
)
$bakedSimPath = Join-Path ([System.IO.Path]::GetTempPath()) "10_simulate_incremental_activity.baked.$([guid]::NewGuid()).ipynb"
Set-Content -Path $bakedSimPath -Value $simNbSrc -NoNewline -Encoding utf8
$simNb = New-FabricNotebookFromFile `
    -Token $fabricToken `
    -WorkspaceId $workspaces['1-bronze'].id `
    -Name '10_simulate_incremental_activity' `
    -NotebookPath $bakedSimPath
Remove-Item $bakedSimPath -ErrorAction SilentlyContinue
Write-Ok "  notebook id=$($simNb.id)"

# Upload the clickstream backfill notebook. We can't bake the KQL cluster URI
# yet because the eventhouse is created later; the bake-and-run happens below
# after the KQL DB exists. Uploading the unbaked source now keeps all notebook
# uploads in one place so the workspace looks consistent in the portal.
Write-Step "Uploading clickstream backfill notebook 01_seed_clickstream_backfill"
$cbNbPath = Join-Path $PSScriptRoot 'fabric' 'notebooks' '01_seed_clickstream_backfill.ipynb'
$cbNb = New-FabricNotebookFromFile `
    -Token $fabricToken `
    -WorkspaceId $workspaces['1-bronze'].id `
    -Name '01_seed_clickstream_backfill' `
    -NotebookPath $cbNbPath
Write-Ok "  notebook id=$($cbNb.id)"

# -----------------------------------------------------------------------------
# Real-time clickstream backbone (Eventhouse + KQL DB + Eventstream).
# Moved AHEAD of the seed run so we can fan out three independent long ops
# in parallel: seed notebook (~2:20), backfill notebook (~2:40), function
# deploy (~1:30). Without this, seed was forced to be sequential before the
# eventhouse existed, costing ~2:20 of wall-clock.
#
# CRITICAL: the destination table + ingestion mapping MUST be baked into the
# KQL database definition (DatabaseSchema.kql) at CREATION time. If we create
# the DB empty and add the table later via Kusto mgmt API, the table doesn't
# get registered in Fabric's catalog, the auto-provisioning of the Kusto pull
# data connection never fires, and the eventstream destination stays in
# "Warning" forever with 0 rows ingested. See:
# https://learn.microsoft.com/fabric/real-time-intelligence/event-streams/api-kusto-pull-destination
# -----------------------------------------------------------------------------
Write-Step "Creating Eventhouse 'contoso_retail_events_eh' for real-time clickstream"
$eventhouse = New-FabricEventhouse `
    -Token $fabricToken `
    -WorkspaceId $workspaces['1-bronze'].id `
    -Name 'contoso_retail_events_eh' `
    -Description 'Contoso retail real-time event store'
Write-Ok "  eventhouse id=$($eventhouse.id)"

Write-Step "Creating KQL database 'contoso_retail_events' (with Clickstream table + mapping baked in)"
$schemaKql = @'
.create-merge table Clickstream (
    event_id: string,
    event_ts: datetime,
    event_type: string,
    customer_id: long,
    product_id: long,
    session_id: string,
    device: string,
    channel: string,
    page_url: string
)

.create-or-alter table Clickstream ingestion json mapping 'clickstream_json_map'
```
[
    {"column":"event_id","Properties":{"Path":"$.event_id"}},
    {"column":"event_ts","Properties":{"Path":"$.event_ts"}},
    {"column":"event_type","Properties":{"Path":"$.event_type"}},
    {"column":"customer_id","Properties":{"Path":"$.customer_id"}},
    {"column":"product_id","Properties":{"Path":"$.product_id"}},
    {"column":"session_id","Properties":{"Path":"$.session_id"}},
    {"column":"device","Properties":{"Path":"$.device"}},
    {"column":"channel","Properties":{"Path":"$.channel"}},
    {"column":"page_url","Properties":{"Path":"$.page_url"}}
]
```
'@
$kqldb = New-FabricKqlDatabaseWithSchema `
    -Token $fabricToken `
    -WorkspaceId $workspaces['1-bronze'].id `
    -Name 'contoso_retail_events' `
    -EventhouseItemId $eventhouse.id `
    -SchemaKql $schemaKql `
    -Description 'Clickstream events landing zone'
$kustoUri = $kqldb.properties.queryServiceUri
if (-not $kustoUri) { throw "KQL DB queryServiceUri not returned" }
Write-Ok "  kqldb id=$($kqldb.id) uri=$kustoUri"

Write-Step "Granting workspace identity Ingestor+Viewer on KQL database"
Grant-FabricKqlDatabaseWorkspaceIdentityAccess `
    -QueryServiceUri $kustoUri `
    -DatabaseName 'contoso_retail_events' `
    -WorkspaceIdentityAppId $wsIdentity.applicationId `
    -TenantId $selectedSub.tenantId
Write-Ok "  workspace identity granted ingestor+viewer"

Write-Step "Baking Kusto cluster URI into 01_seed_clickstream_backfill and re-uploading"
$cbBaked = (Get-Content -Raw -Path $cbNbPath).Replace(
    'kusto_cluster_uri = \"\"',
    "kusto_cluster_uri = \`"$kustoUri\`""
)
$cbBakedPath = Join-Path ([System.IO.Path]::GetTempPath()) "01_seed_clickstream_backfill.baked.$([guid]::NewGuid()).ipynb"
Set-Content -Path $cbBakedPath -Value $cbBaked -NoNewline -Encoding utf8
$cbNb = New-FabricNotebookFromFile `
    -Token $fabricToken `
    -WorkspaceId $workspaces['1-bronze'].id `
    -Name '01_seed_clickstream_backfill' `
    -NotebookPath $cbBakedPath
Remove-Item $cbBakedPath -ErrorAction SilentlyContinue
Write-Ok "  baked notebook id=$($cbNb.id)"

Write-Step "Creating Eventstream 'clickstream_es' (CustomEndpoint -> Eventhouse DirectIngestion)"
$es = New-FabricEventstreamWithEventhouseDest `
    -Token $fabricToken `
    -WorkspaceId $workspaces['1-bronze'].id `
    -Name 'clickstream_es' `
    -KqlDatabaseItemId $kqldb.id `
    -TableName 'Clickstream' `
    -MappingRuleName 'clickstream_json_map' `
    -Description 'Clickstream ingestion stream'
Write-Ok "  eventstream id=$($es.eventstreamId) source=$($es.sourceName) dest=$($es.connectionName)"

Write-Step "Fetching CustomEndpoint source SAS connection string"
$eventstreamConnStr = Get-FabricEventstreamSourceConnectionString `
    -Token $fabricToken `
    -WorkspaceId $workspaces['1-bronze'].id `
    -EventstreamId $es.eventstreamId `
    -SourceId $es.sourceId
Write-Ok "  source conn string retrieved ($($eventstreamConnStr.Length) chars)"

# -----------------------------------------------------------------------------
# 3-way parallel: seed notebook || backfill notebook || function deploy.
# SQL DB is at GP_S_Gen5_8 (min 1.0) so seed has burst headroom; scale-down
# runs --no-wait AFTER seed finishes. Backfill writes into the KQL DB created
# above. Function deploy is independent of both.
# Critical path now = max(seed, backfill) + SQL mirror tail (~20s) instead of
# seed + backfill + func sequential.
# -----------------------------------------------------------------------------
$fabricPs1Path = Join-Path (Join-Path $PSScriptRoot 'scripts') 'Fabric.ps1'

Write-Step "Starting seed notebook in background"
$seedJob = Start-ThreadJob -Name 'seed-nb' -ScriptBlock {
    param($tok, $wsId, $nbId, $fabricPs1)
    . $fabricPs1
    Invoke-FabricNotebook -Token $tok -WorkspaceId $wsId -NotebookId $nbId -TimeoutSeconds 3600 -PollSeconds 20
} -ArgumentList $fabricToken, $workspaces['1-bronze'].id, $seedNb.id, $fabricPs1Path
Write-Ok "  seed job started"

Write-Step "Starting clickstream backfill notebook in background (~2M events into KQL)"
$cbJob = Start-ThreadJob -Name 'backfill-nb' -ScriptBlock {
    param($tok, $wsId, $nbId, $fabricPs1)
    . $fabricPs1
    Invoke-FabricNotebook -Token $tok -WorkspaceId $wsId -NotebookId $nbId -TimeoutSeconds 1800 -PollSeconds 20
} -ArgumentList $fabricToken, $workspaces['1-bronze'].id, $cbNb.id, $fabricPs1Path
Write-Ok "  backfill job started"

Write-Step "Starting Function App deploy in background (OneDeploy, AAD auth)"
$funcSrc  = Join-Path $PSScriptRoot 'functions\clickstream_emitter'
$funcZip  = Join-Path $env:TEMP "clickstream_emitter_$([guid]::NewGuid().ToString('N')).zip"
if (Test-Path $funcZip) { Remove-Item $funcZip -Force }
Compress-Archive -Path (Join-Path $funcSrc '*') -DestinationPath $funcZip -Force
Write-Info "  zipped -> $funcZip"

$funcAppName = $outputs.functionAppName.value
$funcJob = Start-ThreadJob -Name 'func-deploy' -ScriptBlock {
    param($funcAppName, $funcZip)
    $tok = az account get-access-token --resource https://management.azure.com --query accessToken -o tsv
    if (-not $tok) { throw "Failed to get ARM token for OneDeploy" }
    $publishUri = "https://$funcAppName.scm.azurewebsites.net/api/publish?type=zip&RemoteBuild=true&Deployer=deploy.ps1"
    $deployResp = Invoke-WebRequest -Uri $publishUri `
        -Method POST `
        -Headers @{ Authorization = "Bearer $tok" } `
        -InFile $funcZip `
        -ContentType 'application/zip' `
        -TimeoutSec 300 `
        -UseBasicParsing
    $statusUri = $deployResp.Headers.Location
    if ($statusUri -is [array]) { $statusUri = $statusUri[0] }
    if (-not $statusUri) { throw "OneDeploy did not return a Location header" }
    $deadline = (Get-Date).AddMinutes(10)
    do {
        Start-Sleep -Seconds 10
        try { $st = Invoke-RestMethod -Uri $statusUri -Headers @{ Authorization = "Bearer $tok" } -TimeoutSec 60 }
        catch { Write-Output "    poll error: $($_.Exception.Message)"; continue }
        Write-Output ("    status={0} complete={1}" -f $st.status, $st.complete)
    } while (-not $st.complete -and (Get-Date) -lt $deadline)
    if (-not $st.complete) { throw "Function deploy timed out after 10 min" }
    if ($st.status -ne 4)  { throw "Function deploy failed (status=$($st.status), see $($st.log_url))" }
    "OK"
} -ArgumentList $funcAppName, $funcZip
Write-Ok "  function deploy job started"

Write-Step "Waiting for seed notebook to finish (SQL mirror needs initial data)"
$seedJob | Wait-Job | Out-Null
$jobResult = Receive-Job -Job $seedJob
$seedState = $seedJob.State
Remove-Job -Job $seedJob
if ($seedState -ne 'Completed') { throw "Seed notebook thread job ended in state '$seedState'" }
Write-Ok "Seed notebook completed (status=$($jobResult.status))"

Write-Step "Kicking off SQL DB scale-down to idle-cheap SKU (GP_S_Gen5_4) -- fire-and-forget"
# --no-wait: Azure scales the DB asynchronously; the deploy doesn't depend on
# the new SKU being active to continue (seed already drained the burst headroom
# we needed at Gen5_8). Saves ~50s of wall-clock.
az sql db update `
    --name $outputs.sqlDatabaseName.value `
    --server $outputs.sqlServerName.value `
    --resource-group $config.RESOURCE_GROUP `
    --edition GeneralPurpose `
    --family Gen5 `
    --capacity 4 `
    --min-capacity 0.5 `
    --compute-model Serverless `
    --no-wait `
    --output none
if ($LASTEXITCODE -ne 0) { Write-Info "  (non-fatal) SQL scale-down submit failed; please scale back manually" }
else { Write-Ok "  scale-down submitted (will complete in background)" }

# -----------------------------------------------------------------------------
# SQL Mirror + ADLS Shortcut (AFTER seed so initial snapshot is meaningful)
# -----------------------------------------------------------------------------
# Refresh Fabric token in case the seed run took close to the 1h expiry
$fabricToken = Get-FabricToken

Write-Step "Granting workspace identity SQL access + enabling change tracking"
# Workspace identity AAD propagation can lag 30-60s after provisioning. Retry
# CREATE USER until Entra has propagated. db_owner is the simplest grant that
# satisfies both the initial mirror snapshot and ongoing change-tracking reads.
$sqlToken = (az account get-access-token --resource 'https://database.windows.net/' --output json | ConvertFrom-Json).accessToken
# Workspace identity SP: pass both display name (friendly) and the SP's Entra
# object id. WITH OBJECT_ID='<spOid>' tells Azure SQL to bind by Entra object
# id directly instead of doing a Graph lookup by display name. This dodges
# both (a) propagation lag (Graph lookup by name can take several minutes to
# see a brand-new SP) and (b) duplicate-display-name errors from orphan SPs
# left over from prior deployments to the same RG.
# NOTE: OBJECT_ID wants the servicePrincipalId (Entra SP objectId), NOT the
# applicationId. Fabric returns both on workspaceIdentity.
$wsName = $wsIdentity.displayName
$wsOid  = $wsIdentity.servicePrincipalId
$ctSql = @"
IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name = N'$wsName')
    CREATE USER [$wsName] FROM EXTERNAL PROVIDER WITH OBJECT_ID='$wsOid';
ALTER ROLE db_owner ADD MEMBER [$wsName];

IF NOT EXISTS (SELECT 1 FROM sys.change_tracking_databases WHERE database_id = DB_ID())
    ALTER DATABASE CURRENT SET CHANGE_TRACKING = ON (CHANGE_RETENTION = 2 DAYS, AUTO_CLEANUP = ON);

DECLARE @t sysname, @s sysname, @sql nvarchar(max);
DECLARE c CURSOR FOR
    SELECT s.name, t.name
    FROM sys.tables t JOIN sys.schemas s ON s.schema_id = t.schema_id
    WHERE s.name = 'retail'
      AND NOT EXISTS (SELECT 1 FROM sys.change_tracking_tables ct WHERE ct.object_id = t.object_id);
OPEN c; FETCH NEXT FROM c INTO @s, @t;
WHILE @@FETCH_STATUS = 0
BEGIN
    SET @sql = N'ALTER TABLE [' + @s + N'].[' + @t + N'] ENABLE CHANGE_TRACKING WITH (TRACK_COLUMNS_UPDATED = OFF);';
    EXEC sp_executesql @sql;
    FETCH NEXT FROM c INTO @s, @t;
END
CLOSE c; DEALLOCATE c;
"@

$ctDeadline = (Get-Date).AddSeconds(300)
while ($true) {
    try {
        Invoke-Sqlcmd `
            -ServerInstance $outputs.sqlServerFqdn.value `
            -Database $outputs.sqlDatabaseName.value `
            -AccessToken $sqlToken `
            -Query $ctSql `
            -QueryTimeout 180 `
            -ErrorAction Stop
        break
    } catch {
        if ($_.Exception.Message -match 'Principal .* could not be (resolved|found)|not found in the directory' -and (Get-Date) -lt $ctDeadline) {
            Write-Info "  workspace identity not yet visible in Entra; retrying in 15s..."
            Start-Sleep -Seconds 15
            continue
        }
        throw
    }
}
Write-Ok "  SQL grants applied; change tracking enabled on retail.* tables"

Write-Step "Creating Fabric SQL connection (workspace identity auth)"
$conn = New-FabricSqlConnection `
    -Token $fabricToken `
    -DisplayName "contoso_retail_sql ($($outputs.sqlServerFqdn.value))" `
    -SqlServerFqdn $outputs.sqlServerFqdn.value `
    -DatabaseName $outputs.sqlDatabaseName.value `
    -WorkspaceId $workspaces['1-bronze'].id
Write-Ok "  connection id=$($conn.id)"

# Mirror requires the Azure SQL logical server's system-assigned managed
# identity (SAMI) to have write access on the mirror item so the snapshot
# engine can push data into OneLake. UI-driven mirror creation grants this
# automatically; REST does NOT. Without this grant, tables stay "Initialized"
# forever, status="Running", no error. Adding the SAMI as a workspace
# Contributor covers all current and future mirror items in the workspace.
Write-Step "Granting Azure SQL server SAMI Contributor on bronze workspace (required for mirroring)"
$sqlSamiPid = az sql server show -g $config.RESOURCE_GROUP -n $outputs.sqlServerName.value --query identity.principalId -o tsv
if (-not $sqlSamiPid) { throw "Azure SQL server has no system-assigned managed identity" }
Add-FabricWorkspaceRoleAssignment `
    -Token $fabricToken `
    -WorkspaceId $workspaces['1-bronze'].id `
    -PrincipalId $sqlSamiPid `
    -PrincipalType 'ServicePrincipal' `
    -Role 'Contributor'
Write-Ok "  granted Contributor to SQL SAMI $sqlSamiPid"

Write-Step "Creating Mirrored Database for Azure SQL -> bronze workspace"
$mirror = New-FabricMirroredAzureSqlDatabase `
    -Token $fabricToken `
    -WorkspaceId $workspaces['1-bronze'].id `
    -Name 'contoso_retail_sql_mirror' `
    -ConnectionId $conn.id
Write-Ok "  mirrored db id=$($mirror.id) (initial snapshot starting; status updates in Fabric portal)"

Write-Step "Creating ADLS shortcut from bronze lakehouse Files/raw -> $($outputs.storageAccount.value)/raw"
$adlsConn = New-FabricAdlsGen2Connection `
    -Token $fabricToken `
    -DisplayName "contoso_retail_adls ($($outputs.storageAccount.value))" `
    -StorageAccountName $outputs.storageAccount.value `
    -WorkspaceId $workspaces['1-bronze'].id
Write-Ok "  adls connection id=$($adlsConn.id)"

$shortcut = New-FabricAdlsShortcut `
    -Token $fabricToken `
    -WorkspaceId $workspaces['1-bronze'].id `
    -LakehouseId $bronzeLh.id `
    -ShortcutName 'raw' `
    -StorageAccountName $outputs.storageAccount.value `
    -Container $outputs.rawContainer.value `
    -ConnectionId $adlsConn.id
Write-Ok "  shortcut created at Files/raw"

# -----------------------------------------------------------------------------
# Drain the backfill notebook + function deploy thread jobs that were started
# in parallel with the seed. By this point SQL mirror has been kicked off, so
# we're free to wait on the other two long ops.
# -----------------------------------------------------------------------------
Write-Step "Waiting for clickstream backfill notebook to finish"
$cbJob | Wait-Job | Out-Null
$cbResult = Receive-Job -Job $cbJob
$cbState = $cbJob.State
Remove-Job -Job $cbJob
if ($cbState -ne 'Completed') { throw "Clickstream backfill thread job ended in state '$cbState'" }
Write-Ok "  backfill notebook completed (status=$($cbResult.status))"

Write-Step "Waiting for Function App deploy job to finish"
$funcJob | Wait-Job | Out-Null
Receive-Job -Job $funcJob | ForEach-Object { Write-Info $_ }
$funcState = $funcJob.State
Remove-Job -Job $funcJob
Remove-Item $funcZip -ErrorAction SilentlyContinue
if ($funcState -ne 'Completed') { throw "Function deploy thread job ended in state '$funcState'" }
Write-Ok "  function deployed -> https://$($outputs.functionHostname.value)"

# Push the Fabric Eventstream CustomEndpoint SAS conn string into the
# Function app settings AFTER code deploy, so the runtime restart picks it
# up cleanly. Setting it before deploy works too but a second restart is
# wasteful.
Write-Step "Wiring EVENTHUB_CONNECTION_STRING into Function app settings"
az functionapp config appsettings set `
    --name $outputs.functionAppName.value `
    --resource-group $config.RESOURCE_GROUP `
    --settings "EVENTHUB_CONNECTION_STRING=$eventstreamConnStr" `
    --output none
if ($LASTEXITCODE -ne 0) { throw "Failed to set EVENTHUB_CONNECTION_STRING on $($outputs.functionAppName.value)" }
Write-Ok "  EVENTHUB_CONNECTION_STRING set (Function will restart and begin emitting)"

# Flex Consumption does NOT auto-discover triggers in a freshly-uploaded
# package after OneDeploy + restart -- the host scans wwwroot before the new
# package is mounted and ends up with zero registered functions (timer never
# fires, Clickstream stays empty). Forcing a syncfunctiontriggers makes the
# host re-scan against the just-deployed package. Without this the function
# app silently does nothing until manually kicked.
Write-Step "Syncing function triggers (Flex Consumption requires explicit sync after OneDeploy)"
$syncUri = "https://management.azure.com/subscriptions/$($selectedSub.id)/resourceGroups/$($config.RESOURCE_GROUP)/providers/Microsoft.Web/sites/$($outputs.functionAppName.value)/syncfunctiontriggers?api-version=2022-03-01"
az rest --method post --uri $syncUri --output none
if ($LASTEXITCODE -ne 0) { Write-Info "  syncfunctiontriggers returned non-zero (often benign; will retry once)"; Start-Sleep 10; az rest --method post --uri $syncUri --output none }
Write-Ok "  triggers synced"
Write-Info "  emitter fires every 30s -> Fabric Eventstream '$($es.sourceName)' -> Eventhouse 'Clickstream' table"

# -----------------------------------------------------------------------------
# Silver + Gold scaffolding (empty containers only -- notebooks/pipelines/
# shortcuts come in a later phase). Token may be close to expiry by now.
# -----------------------------------------------------------------------------
$fabricToken = Get-FabricToken

Write-Step "Creating silver lakehouse 'contoso_retail_silver_raw' (shortcut target)"
$silverRawLh = New-FabricLakehouse `
    -Token $fabricToken `
    -WorkspaceId $workspaces['2-silver'].id `
    -Name 'contoso_retail_silver_raw'
Write-Ok "  id=$($silverRawLh.id)"

Write-Step "Creating silver lakehouse 'contoso_retail_silver_curated' (notebook write target)"
$silverCuratedLh = New-FabricLakehouse `
    -Token $fabricToken `
    -WorkspaceId $workspaces['2-silver'].id `
    -Name 'contoso_retail_silver_curated'
Write-Ok "  id=$($silverCuratedLh.id)"

Write-Step "Creating gold warehouse 'contoso_retail_gold' (star schema target)"
$goldWh = New-FabricWarehouse `
    -Token $fabricToken `
    -WorkspaceId $workspaces['3-gold'].id `
    -Name 'contoso_retail_gold' `
    -Description 'Contoso Retail gold star schema (dim_* / fact_*)'
Write-Ok "  id=$($goldWh.id)"

# -----------------------------------------------------------------------------
# Done (checkpoint 1: bronze-only, ready for manual silver/gold build-out)
# -----------------------------------------------------------------------------
Write-Done
Write-Host ""
Write-Host ""
Write-Host "============================================================" -ForegroundColor Green
Write-Host "  Deployment Complete" -ForegroundColor Green
Write-Host "============================================================" -ForegroundColor Green
Write-Host ""
Write-Host "Connect to your database:" -ForegroundColor Yellow
Write-Host "  Server:   $($outputs.sqlServerFqdn.value)"
Write-Host "  Database: $($outputs.sqlDatabaseName.value)"
Write-Host "  Auth:     Microsoft Entra ID (your account)"
Write-Host ""
Write-Host "Storage account:" -ForegroundColor Yellow
Write-Host "  Account:    $($outputs.storageAccount.value)"
Write-Host "  DFS URL:    $($outputs.storageDfsEndpoint.value)"
Write-Host "  Containers: $($outputs.rawContainer.value), $($outputs.curatedContainer.value)"
Write-Host ""
Write-Host "Fabric workspaces (capacity '$($outputs.fabricCapacityName.value)'):" -ForegroundColor Yellow
Write-Host "  Bronze: $($workspaces['1-bronze'].displayName)   (id=$($workspaces['1-bronze'].id))"
Write-Host "  Silver: $($workspaces['2-silver'].displayName)   (id=$($workspaces['2-silver'].id))"
Write-Host "  Gold:   $($workspaces['3-gold'].displayName)     (id=$($workspaces['3-gold'].id))"
Write-Host ""
Write-Host "Bronze workspace contents:" -ForegroundColor Yellow
Write-Host "  Lakehouse:        contoso_retail_bronze"
Write-Host "  Seed notebook:    00_seed_historical_data (already executed)"
Write-Host "  Mirrored DB:      contoso_retail_sql_mirror (initial snapshot in progress)"
Write-Host "  Shortcut:         Files/raw -> $($outputs.storageAccount.value)/raw"
Write-Host ""
Write-Host "Silver workspace contents:" -ForegroundColor Yellow
Write-Host "  Lakehouse (raw):     contoso_retail_silver_raw      (shortcut target -- empty)"
Write-Host "  Lakehouse (curated): contoso_retail_silver_curated  (notebook write target -- empty)"
Write-Host ""
Write-Host "Gold workspace contents:" -ForegroundColor Yellow
Write-Host "  Warehouse:        contoso_retail_gold              (empty -- star schema TBD)"
Write-Host ""
Write-Host "Streaming source:" -ForegroundColor Yellow
Write-Host "  Eventhouse:       contoso_retail_events_eh"
Write-Host "  KQL DB / table:   contoso_retail_events / Clickstream"
Write-Host "  Eventstream:      clickstream_es (CustomEndpoint -> Eventhouse DirectIngestion)"
Write-Host "  Emitter:          $($outputs.functionAppName.value) (fires every 30s, ~50 events/fire)"
Write-Host ""
Write-Host "Next steps:" -ForegroundColor Gray
Write-Host "  - Open https://app.fabric.microsoft.com and find '$($workspaces['1-bronze'].displayName)'" -ForegroundColor Gray
Write-Host "  - Watch the Mirrored DB status; it should reach 'Running' within a minute or two" -ForegroundColor Gray
Write-Host "  - Browse the lakehouse: Tables (from mirror) and Files/raw (from shortcut)" -ForegroundColor Gray
Write-Host "  - When ready, ask the deployer to build out silver + gold + pipelines" -ForegroundColor Gray
Write-Host "  - PAUSE the Fabric capacity in the Azure portal when not in use to save cost" -ForegroundColor Gray
Write-Host ""

# -----------------------------------------------------------------------------
# Emit a matching teardown.ps1 with the exact resource names baked in. This
# lets the user shut everything down with one double-click and no parameters,
# and -- importantly -- only deletes the workspaces THIS deployment created,
# not every workspace pinned to the capacity.
# -----------------------------------------------------------------------------
$teardownPath = Join-Path $PSScriptRoot 'teardown.ps1'
$wsLines = ($workspaces.Values | ForEach-Object { "    @{ Id = '$($_.id)'; Name = '$($_.displayName)' }" }) -join ",`r`n"
$teardownBody = @"
# Auto-generated by deploy.ps1 on $(Get-Date -Format o)
# Tears down EXACTLY the resources this deployment created. Hard-coded so the
# user doesn't have to remember anything. Other workspaces on the capacity are
# left alone.
#Requires -Version 7.0
`$ErrorActionPreference = 'Stop'

`$logDir = Join-Path `$PSScriptRoot 'logs'
if (-not (Test-Path `$logDir)) { New-Item -ItemType Directory -Path `$logDir -Force | Out-Null }
`$logPath = Join-Path `$logDir ("teardown-{0}.log" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
try { Start-Transcript -Path `$logPath -Append | Out-Null } catch { }
Write-Host "Logging to `$logPath" -ForegroundColor DarkGray

`$ResourceGroup = '$($config.RESOURCE_GROUP)'
`$Subscription  = '$($selectedSub.id)'
`$TenantId      = '$($selectedSub.tenantId)'
`$CapacityName  = '$($outputs.fabricCapacityName.value)'
`$Workspaces = @(
$wsLines
)

. (Join-Path `$PSScriptRoot 'scripts\Fabric.ps1')

# -----------------------------------------------------------------------------
# Tenant / subscription verification + existence preflight.
# Teardown is destructive and silent failures ("nothing to delete") are bad --
# if the user is signed into the wrong tenant we want to STOP and offer to
# re-auth, not pretend the deletion succeeded.
# -----------------------------------------------------------------------------
function Get-AzContext {
    try { az account show -o json 2>`$null | ConvertFrom-Json } catch { `$null }
}
function Test-FabricWorkspace {
    param(`$Token, `$Id)
    try { Invoke-FabricRest -Token `$Token -Method GET -Path "/workspaces/`$Id" | Out-Null; `$true } catch { `$false }
}
function Invoke-Preflight {
    `$ctx = Get-AzContext
    if (-not `$ctx) { return [pscustomobject]@{ Ok=`$false; Reason='not-logged-in'; Ctx=`$null; RgExists=`$false; WsExists=`$false } }
    `$rgExists = (az group exists --subscription `$ctx.id --name `$ResourceGroup) -eq 'true'
    `$wsExists = `$false
    try {
        `$fabTok = az account get-access-token --resource https://api.fabric.microsoft.com --query accessToken -o tsv 2>`$null
        if (`$fabTok -and `$Workspaces.Count -gt 0) {
            `$wsExists = Test-FabricWorkspace -Token `$fabTok -Id `$Workspaces[0].Id
        }
    } catch { }
    `$tenantOk = (`$ctx.tenantId -eq `$TenantId)
    `$subOk    = (`$ctx.id       -eq `$Subscription)
    `$ok = `$tenantOk -and `$subOk -and (`$rgExists -or `$wsExists)
    [pscustomobject]@{ Ok=`$ok; Reason=''; Ctx=`$ctx; TenantOk=`$tenantOk; SubOk=`$subOk; RgExists=`$rgExists; WsExists=`$wsExists }
}

`$pre = Invoke-Preflight
if (-not `$pre.Ok) {
    Write-Host ''
    Write-Host 'Preflight check FAILED -- not safe to proceed.' -ForegroundColor Red
    Write-Host ''
    Write-Host 'Expected:' -ForegroundColor Yellow
    Write-Host "  Tenant:       `$TenantId"
    Write-Host "  Subscription: `$Subscription"
    Write-Host "  ResourceGrp:  `$ResourceGroup"
    Write-Host ''
    if (`$pre.Ctx) {
        Write-Host 'Currently signed in as:' -ForegroundColor Yellow
        Write-Host "  User:         `$(`$pre.Ctx.user.name)"
        Write-Host "  Tenant:       `$(`$pre.Ctx.tenantId)"
        Write-Host "  Subscription: `$(`$pre.Ctx.id) (`$(`$pre.Ctx.name))"
        Write-Host ''
        Write-Host 'Status:' -ForegroundColor Yellow
        Write-Host ("  Tenant match:           {0}" -f `$(if (`$pre.TenantOk) {'yes'} else {'NO'}))
        Write-Host ("  Subscription match:     {0}" -f `$(if (`$pre.SubOk)    {'yes'} else {'NO'}))
        Write-Host ("  Resource group exists:  {0}" -f `$(if (`$pre.RgExists) {'yes'} else {'NO'}))
        Write-Host ("  Fabric workspace found: {0}" -f `$(if (`$pre.WsExists) {'yes'} else {'NO'}))
    } else {
        Write-Host 'Not signed in to Azure CLI.' -ForegroundColor Yellow
    }
    Write-Host ''
    Write-Host 'This usually means you are signed into the wrong tenant or subscription,'
    Write-Host 'or the deployment was already torn down.'
    Write-Host ''
    `$run = Read-Host "Run 'az login --tenant `$TenantId' now? [y/N]"
    if (`$run -match '^(y|yes)`$') {
        az logout 2>`$null | Out-Null
        az login --tenant `$TenantId | Out-Null
        if (`$LASTEXITCODE -ne 0) { Write-Host 'az login failed. Aborting.' -ForegroundColor Red; exit 1 }
        az account set --subscription `$Subscription | Out-Null
        if (`$LASTEXITCODE -ne 0) {
            Write-Host "Could not set subscription `$Subscription. Available subscriptions in this tenant:" -ForegroundColor Red
            az account list --query "[?tenantId=='`$TenantId'].{name:name,id:id}" -o table
            exit 1
        }
        `$pre = Invoke-Preflight
        if (-not `$pre.Ok) {
            Write-Host ''
            Write-Host 'Preflight still failing after re-auth. Nothing to delete (or wrong account). Aborting.' -ForegroundColor Red
            if (`$pre.Ctx) { Write-Host "  signed in as `$(`$pre.Ctx.user.name) / tenant=`$(`$pre.Ctx.tenantId) / sub=`$(`$pre.Ctx.id)" }
            Write-Host "  RG exists=`$(`$pre.RgExists)  Workspace exists=`$(`$pre.WsExists)"
            exit 1
        }
        Write-Host 'Re-auth succeeded; preflight passed.' -ForegroundColor Green
    } else {
        Write-Host 'Aborting.' -ForegroundColor Yellow; exit 1
    }
}

Write-Host ''
Write-Host 'About to PERMANENTLY DELETE:' -ForegroundColor Yellow
Write-Host "  Signed in as:   `$(`$pre.Ctx.user.name)"
Write-Host "  Tenant:         `$TenantId"
Write-Host "  Subscription:   `$Subscription (`$(`$pre.Ctx.name))"
Write-Host "  Resource group: `$ResourceGroup"
Write-Host "  Capacity:       `$CapacityName"
Write-Host '  Fabric workspaces:'
foreach (`$w in `$Workspaces) { Write-Host "    - `$(`$w.Name) (`$(`$w.Id))" }
Write-Host ''
`$ans = Read-Host 'Type YES to proceed'
if (`$ans -ne 'YES') { Write-Host 'Cancelled.'; exit 0 }

az account set --subscription `$Subscription | Out-Null

Write-Host 'Deleting Fabric workspaces...' -ForegroundColor Cyan
`$fabToken = (az account get-access-token --resource https://api.fabric.microsoft.com --query accessToken -o tsv)
foreach (`$w in `$Workspaces) {
    try {
        Invoke-FabricRest -Token `$fabToken -Method DELETE -Path "/workspaces/`$(`$w.Id)" | Out-Null
        Write-Host "  deleted `$(`$w.Name)" -ForegroundColor Green
    } catch {
        Write-Host "  skip `$(`$w.Name): `$_" -ForegroundColor DarkYellow
    }
}

Write-Host 'Deleting resource group (async)...' -ForegroundColor Cyan
az group delete --name `$ResourceGroup --yes --no-wait

Write-Host ''
Write-Host 'Teardown initiated. Resource group deletion runs in the background.' -ForegroundColor Green
Read-Host 'Press Enter to exit'
"@
Set-Content -Path $teardownPath -Value $teardownBody -Encoding UTF8

# Matching .cmd launcher so the user can double-click without thinking about pwsh.
$teardownCmdPath = Join-Path $PSScriptRoot 'teardown.cmd'
$teardownCmdBody = @"
@echo off
REM Launcher: invokes pwsh 7 via -Command (NOT -File) so stdin/Read-Host work.
REM Double-click this OR run ``teardown.cmd`` from any shell.
pwsh -NoLogo -NoProfile -ExecutionPolicy Bypass -Command "& '%~dp0teardown.ps1'"
if errorlevel 1 (
    echo.
    echo Teardown failed. Press any key to close.
    pause >nul
)
"@
Set-Content -Path $teardownCmdPath -Value $teardownCmdBody -Encoding ASCII
Write-Host "Generated teardown.ps1 + teardown.cmd next to deploy.ps1 -- double-click teardown.cmd when ready to clean up." -ForegroundColor Cyan
Write-Host ""

# Pause so the user sees the success message before the window closes.
# (Most users launch via deploy.cmd which double-clicks shut on exit otherwise.)
Read-Host "Press Enter to exit"
