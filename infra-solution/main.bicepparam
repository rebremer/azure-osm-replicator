using 'main.bicep'

// ── Defaults below can be overridden via env. For an all-in-one
//    greenfield deploy, set: CORE_RG, STORAGE_RG, PG_RG (all the same
//    if you want one RG), STORAGE_ACCOUNT_NAME, PG_SERVER_NAME, LOCATION.
//    deploy.sh exports these into the deployment.
param prefix      = 'osm-updater'
param location    = readEnvironmentVariable('LOCATION', 'westus3')
param vmName      = 'osm-import-vm'
param adminUsername = 'osmadmin'

// ── Auth mode ─────────────────────────────────────────────────────────
// Toggle: set USE_SSH_KEY=true to log in with an SSH key and disable
// password auth on the VM. When true, SSH_PUBLIC_KEY must be set and
// VM_ADMIN_PASSWORD is ignored.
param useSshKey    = bool(readEnvironmentVariable('USE_SSH_KEY', 'false'))
param sshPublicKey = readEnvironmentVariable('SSH_PUBLIC_KEY', '')
// Only used when useSshKey=false. Override at deploy time via env.
param adminPassword = readEnvironmentVariable('VM_ADMIN_PASSWORD', '')

// External resources the VM stack hangs off of. Built from sub/RG/name
// so a fresh deploy in a single RG (CORE_RG=STORAGE_RG=PG_RG) works
// without editing this file.
// SUBSCRIPTION_ID must be exported by deploy.sh (bicepparam has no
// subscription() context). deploy.sh sets it from `az account show`.
var subId      = readEnvironmentVariable('SUBSCRIPTION_ID', '')
var storageRg  = readEnvironmentVariable('STORAGE_RG', 'test-lakehouse-rg')
var pgRg       = readEnvironmentVariable('PG_RG', 'test-database-rg')
var storageSa  = readEnvironmentVariable('STORAGE_ACCOUNT_NAME', 'testpubliclandingzone')
var pgServer   = readEnvironmentVariable('PG_SERVER_NAME', 'test-database-pg')

param storageAccountResourceId  = '/subscriptions/${subId}/resourceGroups/${storageRg}/providers/Microsoft.Storage/storageAccounts/${storageSa}'
param postgresServerResourceId  = '/subscriptions/${subId}/resourceGroups/${pgRg}/providers/Microsoft.DBforPostgreSQL/flexibleServers/${pgServer}'

// ── Key Vault for runtime secrets ─────────────────────────────────────
// Vault is created in the core RG. The VM's UAMI gets Key Vault
// Secrets User. The PG password is uploaded here once and fetched at
// runtime by init-osm.sh / update-osm.sh via managed-identity auth.
// The final KV name is keyVaultName + '-' + 6-char hash of sub+RG,
// so the name is stable per environment and globally unique-ish. Bump
// KV_NAME_PREFIX (or edit the default) whenever a previously-deployed
// KV with purgeProtection=true lingers in soft-deleted state and
// blocks re-use of the same name.
param keyVaultName         = readEnvironmentVariable('KV_NAME_PREFIX', 'osm-updater-kv2')
param pgPasswordSecretName = 'pg-admin-password'
// Threaded into /etc/profile.d/osm-env.sh on the VM as PGUSER / PGDATABASE.
// PGUSER must match the login used in postgres.bicep (default 'bremerov').
param pgAdminLogin   = readEnvironmentVariable('PG_ADMIN_LOGIN', 'bremerov')
param pgDatabaseName = readEnvironmentVariable('PG_DATABASE', 'osm')
// Threaded into osm-env.sh as CONTAINER_NAME.
param containerName  = readEnvironmentVariable('CONTAINER_NAME', 'osmscanning')
// KV is created with publicNetworkAccess=Disabled (ALZ policy
// Deny-PublicPaaSEndpoints). deploy.sh writes the PG password from
// inside the VM (which reaches KV over the private endpoint).
param keyVaultPublicNetworkAccess = readEnvironmentVariable('KV_PUBLIC_NETWORK_ACCESS', 'Disabled')
// Set ASSIGN_ROLES=0 when the deploying user lacks
// Microsoft.Authorization/roleAssignments/write — the KV role
// assignment will be skipped and must be created out-of-band.
param assignVmIdentityKvRole = bool(readEnvironmentVariable('ASSIGN_ROLES', 'true'))
// Purge protection: keep on for ALZ, flip to false in disposable
// test envs (KV_ENABLE_PURGE_PROTECTION=false) so `az keyvault purge`
// works immediately after teardown and the same deterministic name
// can be reused on the next deploy.
param keyVaultEnablePurgeProtection = bool(readEnvironmentVariable('KV_ENABLE_PURGE_PROTECTION', 'true'))

// ── VM access ("no NAT GW, no Bastion") ──────────────────────────────
// The VM gets a Standard Static PIP by default so operators can SSH in
// and the VM has a deterministic IPv4 egress path. Set
// ENABLE_PUBLIC_IP=false once a VNet-attached VPN (peering / S2S / P2S)
// provides the same reachability.
param enablePublicIp = bool(readEnvironmentVariable('ENABLE_PUBLIC_IP', 'true'))

// ── Pre-existing network resources (script 1 outputs) ─────────────────
// deploy-network.sh deploys network.bicep to NETWORK_RG and prints
// these IDs. deploy.sh either reads them from the latest network
// deployment or accepts them via env (BYO existing VNet).
// DNS zones are NOT in this list — they are created HERE (CORE_RG)
// by main.bicep, so the solution owner manages them day-2.
param vnetResourceId  = readEnvironmentVariable('VNET_RESOURCE_ID', '')
param peSubnetId      = readEnvironmentVariable('PE_SUBNET_ID', '')
param vmSubnetId      = readEnvironmentVariable('VM_SUBNET_ID', '')
