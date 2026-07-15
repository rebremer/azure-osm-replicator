// ─────────────────────────────────────────────────────────────────────────────
// main.bicep — workload stack for the VM-based OSM updater.
//
// Assumes the network foundation (VNet + 2 subnets + NSGs + private DNS
// zones) already exists and is passed in by resource ID. Deploy that
// layer first via infra-vnet/network.bicep / deploy-network.sh.
//
// What this deploys (in CORE_RG):
//   - Log Analytics workspace
//   - User-assigned managed identity, NIC + Standard PIP (default on),
//     data disk, VM
//   - Key Vault
//   - Private endpoints (in the pre-existing PE subnet) to:
//       * an EXISTING storage account
//       * an EXISTING PostgreSQL flexible server
//       * the Key Vault deployed here
//     registered against the pre-existing private DNS zones
//
// No NAT Gateway and no Azure Bastion. The VM's Standard PIP provides
// deterministic IPv4 outbound (and inbound SSH for bootstrap); the
// end-state operator access path is a VNet-attached VPN gateway, at
// which point ENABLE_PUBLIC_IP=false can retire the PIP.
//
// What this does NOT deploy (intentional):
//   - VNet / subnets / NSGs / private DNS zones
//     (see infra-vnet/network.bicep — deployed to its own RG,
//     typically NETWORK_RG)
//   - The storage account itself (see storage.bicep)
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

@description('Key Vault name prefix. A subscription/RG-stable 6-char suffix is appended to keep the final name globally unique. Final name length must stay <= 24. Bump the prefix (e.g. -kv2, -kv3) whenever a previously-deployed KV with `enablePurgeProtection=true` lingers in soft-deleted state and blocks re-use of the same deterministic name.')
param keyVaultName string = 'osm-updater-kv2'

@description('Secret name for the PostgreSQL admin password in Key Vault.')
param pgPasswordSecretName string = 'pg-admin-password'

@description('PostgreSQL admin login. Threaded into /etc/profile.d/osm-env.sh on the VM as PGUSER.')
param pgAdminLogin string = 'osmuser'

@description('PostgreSQL database used by init-osm.sh / update-osm.sh. Threaded into /etc/profile.d/osm-env.sh as PGDATABASE.')
param pgDatabaseName string = 'osm'

@description('Blob container used for the PBF source / diff staging. Threaded into /etc/profile.d/osm-env.sh as CONTAINER_NAME.')
param containerName string = 'osmscanning'

@description('Public network access for the Key Vault. Default Disabled to satisfy ALZ Deny-PublicPaaSEndpoints; the secret is written from the VM (inside the VNet) post-deploy by deploy.sh.')
@allowed([ 'Enabled', 'Disabled' ])
param keyVaultPublicNetworkAccess string = 'Disabled'

@description('Create the Key Vault Secrets Officer role assignment for the VM identity. Set false when the deploying principal lacks Microsoft.Authorization/roleAssignments/write; assign the role manually afterwards.')
param assignVmIdentityKvRole bool = true

@description('Enable Key Vault purge protection. Default true for ALZ compliance. Set false in disposable test environments so a deleted KV can be purged immediately (otherwise it blocks the same-name redeploy for 7 days).')
param keyVaultEnablePurgeProtection bool = true

@description('Attach a Standard Static Public IP to the VM NIC. Default true — needed for SSH-in and deterministic IPv4 egress since this stack has no NAT Gateway and no Bastion. Set false once a VPN/ExpressRoute is wired into the VNet.')
param enablePublicIp bool = true

// ──────────────────────────────────────────────
// Pre-existing network resources (deployed by infra-vnet/network.bicep
// into NETWORK_RG). Script 1 exports the VNet + subnet IDs; script 2
// (deploy.sh) threads them through main.bicepparam.
//
// DNS zones live HERE (CORE_RG) — they are created below, not passed
// in. This lets the solution owner manage DNS records day-2 with
// Contributor on CORE_RG only, no rights on NETWORK_RG.
// ──────────────────────────────────────────────
@description('Resource ID of the pre-existing VNet (from network.bicep output vnetId). Used as the target of the private DNS zone links created here.')
param vnetResourceId string

@description('Resource ID of the pre-existing private-endpoint subnet.')
param peSubnetId string

@description('Resource ID of the pre-existing VM subnet.')
param vmSubnetId string

