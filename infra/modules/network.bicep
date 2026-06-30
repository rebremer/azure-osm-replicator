// Network: vnet + 2 subnets + NSGs.
// Subnets:
//   - storage-private-endpoint-subnet : holds blob + PG private endpoints
//   - vm-subnet                       : holds osm-import-vm
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

@description('Azure Bastion subnet prefix (must be >= /26 and the subnet must be named "AzureBastionSubnet").')
param bastionSubnetPrefix string = '10.42.250.0/26'

@description('Optional NAT Gateway resource ID. When set, it is attached to vm-subnet only — the PE subnet and AzureBastionSubnet must remain unassociated (PEs do not need it; Bastion does not support it).')
param natGatewayId string = ''

var vnetName = '${prefix}-vnet'
var peNsgName = '${vnetName}-storage-private-endpoint-subnet-nsg-${location}'
var vmNsgName = '${vnetName}-vm-subnet-nsg-${location}'
var bastionNsgName = '${vnetName}-AzureBastionSubnet-nsg-${location}'

resource peNsg 'Microsoft.Network/networkSecurityGroups@2024-05-01' = {
  name: peNsgName
  location: location
  properties: {
    // Empty rules. Defender for Cloud may auto-create this NSG; we own it
    // here. SSH JIT rules are added by Defender at runtime — do not declare.
    securityRules: []
  }
}

resource vmNsg 'Microsoft.Network/networkSecurityGroups@2024-05-01' = {
  name: vmNsgName
  location: location
  properties: {
    // No baseline rules — JIT inserts an Allow-22 rule on demand. Default
    // deny-inbound + allow-outbound covers everything else.
    securityRules: []
  }
}

// Azure Bastion requires a very specific set of NSG rules on the
// AzureBastionSubnet. ALZ policy Deny-Subnet-Without-Nsg also forces
// us to attach one. Rules per
// https://learn.microsoft.com/azure/bastion/bastion-nsg
resource bastionNsg 'Microsoft.Network/networkSecurityGroups@2024-05-01' = {
  name: bastionNsgName
  location: location
  properties: {
    securityRules: [
      // ── Inbound ──
      {
        name: 'AllowHttpsInbound'
        properties: {
          priority: 120
          access: 'Allow'
          direction: 'Inbound'
          protocol: 'Tcp'
          sourceAddressPrefix: 'Internet'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '443'
        }
      }
      {
        name: 'AllowGatewayManagerInbound'
        properties: {
          priority: 130
          access: 'Allow'
          direction: 'Inbound'
          protocol: 'Tcp'
          sourceAddressPrefix: 'GatewayManager'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '443'
        }
      }
      {
        name: 'AllowAzureLoadBalancerInbound'
        properties: {
          priority: 140
          access: 'Allow'
          direction: 'Inbound'
          protocol: 'Tcp'
          sourceAddressPrefix: 'AzureLoadBalancer'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '443'
        }
      }
      {
        name: 'AllowBastionHostCommunicationInbound'
        properties: {
          priority: 150
          access: 'Allow'
          direction: 'Inbound'
          protocol: '*'
          sourceAddressPrefix: 'VirtualNetwork'
          sourcePortRange: '*'
          destinationAddressPrefix: 'VirtualNetwork'
          destinationPortRanges: [ '8080', '5701' ]
        }
      }
      // ── Outbound ──
      {
        name: 'AllowSshRdpOutbound'
        properties: {
          priority: 100
          access: 'Allow'
          direction: 'Outbound'
          protocol: '*'
          sourceAddressPrefix: '*'
          sourcePortRange: '*'
          destinationAddressPrefix: 'VirtualNetwork'
          destinationPortRanges: [ '22', '3389' ]
        }
      }
      {
        name: 'AllowAzureCloudOutbound'
        properties: {
          priority: 110
          access: 'Allow'
          direction: 'Outbound'
          protocol: 'Tcp'
          sourceAddressPrefix: '*'
          sourcePortRange: '*'
          destinationAddressPrefix: 'AzureCloud'
          destinationPortRange: '443'
        }
      }
      {
        name: 'AllowBastionHostCommunicationOutbound'
        properties: {
          priority: 120
          access: 'Allow'
          direction: 'Outbound'
          protocol: '*'
          sourceAddressPrefix: 'VirtualNetwork'
          sourcePortRange: '*'
          destinationAddressPrefix: 'VirtualNetwork'
          destinationPortRanges: [ '8080', '5701' ]
        }
      }
      {
        name: 'AllowGetSessionInformationOutbound'
        properties: {
          priority: 130
          access: 'Allow'
          direction: 'Outbound'
          protocol: '*'
          sourceAddressPrefix: '*'
          sourcePortRange: '*'
          destinationAddressPrefix: 'Internet'
          destinationPortRanges: [ '80', '443' ]
        }
      }
    ]
  }
}

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
          networkSecurityGroup: { id: peNsg.id }
          privateEndpointNetworkPolicies: 'Disabled'
        }
      }
      {
        name: 'vm-subnet'
        properties: {
          addressPrefix: vmSubnetPrefix
          networkSecurityGroup: { id: vmNsg.id }
          // Attach NAT GW for deterministic outbound (allow-listable
          // SNAT IP, large port budget, immune to default-outbound
          // retirement). NAT GW is IPv4-only — see update-osm.sh for
          // the matching RES_OPTIONS=no-aaaa workaround.
          natGateway: empty(natGatewayId) ? null : { id: natGatewayId }
        }
      }
      {
        // Azure Bastion requires the subnet to be named exactly this
        // and to be >= /26. NSG is mandatory under ALZ
        // Deny-Subnet-Without-Nsg and must permit Bastion's specific
        // traffic pattern (see bastionNsg above).
        name: 'AzureBastionSubnet'
        properties: {
          addressPrefix: bastionSubnetPrefix
          networkSecurityGroup: { id: bastionNsg.id }
        }
      }
    ]
  }
}

output vnetId string = vnet.id
output vnetName string = vnet.name
output peSubnetId string = vnet.properties.subnets[0].id
output vmSubnetId string = vnet.properties.subnets[1].id
output bastionSubnetId string = vnet.properties.subnets[2].id
