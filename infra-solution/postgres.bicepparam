using 'postgres.bicep'

param serverName     = readEnvironmentVariable('PG_SERVER_NAME', 'test-database-pg')
param location       = readEnvironmentVariable('LOCATION', 'westus3')
param postgresVersion = '17'
// General Purpose, D8ds_v5: 8 vCores, 32 GiB RAM. Sized for steady-state
// daily replication on Premium SSD v1 P40 (2048 GiB / 7500 IOPS /
// 250 MB/s). 32 GiB RAM gives ~8 GiB shared_buffers + ~20 GiB OS page
// cache — enough to hold the ~9 GB of hot indexes (per repo memory
// deployment.md #8) plus working heap. VM I/O caps (12,800 IOPS /
// 288 MB/s uncached) stay above P40's ceiling so storage isn't wasted.
//
// History: init ran on Standard_D16ds_v5 (16 vCore / 64 GiB) — observed
// peak CPU ~15% and RAM ~30%, so 8 vCore / 32 GiB is right-sized for
// update-osm.sh. Bump back to D16ds_v5 only if re-running init from
// scratch (planet import benefits from more parallelism during index
// build).
param skuName        = 'Standard_D8ds_v5'
param skuTier        = 'GeneralPurpose'
// P40 tier — storage on Flex only grows, so this matches the current
// deployed size and prevents an idempotency check on redeploy.
param storageSizeGb  = 2048
param adminLogin     = readEnvironmentVariable('PG_ADMIN_LOGIN', 'osmuser')
// Override at deploy time:  --parameters adminPassword='...'
param adminPassword  = readEnvironmentVariable('PG_ADMIN_PASSWORD', '')
param backupRetentionDays = 7
// ALZ policy Deny-PublicPaaSEndpoints requires this to be Disabled.
// The VM reaches PG over the private endpoint created in main.bicep.
param publicNetworkAccess = 'Disabled'
