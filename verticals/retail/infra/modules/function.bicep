// =============================================================================
// Azure Function App on Flex Consumption (FC1) -- Python 3.11 timer-triggered
// emitter that pushes synthetic clickstream events into Event Hubs.
//
// Why Flex Consumption (vs. classic Linux Consumption Y1):
//   - Native identity-based AzureWebJobsStorage + identity-based deployment.
//     Linux Consumption requires Kudu to upload a squashfs via the reserved
//     SCM_RUN_FROM_PACKAGE setting, which ARM rejects from siteConfig.
//     Without storage account keys (tenant policy here), that path is broken.
//   - Same per-execution billing model and free grant.
//   - Deploys via OneDeploy (POST /api/publish?type=zip) with AAD bearer.
// =============================================================================

@description('Function App name (3-60 chars, globally unique within *.azurewebsites.net)')
param appName string

@description('Storage account name dedicated to the Function (3-24 lowercase alphanumeric, globally unique)')
param storageAccountName string

@description('Application Insights resource name')
param appInsightsName string

@description('Flex Consumption plan (serverFarm) name')
param planName string

@description('Azure region')
param location string

@description('Timer schedule (NCRONTAB). Default fires every 30 seconds.')
param timerSchedule string = '*/30 * * * * *'

@description('Number of synthetic clickstream events to emit per timer fire')
param eventsPerFire int = 50

@description('Object ID of the deploying user -- granted Website Contributor on the Function App so they can call OneDeploy with their AAD token')
param deployerObjectId string

@description('Tags to apply')
param tags object = {}

// -----------------------------------------------------------------------------
// Storage account (Functions runtime + deployment package storage).
// AAD-only: tenant policy forbids shared-key auth.
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
    allowSharedKeyAccess: false
    defaultToOAuthAuthentication: true
    supportsHttpsTrafficOnly: true
  }
}

// Flex Consumption requires a pre-existing container for deployment packages.
// The Function MSI writes here on OneDeploy; the runtime reads from here.
// Container name is referenced from functionAppConfig.deployment.storage.
resource blobService 'Microsoft.Storage/storageAccounts/blobServices@2023-05-01' = {
  parent: funcStorage
  name: 'default'
}
resource deployPkgContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-05-01' = {
  parent: blobService
  name: 'deploymentpackage'
  properties: {
    publicAccess: 'None'
  }
}

// -----------------------------------------------------------------------------
// Application Insights (classic, non-workspace, for one-resource simplicity)
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
// Flex Consumption plan (FC1, Linux)
// -----------------------------------------------------------------------------
resource plan 'Microsoft.Web/serverfarms@2024-04-01' = {
  name: planName
  location: location
  tags: tags
  sku: {
    name: 'FC1'
    tier: 'FlexConsumption'
  }
  kind: 'functionapp,linux'
  properties: {
    reserved: true
  }
}

// -----------------------------------------------------------------------------
// Function App (Flex Consumption)
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
    // Flex Consumption uses functionAppConfig (NOT siteConfig.linuxFxVersion)
    // for runtime + deployment wiring. siteConfig is still used for ftps/tls
    // hardening and the appSettings collection.
    functionAppConfig: {
      deployment: {
        storage: {
          type: 'blobContainer'
          value: '${funcStorage.properties.primaryEndpoints.blob}deploymentpackage'
          authentication: {
            type: 'SystemAssignedIdentity'
          }
        }
      }
      runtime: {
        name: 'python'
        version: '3.11'
      }
      scaleAndConcurrency: {
        // Keep it modest -- this is a 30-second timer, not a hot HTTP front end.
        maximumInstanceCount: 40
        instanceMemoryMB: 512
      }
    }
    siteConfig: {
      ftpsState: 'Disabled'
      minTlsVersion: '1.2'
      appSettings: [
        // Identity-based AzureWebJobsStorage (no keys).
        { name: 'AzureWebJobsStorage__accountName', value: funcStorage.name }
        { name: 'AzureWebJobsStorage__credential',  value: 'managedidentity' }

        { name: 'APPLICATIONINSIGHTS_CONNECTION_STRING', value: appInsights.properties.ConnectionString }

        // Emitter wiring -- read by function_app.py
        // EVENTHUB_CONNECTION_STRING is populated post-deploy by deploy.ps1
        // once the Fabric Eventstream CustomEndpoint source exists.
        { name: 'TIMER_SCHEDULE',          value: timerSchedule }
        { name: 'EVENTS_PER_FIRE',         value: string(eventsPerFire) }

        // NB: Flex Consumption does NOT use FUNCTIONS_EXTENSION_VERSION,
        // FUNCTIONS_WORKER_RUNTIME, SCM_DO_BUILD_DURING_DEPLOYMENT, or any
        // *_RUN_FROM_PACKAGE settings -- those are owned by functionAppConfig
        // and the platform rejects them. pip install runs automatically on
        // OneDeploy when the package contains a requirements.txt.
      ]
    }
  }
  dependsOn: [
    deployPkgContainer  // container must exist before OneDeploy uploads
  ]
}

// -----------------------------------------------------------------------------
// RBAC
// Built-in role IDs:
//   Storage Blob Data Owner          = b7e6dc6d-f1e8-4753-8033-0f276bb0955b  (in function-storage-rbac.bicep)
//   Storage Queue Data Contributor   = 974c5e8b-45b9-4653-ba55-5f855dd0fb88  (in function-storage-rbac.bicep)
//   Storage Table Data Contributor   = 0a9a7e1f-b9d0-4cc4-a60d-0319b160aaa3  (in function-storage-rbac.bicep)
//   Website Contributor              = de139f84-1756-47ae-9be6-808fbbe84772
// -----------------------------------------------------------------------------
var roleWebsiteContributor = 'de139f84-1756-47ae-9be6-808fbbe84772'

// Function MSI -- read/write its own storage (runtime + deployment package).
// Nested in a separate module so principalId can be a parameter, which makes
// it usable in the role-assignment guid() name. See function-storage-rbac.bicep
// for the rotation-safety rationale.
module funcStorageRbac 'function-storage-rbac.bicep' = {
  name: 'funcStorageRbac'
  params: {
    storageAccountName: funcStorage.name
    principalId:        funcApp.identity.principalId
  }
}

// Deployer (interactive user) -- Website Contributor on the Function App so
// they can call OneDeploy (POST /api/publish?type=zip) with their AAD token.
resource deployerWebsite 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: funcApp
  name: guid(funcApp.id, deployerObjectId, roleWebsiteContributor)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleWebsiteContributor)
    principalId: deployerObjectId
  }
}

output appName         string = funcApp.name
output principalId     string = funcApp.identity.principalId
output defaultHostname string = funcApp.properties.defaultHostName
