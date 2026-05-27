// =============================================================================
// Azure SQL Server + Database with AAD-only auth
// =============================================================================

@description('Logical SQL server name (lowercase, globally unique)')
param serverName string

@description('Database name')
param databaseName string

@description('Azure region')
param location string

@description('SKU object {name, tier, family, capacity}')
param sku object

@description('Max database storage in GB')
param maxSizeGb int

@description('Auto-pause delay in minutes. -1 disables auto-pause. Default 60.')
param autoPauseDelay int = 60

@description('Object ID of AAD principal granted SQL admin')
param sqlAdminObjectId string

@description('Login name (display) of the AAD admin')
param sqlAdminLoginName string

@description('Client public IP allowed through firewall')
param clientIpAddress string

@description('Tags')
param tags object

resource sqlServer 'Microsoft.Sql/servers@2023-08-01-preview' = {
  name: serverName
  location: location
  tags: tags
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    version: '12.0'
    minimalTlsVersion: '1.2'
    publicNetworkAccess: 'Enabled'
    // AAD-only authentication - no SQL logins
    administrators: {
      administratorType: 'ActiveDirectory'
      principalType: 'User'
      login: sqlAdminLoginName
      sid: sqlAdminObjectId
      tenantId: subscription().tenantId
      azureADOnlyAuthentication: true
    }
  }
}

resource database 'Microsoft.Sql/servers/databases@2023-08-01-preview' = {
  parent: sqlServer
  name: databaseName
  location: location
  tags: tags
  sku: sku
  properties: {
    collation: 'SQL_Latin1_General_CP1_CI_AS'
    zoneRedundant: false
    maxSizeBytes: maxSizeGb * 1024 * 1024 * 1024
    autoPauseDelay: autoPauseDelay
    minCapacity: json('1.0')  // Gen5_8 requires min >= 1.0; deploy.ps1 lowers to 0.5 when it scales the DB down to Gen5_4 post-seed. Bicep has no decimal type; json() smuggles the value through to ARM.
  }
}

// Allow Azure services (Fabric, ADF, etc.) - 0.0.0.0 is a special rule meaning "Azure services"
resource allowAzureServices 'Microsoft.Sql/servers/firewallRules@2023-08-01-preview' = {
  parent: sqlServer
  name: 'AllowAllAzureServices'
  properties: {
    startIpAddress: '0.0.0.0'
    endIpAddress: '0.0.0.0'
  }
}

// Allow the deployer's IP so they can connect with SSMS / Azure Data Studio / sqlcmd
resource allowClientIp 'Microsoft.Sql/servers/firewallRules@2023-08-01-preview' = {
  parent: sqlServer
  name: 'AllowDeployerClient'
  properties: {
    startIpAddress: clientIpAddress
    endIpAddress: clientIpAddress
  }
}

output serverFqdn string = sqlServer.properties.fullyQualifiedDomainName
output serverId   string = sqlServer.id
output databaseId string = database.id
