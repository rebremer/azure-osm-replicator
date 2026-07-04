using 'postgres.bicep'

param serverName     = readEnvironmentVariable('PG_SERVER_NAME', 'test-database-pg')
param location       = readEnvironmentVariable('LOCATION', 'westus3')
param postgresVersion = '17'
// General Purpose, D16ds_v5: 16 vCores, 64 GiB RAM. Sized for the
// Germany planet import on Premium SSD v1 (P30 = 1024 GiB / 5000 IOPS
// / 200 MB/s). 64 GiB RAM gives ~16 GiB shared_buffers + ~40 GiB OS
// page cache, enough to keep the hot indexes warm during daily
// replication once steady-state is reached.
param skuName        = 'Standard_D16ds_v5'
param skuTier        = 'GeneralPurpose'
param storageSizeGb  = 1024
param adminLogin     = readEnvironmentVariable('PG_ADMIN_LOGIN', 'bremerov')
// Override at deploy time:  --parameters adminPassword='...'
param adminPassword  = readEnvironmentVariable('PG_ADMIN_PASSWORD', '')
param backupRetentionDays = 7
// ALZ policy Deny-PublicPaaSEndpoints requires this to be Disabled.
// The VM reaches PG over the private endpoint created in main.bicep.
param publicNetworkAccess = 'Disabled'
