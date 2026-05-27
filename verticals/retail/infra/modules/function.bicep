// =============================================================================
// Azure Function App on Linux Consumption (Y1) -- Python 3.11 timer-triggered
// emitter that pushes synthetic clickstream events into Event Hubs.
//
// Includes everything Functions requires:
//   - Storage account (function host metadata + AzureWebJobsStorage)
//   - App Insights (logs, exception tracking)
//   - Linux Consumption serverFarm
//   - Function App with system-assigned MSI (used to auth to Event Hub)
// =============================================================================

@description('Function App name (3-60 chars, globally unique within *.azurewebsites.net)')
param appName string

@description('Storage account name dedicated to the Function (3-24 lowercase alphanumeric, globally unique). Functions runtime requires its own.')
param storageAccountName string

@description('Application Insights resource name')
param appInsightsName string

@description('Consumption plan (serverFarm) name')
param planName string

@description('Azure region')
param location string

@description('Event Hubs namespace FQDN (e.g. contoso-eh-abc.servicebus.windows.net) -- passed to the function via app setting')
param eventHubNamespaceFqdn string

@description('Event Hub name (the hub to emit into)')
param eventHubName string

@description('Timer schedule (NCRONTAB). Default fires every 30 seconds.')
param timerSchedule string = '*/30 * * * * *'

@description('Number of synthetic clickstream events to emit per timer fire')
param eventsPerFire int = 50

@description('Object ID of the deploying user -- granted Website Contributor on the Function App so they can call the Kudu zipdeploy REST endpoint with their AAD token (we cannot use storage keys, so az CLI zip-deploy is not an option).')
param deployerObjectId string

@description('Tags to apply')
param tags object = {}

// -----------------------------------------------------------------------------
// Storage account (Functions runtime requirement -- separate from data lake)
// AAD-only: tenant policy forbids shared-key auth. Functions runtime + zip
// deploy + WEBSITES_RUN_FROM_PACKAGE all use the Function App MSI instead.
// -----------------------------------------------------------------------------
resource funcStorage 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: storageAccountName
  location: location
  tags: tags
  sku: { name: 'Standard_LRS' }
  kind: 'StorageV2'
  properties: {
    minimumTlsVersion: 'TLS1_2'
    allowBlobPublicAccess: false
    allowSharedKeyAccess: false      // hard-disable account keys (tenant policy)
    defaultToOAuthAuthentication: true
    supportsHttpsTrafficOnly: true
  }
}

// Linux Consumption + identity-based AzureWebJobsStorage requires a writable
// container that Kudu uploads the built squashfs to (the URL is then read
// back by the runtime via WEBSITE_RUN_FROM_PACKAGE). Without this container
// pre-created, Kudu fails with 'Malformed SCM_RUN_FROM_PACKAGE'.
resource scmBlobService 'Microsoft.Storage/storageAccounts/blobServices@2023-05-01' = {
  parent: funcStorage
  name: 'default'
}
resource scmReleases 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-05-01' = {
  parent: scmBlobService
  name: 'scm-releases'
  properties: {
    publicAccess: 'None'
  }
}

// -----------------------------------------------------------------------------
// Application Insights (with workspace-based -- requires a Log Analytics ws)
// For simplicity here we use the classic (non-workspace) ApplicationInsights.
// Microsoft is sunsetting classic but it's still fully supported & is the
// simplest one-resource deploy.
// -----------------------------------------------------------------------------
resource appInsights 'Microsoft.Insights/components@2020-02-02' = {
  name: appInsightsName
  location: location
  tags: tags
  kind: 'web'
  properties: {
    Application_Type: 'web'
    Request_Source: 'rest'
  }
}

// -----------------------------------------------------------------------------
// Linux Consumption (Y1) plan
// -----------------------------------------------------------------------------
resource plan 'Microsoft.Web/serverfarms@2024-04-01' = {
  name: planName
  location: location
  tags: tags
  sku: {
    name: 'Y1'
    tier: 'Dynamic'
  }
  kind: 'functionapp,linux'
  properties: {
    reserved: true  // required for Linux
  }
}

