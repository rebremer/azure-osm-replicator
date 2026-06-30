// Standalone PostgreSQL Flexible Server deployment.
// In production the server already exists (test-database-pg in
// test-database-rg). This file lets you recreate the same shape from
// scratch in a new environment.
targetScope = 'resourceGroup'

@description('PostgreSQL Flexible Server name (globally unique within region).')
param serverName string

@description('Azure region.')
param location string

@description('PostgreSQL version.')
param postgresVersion string = '17'

@description('SKU name (e.g. Standard_D16ds_v5).')
param skuName string = 'Standard_D16ds_v5'

@description('SKU tier.')
@allowed([ 'Burstable', 'GeneralPurpose', 'MemoryOptimized' ])
param skuTier string = 'GeneralPurpose'

@description('Storage size in GB.')
param storageSizeGb int = 1024

@description('Admin login (must NOT be a reserved word, e.g. avoid "admin").')
param adminLogin string

@description('Admin password.')
@secure()
param adminPassword string

@description('Backup retention days.')
param backupRetentionDays int = 7

@description('Public network access — set Disabled for hardened mode.')
@allowed([ 'Enabled', 'Disabled' ])
param publicNetworkAccess string = 'Enabled'

@description('Database to create on the server (used by init/update-osm.sh).')
param databaseName string = 'osm'

resource pg 'Microsoft.DBforPostgreSQL/flexibleServers@2024-08-01' = {
  name: serverName
  location: location
  sku: {
    name: skuName
    tier: skuTier
  }
  properties: {
    version: postgresVersion
    administratorLogin: adminLogin
    administratorLoginPassword: adminPassword
    storage: {
      storageSizeGB: storageSizeGb
      autoGrow: 'Enabled'
    }
    backup: {
      backupRetentionDays: backupRetentionDays
      geoRedundantBackup: 'Disabled'
    }
    highAvailability: { mode: 'Disabled' }
    network: {
      publicNetworkAccess: publicNetworkAccess
    }
    authConfig: {
      passwordAuth: 'Enabled'
      activeDirectoryAuth: 'Enabled'
      tenantId: subscription().tenantId
    }
  }
}

// Allow-list the extensions osm2pgsql needs. Without this, the
// CREATE EXTENSION calls in init-osm.sh fail with "extension X is not
// allow-listed".
//
// NOTE: PostgreSQL Flexible Server serializes server-level config
// writes — applying multiple `configurations` children in parallel
// fails with "ServerIsBusy". Chain them via dependsOn so they apply
// one at a time.
resource extConfig 'Microsoft.DBforPostgreSQL/flexibleServers/configurations@2024-08-01' = {
  parent: pg
  name: 'azure.extensions'
  properties: {
    // PG_PREWARM: warms the OS page cache / shared_buffers on the PG
    // side before iteration 1 of update-osm.sh. Without it, iter 1 is
    // bottlenecked on random PK reads against planet_osm_ways/rels and
    // is markedly slower than iter 2..N.
    value: 'POSTGIS,HSTORE,PG_PREWARM'
    source: 'user-override'
  }
}

// Performance knobs that materially speed up the initial osm2pgsql load.
// Static-context params (require restart) are set here so the server
// is ready before the first import. Dynamic params could be ALTER
// SYSTEM'd at runtime but doing it in Bicep keeps the config in code.
resource maxWalSize 'Microsoft.DBforPostgreSQL/flexibleServers/configurations@2024-08-01' = {
  parent: pg
  name: 'max_wal_size'
  properties: {
    value: '16384'
    source: 'user-override'
  }
  dependsOn: [ extConfig ]
}

resource maxParMaint 'Microsoft.DBforPostgreSQL/flexibleServers/configurations@2024-08-01' = {
  parent: pg
  name: 'max_parallel_maintenance_workers'
  properties: {
    value: '4'
    source: 'user-override'
  }
  dependsOn: [ maxWalSize ]
}

// Target database for osm2pgsql (planet_osm_* tables live here).
resource db 'Microsoft.DBforPostgreSQL/flexibleServers/databases@2024-08-01' = {
  parent: pg
  name: databaseName
  properties: {
    charset: 'UTF8'
    collation: 'en_US.utf8'
  }
  dependsOn: [ maxParMaint ]
}

output serverId string = pg.id
output serverName string = pg.name
output fqdn string = pg.properties.fullyQualifiedDomainName
output databaseName string = db.name
