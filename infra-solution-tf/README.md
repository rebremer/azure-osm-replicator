# infra-solution-tf — Terraform port of `infra-solution/`

Terraform equivalent of the Bicep stack in `../infra-solution/`. Deploys the
same workload — Log Analytics, User-Assigned Managed Identity, VM (with
data disk + optional Standard PIP), Key Vault, and private endpoints to
storage + PostgreSQL + Key Vault — into `CORE_RG`, layered on top of the
network foundation from `../infra-vnet/`.

Shared assets (`init-osm.sh`, `update-osm.sh`, `cloud-init.yaml`) live in
`../infra-solution-shared/` and are consumed by both the Bicep and
Terraform stacks. The VM Custom Script extension reads them at plan
time — same pattern as `infra-solution/modules/vm.bicep`.

## Layout

```
infra-solution-shared/             # shared with Bicep
├── init-osm.sh
├── update-osm.sh
└── cloud-init.yaml

infra-solution-tf/
├── deploy.sh                      # orchestrator (mirrors infra-solution/deploy.sh)
├── README.md                      # this file
├── main/                          # workload stack   (mirrors main.bicep)
│   ├── main.tf
│   ├── variables.tf
│   ├── outputs.tf
│   └── providers.tf
├── storage/                       # standalone SA    (mirrors storage.bicep)
├── postgres/                      # standalone PG    (mirrors postgres.bicep)
├── storage_role_assignment/       # step 4 role RA   (mirrors storageRoleAssignment.bicep)
└── modules/
    ├── key_vault/
    ├── logs/
    ├── private_dns_zone/
    ├── private_endpoint/
    └── vm/
```

Each of `main/`, `storage/`, `postgres/`, `storage_role_assignment/` is a
root module with its own state file — same "one deployment per Bicep file"
model. Configure a remote backend per environment if you don't want local
state.

## Prerequisites

- Terraform ≥ 1.6
- `azurerm` provider 4.x (pinned in each `providers.tf`)
- Azure CLI logged in: `az login --tenant <TID>` and
  `az account set --subscription <SID>`
- Network foundation deployed via `../infra-vnet/deploy-network.sh` (or
  bring your own VNet + subnets and export their IDs)

## Deploy

The one-shot equivalent of `infra-solution/deploy.sh`:

```bash
export CORE_RG=test-osm-solution-rg
export NETWORK_RG=test-osm-netwerk-rg
export LOCATION=westus3

# Secrets (never commit these)
export VM_ADMIN_PASSWORD='...'     # OR: USE_SSH_KEY=true SSH_PUBLIC_KEY='ssh-rsa ...'
export PG_ADMIN_PASSWORD='...'

# Optional: also create the storage account / PG server from scratch
# export DEPLOY_STORAGE=1
# export DEPLOY_PG=1

bash infra-solution-tf/deploy.sh
```

`deploy.sh` runs, in order:

1. Discover `VNET_RESOURCE_ID`, `PE_SUBNET_ID`, `VM_SUBNET_ID` from the
   latest `osm-network-*` deployment in `NETWORK_RG` (unless already set).
2. (Optional, `DEPLOY_STORAGE=1`) `terraform -chdir=storage init/apply`.
3. (Optional, `DEPLOY_PG=1`)      `terraform -chdir=postgres init/apply`.
4. `terraform -chdir=main init/apply` — the workload stack.
5. (Unless `ASSIGN_ROLES=0`) `terraform -chdir=storage_role_assignment
   init/apply` — grants Storage Blob Data Owner on the SA to the VM
   identity.
6. Writes the PG password into Key Vault via `az vm run-command invoke`,
   same as the Bicep flow. This step is shell logic and lives in
   `deploy.sh`.

## Manual Terraform commands

If you don't want the orchestrator:

```bash
cd infra-solution-tf/main
export TF_VAR_subscription_id=$(az account show --query id -o tsv)
export TF_VAR_core_rg=test-osm-solution-rg
export TF_VAR_location=westus3
export TF_VAR_vnet_resource_id=...
export TF_VAR_pe_subnet_id=...
export TF_VAR_vm_subnet_id=...
export TF_VAR_storage_account_resource_id=/subscriptions/.../storageAccounts/testpubliclandingzone
export TF_VAR_postgres_server_resource_id=/subscriptions/.../flexibleServers/test-database-pg
export TF_VAR_admin_password='...'
terraform init
terraform plan
terraform apply
```

All `TF_VAR_*` names match the environment variables `deploy.sh` sets, so
you can `source` an env file and run either path.

## Differences vs the Bicep version

| Concern                        | Bicep                          | Terraform (this folder) |
|--------------------------------|--------------------------------|-------------------------|
| Deterministic KV suffix        | `uniqueString(sub, rg.id)`     | `substr(md5(...), 0, 6)` |
| VM extension `forceUpdateTag`  | `uniqueString(...)`            | sha256 hash in `settings` (triggers update on script change) |
| `readEnvironmentVariable(...)` | direct in `.bicepparam`        | `TF_VAR_*` env vars     |
| Cross-file state               | ARM deployments per RG         | one Terraform state per root module (`main/`, `storage/`, `postgres/`, `storage_role_assignment/`) |

The resulting Azure resources are equivalent.

## Teardown

```bash
terraform -chdir=infra-solution-tf/main destroy
# and optionally:
terraform -chdir=infra-solution-tf/storage_role_assignment destroy
terraform -chdir=infra-solution-tf/postgres destroy
terraform -chdir=infra-solution-tf/storage destroy
```

If Key Vault purge protection is on (default), the vault will linger in
soft-deleted state for 7 days. Set
`TF_VAR_key_vault_enable_purge_protection=false` in disposable envs so
`az keyvault purge` can reclaim the name immediately.
