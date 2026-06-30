// Azure Bastion (Standard SKU) for SSH'ing into osm-import-vm
// without giving the VM a public IP. Standard SKU enables the
// "native client" feature so operators can use plain `ssh`/`scp`
// via `az network bastion ssh|tunnel` from their workstation.
@description('Bastion host name.')
param name string

@description('Azure region.')
param location string

@description('Resource ID of the AzureBastionSubnet (must be named "AzureBastionSubnet", >= /26).')
param bastionSubnetId string

var pipName = '${name}-pip'

resource pip 'Microsoft.Network/publicIPAddresses@2024-05-01' = {
  name: pipName
  location: location
  sku: { name: 'Standard' }
  properties: {
    publicIPAllocationMethod: 'Static'
    publicIPAddressVersion: 'IPv4'
  }
}

resource bastion 'Microsoft.Network/bastionHosts@2024-05-01' = {
  name: name
  location: location
  sku: { name: 'Standard' }
  properties: {
    // Required to use `az network bastion ssh|tunnel` from a workstation.
    enableTunneling: true
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          subnet: { id: bastionSubnetId }
          publicIPAddress: { id: pip.id }
        }
      }
    ]
  }
}

output bastionId string = bastion.id
output bastionName string = bastion.name
