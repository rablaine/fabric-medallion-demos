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

@description('Tags to apply')
param tags object = {}

// -----------------------------------------------------------------------------
// Storage account (Functions runtime requirement -- separate from data lake)
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
    supportsHttpsTrafficOnly: true
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
var storageConnectionString = 'DefaultEndpointsProtocol=https;AccountName=${funcStorage.name};AccountKey=${funcStorage.listKeys().keys[0].value};EndpointSuffix=${environment().suffixes.storage}'

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
        // Functions runtime
        // NB: Linux Consumption does NOT use a content file share, so the
        // WEBSITE_CONTENTAZUREFILECONNECTIONSTRING + WEBSITE_CONTENTSHARE
        // pair (required on Windows Consumption / Premium) must be OMITTED.
        // Setting them on Linux Y1 causes ARM to try creating a file share
        // and fail with a 403 against the storage account.
        { name: 'AzureWebJobsStorage',             value: storageConnectionString }
        { name: 'FUNCTIONS_EXTENSION_VERSION',     value: '~4' }
        { name: 'FUNCTIONS_WORKER_RUNTIME',        value: 'python' }
        { name: 'APPLICATIONINSIGHTS_CONNECTION_STRING', value: appInsights.properties.ConnectionString }

        // Emitter wiring -- read by function_app.py
        { name: 'EVENTHUB_NAMESPACE_FQDN', value: eventHubNamespaceFqdn }
        { name: 'EVENTHUB_NAME',           value: eventHubName }
        { name: 'TIMER_SCHEDULE',          value: timerSchedule }
        { name: 'EVENTS_PER_FIRE',         value: string(eventsPerFire) }

        // Remote-build on zip deploy (required for Linux Consumption to install requirements.txt)
        { name: 'SCM_DO_BUILD_DURING_DEPLOYMENT', value: 'true' }
        { name: 'ENABLE_ORYX_BUILD',              value: 'true' }
      ]
    }
  }
}

output appName        string = funcApp.name
output principalId    string = funcApp.identity.principalId
output defaultHostname string = funcApp.properties.defaultHostName
