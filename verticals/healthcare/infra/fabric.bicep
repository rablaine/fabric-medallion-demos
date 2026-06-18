// =============================================================================
// Contoso Healthcare - Microsoft Fabric capacity (F2 SKU)
// =============================================================================
// Standalone, self-contained deployment (mirrors storage.bicep / fhir.bicep).
// deploy.ps1 launches this with --no-wait so the capacity provisions in parallel
// with the FHIR service; the analytics workspace is created post-deploy against
// this capacity via the Fabric REST API (workspaces are not an ARM resource).
//
// Sized at F2 (not F8 like retail) because healthcare does NOT seed through
// Fabric - the FHIR $export already lands NDJSON in ADLS, and the medallion
// notebooks read that via a OneLake shortcut. F2 is the smallest paid SKU and
// is enough to host the workspace + run the bronze/silver/gold transforms.
//
// F2 = ~$0.36/hr running, ~$263/mo if left on 24/7. PAUSE the capacity in the
// Azure portal when not in use - the workspace stays browsable, compute stops.
//
// The unique suffix is derived from uniqueString(resourceGroup().id) so the name
// is deterministic (same pattern as the retail vertical).
// =============================================================================

targetScope = 'resourceGroup'

@description('Naming prefix for all resources. Lowercase alphanumeric, max 12 chars.')
@maxLength(12)
param resourcePrefix string = 'contoso'

@description('Azure region')
param location string = resourceGroup().location

@description('UPN of the user to grant Fabric capacity admin (must be a member of the Fabric tenant).')
param adminUserPrincipalName string

@description('Common tags')
param tags object = {
  Project: 'Fabric Data Estate Builder'
  Vertical: 'healthcare'
  ManagedBy: 'Fabric Data Estate Builder'
}

var suffix       = uniqueString(resourceGroup().id)
var capacityName = toLower('${resourcePrefix}health${substring(suffix, 0, 8)}') // 3-63 lowercase alphanumeric, unique in the Fabric tenant

resource capacity 'Microsoft.Fabric/capacities@2023-11-01' = {
  name: capacityName
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
// The Fabric REST API addresses capacities by their GUID, not the ARM id.
// deploy.ps1 looks the GUID up by this displayName via GET /v1/capacities.
output capacityName string = capacityName
