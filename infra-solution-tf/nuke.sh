#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# nuke.sh — full teardown of the Terraform stack. Does NOT redeploy.
#
# After this completes, run `bash infra-solution-tf/deploy.sh` yourself.
#
# Requires the same env vars as deploy.sh (source your commands file first):
#   CORE_RG, LOCATION, STORAGE_ACCOUNT_NAME, KV_NAME_PREFIX
#   (SUBSCRIPTION_ID falls back to `az account show --query id`)
#
# Steps:
#   1. Delete CORE_RG (contains everything the stack manages)
#   2. Wait until it's fully gone
#   3. Purge soft-deleted storage account so the name is reusable
#   4. Purge soft-deleted Key Vaults matching KV_NAME_PREFIX
#      (fails fast if purge protection blocks — bump KV_NAME_PREFIX
#       or set KV_ENABLE_PURGE_PROTECTION=false and rerun)
#   5. Wipe local Terraform state (all 4 root modules)
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

# ── Sanity checks on env ──
: "${CORE_RG:?Set CORE_RG (or source your commands file first)}"
: "${LOCATION:?Set LOCATION}"
: "${STORAGE_ACCOUNT_NAME:?Set STORAGE_ACCOUNT_NAME}"
: "${KV_NAME_PREFIX:=osm-updater-kv2}"
SUB="${SUBSCRIPTION_ID:-$(az account show --query id -o tsv)}"

echo "=== nuke ==="
echo "  Subscription : ${SUB}"
echo "  Core RG      : ${CORE_RG}  (${LOCATION})"
echo "  Storage acct : ${STORAGE_ACCOUNT_NAME}"
echo "  KV prefix    : ${KV_NAME_PREFIX}"
echo ""
read -r -p "Type 'nuke' to confirm full teardown: " CONFIRM
if [ "${CONFIRM}" != "nuke" ]; then
    echo "Aborted." >&2
    exit 1
fi

# ── 1. Delete the RG ──
echo ""
echo "=== Step 1: deleting RG ${CORE_RG} ==="
if [ "$(az group exists -n "${CORE_RG}")" = "true" ]; then
    az group delete -n "${CORE_RG}" --yes --no-wait
else
    echo "  RG doesn't exist — skipping."
fi

# ── 2. Wait for it to be gone ──
echo ""
echo "=== Step 2: waiting for ${CORE_RG} to be fully deleted ==="
while [ "$(az group exists -n "${CORE_RG}")" = "true" ]; do
    echo "  $(date +%T) still exists..."
    sleep 20
done
echo "  RG deleted."

# ── 3. Purge soft-deleted storage account ──
echo ""
echo "=== Step 3: purging soft-deleted storage account ${STORAGE_ACCOUNT_NAME} ==="
SA_URL="https://management.azure.com/subscriptions/${SUB}/providers/Microsoft.Storage/locations/${LOCATION}/deletedAccounts/${STORAGE_ACCOUNT_NAME}?api-version=2023-05-01"
# Retry once — sometimes there are two soft-delete records
for _ in 1 2; do
    if timeout 30 az rest --method delete --url "${SA_URL}" 2>/dev/null; then
        echo "  purged ${STORAGE_ACCOUNT_NAME}"
    else
        echo "  no soft-deleted ${STORAGE_ACCOUNT_NAME} to purge (or already purged)"
        break
    fi
done

# ── 4. Purge soft-deleted Key Vaults with the current prefix ──
echo ""
echo "=== Step 4: purging soft-deleted Key Vaults matching ${KV_NAME_PREFIX}-* ==="
KV_LIST=$(az keyvault list-deleted \
    --query "[?properties.location=='${LOCATION}' && starts_with(name, '${KV_NAME_PREFIX}-')].name" \
    -o tsv 2>/dev/null || true)
if [ -z "${KV_LIST}" ]; then
    echo "  no soft-deleted KVs found — skipping."
else
    for KV in ${KV_LIST}; do
        if timeout 60 az keyvault purge -n "${KV}" --location "${LOCATION}" 2>/dev/null; then
            echo "  purged KV ${KV}"
        else
            echo "  ${KV} — purge blocked (purge protection on) or timed out"
            echo "  → bump KV_NAME_PREFIX before running deploy.sh"
            echo "  → or set KV_ENABLE_PURGE_PROTECTION=false to make future teardowns purgeable"
            exit 1
        fi
    done
fi

# ── 5. Wipe local Terraform state ──
echo ""
echo "=== Step 5: wiping local TF state (all 4 root modules) ==="
for d in main storage_role_assignment postgres storage; do
    rm -rf "${SCRIPT_DIR}/${d}/.terraform" \
           "${SCRIPT_DIR}/${d}"/terraform.tfstate*
    echo "  wiped ${d}"
done

echo ""
echo "=== Done ==="
echo "Now run:  bash ${SCRIPT_DIR}/deploy.sh"
