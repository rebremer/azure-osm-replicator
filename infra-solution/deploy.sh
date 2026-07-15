#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# deploy.sh — workload stack for the OSM updater.
#
# PREREQUISITE: run infra-vnet/deploy-network.sh first (or point NETWORK_RG
# at an existing network RG whose latest osm-network-* deployment
# exports the resource IDs consumed here). Alternatively export the
# 3 VNET_/PE_/VM_ subnet ID env vars yourself to attach to a
# pre-existing VNet you own. Private DNS zones are created HERE in
# CORE_RG, not consumed from NETWORK_RG.
#
# Order:
#   0. Resolve pre-existing network IDs (VNet + subnets + DNS zones)
#   1. (Optional) Storage account              → STORAGE_RG
#   2. (Optional) PostgreSQL Flexible Server   → PG_RG
#   3. Workload stack (PEs + VM + KV + identity) → CORE_RG
#   4. Storage Blob Data Owner role on the
#      storage account for the VM identity     → STORAGE_RG
#
# Steps 1 and 2 are guarded by DEPLOY_STORAGE / DEPLOY_PG so you can
# re-run step 3+4 on existing storage / PG (the production case).
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

# ── Resource groups ──
CORE_RG="${CORE_RG:-test-flosm-rg}"
CORE_LOCATION="${CORE_LOCATION:-westus3}"
# Network RG holds the VNet + subnets + NAT GW + private DNS zones
# (deployed by deploy-network.sh). When set, this script auto-discovers
# the resource IDs from its latest osm-network-* deployment.
NETWORK_RG="${NETWORK_RG:-test-network-rg}"
# When deploying greenfield into a single RG, set STORAGE_RG=PG_RG=CORE_RG.
STORAGE_RG="${STORAGE_RG:-test-lakehouse-rg}"
PG_RG="${PG_RG:-test-database-rg}"
# Region for all *.bicepparam files (consumed via readEnvironmentVariable).
export LOCATION="${LOCATION:-${CORE_LOCATION}}"
# Subscription used to build cross-RG resource IDs in main.bicepparam.
export SUBSCRIPTION_ID="${SUBSCRIPTION_ID:-$(az account show --query id -o tsv)}"

# ── Globally-unique resource names ──
# Storage account: 3-24 lowercase. PG server: globally unique DNS name.
export STORAGE_ACCOUNT_NAME="${STORAGE_ACCOUNT_NAME:-testpubliclandingzone}"
export PG_SERVER_NAME="${PG_SERVER_NAME:-test-database-pg}"

# Make derived vars visible to nested az calls / bicep readEnvironmentVariable.
export STORAGE_RG PG_RG

# ── Toggles ──
DEPLOY_STORAGE="${DEPLOY_STORAGE:-0}"
DEPLOY_PG="${DEPLOY_PG:-0}"
# Set USE_SSH_KEY=true to provision the VM with an SSH public key and
# disable password authentication. When true, SSH_PUBLIC_KEY must be set.
USE_SSH_KEY="${USE_SSH_KEY:-false}"

# ── Required secrets ──
if [ "${USE_SSH_KEY}" = "true" ]; then
    : "${SSH_PUBLIC_KEY:?Set SSH_PUBLIC_KEY (OpenSSH format) when USE_SSH_KEY=true}"
    VM_ADMIN_PASSWORD="${VM_ADMIN_PASSWORD:-}"   # ignored, but bicep param needs a value
else
    : "${VM_ADMIN_PASSWORD:?Set VM_ADMIN_PASSWORD before running (or set USE_SSH_KEY=true + SSH_PUBLIC_KEY)}"
    SSH_PUBLIC_KEY="${SSH_PUBLIC_KEY:-}"
fi
# PG password is always required: it is stored as a Key Vault secret
# consumed at runtime by init-osm.sh / update-osm.sh.
: "${PG_ADMIN_PASSWORD:?Set PG_ADMIN_PASSWORD (stored in Key Vault for osm2pgsql/psql)}"

# Built-in role: Storage Blob Data Owner
SBDO_ROLE_ID='b7e6dc6d-f1e8-4753-8033-0f276bb0955b'

echo "=== deploy.sh ==="
echo "Core RG:       ${CORE_RG} (${CORE_LOCATION})"
echo "Network RG:    ${NETWORK_RG}"
echo "Storage RG:    ${STORAGE_RG}  (deploy=${DEPLOY_STORAGE})"
echo "PG RG:         ${PG_RG}       (deploy=${DEPLOY_PG})"

# Make sure the core RG exists.
az group create -n "${CORE_RG}" -l "${CORE_LOCATION}" --output none

# ── Step 0: resolve pre-existing network resource IDs ──
# Priority:
#   1. If VNET_RESOURCE_ID is already set, trust the caller and require
#      the subnet IDs to be present (BYO existing VNet).
#   2. Otherwise, discover the latest osm-network-* deployment in
#      NETWORK_RG and pull the outputs.
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

