#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# nuke-logging.sh — remove everything deploy-logging.sh created.
#
# Removes (in reverse order):
#   1. DCR ↔ VM association
#   2. Data Collection Rule
#   3. AzureMonitorLinuxAgent VM extension
#
# Leaves alone:
#   - The Log Analytics workspace (owned by the workload deployment)
#   - The system-assigned managed identity on the VM (harmless; may be
#     used by other things you add later)
#   - The Microsoft.Insights RP registration (subscription-wide)
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

CORE_RG="${CORE_RG:-test-flosm-rg}"
VM_NAME="${VM_NAME:-osm-import-vm}"
DCR_NAME="${DCR_NAME:-osm-syslog-dcr}"
DCRA_NAME="${DCRA_NAME:-osm-syslog-dcra}"
SUBSCRIPTION_ID="${SUBSCRIPTION_ID:-$(az account show --query id -o tsv)}"

echo "=== logging-solution nuke ==="
echo "  Subscription : ${SUBSCRIPTION_ID}"
echo "  RG           : ${CORE_RG}"
echo "  VM           : ${VM_NAME}"
echo "  DCR          : ${DCR_NAME}"
echo "  DCR assoc    : ${DCRA_NAME}"
echo ""
read -r -p "Type 'nuke' to confirm teardown of the logging pipeline: " CONFIRM
if [ "${CONFIRM}" != "nuke" ]; then
    echo "Aborted." >&2
    exit 1
fi

VM_ID=$(az vm show -g "${CORE_RG}" -n "${VM_NAME}" --query id -o tsv 2>/dev/null || true)

# ── 1. Delete the DCR association (child of the VM) ──────────────────────────
if [ -n "${VM_ID}" ]; then
    echo ""
    echo "=== Step 1: Delete DCR association ${DCRA_NAME} ==="
    DCRA_URL="https://management.azure.com${VM_ID}/providers/Microsoft.Insights/dataCollectionRuleAssociations/${DCRA_NAME}?api-version=2022-06-01"
    az rest --method delete --url "${DCRA_URL}" --output none 2>/dev/null || \
        echo "  Association not found — skipping."
else
    echo "  VM not found — skipping association delete."
fi

# ── 2. Delete the DCR ────────────────────────────────────────────────────────
echo ""
echo "=== Step 2: Delete DCR ${DCR_NAME} ==="
if az monitor data-collection rule show -g "${CORE_RG}" -n "${DCR_NAME}" >/dev/null 2>&1; then
    az monitor data-collection rule delete -g "${CORE_RG}" -n "${DCR_NAME}" --yes --output none
    echo "  Deleted."
else
    echo "  DCR not found — skipping."
fi

# ── 3. Uninstall the AMA extension ───────────────────────────────────────────
echo ""
echo "=== Step 3: Uninstall AzureMonitorLinuxAgent from ${VM_NAME} ==="
if [ -n "${VM_ID}" ] && az vm extension show \
        -g "${CORE_RG}" --vm-name "${VM_NAME}" \
        --name AzureMonitorLinuxAgent >/dev/null 2>&1; then
    az vm extension delete \
        -g "${CORE_RG}" --vm-name "${VM_NAME}" \
        --name AzureMonitorLinuxAgent --output none
    echo "  Deleted."
else
    echo "  Extension not present — skipping."
fi

echo ""
echo "=== Done ==="
