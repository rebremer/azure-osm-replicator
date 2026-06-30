// ─────────────────────────────────────────────────────────────────────────────
// main.bicep — recreate the entire test-flosm-rg infrastructure for the
// VM-based OSM updater.
//
// What this deploys (in test-flosm-rg):
//   - VNet (osm-updater-vnet) with 2 subnets + 2 NSGs
//   - Private DNS zones for blob and PostgreSQL Flexible Server + vnet links
//   - Private endpoints to an EXISTING storage account and an EXISTING
//     PostgreSQL flexible server (these may live in other resource groups)
//   - Log Analytics workspace
//   - User-assigned managed identity, public IP, NIC, data disk, VM
//
// What this does NOT deploy (intentional):
//   - The storage account itself (see storage.bicep — separate deployment)
//   - The PostgreSQL flexible server itself (see postgres.bicep)
//   - Defender for Cloud auto-created resources (JIT NSG rules, MDE.Linux
//     extension on the VM, Defender malware-scan tagging) — these appear
//     after deployment when Defender is enabled on the subscription
//   - Role assignments on the storage account (deployed via the
//     storageRoleAssignment module at the storage scope; see deploy.sh)
// ─────────────────────────────────────────────────────────────────────────────
targetScope = 'resourceGroup'

@description('Resource name prefix.')
param prefix string = 'osm-updater'

@description('Azure region for new resources in this RG.')
param location string = resourceGroup().location

@description('VM name.')
param vmName string = 'osm-import-vm'

@description('VM admin username.')
param adminUsername string = 'osmadmin'

@description('VM admin password. Required when useSshKey=false.')
@secure()
param adminPassword string = ''

@description('If true, authenticate to the VM with an SSH public key and disable password auth.')
param useSshKey bool = false

@description('SSH public key (OpenSSH format). Required when useSshKey=true.')
param sshPublicKey string = ''

@description('Existing storage account resource ID (target of blob private endpoint).')
param storageAccountResourceId string

@description('Existing PostgreSQL flexible server resource ID (target of PG private endpoint).')
param postgresServerResourceId string

@description('Availability zone for the VM and its Premium SSD v2 data disk.')
@allowed([ '1', '2', '3' ])
param availabilityZone string = '1'

@description('Key Vault name prefix. A subscription/RG-stable 6-char suffix is appended to keep the final name globally unique. Final name length must stay <= 24.')
param keyVaultName string = 'osm-updater-kv'

@description('Secret name for the PostgreSQL admin password in Key Vault.')
param pgPasswordSecretName string = 'pg-admin-password'

@description('Public network access for the Key Vault. Default Disabled to satisfy ALZ Deny-PublicPaaSEndpoints; the secret is written from the VM (inside the VNet) post-deploy by deploy.sh.')
@allowed([ 'Enabled', 'Disabled' ])
param keyVaultPublicNetworkAccess string = 'Disabled'

@description('Create the Key Vault Secrets Officer role assignment for the VM identity. Set false when the deploying principal lacks Microsoft.Authorization/roleAssignments/write; assign the role manually afterwards.')
param assignVmIdentityKvRole bool = true

@description('Attach a public IP to the VM NIC. Default false to satisfy ALZ Deny-Public-IP-On-NIC. Operators reach the VM via Azure Bastion (see enableBastion).')
param enablePublicIp bool = false

@description('Deploy an Azure Bastion host (Standard SKU, with native-client tunneling) so operators can SSH/SCP to the VM without a public IP. Adds ~$140/mo.')
param enableBastion bool = true

@description('Deploy a NAT Gateway + Standard Static PIP and attach it to vm-subnet for deterministic IPv4 egress. Default true. Disable only if outbound is handled by an upstream firewall/UDR.')
param enableNatGateway bool = true

// ──────────────────────────────────────────────
// NAT Gateway (deployed before the vnet so the subnet PUT carries the
// association on first deploy and we avoid a separate subnet PATCH).
// ──────────────────────────────────────────────
module natGw 'modules/natGateway.bicep' = if (enableNatGateway) {
  name: 'nat-gateway'
  params: {
    name: '${prefix}-natgw'
    location: location
    availabilityZone: availabilityZone
  }
}

// ──────────────────────────────────────────────
// Network: vnet + subnets + NSGs
// ──────────────────────────────────────────────
module net 'modules/network.bicep' = {
  name: 'network'
  params: {
    prefix: prefix
    location: location
    natGatewayId: enableNatGateway ? natGw!.outputs.natGatewayId : ''
  }
}

// ──────────────────────────────────────────────
// Private DNS zones + vnet links
// ──────────────────────────────────────────────
module dnsBlob 'modules/privateDnsZone.bicep' = {
  name: 'dns-blob'
  params: {
    zoneName: 'privatelink.blob.${environment().suffixes.storage}'
    vnetId: net.outputs.vnetId
    linkName: '${net.outputs.vnetName}-link'
  }
}

