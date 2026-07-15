#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# deploy.sh — Terraform port of infra-solution/deploy.sh.
#
# Mirrors the same 5-step order:
#   0. Resolve pre-existing network IDs from NETWORK_RG.
#   1. (Optional) Storage account              → storage/
#   2. (Optional) PostgreSQL Flexible Server   → postgres/
#   3. Workload stack (PEs + VM + KV + identity) → main/
#   4. Storage Blob Data Owner role RA         → storage_role_assignment/
#   5. Write PG password into Key Vault via `az vm run-command invoke`.
#
# Terraform state is stored per root module in that module's directory
# (local backend). Swap for a remote backend before using in shared envs.
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

# ── Resource groups ──
CORE_RG="${CORE_RG:-test-flosm-rg}"
CORE_LOCATION="${CORE_LOCATION:-westus3}"
NETWORK_RG="${NETWORK_RG:-test-network-rg}"
STORAGE_RG="${STORAGE_RG:-test-lakehouse-rg}"
PG_RG="${PG_RG:-test-database-rg}"
export LOCATION="${LOCATION:-${CORE_LOCATION}}"
export SUBSCRIPTION_ID="${SUBSCRIPTION_ID:-$(az account show --query id -o tsv)}"

# ── Globally-unique resource names ──
export STORAGE_ACCOUNT_NAME="${STORAGE_ACCOUNT_NAME:-testpubliclandingzone}"
export PG_SERVER_NAME="${PG_SERVER_NAME:-test-database-pg}"
export STORAGE_RG PG_RG CORE_RG

# ── Toggles ──
DEPLOY_STORAGE="${DEPLOY_STORAGE:-0}"
DEPLOY_PG="${DEPLOY_PG:-0}"
USE_SSH_KEY="${USE_SSH_KEY:-false}"

# ── Required secrets ──
if [ "${USE_SSH_KEY}" = "true" ]; then
    : "${SSH_PUBLIC_KEY:?Set SSH_PUBLIC_KEY (OpenSSH format) when USE_SSH_KEY=true}"
    VM_ADMIN_PASSWORD="${VM_ADMIN_PASSWORD:-}"
else
    : "${VM_ADMIN_PASSWORD:?Set VM_ADMIN_PASSWORD (or USE_SSH_KEY=true + SSH_PUBLIC_KEY)}"
    SSH_PUBLIC_KEY="${SSH_PUBLIC_KEY:-}"
fi
: "${PG_ADMIN_PASSWORD:?Set PG_ADMIN_PASSWORD (stored in Key Vault for osm2pgsql/psql)}"

# Built-in role: Storage Blob Data Owner
SBDO_ROLE_ID='b7e6dc6d-f1e8-4753-8033-0f276bb0955b'

echo "=== deploy.sh (terraform) ==="
echo "Core RG:       ${CORE_RG} (${CORE_LOCATION})"
echo "Network RG:    ${NETWORK_RG}"
echo "Storage RG:    ${STORAGE_RG}  (deploy=${DEPLOY_STORAGE})"
echo "PG RG:         ${PG_RG}       (deploy=${DEPLOY_PG})"

# ── Step 0: resolve pre-existing network IDs ──
if [ -z "${VNET_RESOURCE_ID:-}" ]; then
    echo ""
    echo "=== Step 0: discovering network IDs from ${NETWORK_RG} ==="
    NET_DEPLOY=$(az deployment group list -g "${NETWORK_RG}" \
        --query "[?starts_with(name, 'osm-network-')] | sort_by(@, &properties.timestamp) | [-1].name" \
        -o tsv 2>/dev/null || true)
    if [ -z "${NET_DEPLOY}" ]; then
        echo "ERROR: no osm-network-* deployment found in ${NETWORK_RG}." >&2
        echo "       Run infra-vnet/deploy-network.sh first, or export VNET_RESOURCE_ID" >&2
        echo "       + PE_SUBNET_ID + VM_SUBNET_ID to point at an existing VNet." >&2
        exit 1
    fi
    echo "Reading outputs from: ${NET_DEPLOY}"
    read_net_out() {
        az deployment group show -g "${NETWORK_RG}" -n "${NET_DEPLOY}" \
            --query "properties.outputs.$1.value" -o tsv
    }
    VNET_RESOURCE_ID=$(read_net_out vnetId)
    PE_SUBNET_ID=$(read_net_out peSubnetId)
    VM_SUBNET_ID=$(read_net_out vmSubnetId)
fi

