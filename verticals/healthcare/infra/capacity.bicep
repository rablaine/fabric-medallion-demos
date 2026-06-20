// =============================================================================
// Contoso Healthcare (assisted sample-data flow) - Microsoft Fabric F8 capacity
// =============================================================================
// The assisted sample-data flow does NOT stand up Azure Health Data Services or
// any storage - the demo data comes from the Fabric Healthcare data solutions
// built-in SAMPLE dataset, staged into the bronze lakehouse by
// deploy-sampledata.ps1. So the only Azure resource it needs is the Fabric F8
// capacity that hosts the analytics workspace.
//
// Naming matches fhir.bicep's capacity (same uniqueString(resourceGroup().id)
// suffix) so a capacity provisioned here is addressable the same way.
// F8 = ~$1.05/hr; PAUSE it in the Azure portal when idle - the workspace stays
// browsable, compute stops.
// =============================================================================

targetScope = 'resourceGroup'

@description('Naming prefix for all resources. Lowercase alphanumeric, max 12 chars.')
@maxLength(12)
param resourcePrefix string = 'contoso'

@description('Azure region. Must have Microsoft Fabric capacity quota (West US 3 is validated).')
param location string = resourceGroup().location

@description('UPN of the user to grant Fabric capacity admin (must be a member of the Fabric tenant).')
param adminUserPrincipalName string

@description('Common tags')
param tags object = {
  Project: 'Fabric Data Estate Builder'
  Vertical: 'healthcare'
  Flow: 'sample-data'
  ManagedBy: 'Fabric Data Estate Builder'
}

var suffix       = uniqueString(resourceGroup().id)
var capacityName = toLower('${resourcePrefix}health${substring(suffix, 0, 8)}') // 3-63 lowercase alphanumeric, unique in the Fabric tenant

// Microsoft Fabric F8 capacity that hosts the analytics workspace. The workspace
// and the Healthcare data solutions item are created post-deploy via the Fabric
// REST API (they are not ARM resources).
resource capacity 'Microsoft.Fabric/capacities@2023-11-01' = {
  name: capacityName
  location: location
  tags: tags
  sku: {
    name: 'F8'
    tier: 'Fabric'
  }
  properties: {
    administration: {
      members: [
        adminUserPrincipalName
      ]
    }
  }
}

// The Fabric REST API addresses capacities by their GUID, not the ARM id.
// deploy-sampledata.ps1 looks the GUID up by this displayName via GET /v1/capacities.
output capacityName string = capacityName
