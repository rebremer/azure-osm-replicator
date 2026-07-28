#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# deploy-logging.sh — wire the always-on VM into the Log Analytics workspace
# that infra-solution / infra-solution-tf already deploys, using pure az CLI
# (no Bicep, no Terraform).
#
# Design:
#   The update-osm service already writes every "=== Step N ===" line to
#   stdout/stderr. systemd captures that into journald, and Ubuntu's default
#   rsyslog config forwards journald messages into /var/log/syslog.
#
#   All we need on the Azure side is:
#     1. The Microsoft.Insights resource provider registered.
#     2. A system-assigned managed identity on the VM (AMA uses this by
#        default; the existing UAMI keeps working for KV/Storage in
#        update-osm.sh).
#     3. The AzureMonitorLinuxAgent VM extension installed.
#     4. A Data Collection Rule (DCR) that ingests syslog into the
#        workspace's built-in `Syslog` table.
#     5. A DCR ↔ VM association so AMA knows which rule to apply.
#
#   After that, no code change to update-osm.sh — its console output flows
#   syslog → AMA → workspace automatically.
#
# Requires:
#   - az CLI logged in to the same subscription as the workload
#   - The workload's VM + Log Analytics workspace already deployed
#
# Env overrides (defaults match infra-solution/main.bicepparam):
#   CORE_RG          resource group holding the VM + workspace
#   LOCATION         Azure region                              (default: westus3)
#   VM_NAME          VM to instrument                          (default: osm-import-vm)
#   LAW_NAME         Log Analytics workspace name              (default: osm-updater-logs)
#   DCR_NAME         Data Collection Rule name                 (default: osm-syslog-dcr)
#   DCRA_NAME        DCR association name                      (default: osm-syslog-dcra)
#   SUBSCRIPTION_ID  falls back to `az account show`
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

CORE_RG="${CORE_RG:-test-flosm-rg}"
LOCATION="${LOCATION:-westus3}"
VM_NAME="${VM_NAME:-osm-import-vm}"
LAW_NAME="${LAW_NAME:-osm-updater-logs}"
DCR_NAME="${DCR_NAME:-osm-syslog-dcr}"
DCRA_NAME="${DCRA_NAME:-osm-syslog-dcra}"
SUBSCRIPTION_ID="${SUBSCRIPTION_ID:-$(az account show --query id -o tsv)}"

echo "=== logging-solution deploy ==="
echo "  Subscription : ${SUBSCRIPTION_ID}"
echo "  RG           : ${CORE_RG}  (${LOCATION})"
echo "  VM           : ${VM_NAME}"
echo "  Workspace    : ${LAW_NAME}"
echo "  DCR          : ${DCR_NAME}"
echo "  DCR assoc    : ${DCRA_NAME}"
echo ""

# ── Preflight: resolve resource IDs (both must already exist) ────────────────
VM_ID=$(az vm show -g "${CORE_RG}" -n "${VM_NAME}" --query id -o tsv)
LAW_ID=$(az monitor log-analytics workspace show -g "${CORE_RG}" -n "${LAW_NAME}" --query id -o tsv)
echo "  VM ID  : ${VM_ID}"
echo "  LAW ID : ${LAW_ID}"

# ── 1. Register Microsoft.Insights (idempotent; instant if already done) ─────
echo ""
echo "=== Step 1: Ensure Microsoft.Insights RP is registered ==="
STATE=$(az provider show --namespace Microsoft.Insights --query registrationState -o tsv)
if [ "${STATE}" != "Registered" ]; then
    az provider register --namespace Microsoft.Insights --wait
    echo "  Registered."
else
    echo "  Already registered — skipping."
fi

# ── 2. Enable system-assigned managed identity ───────────────────────────────
# AMA uses SAI by default. Adding SAI alongside the existing UAI is a no-op
# for update-osm.sh (which explicitly targets its UAI by client-id via IMDS).
echo ""
echo "=== Step 2: Ensure system-assigned identity on ${VM_NAME} ==="
SAI_PRINCIPAL=$(az vm identity show -g "${CORE_RG}" -n "${VM_NAME}" \
    --query principalId -o tsv 2>/dev/null || true)
if [ -z "${SAI_PRINCIPAL}" ] || [ "${SAI_PRINCIPAL}" = "None" ]; then
    az vm identity assign -g "${CORE_RG}" -n "${VM_NAME}" >/dev/null
    echo "  Enabled system-assigned identity."