: "${VNET_RESOURCE_ID:?}"
: "${PE_SUBNET_ID:?}"
: "${VM_SUBNET_ID:?}"

echo "  VNET_RESOURCE_ID = ${VNET_RESOURCE_ID}"
echo "  PE_SUBNET_ID     = ${PE_SUBNET_ID}"
echo "  VM_SUBNET_ID     = ${VM_SUBNET_ID}"

# Make sure the core RG exists (Terraform's azurerm_resource_group is
# managed in main/, but we pre-create it so step 3 can use the existing
# data source pattern without a chicken-and-egg on first apply).
az group create -n "${CORE_RG}" -l "${CORE_LOCATION}" --output none

# Env vars → TF_VAR_* passthrough. Terraform variables use snake_case.
export TF_VAR_subscription_id="${SUBSCRIPTION_ID}"
export TF_VAR_location="${LOCATION}"

# ── Step 1: storage account (optional) ──
if [ "${DEPLOY_STORAGE}" = "1" ]; then
    echo ""
    echo "=== Step 1: storage account ==="
    az group create -n "${STORAGE_RG}" -l "${CORE_LOCATION}" --output none
    (
        cd "${SCRIPT_DIR}/storage"
        TF_VAR_resource_group_name="${STORAGE_RG}" \
        TF_VAR_storage_account_name="${STORAGE_ACCOUNT_NAME}" \
            terraform init -input=false
        TF_VAR_resource_group_name="${STORAGE_RG}" \
        TF_VAR_storage_account_name="${STORAGE_ACCOUNT_NAME}" \
            terraform apply -auto-approve -input=false
    )
fi

# ── Step 2: PostgreSQL (optional) ──
if [ "${DEPLOY_PG}" = "1" ]; then
    echo ""
    echo "=== Step 2: PostgreSQL flexible server ==="
    az group create -n "${PG_RG}" -l "${CORE_LOCATION}" --output none
    (
        cd "${SCRIPT_DIR}/postgres"
        TF_VAR_resource_group_name="${PG_RG}" \
        TF_VAR_server_name="${PG_SERVER_NAME}" \
        TF_VAR_admin_password="${PG_ADMIN_PASSWORD}" \
            terraform init -input=false

        # PG-flex RP frequently returns transient InternalServerError
        # (5xx) on create. Retry the apply up to PG_MAX_ATTEMPTS times
        # with a back-off. Between attempts, delete any half-created
        # ghost server that the failed create might have left behind so
        # the next attempt starts from a clean slate.
        PG_MAX_ATTEMPTS="${PG_MAX_ATTEMPTS:-3}"
        PG_ATTEMPT=1
        while : ; do
            if TF_VAR_resource_group_name="${PG_RG}" \
               TF_VAR_server_name="${PG_SERVER_NAME}" \
               TF_VAR_admin_password="${PG_ADMIN_PASSWORD}" \
               terraform apply -auto-approve -input=false ; then
                break
            fi
            if [ "${PG_ATTEMPT}" -ge "${PG_MAX_ATTEMPTS}" ]; then
                echo "PG apply failed after ${PG_MAX_ATTEMPTS} attempts — giving up." >&2
                exit 1
            fi
            SLEEP_SEC=$((60 * PG_ATTEMPT))
            echo "PG apply failed (attempt ${PG_ATTEMPT}/${PG_MAX_ATTEMPTS})." >&2
            echo "  Deleting any ghost server, then retrying in ${SLEEP_SEC}s..." >&2
            az postgres flexible-server delete \
                -g "${PG_RG}" -n "${PG_SERVER_NAME}" --yes 2>/dev/null || true
            # Also drop any partial state entry so the next apply re-creates cleanly.
            terraform state rm azurerm_postgresql_flexible_server.pg 2>/dev/null || true
            terraform state rm azurerm_postgresql_flexible_server_configuration.extensions 2>/dev/null || true
            terraform state rm azurerm_postgresql_flexible_server_configuration.max_wal_size 2>/dev/null || true
            terraform state rm azurerm_postgresql_flexible_server_configuration.max_par_maint 2>/dev/null || true
            terraform state rm azurerm_postgresql_flexible_server_database.db 2>/dev/null || true
            sleep "${SLEEP_SEC}"
            PG_ATTEMPT=$((PG_ATTEMPT + 1))
        done
    )
fi

