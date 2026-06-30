// VM: osm-import-vm — always-on import/updater host.
//   - E32-8s_v5 (128 GB RAM, 8 active vCPU on a 32-vCPU SKU)
//   - 128 GB Premium_LRS OS disk
//   - 256 GB Premium SSD v2 data disk on /mnt/data (10000 IOPS, 256 MB/s)
//   - Public IP for SSH-via-JIT (Defender)
//   - User-assigned managed identity for azcopy MSI auth
//
// NOTE: Premium SSD v2 requires the disk and VM to be deployed into a
// specific availability zone. The Standard public IP is also made zonal
// to match.
@description('VM name.')
param vmName string

@description('Azure region.')
param location string

@description('VM SKU.')
param vmSize string = 'Standard_E32-8s_v5'

@description('Admin username.')
param adminUsername string

@description('Admin SSH password. Required when useSshKey=false. Ignored when useSshKey=true.')
@secure()
param adminPassword string = ''

@description('If true, authenticate to the VM with an SSH public key and disable password auth. If false, use the password above.')
param useSshKey bool = false

@description('SSH public key (OpenSSH format, e.g. "ssh-rsa AAAA..."). Required when useSshKey=true.')
param sshPublicKey string = ''

@description('Subnet ID for the VM NIC.')
param subnetId string

@description('Data disk size in GB.')
param dataDiskSizeGB int = 256

@description('Data disk provisioned IOPS (Premium SSD v2).')
param dataDiskIops int = 3000

@description('Data disk provisioned throughput in MB/s (Premium SSD v2).')
param dataDiskThroughputMBps int = 750

@description('Availability zone for the VM, data disk, and public IP. Required for Premium SSD v2.')
@allowed([ '1', '2', '3' ])
param availabilityZone string = '1'

@description('OS disk size in GB. Only honoured on initial VM create; ARM rejects size changes via the VM resource after the fact.')
param osDiskSizeGB int = 128

@description('OS disk storage SKU. Only honoured on initial VM create; ARM rejects SKU changes via the VM resource after the fact. Set this to the SKU of the existing OS disk on re-deploys to avoid OperationNotAllowed.')
@allowed([
  'Standard_LRS'
  'StandardSSD_LRS'
  'Premium_LRS'
  'PremiumV2_LRS'
  'StandardSSD_ZRS'
  'Premium_ZRS'
])
param osDiskStorageAccountType string = 'Premium_LRS'

@description('If true, omit osDisk size + managedDisk.storageAccountType from the VM resource so re-deploys against an existing VM do not attempt immutable changes. Default true — set false only for greenfield deploys where you want Bicep to set those properties.')
param osDiskOmitImmutableProps bool = true

@description('Attach a public IP to the VM NIC. Default false; under ALZ corp policy Deny-Public-IP-On-NIC the NIC must not have a PIP, so reach the VM via Bastion instead.')
param enablePublicIp bool = false

@description('Optional cloud-init YAML to bootstrap the VM (osm2pgsql, azcopy, pyosmium, mounts).')
param cloudInit string = loadTextContent('cloud-init.yaml')

var nicName = '${vmName}-nic'
var pipName = '${vmName}-pip'
var miName  = '${vmName}-mi'
var dataDiskName = '${vmName}-data'

resource mi 'Microsoft.ManagedIdentity/userAssignedIdentities@2024-11-30' = {
  name: miName
  location: location
}

resource pip 'Microsoft.Network/publicIPAddresses@2024-05-01' = if (enablePublicIp) {
  name: pipName
  location: location
  sku: { name: 'Standard' }
  zones: [ availabilityZone ]
  properties: {
    publicIPAllocationMethod: 'Static'
    publicIPAddressVersion: 'IPv4'
  }
}

resource nic 'Microsoft.Network/networkInterfaces@2024-05-01' = {
  name: nicName
  location: location
  properties: {
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          subnet: { id: subnetId }
          privateIPAllocationMethod: 'Dynamic'
          publicIPAddress: enablePublicIp ? { id: pip.id } : null
        }
      }
    ]
  }
}

resource dataDisk 'Microsoft.Compute/disks@2024-03-02' = {
  name: dataDiskName
  location: location
  sku: { name: 'PremiumV2_LRS' }
  zones: [ availabilityZone ]
  properties: {
    creationData: { createOption: 'Empty' }
    diskSizeGB: dataDiskSizeGB
    diskIOPSReadWrite: dataDiskIops
    diskMBpsReadWrite: dataDiskThroughputMBps
  }
}

resource vm 'Microsoft.Compute/virtualMachines@2024-11-01' = {
  name: vmName
  location: location
  zones: [ availabilityZone ]
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${mi.id}': {}
    }
  }
  properties: {
    hardwareProfile: { vmSize: vmSize }
    storageProfile: {
      imageReference: {
        publisher: 'Canonical'
        offer: 'ubuntu-24_04-lts'
        sku: 'server'
        version: 'latest'
      }
      osDisk: osDiskOmitImmutableProps ? {
        createOption: 'FromImage'
        caching: 'ReadWrite'
      } : {
        createOption: 'FromImage'
        caching: 'ReadWrite'
        diskSizeGB: osDiskSizeGB
        managedDisk: { storageAccountType: osDiskStorageAccountType }
      }
      dataDisks: [
        {
          lun: 0
          name: dataDiskName
          createOption: 'Attach'
          // Premium SSD v2 does not support host caching; must be 'None'.
          caching: 'None'
          managedDisk: { id: dataDisk.id }
        }
      ]
    }
    osProfile: {
      computerName: vmName
      adminUsername: adminUsername
      adminPassword: useSshKey ? null : adminPassword
      customData: base64(cloudInit)
      linuxConfiguration: {
        disablePasswordAuthentication: useSshKey
        ssh: useSshKey ? {
          publicKeys: [
            {
              path: '/home/${adminUsername}/.ssh/authorized_keys'
              keyData: sshPublicKey
            }
          ]
        } : null
      }
    }
    networkProfile: {
      networkInterfaces: [ { id: nic.id } ]
    }
  }
}

output vmId string = vm.id
output vmName string = vm.name
output managedIdentityId string = mi.id
output managedIdentityPrincipalId string = mi.properties.principalId
output managedIdentityClientId string = mi.properties.clientId
output publicIp string = enablePublicIp ? pip!.properties.ipAddress : ''
output privateIp string = nic.properties.ipConfigurations[0].properties.privateIPAddress
