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
# Helpers
# -----------------------------------------------------------------------------
function Write-Step($msg)    { Write-Host "==> $msg" -ForegroundColor Cyan }
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
    @{ Suffix = '1-bronze'; Description = 'Contoso Retail - Bronze (raw ingest + sim)' }
)

$workspaces = @{}
foreach ($ws in $workspaceNames) {
    $wsName = "contoso-retail-$($ws.Suffix)-$($outputs.uniqueSuffix.value)"
    Write-Step "Creating Fabric workspace '$wsName'"
    $created = New-FabricWorkspace -Token $fabricToken -Name $wsName -CapacityId $capacityId -Description $ws.Description
    $workspaces[$ws.Suffix] = $created
    Write-Ok "  id=$($created.id)"
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

Write-Step "Running seed notebook (this populates SQL + ADLS; ~10-20 min)"
$jobResult = Invoke-FabricNotebook `
    -Token $fabricToken `
    -WorkspaceId $workspaces['1-bronze'].id `
    -NotebookId $seedNb.id `
    -TimeoutSeconds 3600 `
    -PollSeconds 20
Write-Ok "Seed notebook completed (status=$($jobResult.status))"

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
# Use the workspace identity's applicationId (GUID) as the SQL principal name
# instead of the workspace display name. AppId is globally unique in Entra, so
# this avoids "duplicate display name" collisions when a prior deployment to
# the same RG name left an orphan SP behind. SQL accepts the appId directly in
# CREATE USER ... FROM EXTERNAL PROVIDER.
$wsIdent  = $wsIdentity.applicationId
$ctSql = @"
IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name = N'$wsIdent')
    CREATE USER [$wsIdent] FROM EXTERNAL PROVIDER;
ALTER ROLE db_owner ADD MEMBER [$wsIdent];

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
# Done (checkpoint 1: bronze-only, ready for manual silver/gold build-out)
# -----------------------------------------------------------------------------
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
Write-Host "  Bronze: contoso-retail-1-bronze   (id=$($workspaces['1-bronze'].id))"
Write-Host "  (silver + gold workspaces come in the next build phase)"
Write-Host ""
Write-Host "Bronze workspace contents:" -ForegroundColor Yellow
Write-Host "  Lakehouse:        contoso_retail_bronze"
Write-Host "  Seed notebook:    00_seed_historical_data (already executed)"
Write-Host "  Mirrored DB:      contoso_retail_sql_mirror (initial snapshot in progress)"
Write-Host "  Shortcut:         Files/raw -> $($outputs.storageAccount.value)/raw"
Write-Host ""
Write-Host "Next steps:" -ForegroundColor Gray
Write-Host "  - Open https://app.fabric.microsoft.com and find 'contoso-retail-1-bronze'" -ForegroundColor Gray
Write-Host "  - Watch the Mirrored DB status; it should reach 'Running' within a minute or two" -ForegroundColor Gray
Write-Host "  - Browse the lakehouse: Tables (from mirror) and Files/raw (from shortcut)" -ForegroundColor Gray
Write-Host "  - When ready, ask the deployer to build out silver + gold + pipelines" -ForegroundColor Gray
Write-Host "  - PAUSE the Fabric capacity in the Azure portal when not in use to save cost" -ForegroundColor Gray
Write-Host ""

# Pause so the user sees the success message before the window closes.
# (Most users launch via deploy.cmd which double-clicks shut on exit otherwise.)
Read-Host "Press Enter to exit"
