terraform {
  required_version = ">= 1.6"
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
  }
}

provider "azurerm" {
  features {}
  subscription_id = var.subscription_id
  # ALZ policy on this subscription forbids shared-key data-plane auth.
  # Force the provider to use the caller's AAD identity for all
  # data-plane calls (post-create blob-service poll, container CRUD).
  storage_use_azuread = true
}
