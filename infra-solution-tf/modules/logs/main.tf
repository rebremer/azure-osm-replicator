# Log Analytics workspace.
# Mirrors infra-solution/modules/logs.bicep.

variable "name" {
  description = "Workspace name."
  type        = string
}

variable "resource_group_name" {
  description = "RG."
  type        = string
}

variable "location" {
  description = "Azure region."
  type        = string
}

variable "retention_in_days" {
  description = "Retention days."
  type        = number
  default     = 30
}

resource "azurerm_log_analytics_workspace" "law" {
  name                = var.name
  location            = var.location
  resource_group_name = var.resource_group_name
  sku                 = "PerGB2018"
  retention_in_days   = var.retention_in_days
}

output "id" {
  value = azurerm_log_analytics_workspace.law.id
}

output "customer_id" {
  value = azurerm_log_analytics_workspace.law.workspace_id
}
