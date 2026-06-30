// Generic private endpoint to a target resource + DNS zone group registration.
@description('Private endpoint name.')
param name string

@description('Azure region.')
param location string

@description('PE subnet ID.')
param subnetId string

@description('Target resource ID (e.g. storage account or PG flexible server).')
param targetResourceId string

@description('Group ID for the PE (e.g. blob, postgresqlServer).')
param groupId string

@description('Private DNS zone ID to register against.')
param privateDnsZoneId string

resource pe 'Microsoft.Network/privateEndpoints@2024-05-01' = {
  name: name
  location: location
  properties: {
    subnet: { id: subnetId }
    privateLinkServiceConnections: [
      {
        name: groupId
        properties: {
          privateLinkServiceId: targetResourceId
          groupIds: [ groupId ]
        }
      }
    ]
  }
}

resource dnsGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2024-05-01' = {
  parent: pe
  name: 'default'
  properties: {
    privateDnsZoneConfigs: [
      {
        name: 'config'
        properties: { privateDnsZoneId: privateDnsZoneId }
      }
    ]
  }
}

output id string = pe.id
