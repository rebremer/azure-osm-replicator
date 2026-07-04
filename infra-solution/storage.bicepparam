using 'storage.bicep'

param storageAccountName = readEnvironmentVariable('STORAGE_ACCOUNT_NAME', 'testpubliclandingzone')
param location           = readEnvironmentVariable('LOCATION', 'westus3')
param skuName            = 'Standard_LRS'
param containerName      = 'osmscanning'
param allowBlobPublicAccess = false
// ALZ policy Deny-PublicPaaSEndpoints requires this to be Disabled.
// The VM reaches blob storage over the private endpoint created in main.bicep.
param publicNetworkAccess = 'Disabled'