module dnsPg 'modules/privateDnsZone.bicep' = {
  name: 'dns-pg'
  params: {
    zoneName: 'privatelink.postgres.database.azure.com'
    vnetId: net.outputs.vnetId
    linkName: '${net.outputs.vnetName}-pg-link'
  }
}

module dnsKv 'modules/privateDnsZone.bicep' = {
  name: 'dns-kv'
  params: {
    zoneName: 'privatelink.vaultcore.azure.net'
    vnetId: net.outputs.vnetId
    linkName: '${net.outputs.vnetName}-kv-link'
  }
}

// ──────────────────────────────────────────────
// Private endpoints to the existing storage + PG
// ──────────────────────────────────────────────
var storageAccountName = last(split(storageAccountResourceId, '/'))
var pgServerName = last(split(postgresServerResourceId, '/'))

module peBlob 'modules/privateEndpoint.bicep' = {
  name: 'pe-blob'
  params: {
    name: '${storageAccountName}-blob-pe'
    location: location
    subnetId: net.outputs.peSubnetId
    targetResourceId: storageAccountResourceId
    groupId: 'blob'
    privateDnsZoneId: dnsBlob.outputs.zoneId
  }
}

module pePg 'modules/privateEndpoint.bicep' = {
  name: 'pe-pg'
  params: {
    name: '${pgServerName}-pg-pe'
    location: location
    subnetId: net.outputs.peSubnetId
    targetResourceId: postgresServerResourceId
    groupId: 'postgresqlServer'
    privateDnsZoneId: dnsPg.outputs.zoneId
  }
}

// ──────────────────────────────────────────────
// Observability
// ──────────────────────────────────────────────
module logs 'modules/logs.bicep' = {
  name: 'logs'
  params: {
    name: '${prefix}-logs'
    location: location
  }
}

// ──────────────────────────────────────────────
// VM + identity + disk + NIC + PIP
// ──────────────────────────────────────────────
module vm 'modules/vm.bicep' = {
  name: 'vm'
  params: {
    vmName: vmName
    location: location
    adminUsername: adminUsername
    adminPassword: adminPassword
    useSshKey: useSshKey
    sshPublicKey: sshPublicKey
    subnetId: net.outputs.vmSubnetId
    availabilityZone: availabilityZone
    enablePublicIp: enablePublicIp
  }
}

// Azure Bastion for SSH access when the VM has no public IP.
module bastion 'modules/bastion.bicep' = if (enableBastion) {
  name: 'bastion'
  params: {
    name: '${prefix}-bastion'
    location: location
    bastionSubnetId: net.outputs.bastionSubnetId
  }
}

// ──────────────────────────────────────────────
// Key Vault for runtime secrets (PG password etc.)
// VM managed identity gets Key Vault Secrets User.
// ──────────────────────────────────────────────
module kv 'modules/keyVault.bicep' = {
  name: 'keyvault'
  params: {
    // 6-char deterministic suffix derived from subscription + RG so
    // the name is stable across redeploys but unique per environment.
    name: '${keyVaultName}-${substring(uniqueString(subscription().subscriptionId, resourceGroup().id), 0, 6)}'
    location: location
    vmIdentityPrincipalId: vm.outputs.managedIdentityPrincipalId
    pgPasswordSecretName: pgPasswordSecretName
    publicNetworkAccess: keyVaultPublicNetworkAccess
    assignVmIdentityRole: assignVmIdentityKvRole
  }
}

// Private endpoint so the VM resolves the KV over the VNet rather
// than the public Internet. The KV stays publicNetworkAccess=Enabled
// so deploy-time secret writes still work from the operator's
// workstation; lock it down by setting publicNetworkAccess=Disabled
// on keyVault.bicep once everything is wired up.
module peKv 'modules/privateEndpoint.bicep' = {
  name: 'pe-kv'
  params: {
    name: '${kv.outputs.keyVaultName}-pe'
    location: location
    subnetId: net.outputs.peSubnetId
    targetResourceId: kv.outputs.keyVaultId
    groupId: 'vault'
    privateDnsZoneId: dnsKv.outputs.zoneId
  }
}

output vmPublicIp string = vm.outputs.publicIp
output vmPrivateIp string = vm.outputs.privateIp
output vmName string = vm.outputs.vmName
output bastionName string = enableBastion ? bastion!.outputs.bastionName : ''
output managedIdentityClientId string = vm.outputs.managedIdentityClientId
output managedIdentityPrincipalId string = vm.outputs.managedIdentityPrincipalId
output logAnalyticsCustomerId string = logs.outputs.customerId
output keyVaultName string = kv.outputs.keyVaultName
output keyVaultUri string = kv.outputs.keyVaultUri
output pgSecretName string = kv.outputs.pgSecretName
output natGatewaySnatIp string = enableNatGateway ? natGw!.outputs.snatPublicIp : ''
