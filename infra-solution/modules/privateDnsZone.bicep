// Private DNS zone + vnet link.
@description('Zone name, e.g. privatelink.blob.core.windows.net')
param zoneName string

@description('VNet ID to link.')
param vnetId string

@description('Link name.')
param linkName string

resource zone 'Microsoft.Network/privateDnsZones@2024-06-01' = {
  name: zoneName
  location: 'global'
}

resource link 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2024-06-01' = {
  parent: zone
  name: linkName
  location: 'global'
  properties: {
    registrationEnabled: false
    virtualNetwork: { id: vnetId }
  }
}

output zoneId string = zone.id
output zoneName string = zone.name