else
    echo "  Already enabled (principalId=${SAI_PRINCIPAL}) — skipping."
fi

# ── 3. Install AzureMonitorLinuxAgent extension ──────────────────────────────
# `az vm extension set` is upsert-style: safe to re-run. --enable-auto-upgrade
# keeps AMA current without further intervention.
echo ""
echo "=== Step 3: Install AzureMonitorLinuxAgent VM extension ==="
az vm extension set \
    --resource-group "${CORE_RG}" \
    --vm-name "${VM_NAME}" \
    --name AzureMonitorLinuxAgent \
    --publisher Microsoft.Azure.Monitor \
    --enable-auto-upgrade true \
    --output none
echo "  Extension installed / up-to-date."

# ── 4. Create the DCR via ARM REST (PUT is idempotent) ───────────────────────
# Facilities chosen to cover journald forwarding on Ubuntu:
#   - user, daemon, syslog : where journald's rsyslog forwarder lands
#     the vast majority of systemd unit stdout/stderr
#   - cron                 : for the osm-update.timer heartbeat
#   - local0               : reserved for future explicit `logger -p local0.*`
# Severity floor "Info" so we capture the =====/log() lines, not just errors.
echo ""
echo "=== Step 4: Create/update DCR ${DCR_NAME} ==="
DCR_URL="https://management.azure.com/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${CORE_RG}/providers/Microsoft.Insights/dataCollectionRules/${DCR_NAME}?api-version=2022-06-01"

DCR_BODY=$(mktemp)
cat > "${DCR_BODY}" <<JSON
{
  "location": "${LOCATION}",
  "properties": {
    "dataSources": {
      "syslog": [
        {
          "name": "osmSyslog",
          "streams": ["Microsoft-Syslog"],
          "facilityNames": ["user", "daemon", "syslog", "cron", "local0"],
          "logLevels": ["Info", "Notice", "Warning", "Error", "Critical", "Alert", "Emergency"]
        }
      ]
    },
    "destinations": {
      "logAnalytics": [
        {
          "workspaceResourceId": "${LAW_ID}",
          "name": "law-dest"
        }
      ]
    },
    "dataFlows": [
      {
        "streams": ["Microsoft-Syslog"],
        "destinations": ["law-dest"]
      }
    ]
  }
}
JSON

az rest --method put --url "${DCR_URL}" --body @"${DCR_BODY}" --output none
rm -f "${DCR_BODY}"

DCR_ID="/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${CORE_RG}/providers/Microsoft.Insights/dataCollectionRules/${DCR_NAME}"
echo "  DCR ID: ${DCR_ID}"

# ── 5. Associate DCR ↔ VM via ARM REST ───────────────────────────────────────
# Associations are child resources of the *target* (the VM), not the DCR.
echo ""
echo "=== Step 5: Create/update DCR association ${DCRA_NAME} ==="
DCRA_URL="https://management.azure.com${VM_ID}/providers/Microsoft.Insights/dataCollectionRuleAssociations/${DCRA_NAME}?api-version=2022-06-01"

az rest --method put --url "${DCRA_URL}" \
    --body "{\"properties\":{\"dataCollectionRuleId\":\"${DCR_ID}\",\"description\":\"osm-update syslog\"}}" \
    --output none
echo "  Association created."

# ── Done ─────────────────────────────────────────────────────────────────────
cat <<EOF

=== Done ===

Data starts flowing within ~5–10 minutes of AMA finishing provisioning and
the first update-osm.service run producing output.

Verify AMA is healthy on the VM:
    az vm extension show -g ${CORE_RG} --vm-name ${VM_NAME} \\
        --name AzureMonitorLinuxAgent --query provisioningState -o tsv

Verify the association landed:
    az monitor data-collection rule association list \\
        --resource "${VM_ID}" -o table

Query in Log Analytics (Portal → Logs, or 'az monitor log-analytics query'):

    Syslog
    | where TimeGenerated > ago(1h)
    | where ProcessName in ("systemd", "update-osm") or SyslogMessage has "osm-update"
    | project TimeGenerated, Computer, SeverityLevel, ProcessName, SyslogMessage
    | order by TimeGenerated asc

EOF
