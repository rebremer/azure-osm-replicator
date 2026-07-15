data "azurerm_storage_account" "sa" {
  name                = var.storage_account_name
  resource_group_name = var.resource_group_name
}

resource "azurerm_role_assignment" "ra" {
  scope              = data.azurerm_storage_account.sa.id
  role_definition_id = "/subscriptions/${var.subscription_id}/providers/Microsoft.Authorization/roleDefinitions/${var.role_definition_id}"
  principal_id       = var.principal_id
  principal_type     = var.principal_type
}

output "role_assignment_id" {
  value = azurerm_role_assignment.ra.id
}
