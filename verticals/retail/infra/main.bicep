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

@description('Deployment scale: drives SKUs')
@allowed(['small', 'medium', 'large'])
param scale string = 'small'

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
// SKU mapping
// -----------------------------------------------------------------------------
var sqlSkuMap = {
  small:  { name: 'Basic',     tier: 'Basic',         capacity: 5 }
  medium: { name: 'S0',        tier: 'Standard',      capacity: 10 }
  large:  { name: 'S2',        tier: 'Standard',      capacity: 50 }
}

var storageSkuMap = {
  small:  'Standard_LRS'
  medium: 'Standard_LRS'
  large:  'Standard_ZRS'
}

// Resource names (Azure has uniqueness rules per resource type)
var suffix     = uniqueString(resourceGroup().id)
var sqlServer  = toLower('${resourcePrefix}-retail-sql-${substring(suffix, 0, 6)}')
var sqlDb      = 'contoso_retail'
var storageAcc = toLower('${resourcePrefix}rt${substring(suffix, 0, 8)}') // storage = 3-24 lowercase alphanumeric

// -----------------------------------------------------------------------------
// Storage (ADLS Gen2)
// -----------------------------------------------------------------------------
module storage 'modules/storage.bicep' = {
  name: 'storage-deploy'
  params: {
    name: storageAcc
    location: location
    sku: storageSkuMap[scale]
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
    sku: sqlSkuMap[scale]
    sqlAdminObjectId: sqlAdminObjectId
    sqlAdminLoginName: sqlAdminLoginName
    clientIpAddress: clientIpAddress
    tags: tags
  }
}

// -----------------------------------------------------------------------------
// Outputs
// -----------------------------------------------------------------------------
output sqlServerFqdn     string = sql.outputs.serverFqdn
output sqlServerName     string = sqlServer
output sqlDatabaseName   string = sqlDb
output storageAccount    string = storage.outputs.storageAccountName
output storageDfsEndpoint string = storage.outputs.dfsEndpoint
output rawContainer      string = storage.outputs.rawContainerName
output curatedContainer  string = storage.outputs.curatedContainerName
