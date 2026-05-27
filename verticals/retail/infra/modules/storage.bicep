// =============================================================================
// ADLS Gen2 storage account with raw + curated containers
// =============================================================================

@description('Storage account name (3-24 lowercase alphanumeric)')
param name string

@description('Azure region')
param location string

@description('SKU name (Standard_LRS, Standard_ZRS, etc.)')
param sku string

@description('Object ID of the principal to grant Storage Blob Data Contributor (the deploying user, so notebooks running on their behalf can read/write ADLS)')
param dataContributorObjectId string

@description('Tags')
param tags object

resource storage 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: name
  location: location
  tags: tags
  sku: {
    name: sku
  }
  kind: 'StorageV2'
  properties: {
    isHnsEnabled: true            // Hierarchical namespace = ADLS Gen2
    minimumTlsVersion: 'TLS1_2'
    allowBlobPublicAccess: false
    supportsHttpsTrafficOnly: true
    accessTier: 'Hot'
    networkAcls: {
      defaultAction: 'Allow'
      bypass: 'AzureServices'
    }
  }
}

resource blobService 'Microsoft.Storage/storageAccounts/blobServices@2023-05-01' = {
  parent: storage
  name: 'default'
  properties: {
    deleteRetentionPolicy: {
      enabled: true
      days: 7
    }
  }
}

resource rawContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-05-01' = {
  parent: blobService
  name: 'raw'
  properties: {
    publicAccess: 'None'
  }
}

resource curatedContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-05-01' = {
  parent: blobService
  name: 'curated'
  properties: {
    publicAccess: 'None'
  }
}

// -----------------------------------------------------------------------------
// RBAC: grant the deploying user "Storage Blob Data Contributor" on the
// account. The Fabric seeding notebook runs under the user's delegated
// identity, so it inherits this grant to write CSV + Parquet files.
// Role ID: ba92f5b4-2d11-453d-a403-e96b0029c9fe
// -----------------------------------------------------------------------------
resource blobDataContributorRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: storage
  name: guid(storage.id, dataContributorObjectId, 'ba92f5b4-2d11-453d-a403-e96b0029c9fe')
  properties: {
    principalId: dataContributorObjectId
    principalType: 'User'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'ba92f5b4-2d11-453d-a403-e96b0029c9fe')
  }
}

output storageAccountName    string = storage.name
output storageAccountId      string = storage.id
output dfsEndpoint           string = storage.properties.primaryEndpoints.dfs
output rawContainerName      string = rawContainer.name
output curatedContainerName  string = curatedContainer.name
