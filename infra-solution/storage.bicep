// Standalone storage account deployment.
// In production the storage already exists (testpubliclandingzone in
// test-lakehouse-rg). This file lets you recreate the same shape from
// scratch in a new environment.
//
// Notes:
//   - Container `osmscanning` is the well-known landing container the
//     updater reads/writes.
//   - publicNetworkAccess defaults to Enabled to match current state, but
//     the recommended hardened deployment sets it to Disabled and accesses
//     blob storage exclusively via the private endpoint.
targetScope = 'resourceGroup'

@description('Storage account name (3-24 lowercase, globally unique).')
param storageAccountName string

@description('Azure region.')
param location string

@description('SKU.')
param skuName string = 'Standard_LRS'

@description('Container name to create.')
param containerName string = 'osmscanning'

@description('Allow blob public access flag (account-level).')
param allowBlobPublicAccess bool = false

@description('Public network access — set Disabled for hardened mode.')
@allowed([ 'Enabled', 'Disabled' ])
param publicNetworkAccess string = 'Enabled'

resource sa 'Microsoft.Storage/storageAccounts@2024-01-01' = {
  name: storageAccountName
  location: location
  kind: 'StorageV2'
  sku: { name: skuName }
  properties: {
    minimumTlsVersion: 'TLS1_2'
    allowBlobPublicAccess: allowBlobPublicAccess
    publicNetworkAccess: publicNetworkAccess
    networkAcls: {
      defaultAction: publicNetworkAccess == 'Disabled' ? 'Deny' : 'Allow'
      bypass: 'AzureServices'
    }
  }
}

resource blobSvc 'Microsoft.Storage/storageAccounts/blobServices@2024-01-01' = {
  parent: sa
  name: 'default'
}

resource container 'Microsoft.Storage/storageAccounts/blobServices/containers@2024-01-01' = {
  parent: blobSvc
  name: containerName
  properties: {
    publicAccess: 'None'
  }
}

output storageAccountId string = sa.id
output storageAccountName string = sa.name
output blobEndpoint string = sa.properties.primaryEndpoints.blob
