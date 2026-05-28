// =============================================================================
// Contoso Tech - Retail Vertical (Phase 1: SQL + Storage)
// =============================================================================
// First deploy scope:
//   - Azure SQL Server + Database
//   - Storage account (ADLS Gen2) with raw + curated containers
//
// Coming later: Cosmos DB, Event Hub, Fabric workspace, Purview, Key Vault
// =============================================================================

targetScope = 'resourceGroup'

@description('Naming prefix for all resources. Lowercase alphanumeric, max 12 chars.')
@maxLength(12)
param resourcePrefix string = 'contoso'

@description('Azure region')
param location string = resourceGroup().location

@description('Object ID of the AAD principal to grant SQL admin (your user)')
param sqlAdminObjectId string

@description('Display name of the AAD principal for SQL admin')
param sqlAdminLoginName string

@description('Client IP to allow through SQL firewall (your public IP)')
param clientIpAddress string

@description('Common tags')
param tags object = {
  Project: 'Contoso Data Estate'
  Vertical: 'retail'
  ManagedBy: 'Contoso Data Estate Builder'
}

// -----------------------------------------------------------------------------
// Fixed SKUs
// -----------------------------------------------------------------------------
// Azure SQL: Serverless General Purpose Gen5, 4 vCore. Auto-pauses after
// 60 min idle so the DB costs only ~$0.12/GB/mo of storage when nobody is
// using it. Cold-start from paused: ~30-60s on the first query.
// 4 vCore gives headroom to load a fiscal quarter of seed data in minutes
// and run the bronze/silver/gold notebooks against it without throttling.
// Deploy at Gen5_8 so the seed notebook has the throughput it needs out of
// the gate; deploy.ps1 scales down to Gen5_4 (min 0.5) once the seed completes.
var sqlSku       = { name: 'GP_S_Gen5_8', tier: 'GeneralPurpose', family: 'Gen5', capacity: 8 }
var sqlMaxSizeGb = 128
var storageSku   = 'Standard_LRS'

// Resource names (Azure has uniqueness rules per resource type)
var suffix         = uniqueString(resourceGroup().id)
var sqlServer      = toLower('${resourcePrefix}-retail-sql-${substring(suffix, 0, 6)}')
var sqlDb          = 'contoso_retail'
var storageAcc     = toLower('${resourcePrefix}rt${substring(suffix, 0, 8)}') // storage = 3-24 lowercase alphanumeric
var fabricCapacity = toLower('${resourcePrefix}retail${substring(suffix, 0, 8)}') // capacity name = lowercase alnum, globally unique in Fabric tenant
var funcAppName    = toLower('${resourcePrefix}-retail-emit-${substring(suffix, 0, 6)}') // *.azurewebsites.net global unique
var funcStorageAcc = toLower('${resourcePrefix}rtfn${substring(suffix, 0, 8)}')          // dedicated storage for the Function runtime
var funcPlanName   = toLower('${resourcePrefix}-retail-funcplan-${substring(suffix, 0, 6)}')
var funcAiName     = toLower('${resourcePrefix}-retail-funcai-${substring(suffix, 0, 6)}')

// -----------------------------------------------------------------------------
// Storage (ADLS Gen2)
// -----------------------------------------------------------------------------
module storage 'modules/storage.bicep' = {
  name: 'storage-deploy'
  params: {
    name: storageAcc
    location: location
    sku: storageSku
    dataContributorObjectId: sqlAdminObjectId
    tags: tags
  }
}

// -----------------------------------------------------------------------------
// Azure SQL
// -----------------------------------------------------------------------------
module sql 'modules/sql.bicep' = {
  name: 'sql-deploy'
  params: {
    serverName: sqlServer
    databaseName: sqlDb
    location: location
    sku: sqlSku
    maxSizeGb: sqlMaxSizeGb
    sqlAdminObjectId: sqlAdminObjectId
    sqlAdminLoginName: sqlAdminLoginName
    clientIpAddress: clientIpAddress
    tags: tags
  }
}

// -----------------------------------------------------------------------------
// Fabric F2 capacity
// -----------------------------------------------------------------------------
module fabric 'modules/fabric.bicep' = {
  name: 'fabric-deploy'
  params: {
    name: fabricCapacity
    location: location
    adminUserPrincipalName: sqlAdminLoginName
    tags: tags
  }
}

// -----------------------------------------------------------------------------
// Function App (clickstream emitter, Linux Flex Consumption)
// Pushes events into a Fabric Eventstream CustomEndpoint source. The
// EVENTHUB_CONNECTION_STRING app setting is populated by deploy.ps1 after
// the Eventstream is created (no Azure Event Hub namespace exists).
// -----------------------------------------------------------------------------
module funcApp 'modules/function.bicep' = {
  name: 'func-deploy'
  params: {
    appName: funcAppName
    storageAccountName: funcStorageAcc
    appInsightsName: funcAiName
    planName: funcPlanName
    location: location
    // Same principal that admins SQL also owns the Function -- gets Website
    // Contributor so deploy.ps1 can push code via Kudu /api/zipdeploy.
    deployerObjectId: sqlAdminObjectId
    tags: tags
  }
}

// -----------------------------------------------------------------------------
// Outputs
// -----------------------------------------------------------------------------
output sqlServerFqdn      string = sql.outputs.serverFqdn
output sqlServerName      string = sqlServer
output sqlDatabaseName    string = sqlDb
output storageAccount     string = storage.outputs.storageAccountName
output storageDfsEndpoint string = storage.outputs.dfsEndpoint
output rawContainer       string = storage.outputs.rawContainerName
output curatedContainer   string = storage.outputs.curatedContainerName
output fabricCapacityId   string = fabric.outputs.capacityId
output fabricCapacityName string = fabric.outputs.capacityName
output uniqueSuffix       string = substring(suffix, 0, 8)
output functionAppName    string = funcApp.outputs.appName
output functionHostname   string = funcApp.outputs.defaultHostname
