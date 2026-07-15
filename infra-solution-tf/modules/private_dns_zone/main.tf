# Private DNS zone + VNet link.
# Mirrors infra-solution/modules/privateDnsZone.bicep.

variable "zone_name" {
  description = "Zone name, e.g. privatelink.blob.core.windows.net"
  type        = string
}

variable "resource_group_name" {
  description = "RG hosting the DNS zone."
  type        = string
}

variable "vnet_id" {
  description = "VNet ID to link."
  type        = string
}

variable "link_name" {
  description = "Link name."
  type        = string
}

resource "azurerm_private_dns_zone" "zone" {
  name                = var.zone_name
  resource_group_name = var.resource_group_name
}

resource "azurerm_private_dns_zone_virtual_network_link" "link" {
  name                  = var.link_name
  resource_group_name   = var.resource_group_name
  private_dns_zone_name = azurerm_private_dns_zone.zone.name
  virtual_network_id    = var.vnet_id
  registration_enabled  = false
}

output "zone_id" {
  value = azurerm_private_dns_zone.zone.id
}

output "zone_name" {
  value = azurerm_private_dns_zone.zone.name
}
