# Mirrors infra-solution/storage.bicep + storage.bicepparam.

variable "subscription_id" {
  type = string
}

variable "resource_group_name" {
  description = "RG that hosts the storage account."
  type        = string
}

variable "storage_account_name" {
  description = "Storage account name (3-24 lowercase, globally unique)."
  type        = string
}

variable "location" {
  type    = string
  default = "westus3"
}

variable "sku_name" {
  type    = string
  default = "Standard_LRS"
}

variable "container_name" {
  type    = string
  default = "osmscanning"
}

variable "allow_blob_public_access" {
  type    = bool
  default = false
}

variable "public_network_access" {
  type    = string
  default = "Disabled"
  validation {
    condition     = contains(["Enabled", "Disabled"], var.public_network_access)
    error_message = "public_network_access must be Enabled or Disabled."
  }
}
