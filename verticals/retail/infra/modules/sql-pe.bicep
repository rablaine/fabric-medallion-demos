// =============================================================================
// Private Endpoint to Azure SQL server + privatelink.database.windows.net DNS
// =============================================================================
// Required so the Fabric VNet Data Gateway (in snet-gateway) can resolve the
// SQL server FQDN to a private IP and reach it while publicNetworkAccess on
// the SQL server is Disabled. Without the private DNS zone link, the gateway
// would resolve the FQDN to the SQL server's public IP and the connection
// would be rejected.
// =============================================================================

@description('Private endpoint name')
param peName string

@description('Azure region')
param location string

@description('SQL server resource id')
param sqlServerId string

@description('Subnet resource id to host the PE')
param subnetId string

@description('VNet resource id to link the private DNS zone to')
param vnetId string

@description('Tags')
param tags object

#disable-next-line no-hardcoded-env-urls
var dnsZoneName = 'privatelink.database.windows.net'

resource pe 'Microsoft.Network/privateEndpoints@2024-01-01' = {
  name: peName
  location: location
  tags: tags
  properties: {
    subnet: { id: subnetId }
    privateLinkServiceConnections: [
      {
        name: '${peName}-conn'
        properties: {
          privateLinkServiceId: sqlServerId
          groupIds: [ 'sqlServer' ]
        }
      }
    ]
  }
}

resource dnsZone 'Microsoft.Network/privateDnsZones@2020-06-01' = {
  name: dnsZoneName
  location: 'global'
  tags: tags
}

resource dnsLink 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2020-06-01' = {
  parent: dnsZone
  name: 'sql-dns-link'
  location: 'global'
  tags: tags
  properties: {
    virtualNetwork: { id: vnetId }
    registrationEnabled: false
  }
}

resource zoneGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2024-01-01' = {
  parent: pe
  name: 'sql-zg'
  properties: {
    privateDnsZoneConfigs: [
      {
        name: dnsZoneName
        properties: { privateDnsZoneId: dnsZone.id }
      }
    ]
  }
}

output peName string = pe.name
output peId   string = pe.id
