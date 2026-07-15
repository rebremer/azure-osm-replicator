# ─────────────────────────────────────────────────────────────────────────────
# main.tf — workload stack for the VM-based OSM updater (Terraform port
# of infra-solution/main.bicep).
#
# Assumes the network foundation (VNet + subnets + NSGs) already exists
# and is passed in by resource ID. DNS zones are created HERE in CORE_RG.
# ─────────────────────────────────────────────────────────────────────────────

data "azurerm_client_config" "current" {}

data "azurerm_resource_group" "core" {
  name = var.core_rg
}

# Derive names from the target resource IDs (mirrors bicep last(split(...))).
locals {
  storage_account_name = element(split("/", var.storage_account_resource_id), length(split("/", var.storage_account_resource_id)) - 1)
  pg_server_name       = element(split("/", var.postgres_server_resource_id), length(split("/", var.postgres_server_resource_id)) - 1)
  pg_server_fqdn       = "${local.pg_server_name}.postgres.database.azure.com"

  # Deterministic 6-char suffix from sub + RG (mirrors bicep
  # uniqueString(subscription().subscriptionId, resourceGroup().id)).
  # bicep's uniqueString is a MurmurHash; we approximate with md5 —
  # different value but equally stable.
  kv_suffix         = substr(md5("${var.subscription_id}${data.azurerm_resource_group.core.id}"), 0, 6)
  key_vault_full_name = "${var.key_vault_name_prefix}-${local.kv_suffix}"

  vnet_link_name = "osm-updater-vnet-link"

  # Path to shared scripts in repo root — resolved relative to this
  # root module (infra-solution-tf/main/). ${path.root} points to the
  # working directory (the `main/` folder when run via terraform CLI).
  repo_root = "${path.module}/../.."
}

# ──────────────────────────────────────────────
# Private DNS zones + VNet links — all in CORE_RG.
# ──────────────────────────────────────────────
module "dns_blob" {
  source              = "../modules/private_dns_zone"
  zone_name           = "privatelink.blob.core.windows.net"
  resource_group_name = data.azurerm_resource_group.core.name
  vnet_id             = var.vnet_resource_id
  link_name           = local.vnet_link_name
}

module "dns_pg" {
  source              = "../modules/private_dns_zone"
  zone_name           = "privatelink.postgres.database.azure.com"
  resource_group_name = data.azurerm_resource_group.core.name
  vnet_id             = var.vnet_resource_id
  link_name           = local.vnet_link_name
}

module "dns_kv" {
  source              = "../modules/private_dns_zone"
  zone_name           = "privatelink.vaultcore.azure.net"
  resource_group_name = data.azurerm_resource_group.core.name
  vnet_id             = var.vnet_resource_id
  link_name           = local.vnet_link_name
}

# ──────────────────────────────────────────────
# Private endpoints to existing storage + PG
# ──────────────────────────────────────────────
module "pe_blob" {
  source              = "../modules/private_endpoint"
  name                = "${local.storage_account_name}-blob-pe"
  resource_group_name = data.azurerm_resource_group.core.name
  location            = var.location
  subnet_id           = var.pe_subnet_id
  target_resource_id  = var.storage_account_resource_id
  group_id            = "blob"
  private_dns_zone_id = module.dns_blob.zone_id
}

module "pe_pg" {
  source              = "../modules/private_endpoint"
  name                = "${local.pg_server_name}-pg-pe"
  resource_group_name = data.azurerm_resource_group.core.name
  location            = var.location
  subnet_id           = var.pe_subnet_id
  target_resource_id  = var.postgres_server_resource_id
  group_id            = "postgresqlServer"
  private_dns_zone_id = module.dns_pg.zone_id
}

# ──────────────────────────────────────────────
# Observability
# ──────────────────────────────────────────────
module "logs" {
  source              = "../modules/logs"
  name                = "${var.prefix}-logs"
  resource_group_name = data.azurerm_resource_group.core.name
  location            = var.location
}

# ──────────────────────────────────────────────
# VM + identity + disk + NIC + PIP
# ──────────────────────────────────────────────
module "vm" {
  source                 = "../modules/vm"
  vm_name                = var.vm_name
  resource_group_name    = data.azurerm_resource_group.core.name
  location               = var.location
  admin_username         = var.admin_username
  admin_password         = var.admin_password
  use_ssh_key            = var.use_ssh_key
  ssh_public_key         = var.ssh_public_key
  subnet_id              = var.vm_subnet_id
  availability_zone      = var.availability_zone
  enable_public_ip       = var.enable_public_ip
  # Baked into /etc/profile.d/osm-env.sh on the VM.
  key_vault_name          = local.key_vault_full_name
  pg_password_secret_name = var.pg_password_secret_name
  pg_server_fqdn          = local.pg_server_fqdn
  pg_admin_login          = var.pg_admin_login
  pg_database_name        = var.pg_database_name
  storage_account_name    = local.storage_account_name
  container_name          = var.container_name
  # Shared assets in infra-solution-shared/ are consumed by both the
  # Bicep and Terraform stacks — single source of truth.
  init_osm_script_path   = "${local.repo_root}/infra-solution-shared/init-osm.sh"
  update_osm_script_path = "${local.repo_root}/infra-solution-shared/update-osm.sh"
  cloud_init_path        = "${local.repo_root}/infra-solution-shared/cloud-init.yaml"
}

# ──────────────────────────────────────────────
# Key Vault for runtime secrets (PG password etc.)
# VM managed identity gets Key Vault Secrets Officer.
# ──────────────────────────────────────────────
module "kv" {
  source                    = "../modules/key_vault"
  name                      = local.key_vault_full_name
  resource_group_name       = data.azurerm_resource_group.core.name
  location                  = var.location
  tenant_id                 = data.azurerm_client_config.current.tenant_id
  vm_identity_principal_id  = module.vm.managed_identity_principal_id
  pg_password_secret_name   = var.pg_password_secret_name
  public_network_access     = var.key_vault_public_network_access
  assign_vm_identity_role   = var.assign_vm_identity_kv_role
  enable_purge_protection   = var.key_vault_enable_purge_protection
}

# Private endpoint so the VM resolves the KV over the VNet.
module "pe_kv" {
  source              = "../modules/private_endpoint"
  name                = "${module.kv.key_vault_name}-pe"
  resource_group_name = data.azurerm_resource_group.core.name
  location            = var.location
  subnet_id           = var.pe_subnet_id
  target_resource_id  = module.kv.key_vault_id
  group_id            = "vault"
  private_dns_zone_id = module.dns_kv.zone_id
}
