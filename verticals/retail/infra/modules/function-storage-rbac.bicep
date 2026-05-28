// -----------------------------------------------------------------------------
// Function MSI -> storage account RBAC.
//
// Extracted into a nested module so principalId can be received as a parameter.
// Parameters are available at start-of-deployment within the nested module,
// which lets us include principalId in the guid() role-assignment name.
//
// Why bother: if the Function App's system-assigned identity is rotated (app
// deleted/recreated while the storage account survives), a deterministic
// guid(storage.id, role) name would resolve to the existing assignment that
// still points at the dead principalId. Azure would no-op the update and the
// new MI would silently have no storage access -- Functions host stuck at
// 401, no triggers register, no telemetry. Including principalId in the
// guid() forces a fresh assignment resource on rotation.
// -----------------------------------------------------------------------------
param storageAccountName string
param principalId        string

var roleBlobOwner   = 'b7e6dc6d-f1e8-4753-8033-0f276bb0955b'
var roleQueueWriter = '974c5e8b-45b9-4653-ba55-5f855dd0fb88'
var roleTableWriter = '0a9a7e1f-b9d0-4cc4-a60d-0319b160aaa3'

resource funcStorage 'Microsoft.Storage/storageAccounts@2023-05-01' existing = {
  name: storageAccountName
}

resource msiBlob 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: funcStorage
  name: guid(funcStorage.id, principalId, roleBlobOwner)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleBlobOwner)
    principalId: principalId
    principalType: 'ServicePrincipal'
  }
}

resource msiQueue 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: funcStorage
  name: guid(funcStorage.id, principalId, roleQueueWriter)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleQueueWriter)
    principalId: principalId
    principalType: 'ServicePrincipal'
  }
}

resource msiTable 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: funcStorage
  name: guid(funcStorage.id, principalId, roleTableWriter)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleTableWriter)
    principalId: principalId
    principalType: 'ServicePrincipal'
  }
}
