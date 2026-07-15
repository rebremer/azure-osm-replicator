# Standalone PostgreSQL Flexible Server (mirrors infra-solution/postgres.bicep).

data "azurerm_client_config" "current" {}

data "azurerm_resource_group" "rg" {
  name = var.resource_group_name
}

resource "azurerm_postgresql_flexible_server" "pg" {
  name                          = var.server_name
  location                      = var.location
  resource_group_name           = data.azurerm_resource_group.rg.name
  version                       = var.postgres_version
  sku_name                      = var.sku_name
  storage_mb                    = var.storage_mb
  storage_tier                  = var.storage_tier
  auto_grow_enabled             = true
  administrator_login           = var.admin_login
  administrator_password        = var.admin_password
  backup_retention_days         = var.backup_retention_days
  geo_redundant_backup_enabled  = false
  public_network_access_enabled = var.public_network_access == "Enabled"

  authentication {
    password_auth_enabled         = true
    active_directory_auth_enabled = true
    tenant_id                     = data.azurerm_client_config.current.tenant_id
  }

  # High availability disabled by default (no `high_availability` block).

  # Azure auto-assigns an availability zone when HA is disabled and no
  # `zone` is specified. azurerm reads that back on refresh and, on the
  # next plan, tries to null it out — which fails with:
  #   "zone can only be changed when exchanged with the zone specified
  #    in high_availability.0.standby_availability_zone".
  # Ignore drift on the auto-assigned values so plans stay clean.
  lifecycle {
    ignore_changes = [
      zone,
      high_availability[0].standby_availability_zone,
    ]
  }
}

# Allow-list extensions osm2pgsql needs. PG-flex serializes server-level
# config writes, so chain them via depends_on to avoid ServerIsBusy.
resource "azurerm_postgresql_flexible_server_configuration" "extensions" {
  name      = "azure.extensions"
  server_id = azurerm_postgresql_flexible_server.pg.id
  value     = "POSTGIS,HSTORE,PG_PREWARM"
}

resource "azurerm_postgresql_flexible_server_configuration" "max_wal_size" {
  name      = "max_wal_size"
  server_id = azurerm_postgresql_flexible_server.pg.id
  value     = "16384"

  depends_on = [azurerm_postgresql_flexible_server_configuration.extensions]
}

resource "azurerm_postgresql_flexible_server_configuration" "max_par_maint" {
  name      = "max_parallel_maintenance_workers"
  server_id = azurerm_postgresql_flexible_server.pg.id
  value     = "4"

  depends_on = [azurerm_postgresql_flexible_server_configuration.max_wal_size]
}

# Target DB for osm2pgsql (planet_osm_* tables live here).
resource "azurerm_postgresql_flexible_server_database" "db" {
  name      = var.database_name
  server_id = azurerm_postgresql_flexible_server.pg.id
  collation = "en_US.utf8"
  charset   = "UTF8"

  depends_on = [azurerm_postgresql_flexible_server_configuration.max_par_maint]
}

output "server_id" {
  value = azurerm_postgresql_flexible_server.pg.id
}

output "server_name" {
  value = azurerm_postgresql_flexible_server.pg.name
}

output "fqdn" {
  value = azurerm_postgresql_flexible_server.pg.fqdn
}

output "database_name" {
  value = azurerm_postgresql_flexible_server_database.db.name
}
