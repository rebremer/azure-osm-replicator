# Generic private endpoint to a target resource + DNS zone group.
# Mirrors infra-solution/modules/privateEndpoint.bicep.

variable "name" {
  description = "Private endpoint name."
  type        = string
}

variable "resource_group_name" {
  description = "RG hosting the PE."
  type        = string
}

variable "location" {
  description = "Azure region."
  type        = string
}

variable "subnet_id" {
  description = "PE subnet ID."
  type        = string
}

variable "target_resource_id" {
  description = "Target resource ID (e.g. storage account or PG flexible server)."
  type        = string
}

variable "group_id" {
  description = "Group ID for the PE (e.g. blob, postgresqlServer, vault)."
  type        = string
}

variable "private_dns_zone_id" {
  description = "Private DNS zone ID to register against."
  type        = string
}

resource "azurerm_private_endpoint" "pe" {
  name                = var.name
  location            = var.location
  resource_group_name = var.resource_group_name
  subnet_id           = var.subnet_id

  private_service_connection {
    name                           = var.group_id
    private_connection_resource_id = var.target_resource_id
    subresource_names              = [var.group_id]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "default"
    private_dns_zone_ids = [var.private_dns_zone_id]
  }
}

output "id" {
  value = azurerm_private_endpoint.pe.id
}
