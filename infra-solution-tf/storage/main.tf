# Standalone storage account deployment (mirrors infra-solution/storage.bicep).

data "azurerm_resource_group" "rg" {
  name = var.resource_group_name
}

resource "azurerm_storage_account" "sa" {
  name                            = var.storage_account_name
  resource_group_name             = data.azurerm_resource_group.rg.name
  location                        = var.location
  account_tier                    = split("_", var.sku_name)[0] == "Standard" ? "Standard" : "Premium"
  account_replication_type        = split("_", var.sku_name)[1]
  account_kind                    = "StorageV2"
  min_tls_version                 = "TLS1_2"
  allow_nested_items_to_be_public = var.allow_blob_public_access
  public_network_access_enabled   = var.public_network_access == "Enabled"
  # ALZ policy: key-based auth is denied on this subscription.
  shared_access_key_enabled       = false

  network_rules {
    default_action = var.public_network_access == "Disabled" ? "Deny" : "Allow"
    bypass         = ["AzureServices"]
  }
}

resource "azurerm_storage_container" "container" {
  name                  = var.container_name
  storage_account_id    = azurerm_storage_account.sa.id
  container_access_type = "private"
}

output "storage_account_id" {
  value = azurerm_storage_account.sa.id
}

output "storage_account_name" {
  value = azurerm_storage_account.sa.name
}

output "blob_endpoint" {
  value = azurerm_storage_account.sa.primary_blob_endpoint
}
