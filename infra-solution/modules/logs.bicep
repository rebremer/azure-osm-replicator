// Log Analytics workspace.
@description('Workspace name.')
param name string

@description('Azure region.')
param location string

@description('Retention days.')
param retentionInDays int = 30

resource law 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: name
  location: location
  properties: {
    sku: { name: 'PerGB2018' }
    retentionInDays: retentionInDays
  }
}

output id string = law.id
output customerId string = law.properties.customerId