# ── Step 3: workload stack (PEs + VM + KV) ──
echo ""
echo "=== Step 3: workload stack (PEs + VM + KV) ==="
ASSIGN_ROLES="${ASSIGN_ROLES:-1}"
case "${ASSIGN_ROLES}" in
    1|true|TRUE|True)    ASSIGN_ROLES=1; ASSIGN_ROLES_TF=true ;;
    0|false|FALSE|False) ASSIGN_ROLES=0; ASSIGN_ROLES_TF=false ;;
    *) echo "ASSIGN_ROLES must be 1/0 or true/false" >&2; exit 1 ;;
esac

STORAGE_RID="/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${STORAGE_RG}/providers/Microsoft.Storage/storageAccounts/${STORAGE_ACCOUNT_NAME}"
PG_RID="/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${PG_RG}/providers/Microsoft.DBforPostgreSQL/flexibleServers/${PG_SERVER_NAME}"

(
    cd "${SCRIPT_DIR}/main"
    export TF_VAR_core_rg="${CORE_RG}"
    export TF_VAR_vnet_resource_id="${VNET_RESOURCE_ID}"
    export TF_VAR_pe_subnet_id="${PE_SUBNET_ID}"
    export TF_VAR_vm_subnet_id="${VM_SUBNET_ID}"
    export TF_VAR_storage_account_resource_id="${STORAGE_RID}"
    export TF_VAR_postgres_server_resource_id="${PG_RID}"
    export TF_VAR_use_ssh_key="${USE_SSH_KEY}"
    export TF_VAR_ssh_public_key="${SSH_PUBLIC_KEY}"
    export TF_VAR_admin_password="${VM_ADMIN_PASSWORD}"
    export TF_VAR_key_vault_public_network_access="${KV_PUBLIC_NETWORK_ACCESS:-Disabled}"
    export TF_VAR_enable_public_ip="${ENABLE_PUBLIC_IP:-true}"
    export TF_VAR_assign_vm_identity_kv_role="${ASSIGN_ROLES_TF}"
    export TF_VAR_key_vault_enable_purge_protection="${KV_ENABLE_PURGE_PROTECTION:-true}"
    export TF_VAR_pg_admin_login="${PG_ADMIN_LOGIN:-osmuser}"
    # Bump KV_NAME_PREFIX (default osm-updater-kv2) when a prior KV
    # with the same deterministic name is still soft-deleted and blocks
    # re-use of the name.
    export TF_VAR_key_vault_name_prefix="${KV_NAME_PREFIX:-osm-updater-kv2}"

    terraform init -input=false
    terraform apply -auto-approve -input=false
)

# Pull outputs from main/ state.
read_main_out() {
    terraform -chdir="${SCRIPT_DIR}/main" output -raw "$1"
}
MI_PRINCIPAL_ID=$(read_main_out managed_identity_principal_id)
MI_CLIENT_ID=$(read_main_out managed_identity_client_id)
VM_PIP=$(read_main_out vm_public_ip || echo "")
VM_PRIVATE_IP=$(read_main_out vm_private_ip)
VM_NAME_OUT=$(read_main_out vm_name)
KV_NAME=$(read_main_out key_vault_name)
KV_URI=$(read_main_out key_vault_uri)
PG_SECRET_NAME=$(read_main_out pg_secret_name)

# ── Step 4: storage role assignment for the VM identity ──
if [ "${ASSIGN_ROLES}" = "1" ]; then
    echo ""
    echo "=== Step 4: Storage Blob Data Owner for VM identity ==="
    (
        cd "${SCRIPT_DIR}/storage_role_assignment"
        TF_VAR_resource_group_name="${STORAGE_RG}" \
        TF_VAR_storage_account_name="${STORAGE_ACCOUNT_NAME}" \
        TF_VAR_principal_id="${MI_PRINCIPAL_ID}" \
        TF_VAR_role_definition_id="${SBDO_ROLE_ID}" \
            terraform init -input=false
        TF_VAR_resource_group_name="${STORAGE_RG}" \
        TF_VAR_storage_account_name="${STORAGE_ACCOUNT_NAME}" \
        TF_VAR_principal_id="${MI_PRINCIPAL_ID}" \
        TF_VAR_role_definition_id="${SBDO_ROLE_ID}" \
            terraform apply -auto-approve -input=false
    )
else
    echo ""
    echo "=== Step 4: SKIPPED (ASSIGN_ROLES=0) ==="
    echo "  Manually grant 'Storage Blob Data Owner' on ${STORAGE_ACCOUNT_NAME}"
    echo "  and 'Key Vault Secrets Officer' on ${KV_NAME}"
    echo "  to principal ${MI_PRINCIPAL_ID}."
fi