: "${VNET_RESOURCE_ID:?Set VNET_RESOURCE_ID (or run deploy-network.sh first).}"
: "${PE_SUBNET_ID:?Set PE_SUBNET_ID}"
: "${VM_SUBNET_ID:?Set VM_SUBNET_ID}"

export VNET_RESOURCE_ID PE_SUBNET_ID VM_SUBNET_ID

echo "  VNET_RESOURCE_ID = ${VNET_RESOURCE_ID}"
echo "  PE_SUBNET_ID     = ${PE_SUBNET_ID}"
echo "  VM_SUBNET_ID     = ${VM_SUBNET_ID}"

# ── Step 1: storage account (optional) ──
if [ "${DEPLOY_STORAGE}" = "1" ]; then
    echo ""
    echo "=== Step 1: storage account ==="
    az group create -n "${STORAGE_RG}" -l "${CORE_LOCATION}" --output none
    az deployment group create \
        --resource-group "${STORAGE_RG}" \
        --name "osm-storage-$(date +%Y%m%d-%H%M%S)" \
        --template-file infra-solution/storage.bicep \
        --parameters infra-solution/storage.bicepparam \
        --output none
fi

# ── Step 2: PostgreSQL (optional) ──
if [ "${DEPLOY_PG}" = "1" ]; then
    echo ""
    echo "=== Step 2: PostgreSQL flexible server ==="
    az group create -n "${PG_RG}" -l "${CORE_LOCATION}" --output none
    PG_ADMIN_PASSWORD="${PG_ADMIN_PASSWORD}" \
    az deployment group create \
        --resource-group "${PG_RG}" \
        --name "osm-pg-$(date +%Y%m%d-%H%M%S)" \
        --template-file infra-solution/postgres.bicep \
        --parameters infra-solution/postgres.bicepparam \
        --output none
fi

# ── Step 3: workload stack (PEs + VM + KV) ──
echo ""
echo "=== Step 3: workload stack (PEs + VM + KV) ==="
# Normalize ASSIGN_ROLES (default 1/true). 0/false skips both the KV
# role assignment (in main.bicep) and the storage role assignment (in
# Step 4) — use when the deploying principal lacks
# Microsoft.Authorization/roleAssignments/write.
ASSIGN_ROLES="${ASSIGN_ROLES:-1}"
case "${ASSIGN_ROLES}" in
    1|true|TRUE|True)    ASSIGN_ROLES=1; ASSIGN_ROLES_BICEP=true ;;
    0|false|FALSE|False) ASSIGN_ROLES=0; ASSIGN_ROLES_BICEP=false ;;
    *) echo "ASSIGN_ROLES must be 1/0 or true/false" >&2; exit 1 ;;
esac

DEPLOY_NAME="osm-core-$(date +%Y%m%d-%H%M%S)"
USE_SSH_KEY="${USE_SSH_KEY}" \
SSH_PUBLIC_KEY="${SSH_PUBLIC_KEY}" \
VM_ADMIN_PASSWORD="${VM_ADMIN_PASSWORD}" \
KV_PUBLIC_NETWORK_ACCESS="${KV_PUBLIC_NETWORK_ACCESS:-Disabled}" \
ENABLE_PUBLIC_IP="${ENABLE_PUBLIC_IP:-true}" \
AUTOSHUTDOWN_ENABLED="${AUTOSHUTDOWN_ENABLED:-true}" \
AUTOSHUTDOWN_TIME="${AUTOSHUTDOWN_TIME:-0300}" \
AUTOSHUTDOWN_TIMEZONE="${AUTOSHUTDOWN_TIMEZONE:-W. Europe Standard Time}" \
ASSIGN_ROLES="${ASSIGN_ROLES_BICEP}" \
az deployment group create \
    --resource-group "${CORE_RG}" \
    --name "${DEPLOY_NAME}" \
    --template-file infra-solution/main.bicep \
    --parameters infra-solution/main.bicepparam \
    --output none

# Pull outputs we need for the role assignment.
MI_PRINCIPAL_ID=$(az deployment group show -g "${CORE_RG}" -n "${DEPLOY_NAME}" \
    --query "properties.outputs.managedIdentityPrincipalId.value" -o tsv)
MI_CLIENT_ID=$(az deployment group show -g "${CORE_RG}" -n "${DEPLOY_NAME}" \
    --query "properties.outputs.managedIdentityClientId.value" -o tsv)
VM_PIP=$(az deployment group show -g "${CORE_RG}" -n "${DEPLOY_NAME}" \
    --query "properties.outputs.vmPublicIp.value" -o tsv)
VM_PRIVATE_IP=$(az deployment group show -g "${CORE_RG}" -n "${DEPLOY_NAME}" \
    --query "properties.outputs.vmPrivateIp.value" -o tsv)
VM_NAME_OUT=$(az deployment group show -g "${CORE_RG}" -n "${DEPLOY_NAME}" \
    --query "properties.outputs.vmName.value" -o tsv)
