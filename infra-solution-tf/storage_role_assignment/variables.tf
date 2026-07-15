# Cross-RG role assignment on an existing storage account.
# Mirrors infra-solution/modules/storageRoleAssignment.bicep, hoisted
# to its own root module so `deploy.sh` step 4 can plan/apply just this
# assignment (same shape as the Bicep flow).

variable "subscription_id" {
  type = string
}

variable "resource_group_name" {
  description = "RG that hosts the storage account."
  type        = string
}

variable "storage_account_name" {
  type = string
}

variable "principal_id" {
  description = "Principal ID (UAMI, SP, group, user) to grant."
  type        = string
}

variable "role_definition_id" {
  description = "Role definition GUID, e.g. b7e6dc6d-f1e8-4753-8033-0f276bb0955b (Storage Blob Data Owner)."
  type        = string
}

variable "principal_type" {
  type    = string
  default = "ServicePrincipal"
}
