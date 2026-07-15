# Key Vault for OSM updater secrets.
# Mirrors infra-solution/modules/keyVault.bicep.
#
# - RBAC-authorisation (no access policies).
# - VM's UAMI gets "Key Vault Secrets Officer".
# - publicNetworkAccess=Disabled by default.

variable "name" {
  description = "Key Vault name (3-24 chars, globally unique)."
  type        = string
}

variable "resource_group_name" {
  type = string
}

variable "location" {
  type = string
}

variable "tenant_id" {
  description = "Tenant ID for the vault."
  type        = string
}

variable "vm_identity_principal_id" {
  description = "Principal ID of the VM UAMI that needs read/write on secrets."
  type        = string
}

variable "pg_password_secret_name" {
  description = "Secret name for the PostgreSQL admin password."
  type        = string
  default     = "pg-admin-password"
}

variable "public_network_access" {
  description = "Public network access for the vault."
  type        = string
  default     = "Disabled"
  validation {
    condition     = contains(["Enabled", "Disabled"], var.public_network_access)
    error_message = "public_network_access must be Enabled or Disabled."
  }
}

variable "assign_vm_identity_role" {
  description = "Create the Key Vault Secrets Officer role assignment for the VM identity."
  type        = bool
  default     = true
}

variable "enable_purge_protection" {
  description = "Enable purge protection. Set false in disposable test envs."
  type        = bool
  default     = true
}

# Built-in role: Key Vault Secrets Officer (read + write secrets)
locals {
  kv_secrets_officer_role_id = "b86a8fe4-44ce-4948-aee5-eccb2c155cd7"
}

resource "azurerm_key_vault" "kv" {
  name                          = var.name
  location                      = var.location
  resource_group_name           = var.resource_group_name
  tenant_id                     = var.tenant_id
  sku_name                      = "standard"
  rbac_authorization_enabled    = true
  soft_delete_retention_days    = 7
  purge_protection_enabled      = var.enable_purge_protection
  public_network_access_enabled = var.public_network_access == "Enabled"

  network_acls {
    default_action = var.public_network_access == "Disabled" ? "Deny" : "Allow"
    bypass         = "AzureServices"
  }
}

resource "azurerm_role_assignment" "secrets_officer" {
  count                = var.assign_vm_identity_role ? 1 : 0
  scope                = azurerm_key_vault.kv.id
  role_definition_id   = "/subscriptions/${data.azurerm_client_config.current.subscription_id}/providers/Microsoft.Authorization/roleDefinitions/${local.kv_secrets_officer_role_id}"
  principal_id         = var.vm_identity_principal_id
  principal_type       = "ServicePrincipal"
}

data "azurerm_client_config" "current" {}

output "key_vault_id" {
  value = azurerm_key_vault.kv.id
}

output "key_vault_name" {
  value = azurerm_key_vault.kv.name
}

output "key_vault_uri" {
  value = azurerm_key_vault.kv.vault_uri
}

output "pg_secret_name" {
  value = var.pg_password_secret_name
}
