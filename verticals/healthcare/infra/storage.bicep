// =============================================================================
// Contoso Healthcare - storage (ADLS Gen2) for FHIR $import / $export
// =============================================================================
// Fast, standalone deployment. deploy.ps1 runs this synchronously first so the
// seed can start uploading while the (much slower) FHIR service provisions in
// parallel from infra/fhir.bicep.
//
// The unique suffix is derived from uniqueString(resourceGroup().id) so the
// account name is deterministic and matches the name fhir.bicep computes for
// its import/export integration store (same RG -> same suffix).
// =============================================================================

targetScope = 'resourceGroup'

@description('Naming prefix for all resources. Lowercase alphanumeric, max 12 chars.')
@maxLength(12)
param resourcePrefix string = 'contoso'

@description('Azure region')
param location string = resourceGroup().location

@description('Object ID of the deploying user. Granted Storage Blob Data Contributor so deploy.ps1 can upload the seed (shared-key auth is disabled by policy).')
param deployerObjectId string

@description('Blob containers to create (FHIR import source + export sink).')
param containers array = [
  'fhirimport'
  'fhirexport'
]

@description('Common tags')
param tags object = {
  Project: 'Fabric Data Estate Builder'
  Vertical: 'healthcare'
  ManagedBy: 'Fabric Data Estate Builder'
}

var suffix             = uniqueString(resourceGroup().id)
var storageAccountName = toLower('${resourcePrefix}hl${substring(suffix, 0, 8)}') // storage = 3-24 lowercase alphanumeric

// Storage Blob Data Contributor
var storageBlobDataContributor = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'ba92f5b4-2d11-453d-a403-e96b0029c9fe')

resource storage 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: storageAccountName
  location: location
  tags: tags
  sku: {
    name: 'Standard_LRS'
  }
  kind: 'StorageV2'
  properties: {
    isHnsEnabled: true            // ADLS Gen2
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
}

resource containerResources 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-05-01' = [
  for c in containers: {
    parent: blobService
    name: c
    properties: {
      publicAccess: 'None'
    }
  }
]

// Deployer uploads the seed under its own identity (--auth-mode login).
resource deployerStorageRbac 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: storage
  name: guid(storage.id, deployerObjectId, storageBlobDataContributor)
  properties: {
    principalId: deployerObjectId
    principalType: 'User'
    roleDefinitionId: storageBlobDataContributor
  }
}

output storageAccountName string = storageAccountName
output containers array = containers
