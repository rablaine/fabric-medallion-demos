// =============================================================================
// Microsoft Fabric Capacity (F8 SKU)
// =============================================================================
// F8 = ~$1.05/hr running, ~$760/mo if left on 24/7. PAUSE the capacity in the
// Azure portal when not in use - workspaces remain browsable, compute stops.
//
// Sized at F8 (not F2) so seed + Mirror initial snapshot + Eventstream + the
// always-on Function emitter can all run concurrently without throttling.
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

output capacityId string = capacity.id
output capacityName string = capacity.name
// The Fabric REST API uses the GUID portion of the ARM resource ID,
// not the ARM resource ID itself. Callers can derive it from `capacityId`.
