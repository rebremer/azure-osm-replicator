// NSGs for the OSM updater subnets.
//
// Deployed via a cross-RG module from infra-vnet/network.bicep so the
// NSG resources live in the SOLUTION resource group (CORE_RG), while
// the subnets that reference them live in the NETWORK resource group.
// This lets the solution owner edit NSG rules day-2 with Contributor
// on CORE_RG only — no rights required on NETWORK_RG.
//
// Cross-scope attachment note: whoever runs deploy-network.sh needs
// `Microsoft.Network/networkSecurityGroups/join/action` on CORE_RG and
// subnet write on NETWORK_RG at setup time. Day-2 the workload owner
// can PATCH NSG rules without touching NETWORK_RG.
@description('Resource name prefix (used to derive NSG names). Must match the prefix used in the network module so names stay consistent with earlier deploys.')
param prefix string

@description('Azure region.')
param location string

var vnetName = '${prefix}-vnet'
var peNsgName = '${vnetName}-storage-private-endpoint-subnet-nsg-${location}'
var vmNsgName = '${vnetName}-vm-subnet-nsg-${location}'

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
    // deny-inbound + allow-outbound covers everything else. Operators
    // reach the VM either via the VM Standard PIP (enablePublicIp=true
    // in main.bicep) or via a VNet-attached VPN gateway (peering / S2S).
    securityRules: []
  }
}

output peNsgId string = peNsg.id
output vmNsgId string = vmNsg.id
