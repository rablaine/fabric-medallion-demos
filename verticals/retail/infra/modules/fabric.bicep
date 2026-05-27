// =============================================================================
// Microsoft Fabric Capacity (F2 SKU)
// =============================================================================
// F2 is the smallest paid Fabric SKU (~$262/mo if left running 24/7).
// PAUSE the capacity in the Azure portal when not in use - all 3 workspaces
// will continue to function for browsing but compute pauses.
//
// The capacity admin user (typically the deployer's UPN) is allowed to
// assign workspaces to this capacity via the Fabric REST API.
// =============================================================================

@description('Capacity name. Lowercase alphanumeric, 3-63 chars, globally unique within the Fabric tenant.')
@minLength(3)
@maxLength(63)
param name string

@description('Azure region')
param location string

@description('UPN of the user to grant capacity admin')
param adminUserPrincipalName string

@description('Tags')
param tags object

resource capacity 'Microsoft.Fabric/capacities@2023-11-01' = {
  name: name
  location: location
  tags: tags
  sku: {
    name: 'F2'
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

output capacityId string = capacity.id
output capacityName string = capacity.name
// The Fabric REST API uses the GUID portion of the ARM resource ID,
// not the ARM resource ID itself. Callers can derive it from `capacityId`.