# ── Step 5: write PG password into Key Vault from inside the VM ──
echo ""
echo "=== Step 5: writing ${PG_SECRET_NAME} to ${KV_NAME} via az vm run-command ==="

PG_SECRET_EXP_DAYS="${PG_SECRET_EXP_DAYS:-90}"
PG_SECRET_CONTENT_TYPE="${PG_SECRET_CONTENT_TYPE:-text/plain}"
PG_SECRET_EXP_UNIX=$(date -u -d "+${PG_SECRET_EXP_DAYS} days" +%s)
REMOTE_SCRIPT=$(cat <<EOS
set -eu
TOKEN=\$(curl -sS -H Metadata:true \
  "http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=https%3A%2F%2Fvault.azure.net&client_id=${MI_CLIENT_ID}" \
  | python3 -c 'import sys,json;print(json.load(sys.stdin)["access_token"])')
BODY=\$(python3 -c 'import json,sys;print(json.dumps({"value": sys.argv[1], "contentType": sys.argv[3], "attributes": {"exp": int(sys.argv[2])}}))' '${PG_ADMIN_PASSWORD}' '${PG_SECRET_EXP_UNIX}' '${PG_SECRET_CONTENT_TYPE}')
HTTP=\$(curl -sS -o /tmp/kv_resp -w '%{http_code}' -X PUT \
  -H "Authorization: Bearer \$TOKEN" -H "Content-Type: application/json" \
  -d "\$BODY" \
  "https://${KV_NAME}.vault.azure.net/secrets/${PG_SECRET_NAME}?api-version=7.4")
if [ "\$HTTP" != "200" ]; then
    echo "ERROR: KV PUT returned \$HTTP" >&2
    cat /tmp/kv_resp >&2
    rm -f /tmp/kv_resp
    exit 1
fi
rm -f /tmp/kv_resp
echo "Secret ${PG_SECRET_NAME} written to ${KV_NAME}."
EOS
)

KV_PUSH_ATTEMPT=1
KV_PUSH_MAX=5
KV_PUSH_OK=0
while [ "${KV_PUSH_ATTEMPT}" -le "${KV_PUSH_MAX}" ]; do
    KV_PUSH_MSG=$(az vm run-command invoke \
        --resource-group "${CORE_RG}" \
        --name "${VM_NAME_OUT:-osm-import-vm}" \
        --command-id RunShellScript \
        --scripts "${REMOTE_SCRIPT}" \
        --query "value[0].message" -o tsv 2>&1 || true)
    printf '%s\n' "${KV_PUSH_MSG}"
    if printf '%s' "${KV_PUSH_MSG}" | grep -q "Secret ${PG_SECRET_NAME} written to ${KV_NAME}."; then
        KV_PUSH_OK=1
        break
    fi
    echo "  attempt ${KV_PUSH_ATTEMPT}/${KV_PUSH_MAX} did not confirm success; retrying in 20s (likely RBAC propagation)..."
    KV_PUSH_ATTEMPT=$((KV_PUSH_ATTEMPT + 1))
    sleep 20
done
if [ "${KV_PUSH_OK}" != "1" ]; then
    echo "ERROR: failed to write ${PG_SECRET_NAME} to ${KV_NAME} after ${KV_PUSH_MAX} attempts." >&2
    exit 1
fi

echo ""
echo "=== Done ==="
echo "VM private IP:                 ${VM_PRIVATE_IP}"
echo "VM public IP:                  ${VM_PIP:-<none — reach VM via VPN over the VNet>}"
echo "Managed identity client id:    ${MI_CLIENT_ID}"
echo "Managed identity principal id: ${MI_PRINCIPAL_ID}"
echo "Key Vault:                     ${KV_NAME} (${KV_URI})"
echo "PG password secret:            ${PG_SECRET_NAME}"

SSH_USER="${SSH_USER:-osmadmin}"
PG_FQDN="${PG_SERVER_NAME}.postgres.database.azure.com"

if [ -n "${VM_PIP}" ]; then
cat <<EOF

── Reach the VM over its public IP (default; ENABLE_PUBLIC_IP=true) ──
ssh -i ~/osm-vm-key ${SSH_USER}@${VM_PIP}
EOF
else
cat <<EOF

── No public IP; reach the VM over your VNet (VPN / peering) ──
ssh -i ~/osm-vm-key ${SSH_USER}@${VM_PRIVATE_IP}
EOF
fi

cat <<EOF

── Run on the VM ──────────────────────────────────────────────
./init-osm.sh
# then on a timer: ./update-osm.sh
EOF
