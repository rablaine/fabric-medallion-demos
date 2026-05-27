// =============================================================================
// Event Hubs namespace + hub for streaming demo sources (e.g. clickstream).
// Standard SKU = 1 day default retention, AAD auth, 1 TU autoinflate to 3.
// =============================================================================

@description('Event Hubs namespace name (6-50 alphanumeric, must be globally unique)')
param namespaceName string

@description('Azure region')
param location string

@description('Hub name (the queue the Function emits into)')
param hubName string = 'clickstream'

@description('Object ID of the principal to grant Azure Event Hubs Data Sender (Function App MSI)')
param senderPrincipalId string

@description('Object ID of the deploying user, granted Data Owner so they can inspect events in the portal')
param ownerPrincipalId string

@description('Tags to apply')
param tags object = {}

resource ns 'Microsoft.EventHub/namespaces@2024-01-01' = {
  name: namespaceName
  location: location
  tags: tags
  sku: {
    name: 'Standard'
    tier: 'Standard'
    capacity: 1
  }
  properties: {
    isAutoInflateEnabled: true
    maximumThroughputUnits: 3
    minimumTlsVersion: '1.2'
    publicNetworkAccess: 'Enabled'
    disableLocalAuth: false  // keep keys available; we use AAD by default but local auth is handy for ad-hoc cli testing
  }
}

resource hub 'Microsoft.EventHub/namespaces/eventhubs@2024-01-01' = {
  parent: ns
  name: hubName
  properties: {
    messageRetentionInDays: 1
    partitionCount: 4  // matches a small Spark/Eventstream consumer; oversized for the demo emitter
    status: 'Active'
  }
}

// RBAC: Function App MSI = sender, deploying user = data owner (read in portal).
// Built-in role IDs:
//   Azure Event Hubs Data Sender  = 2b629674-e913-4c01-ae53-ef4638d8f975
//   Azure Event Hubs Data Owner   = f526a384-b230-433a-b45c-95f59c4a2dec
var roleSender = '2b629674-e913-4c01-ae53-ef4638d8f975'
var roleOwner  = 'f526a384-b230-433a-b45c-95f59c4a2dec'

resource senderAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: ns
  name: guid(ns.id, senderPrincipalId, roleSender)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleSender)
    principalId: senderPrincipalId
    principalType: 'ServicePrincipal'
  }
}

resource ownerAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: ns
  name: guid(ns.id, ownerPrincipalId, roleOwner)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleOwner)
    principalId: ownerPrincipalId
    // user principal -- omit principalType so ARM accepts either user/group
  }
}

output namespaceName string = ns.name
output namespaceFqdn  string = '${ns.name}.servicebus.windows.net'
output hubName        string = hub.name
output namespaceId    string = ns.id
