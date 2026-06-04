// =============================================================================
// VNet for Fabric VNet Data Gateway + SQL Private Endpoint
// =============================================================================
// snet-gateway: delegated to Microsoft.PowerPlatform/vnetaccesslinks. Hosts
//   the Fabric VNet Data Gateway that carries Mirroring traffic to SQL while
//   publicNetworkAccess on the SQL server is Disabled.
// snet-pe: holds the customer-side Private Endpoint to the SQL logical
//   server. The gateway resolves the SQL FQDN via the private DNS zone (see
//   sql-pe.bicep) and routes through this PE to reach SQL over the VNet.
// Notebook Spark traffic uses a SEPARATE workspace Managed Private Endpoint
// (created via Fabric REST in deploy.ps1) -- this VNet does NOT carry it.
// =============================================================================

@description('VNet name')
param vnetName string

@description('Azure region')
param location string

@description('Tags')
param tags object

var vnetAddressPrefix    = '10.50.0.0/16'
var gatewaySubnetName    = 'snet-gateway'
var gatewaySubnetPrefix  = '10.50.1.0/24'
var peSubnetName         = 'snet-pe'
var peSubnetPrefix       = '10.50.2.0/24'

resource vnet 'Microsoft.Network/virtualNetworks@2024-01-01' = {
  name: vnetName
  location: location
  tags: tags
  properties: {
    addressSpace: { addressPrefixes: [ vnetAddressPrefix ] }
    subnets: [
      {
        name: gatewaySubnetName
        properties: {
          addressPrefix: gatewaySubnetPrefix
          delegations: [
            {
              name: 'powerplatform-vnetaccesslinks'
              properties: { serviceName: 'Microsoft.PowerPlatform/vnetaccesslinks' }
            }
          ]
        }
      }
      {
        name: peSubnetName
        properties: {
          addressPrefix: peSubnetPrefix
          // Required for PE creation in this subnet
          privateEndpointNetworkPolicies: 'Disabled'
        }
      }
    ]
  }
}

output vnetId             string = vnet.id
output vnetName           string = vnet.name
output gatewaySubnetName  string = gatewaySubnetName
output peSubnetId         string = '${vnet.id}/subnets/${peSubnetName}'
