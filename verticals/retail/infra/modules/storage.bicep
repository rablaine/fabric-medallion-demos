// =============================================================================
// ADLS Gen2 storage account with raw + curated containers
// =============================================================================

@description('Storage account name (3-24 lowercase alphanumeric)')
param name string

@description('Azure region')
param location string

@description('SKU name (Standard_LRS, Standard_ZRS, etc.)')
param sku string

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

output storageAccountName    string = storage.name
output storageAccountId      string = storage.id
output dfsEndpoint           string = storage.properties.primaryEndpoints.dfs
output rawContainerName      string = rawContainer.name
output curatedContainerName  string = curatedContainer.name
