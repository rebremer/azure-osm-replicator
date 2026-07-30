# Mirrors infra-solution/postgres.bicep + postgres.bicepparam.

variable "subscription_id" {
  type = string
}

variable "resource_group_name" {
  type = string
}

variable "server_name" {
  description = "PostgreSQL Flexible Server name (globally unique within region)."
  type        = string
}

variable "location" {
  type    = string
  default = "westus3"
}

variable "postgres_version" {
  type    = string
  default = "17"
}

variable "sku_name" {
  description = "azurerm PG-flex SKU name, e.g. MO_Standard_E8ds_v5 (Memory-Optimised, 8 vCPU / 64 GB RAM)."
  type        = string
  default     = "MO_Standard_E8ds_v5"
}

variable "storage_mb" {
  description = "Storage size in MB. 1 TiB = 1048576, 2 TiB = 2097152."
  type        = number
  default     = 2097152
}

variable "storage_tier" {
  description = "Provisioned IOPS tier. P40 = 7 500 IOPS / 250 MB/s. Valid at 1 TiB as an upgrade over the auto-picked P30."
  type        = string
  default     = "P40"
}

variable "admin_login" {
  type    = string
  default = "osmuser"
}

variable "admin_password" {
  type      = string
  sensitive = true
}

variable "backup_retention_days" {
  type    = number
  default = 7
}

variable "public_network_access" {
  type    = string
  default = "Disabled"
  validation {
    condition     = contains(["Enabled", "Disabled"], var.public_network_access)
    error_message = "public_network_access must be Enabled or Disabled."
  }
}

variable "database_name" {
  type    = string
  default = "osm"
}
