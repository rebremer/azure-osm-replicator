// Key Vault for OSM updater secrets.
//
// - RBAC-authorisation (no access policies). The VM's user-assigned
//   managed identity is granted "Key Vault Secrets Officer" so it
//   can both read existing secrets and write new ones (used by
//   deploy.sh post-create to upload the PG password from inside the
//   VNet).
// - publicNetworkAccess=Disabled by default (ALZ policy
//   Deny-PublicPaaSEndpoints forbids Enabled). The vault is reached
//   exclusively via the private endpoint created in main.bicep.
@description('Key Vault name (3-24 chars, globally unique).')
param name string

@description('Azure region.')
param location string

@description('Tenant ID for the vault.')
param tenantId string = subscription().tenantId

@description('Principal ID of the VM user-assigned managed identity that needs read/write access to secrets.')
param vmIdentityPrincipalId string

@description('Secret name for the PostgreSQL admin password (referenced by init/update-osm.sh).')
param pgPasswordSecretName string = 'pg-admin-password'

@description('Public network access for the vault. Default Disabled to satisfy ALZ Deny-PublicPaaSEndpoints; VM uses the private endpoint.')
@allowed([ 'Enabled', 'Disabled' ])
param publicNetworkAccess string = 'Disabled'

@description('Create the Key Vault Secrets Officer role assignment for the VM identity. Set false when the deploying principal lacks Microsoft.Authorization/roleAssignments/write; assign the role manually afterwards.')
param assignVmIdentityRole bool = true

// Built-in role: Key Vault Secrets Officer (read + write secrets)
var kvSecretsOfficerRoleId = 'b86a8fe4-44ce-4948-aee5-eccb2c155cd7'

resource kv 'Microsoft.KeyVault/vaults@2024-11-01' = {
  name: name
  location: location
  properties: {
    tenantId: tenantId
    sku: {
      family: 'A'
      name: 'standard'
    }
    enableRbacAuthorization: true
    enableSoftDelete: true
    softDeleteRetentionInDays: 7
    enablePurgeProtection: true
    publicNetworkAccess: publicNetworkAccess
    networkAcls: {
      defaultAction: publicNetworkAccess == 'Disabled' ? 'Deny' : 'Allow'
      bypass: 'AzureServices'
    }
  }
}

resource secretsOfficerRa 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (assignVmIdentityRole) {
  scope: kv
  name: guid(kv.id, vmIdentityPrincipalId, kvSecretsOfficerRoleId)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', kvSecretsOfficerRoleId)
    principalId: vmIdentityPrincipalId
    principalType: 'ServicePrincipal'
  }
}

output keyVaultId string = kv.id
output keyVaultName string = kv.name
output keyVaultUri string = kv.properties.vaultUri
output pgSecretName string = pgPasswordSecretName