// -----------------------------------------------------------------------------
// Function App
// -----------------------------------------------------------------------------
resource funcApp 'Microsoft.Web/sites@2024-04-01' = {
  name: appName
  location: location
  tags: tags
  kind: 'functionapp,linux'
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    serverFarmId: plan.id
    httpsOnly: true
    siteConfig: {
      linuxFxVersion: 'Python|3.11'
      ftpsState: 'Disabled'
      minTlsVersion: '1.2'
      appSettings: [
        // Functions runtime -- IDENTITY-BASED storage (no account keys).
        // The '__accountName' suffix tells the Functions host to authenticate
        // with its own MSI via DefaultAzureCredential. Requires the MSI to
        // hold Blob/Queue/Table Data roles on the storage account (assigned
        // below). Setting plain 'AzureWebJobsStorage' to a key-based string
        // would fail tenant policy.
        // Linux Consumption does NOT use a content file share, so the
        // WEBSITE_CONTENTAZUREFILECONNECTIONSTRING + WEBSITE_CONTENTSHARE
        // pair (required on Windows Consumption / Premium) must be OMITTED.
        { name: 'AzureWebJobsStorage__accountName', value: funcStorage.name }
        { name: 'AzureWebJobsStorage__credential',  value: 'managedidentity' }
        { name: 'FUNCTIONS_EXTENSION_VERSION',      value: '~4' }
        { name: 'FUNCTIONS_WORKER_RUNTIME',         value: 'python' }
        { name: 'APPLICATIONINSIGHTS_CONNECTION_STRING', value: appInsights.properties.ConnectionString }

        // Emitter wiring -- read by function_app.py
        { name: 'EVENTHUB_NAMESPACE_FQDN', value: eventHubNamespaceFqdn }
        { name: 'EVENTHUB_NAME',           value: eventHubName }
        { name: 'TIMER_SCHEDULE',          value: timerSchedule }
        { name: 'EVENTS_PER_FIRE',         value: string(eventsPerFire) }

        // Remote-build on zip deploy (required for Linux Consumption Python
        // so Oryx runs pip install -r requirements.txt server-side).
        { name: 'SCM_DO_BUILD_DURING_DEPLOYMENT', value: 'true' }
        { name: 'ENABLE_ORYX_BUILD',              value: 'true' }

        // Identity-based deploy target: Kudu uploads the built squashfs to
        // this container using the Function MSI (which has Blob Data Owner
        // via the role assignment below). Required because account keys are
        // disabled and the legacy 'put SAS URL in WEBSITE_RUN_FROM_PACKAGE'
        // path requires keys to mint the SAS.
        { name: 'SCM_RUN_FROM_PACKAGE', value: '${funcStorage.properties.primaryEndpoints.blob}scm-releases' }
      ]
    }
  }
  dependsOn: [
    scmReleases  // container must exist before Kudu tries to upload the squashfs
  ]
}

// -----------------------------------------------------------------------------
// RBAC: Function MSI needs read/write to its own storage account.
// Built-in role IDs:
//   Storage Blob Data Owner          = b7e6dc6d-f1e8-4753-8033-0f276bb0955b
//   Storage Queue Data Contributor   = 974c5e8b-45b9-4653-ba55-5f855dd0fb88
//   Storage Table Data Contributor   = 0a9a7e1f-b9d0-4cc4-a60d-0319b160aaa3
//   Website Contributor              = de139f84-1756-47ae-9be6-808fbbe84772 (for deployer to call Kudu)
// -----------------------------------------------------------------------------
var roleBlobOwner   = 'b7e6dc6d-f1e8-4753-8033-0f276bb0955b'
var roleQueueWriter = '974c5e8b-45b9-4653-ba55-5f855dd0fb88'
var roleTableWriter = '0a9a7e1f-b9d0-4cc4-a60d-0319b160aaa3'
var roleWebsiteContributor = 'de139f84-1756-47ae-9be6-808fbbe84772'

resource msiBlob 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: funcStorage
  name: guid(funcStorage.id, funcApp.id, roleBlobOwner)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleBlobOwner)
    principalId: funcApp.identity.principalId
    principalType: 'ServicePrincipal'
  }
}
resource msiQueue 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: funcStorage
  name: guid(funcStorage.id, funcApp.id, roleQueueWriter)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleQueueWriter)
    principalId: funcApp.identity.principalId
    principalType: 'ServicePrincipal'
  }
}
resource msiTable 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: funcStorage
  name: guid(funcStorage.id, funcApp.id, roleTableWriter)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleTableWriter)
    principalId: funcApp.identity.principalId
    principalType: 'ServicePrincipal'
  }
}
// Deployer (interactive user running deploy.ps1) gets Website Contributor on
// the Function App so they can call the Kudu /api/zipdeploy endpoint with
// their AAD bearer token. The az CLI zip-deploy needs storage keys and is
// blocked by tenant policy; the Kudu REST API accepts an AAD token directly.
resource deployerWebsite 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: funcApp
  name: guid(funcApp.id, deployerObjectId, roleWebsiteContributor)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleWebsiteContributor)
    principalId: deployerObjectId
  }
}

output appName        string = funcApp.name
output principalId    string = funcApp.identity.principalId
output defaultHostname string = funcApp.properties.defaultHostName
