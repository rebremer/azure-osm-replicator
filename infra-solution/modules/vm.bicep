// VM: osm-import-vm — always-on import/updater host.
//   - E32-8s_v5 (128 GB RAM, 8 active vCPU on a 32-vCPU SKU)
//   - 128 GB Premium_LRS OS disk
//   - 256 GB Premium SSD v2 data disk on /mnt/data (10000 IOPS, 256 MB/s)
//   - Standard Static Public IP on the NIC (default on) for SSH-in +
//     deterministic IPv4 egress — no NAT Gateway, no Bastion.
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

@description('Attach a Standard Static Public IP to the VM NIC. Default true — needed for SSH-in and deterministic IPv4 egress since this stack has no NAT Gateway and no Bastion. Set false once a VPN/ExpressRoute is wired into the VNet.')
param enablePublicIp bool = true

@description('Optional cloud-init YAML to bootstrap the VM (osm2pgsql, azcopy, pyosmium, mounts).')
param cloudInit string = loadTextContent('../../infra-solution-shared/cloud-init.yaml')

@description('init-osm.sh contents, materialised into /home/<adminUsername>/init-osm.sh by the CustomScript extension.')
param initOsmScript string = loadTextContent('../../infra-solution-shared/init-osm.sh')

@description('update-osm.sh contents, materialised into /home/<adminUsername>/update-osm.sh by the CustomScript extension.')
param updateOsmScript string = loadTextContent('../../infra-solution-shared/update-osm.sh')

// ── Runtime env baked into /etc/profile.d/osm-env.sh at deploy time. ──
// These flow from main.bicep so interactive shells (and
// init-osm.sh / update-osm.sh) see the right identity, KV, PG endpoint
// and storage account without operators having to `export` anything.
@description('Key Vault name that holds the runtime secrets (e.g. PG password). Written to osm-env.sh as KEY_VAULT_NAME.')
param keyVaultName string = ''

@description('Name of the PG password secret inside the Key Vault. Written to osm-env.sh as PG_PASSWORD_SECRET_NAME.')
param pgPasswordSecretName string = 'pg-admin-password'

@description('PostgreSQL server FQDN. Written to osm-env.sh as PGHOST.')
param pgServerFqdn string = ''

@description('PostgreSQL admin login. Written to osm-env.sh as PGUSER.')
param pgAdminLogin string = 'osmuser'

@description('PostgreSQL database name. Written to osm-env.sh as PGDATABASE.')
param pgDatabaseName string = 'osm'

@description('Blob storage account name (PBF source / diff staging). Written to osm-env.sh as STORAGE_ACCOUNT.')
param storageAccountName string = ''

@description('Blob container name inside the storage account. Written to osm-env.sh as CONTAINER_NAME.')
param containerName string = 'osmscanning'

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

// ─────────────────────────────────────────────────────────────────────────────
// CustomScript extension — deploy init-osm.sh + update-osm.sh + osm-env.sh.
//
// The two shell scripts are ~52 KB together, which does not fit into
// cloud-init customData alongside the existing YAML (customData is capped
// at 64 KB base64 → ~48 KB raw). CustomScript's protectedSettings.script
// accepts up to 256 KB base64, so we base64-embed all three artefacts
// inside a tiny installer wrapper and decode them onto disk at first boot.
//
// /etc/profile.d/osm-env.sh exports the values init-osm.sh / update-osm.sh
// read at runtime (UAI client id, KV name, PG host, storage account) so
// operators can just SSH in and run `./init-osm.sh` — no manual exports.
//
// forceUpdateTag reruns the extension whenever any artefact changes.
// ─────────────────────────────────────────────────────────────────────────────
var osmEnvFile = join([
  '# Auto-generated by infra-solution/modules/vm.bicep at deploy time.'
  '# Sourced by /etc/profile so interactive shells (and init-osm.sh /'
  '# update-osm.sh) see the right identity, Key Vault, PostgreSQL and'
  '# storage settings without operators having to export anything.'
  'export UAI_CLIENT_ID=\'${mi.properties.clientId}\''
  'export AZCOPY_AUTO_LOGIN_TYPE=\'MSI\''
  'export AZCOPY_MSI_CLIENT_ID=\'${mi.properties.clientId}\''
  'export KEY_VAULT_NAME=\'${keyVaultName}\''
  'export PG_PASSWORD_SECRET_NAME=\'${pgPasswordSecretName}\''
  'export PGHOST=\'${pgServerFqdn}\''
  'export PGUSER=\'${pgAdminLogin}\''
  'export PGDATABASE=\'${pgDatabaseName}\''
  'export PGSSLMODE=\'require\''
  'export STORAGE_ACCOUNT=\'${storageAccountName}\''
  'export CONTAINER_NAME=\'${containerName}\''
  ''
], '\n')

var installerScript = format('''#!/usr/bin/env bash
set -euo pipefail
USER_NAME='{0}'
HOME_DIR="/home/$USER_NAME"
install -d -o "$USER_NAME" -g "$USER_NAME" -m 0755 "$HOME_DIR"
echo '{1}' | base64 -d > "$HOME_DIR/init-osm.sh"
echo '{2}' | base64 -d > "$HOME_DIR/update-osm.sh"
chmod 0755 "$HOME_DIR/init-osm.sh" "$HOME_DIR/update-osm.sh"
chown "$USER_NAME:$USER_NAME" "$HOME_DIR/init-osm.sh" "$HOME_DIR/update-osm.sh"
echo '{3}' | base64 -d > /etc/profile.d/osm-env.sh
chmod 0644 /etc/profile.d/osm-env.sh
''', adminUsername, base64(initOsmScript), base64(updateOsmScript), base64(osmEnvFile))

resource installOsmScripts 'Microsoft.Compute/virtualMachines/extensions@2024-11-01' = {
  parent: vm
  name: 'installOsmScripts'
  location: location
  properties: {
    publisher: 'Microsoft.Azure.Extensions'
    type: 'CustomScript'
    typeHandlerVersion: '2.1'
    autoUpgradeMinorVersion: true
    // Rerun the extension whenever any embedded artefact changes.
    forceUpdateTag: uniqueString(initOsmScript, updateOsmScript, osmEnvFile)
    protectedSettings: {
      script: base64(installerScript)
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
