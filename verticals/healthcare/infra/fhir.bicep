// =============================================================================
// Contoso Healthcare - Azure Health Data Services workspace + FHIR R4 service
// =============================================================================
// This is the long pole of the deploy (~6 min). deploy.ps1 launches it with
// --no-wait so the seed upload (against the storage account from storage.bicep)
// runs in parallel while the FHIR service provisions.
//
// import/export config and the AAD authentication config are baked into the
// service resource at create time, so there is no separate post-create
// "az resource update" step (that step previously cost ~3 min on its own).
//
// The unique suffix is derived from uniqueString(resourceGroup().id), matching
// storage.bicep so the integration data store name lines up (same RG).
// =============================================================================

targetScope = 'resourceGroup'

@description('Naming prefix for all resources. Lowercase alphanumeric, max 12 chars.')
@maxLength(12)
param resourcePrefix string = 'contoso'

@description('Azure region (AHDS is region-limited; southcentralus is validated).')
param location string = resourceGroup().location

@description('Object ID of the deploying user. Granted FHIR Data Contributor so deploy.ps1 can run $import / $export.')
param deployerObjectId string

@description('FHIR service (child) name. Forms the host: <workspace>-<service>.fhir.azurehealthcareapis.com')
param fhirServiceName string = 'fhirr4'

@description('Common tags')
param tags object = {
  Project: 'Fabric Data Estate Builder'
  Vertical: 'healthcare'
  ManagedBy: 'Fabric Data Estate Builder'
}

var suffix             = uniqueString(resourceGroup().id)
var workspaceName      = toLower('${resourcePrefix}hls${substring(suffix, 0, 8)}') // workspace = alphanumeric only
var storageAccountName = toLower('${resourcePrefix}hl${substring(suffix, 0, 8)}')  // must match storage.bicep
var fhirUrl            = 'https://${workspaceName}-${fhirServiceName}.fhir.azurehealthcareapis.com'

// FHIR Data Contributor / Storage Blob Data Contributor
var fhirDataContributor        = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '5a1fc7df-4bf1-4951-a576-89034ee01acd')
var storageBlobDataContributor = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'ba92f5b4-2d11-453d-a403-e96b0029c9fe')

// Provisioned first by storage.bicep; the FHIR MSI needs blob access to it.
resource storage 'Microsoft.Storage/storageAccounts@2023-05-01' existing = {
  name: storageAccountName
}

resource workspace 'Microsoft.HealthcareApis/workspaces@2024-03-31' = {
  name: workspaceName
  location: location
  tags: tags
}

resource fhir 'Microsoft.HealthcareApis/workspaces/fhirservices@2024-03-31' = {
  parent: workspace
  name: fhirServiceName
  location: location
  kind: 'fhir-R4'
  tags: tags
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    authenticationConfiguration: {
      authority: '${environment().authentication.loginEndpoint}${tenant().tenantId}'
      audience: fhirUrl
      smartProxyEnabled: false
    }
    importConfiguration: {
      enabled: true
      initialImportMode: false
      integrationDataStore: storageAccountName
    }
    exportConfiguration: {
      storageAccountName: storageAccountName
    }
  }
}

// Deployer kicks off $import / $export (data plane).
resource deployerFhirRbac 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: fhir
  name: guid(fhir.id, deployerObjectId, fhirDataContributor)
  properties: {
    principalId: deployerObjectId
    principalType: 'User'
    roleDefinitionId: fhirDataContributor
  }
}

// FHIR managed identity reads import blobs / writes export blobs.
resource fhirStorageRbac 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: storage
  name: guid(storage.id, fhir.id, storageBlobDataContributor)
  properties: {
    principalId: fhir.identity.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: storageBlobDataContributor
  }
}

output fhirServiceUrl  string = fhirUrl
output workspaceName   string = workspaceName
output fhirServiceName string = fhirServiceName
output fhirPrincipalId string = fhir.identity.principalId
output storageAccountName string = storageAccountName
