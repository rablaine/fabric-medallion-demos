// =============================================================================
// Contoso Tech - Retail Vertical (Pre-deploy: Fabric Capacity only)
// =============================================================================
// Split out from main.bicep so deploy.ps1 can stand up the Fabric capacity
// (~30s) early, then create the Fabric workspaces + bronze workspace identity
// + tenant-setting grant BEFORE the slow main bicep runs. That overlaps the
// 5-15min Entra/Fabric propagation window with the rest of the deploy.
// =============================================================================

targetScope = 'resourceGroup'

@description('Naming prefix for all resources. Lowercase alphanumeric, max 12 chars.')
@maxLength(12)
param resourcePrefix string = 'contoso'

@description('Azure region')
param location string = resourceGroup().location

@description('Display name (UPN) of the AAD principal to grant Fabric capacity admin')
param adminUserPrincipalName string

@description('Common tags')
param tags object = {
  Project: 'Contoso Data Estate'
  Vertical: 'retail'
  ManagedBy: 'Contoso Data Estate Builder'
}

// uniqueString(resourceGroup().id) is deterministic per RG, so this matches
// the suffix main.bicep computes -- both bicep files derive the same names.
var suffix         = uniqueString(resourceGroup().id)
var fabricCapacity = toLower('${resourcePrefix}retail${substring(suffix, 0, 8)}')

module fabric 'modules/fabric.bicep' = {
  name: 'fabric-deploy'
  params: {
    name: fabricCapacity
    location: location
    adminUserPrincipalName: adminUserPrincipalName
    tags: tags
  }
}

output fabricCapacityId   string = fabric.outputs.capacityId
output fabricCapacityName string = fabric.outputs.capacityName
output uniqueSuffix       string = substring(suffix, 0, 8)