KV_NAME=$(az deployment group show -g "${CORE_RG}" -n "${DEPLOY_NAME}" \
    --query "properties.outputs.keyVaultName.value" -o tsv)
KV_URI=$(az deployment group show -g "${CORE_RG}" -n "${DEPLOY_NAME}" \
    --query "properties.outputs.keyVaultUri.value" -o tsv)
PG_SECRET_NAME=$(az deployment group show -g "${CORE_RG}" -n "${DEPLOY_NAME}" \
    --query "properties.outputs.pgSecretName.value" -o tsv)

# ── Step 4: storage role assignment for the VM identity ──
# Skipped automatically when ASSIGN_ROLES=0 (see Step 3 normalization).
if [ "${ASSIGN_ROLES}" = "1" ]; then
    echo ""
    echo "=== Step 4: Storage Blob Data Owner for VM identity ==="
    az deployment group create \
        --resource-group "${STORAGE_RG}" \
        --name "osm-storage-ra-$(date +%Y%m%d-%H%M%S)" \
        --template-file infra-solution/modules/storageRoleAssignment.bicep \
        --parameters \
            storageAccountName="${STORAGE_ACCOUNT_NAME}" \
            principalId="${MI_PRINCIPAL_ID}" \
            roleDefinitionId="${SBDO_ROLE_ID}" \
            principalType=ServicePrincipal \
        --output none
else
    echo ""
    echo "=== Step 4: SKIPPED (ASSIGN_ROLES=0) ==="
    echo "  Manually grant 'Storage Blob Data Owner' on ${STORAGE_ACCOUNT_NAME}"
    echo "  and 'Key Vault Secrets Officer' on ${KV_NAME}"
    echo "  to principal ${MI_PRINCIPAL_ID}."
fi

# ── Step 5: write PG password into Key Vault from inside the VM ──
# KV has publicNetworkAccess=Disabled (ALZ policy). Whether or not the
# VM has a public IP, `az vm run-command invoke` goes through the ARM
# control plane (no inbound network needed) to run a small script on
# the VM. The VM has the Secrets Officer role on the KV, so it can PUT
# the secret via IMDS+curl over the KV private endpoint.
echo ""
echo "=== Step 5: writing ${PG_SECRET_NAME} to ${KV_NAME} via az vm run-command ==="

# Build the remote script. The PG password is interpolated into a
# single-use script string sent to the VM control-plane endpoint;
# it does not land on disk and is not visible in the VM process
# list (run-command writes the script to a temp file and executes
# it server-side, then deletes it).
#
# ALZ guardrails Enforce-GR-KeyVault require:
#   - "Secrets should have the specified maximum validity period"
#     → secret must have an exp <= maxValidityInDays from now (cap is
#     90 days in this env).
#   - "Secrets should have content type set" → contentType must be
#     non-empty.
PG_SECRET_EXP_DAYS="${PG_SECRET_EXP_DAYS:-90}"
PG_SECRET_CONTENT_TYPE="${PG_SECRET_CONTENT_TYPE:-text/plain}"
PG_SECRET_EXP_UNIX=$(date -u -d "+${PG_SECRET_EXP_DAYS} days" +%s)
REMOTE_SCRIPT=$(cat <<EOS
# az vm run-command RunShellScript executes via /bin/sh (dash on
# Ubuntu), which does NOT support 'set -o pipefail'. Stick to POSIX.
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

# `az vm run-command invoke` returns exit 0 even when the inner script
# exit 1'd — we have to parse the message ourselves. Also retry a few
# times because the KV Secrets Officer role assignment can take
# 30–90s to propagate globally after deploy Step 3.
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
    echo "       See the messages above for the HTTP status returned by KV." >&2
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
echo ""
SSH_USER="${SSH_USER:-osmadmin}"
PG_FQDN="${PG_SERVER_NAME}.postgres.database.azure.com"

if [ -n "${VM_PIP}" ]; then
cat <<EOF
── Reach the VM over its public IP (default; ENABLE_PUBLIC_IP=true) ──
# init-osm.sh and update-osm.sh are already installed in ~${SSH_USER}
# by the CustomScript extension on the VM (see infra-solution/modules/vm.bicep).

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
# The VM's /etc/profile.d/osm-env.sh (written by the CustomScript
# extension in infra-solution/modules/vm.bicep) already exports:
#   UAI_CLIENT_ID=${MI_CLIENT_ID}
#   KEY_VAULT_NAME=${KV_NAME}
#   PG_PASSWORD_SECRET_NAME=${PG_SECRET_NAME}
#   PGHOST=${PG_FQDN}
#   PGUSER=${PG_ADMIN_LOGIN:-osmuser}
#   PGDATABASE=osm
#   STORAGE_ACCOUNT=${STORAGE_ACCOUNT_NAME}
#   CONTAINER_NAME=osmscanning
# so a fresh SSH shell can just run:

./init-osm.sh
# then on a timer: ./update-osm.sh
EOF
