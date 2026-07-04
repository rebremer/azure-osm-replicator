// ─────────────────────────────────────────────────────────────────────────────
// network.bicep — network foundation for the OSM updater stack.
//
// Deploys:
//   - NSGs in CORE_RG (solution RG, via cross-RG module) so the solution
//     owner can edit NSG rules day-2 without rights on the network RG.
//   - VNet + 2 subnets (PE, VM) in the current RG (NETWORK_RG) with
//     the NSGs from CORE_RG attached at subnet-create time.
//
// Private DNS zones are NOT deployed here — they live in CORE_RG and
// are created by infra-solution/main.bicep (they only need read on the
// VNet to establish a link).
//
// No NAT Gateway and no Azure Bastion — outbound goes via the VM's
// Standard PIP (enablePublicIp=true in infra-solution/main.bicep) and
// operators reach the VM via SSH-on-PIP today / VPN gateway later.
//
// Permissions required at run time:
//   NETWORK_RG (this deploy's target RG):
//     - Microsoft.Network/virtualNetworks/write
//     - Microsoft.Network/networkSecurityGroups/join/action (on CORE_RG NSGs)
//   CORE_RG (cross-RG module target):
//     - Microsoft.Network/networkSecurityGroups/write
// ─────────────────────────────────────────────────────────────────────────────
targetScope = 'resourceGroup'

@description('Resource name prefix.')
param prefix string = 'osm-updater'

@description('Azure region.')
param location string = resourceGroup().location

@description('VNet address space.')
param vnetAddressPrefix string = '10.42.0.0/16'

@description('Private-endpoint subnet prefix.')
param peSubnetPrefix string = '10.42.1.0/24'

@description('VM subnet prefix.')
param vmSubnetPrefix string = '10.42.6.0/24'

@description('Name of the SOLUTION resource group (CORE_RG) where the NSGs will be created via cross-RG module. Must already exist.')
param coreResourceGroupName string

// ──────────────────────────────────────────────
// NSGs — deployed to CORE_RG (solution RG), not this RG (NETWORK_RG).
// ──────────────────────────────────────────────
module nsgs 'modules/nsgs.bicep' = {
  name: 'nsgs'
  scope: resourceGroup(coreResourceGroupName)
  params: {
    prefix: prefix
    location: location
  }
}

// ──────────────────────────────────────────────
// VNet + subnets (in this RG = NETWORK_RG), referencing the
// cross-RG NSG IDs from CORE_RG.
// ──────────────────────────────────────────────
module net 'modules/network.bicep' = {
  name: 'network'
  params: {
    prefix: prefix
    location: location
    vnetAddressPrefix: vnetAddressPrefix
    peSubnetPrefix: peSubnetPrefix
    vmSubnetPrefix: vmSubnetPrefix
    peNsgId: nsgs.outputs.peNsgId
    vmNsgId: nsgs.outputs.vmNsgId
  }
}

output vnetId string = net.outputs.vnetId
output vnetName string = net.outputs.vnetName
output peSubnetId string = net.outputs.peSubnetId
output vmSubnetId string = net.outputs.vmSubnetId
output peNsgId string = nsgs.outputs.peNsgId
output vmNsgId string = nsgs.outputs.vmNsgId
