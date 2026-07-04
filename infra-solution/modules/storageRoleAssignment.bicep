// Role assignment on an EXISTING storage account (cross-RG).
// Deployed at the storage account scope so the assignment is colocated
// with the resource it protects.
@description('Storage account name.')
param storageAccountName string

@description('Principal ID to grant.')
param principalId string

@description('Role definition ID (GUID, not the full resource ID).')
param roleDefinitionId string

@description('Principal type for the assignment.')
param principalType string = 'ServicePrincipal'

resource sa 'Microsoft.Storage/storageAccounts@2024-01-01' existing = {
  name: storageAccountName
}

resource ra 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: sa
  // Deterministic name → idempotent: same triplet always re-uses the same RA.
  name: guid(sa.id, principalId, roleDefinitionId)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleDefinitionId)
    principalId: principalId
    principalType: principalType
  }
}
