using 'network.bicep'

// Address space & subnets — matches the values baked into
// modules/network.bicep so an existing deployment can be re-created
// in-place without renumbering.
param prefix                = 'osm-updater'
param location              = readEnvironmentVariable('LOCATION', 'westus3')
param vnetAddressPrefix     = readEnvironmentVariable('VNET_ADDRESS_PREFIX', '10.42.0.0/16')
param peSubnetPrefix        = readEnvironmentVariable('PE_SUBNET_PREFIX', '10.42.1.0/24')
param vmSubnetPrefix        = readEnvironmentVariable('VM_SUBNET_PREFIX', '10.42.6.0/24')
// Solution RG where the NSGs are created via cross-RG module.
// deploy-network.sh exports CORE_RG and ensures the RG exists.
param coreResourceGroupName = readEnvironmentVariable('CORE_RG', 'test-flosm-rg')
