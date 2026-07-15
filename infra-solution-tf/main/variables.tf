# Mirrors infra-solution/main.bicepparam. All values overridable via TF_VAR_*.

variable "subscription_id" {
  description = "Azure subscription ID."
  type        = string
}

variable "core_rg" {
  description = "Resource group that holds the workload stack (this deployment)."
  type        = string
}

variable "location" {
  description = "Azure region."
  type        = string
  default     = "westus3"
}

variable "prefix" {
  description = "Resource name prefix."
  type        = string
  default     = "osm-updater"
}

variable "vm_name" {
  type    = string
  default = "osm-import-vm"
}

variable "admin_username" {
  type    = string
  default = "osmadmin"
}

variable "admin_password" {
  description = "Required when use_ssh_key=false."
  type        = string
  default     = ""
  sensitive   = true
}

variable "use_ssh_key" {
  type    = bool
  default = false
}

variable "ssh_public_key" {
  type    = string
  default = ""
}

variable "storage_account_resource_id" {
  description = "Existing storage account resource ID (target of blob PE)."
  type        = string
}

variable "postgres_server_resource_id" {
  description = "Existing PostgreSQL flexible server resource ID (target of PG PE)."
  type        = string
}

variable "availability_zone" {
  type    = string
  default = "1"
}

variable "key_vault_name_prefix" {
  description = "Key Vault name prefix. A 6-char deterministic suffix is appended for global uniqueness."
  type        = string
  default     = "osm-updater-kv2"
}

variable "pg_password_secret_name" {
  type    = string
  default = "pg-admin-password"
}

variable "pg_admin_login" {
  type    = string
  default = "osmuser"
}

variable "pg_database_name" {
  type    = string
  default = "osm"
}

variable "container_name" {
  type    = string
  default = "osmscanning"
}

variable "key_vault_public_network_access" {
  type    = string
  default = "Disabled"
  validation {
    condition     = contains(["Enabled", "Disabled"], var.key_vault_public_network_access)
    error_message = "key_vault_public_network_access must be Enabled or Disabled."
  }
}

variable "assign_vm_identity_kv_role" {
  type    = bool
  default = true
}

variable "key_vault_enable_purge_protection" {
  type    = bool
  default = true
}

variable "enable_public_ip" {
  type    = bool
  default = true
}

variable "autoshutdown_enabled" {
  type    = bool
  default = true
}

variable "autoshutdown_time" {
  description = "Daily shutdown time (HHmm, 24h). 0300 = 03:00 local."
  type        = string
  default     = "0300"
}

variable "autoshutdown_timezone" {
  description = "Windows time zone ID."
  type        = string
  default     = "W. Europe Standard Time"
}

# ── Pre-existing network resources (deployed by infra-vnet). ──
variable "vnet_resource_id" {
  type = string
}

variable "pe_subnet_id" {
  type = string
}

variable "vm_subnet_id" {
  type = string
}