// ──────────────────────────────────────────────
// Private DNS zones + VNet links — all created in CORE_RG (this RG).
// Each link only needs read on the target VNet, not write, so the
// solution owner can create/manage them without Contributor on
// NETWORK_RG.
// ──────────────────────────────────────────────
var vnetLinkName = 'osm-updater-vnet-link'

module dnsBlob 'modules/privateDnsZone.bicep' = {
  name: 'dns-blob'
  params: {
    zoneName: 'privatelink.blob.${environment().suffixes.storage}'
    vnetId: vnetResourceId
    linkName: vnetLinkName
  }
}

module dnsPg 'modules/privateDnsZone.bicep' = {
  name: 'dns-pg'
  params: {
    zoneName: 'privatelink.postgres.database.azure.com'
    vnetId: vnetResourceId
    linkName: vnetLinkName
  }
}

module dnsKv 'modules/privateDnsZone.bicep' = {
  name: 'dns-kv'
  params: {
    zoneName: 'privatelink.vaultcore.azure.net'
    vnetId: vnetResourceId
    linkName: vnetLinkName
  }
}

// ──────────────────────────────────────────────
// Private endpoints to the existing storage + PG
// ──────────────────────────────────────────────
var storageAccountName = last(split(storageAccountResourceId, '/'))
var pgServerName = last(split(postgresServerResourceId, '/'))
var pgServerFqdn = '${pgServerName}.postgres.database.azure.com'

// KV name is computed once here (deterministic 6-char suffix from
// sub+RG uniqueString) so it can be baked into /etc/profile.d/osm-env.sh
// on the VM BEFORE the KV module runs. Otherwise the VM module would
// depend on the KV module which depends on the VM identity → cycle.
var keyVaultFullName = '${keyVaultName}-${substring(uniqueString(subscription().subscriptionId, resourceGroup().id), 0, 6)}'

module peBlob 'modules/privateEndpoint.bicep' = {
  name: 'pe-blob'
  params: {
    name: '${storageAccountName}-blob-pe'
    location: location
    subnetId: peSubnetId
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
    subnetId: peSubnetId
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
    subnetId: vmSubnetId
    availabilityZone: availabilityZone
    enablePublicIp: enablePublicIp
    // Values baked into /etc/profile.d/osm-env.sh on the VM.
    keyVaultName: keyVaultFullName
    pgPasswordSecretName: pgPasswordSecretName
    pgServerFqdn: pgServerFqdn
    pgAdminLogin: pgAdminLogin
    pgDatabaseName: pgDatabaseName
    storageAccountName: storageAccountName
    containerName: containerName
  }
}

// ──────────────────────────────────────────────
// Key Vault for runtime secrets (PG password etc.)
// VM managed identity gets Key Vault Secrets User.
// ──────────────────────────────────────────────
module kv 'modules/keyVault.bicep' = {
  name: 'keyvault'
  params: {
    // Reuses the deterministic name hoisted above so the same value
    // is baked into the VM's /etc/profile.d/osm-env.sh.
    name: keyVaultFullName
    location: location
    vmIdentityPrincipalId: vm.outputs.managedIdentityPrincipalId
    pgPasswordSecretName: pgPasswordSecretName
    publicNetworkAccess: keyVaultPublicNetworkAccess
    assignVmIdentityRole: assignVmIdentityKvRole
    enablePurgeProtection: keyVaultEnablePurgeProtection
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
    subnetId: peSubnetId
    targetResourceId: kv.outputs.keyVaultId
    groupId: 'vault'
    privateDnsZoneId: dnsKv.outputs.zoneId
  }
}

output vnetResourceId string = vnetResourceId
output vmPublicIp string = vm.outputs.publicIp
output vmPrivateIp string = vm.outputs.privateIp
output vmName string = vm.outputs.vmName
output managedIdentityClientId string = vm.outputs.managedIdentityClientId
output managedIdentityPrincipalId string = vm.outputs.managedIdentityPrincipalId
output logAnalyticsCustomerId string = logs.outputs.customerId
output keyVaultName string = kv.outputs.keyVaultName
output keyVaultUri string = kv.outputs.keyVaultUri
output pgSecretName string = kv.outputs.pgSecretName
output dnsBlobZoneId string = dnsBlob.outputs.zoneId
output dnsPgZoneId string = dnsPg.outputs.zoneId
output dnsKvZoneId string = dnsKv.outputs.zoneId
