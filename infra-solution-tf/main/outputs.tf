output "vnet_resource_id" {
  value = var.vnet_resource_id
}

output "vm_public_ip" {
  value = module.vm.public_ip
}

output "vm_private_ip" {
  value = module.vm.private_ip
}

output "vm_name" {
  value = module.vm.vm_name
}

output "managed_identity_client_id" {
  value = module.vm.managed_identity_client_id
}

output "managed_identity_principal_id" {
  value = module.vm.managed_identity_principal_id
}

output "log_analytics_customer_id" {
  value = module.logs.customer_id
}

output "key_vault_name" {
  value = module.kv.key_vault_name
}

output "key_vault_uri" {
  value = module.kv.key_vault_uri
}

output "pg_secret_name" {
  value = module.kv.pg_secret_name
}

output "dns_blob_zone_id" {
  value = module.dns_blob.zone_id
}

output "dns_pg_zone_id" {
  value = module.dns_pg.zone_id
}

output "dns_kv_zone_id" {
  value = module.dns_kv.zone_id
}
