// Network: vnet + 2 subnets referencing NSGs that live in a different RG.
// Subnets:
//   - storage-private-endpoint-subnet : holds blob + PG + KV private endpoints
//   - vm-subnet                       : holds osm-import-vm
//
// The NSG resources themselves are created in CORE_RG (see the sibling
// module modules/nsgs.bicep, invoked from network.bicep with a
// cross-RG scope). We just receive the resource IDs here and attach
// them to the subnets at VNet-creation time.
@description('Resource name prefix (e.g. osm-updater).')
param prefix string

@description('Azure region.')
param location string

@description('VNet address space.')
param vnetAddressPrefix string = '10.42.0.0/16'

@description('Private-endpoint subnet prefix.')
param peSubnetPrefix string = '10.42.1.0/24'

@description('VM subnet prefix.')
param vmSubnetPrefix string = '10.42.6.0/24'

@description('Resource ID of the NSG for the private-endpoint subnet.')
param peNsgId string

@description('Resource ID of the NSG for the VM subnet.')
param vmNsgId string

var vnetName = '${prefix}-vnet'

resource vnet 'Microsoft.Network/virtualNetworks@2024-05-01' = {
  name: vnetName
  location: location
  properties: {
    addressSpace: {
      addressPrefixes: [ vnetAddressPrefix ]
    }
    subnets: [
      {
        name: 'storage-private-endpoint-subnet'
        properties: {
          addressPrefix: peSubnetPrefix
          networkSecurityGroup: { id: peNsgId }
          privateEndpointNetworkPolicies: 'Disabled'
        }
      }
      {
        name: 'vm-subnet'
        properties: {
          addressPrefix: vmSubnetPrefix
          networkSecurityGroup: { id: vmNsgId }
        }
      }
    ]
  }
}

output vnetId string = vnet.id
output vnetName string = vnet.name
output peSubnetId string = vnet.properties.subnets[0].id
output vmSubnetId string = vnet.properties.subnets[1].id
