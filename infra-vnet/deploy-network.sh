#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# deploy-network.sh — deploy the network foundation for the OSM updater.
#
# Deploys:
#   - NSGs into CORE_RG (solution RG) via cross-RG bicep module — so
#     the solution owner can edit NSG rules day-2 with Contributor on
#     CORE_RG only, no rights on NETWORK_RG.
#   - VNet + 2 subnets (PE, VM) into NETWORK_RG, with the CORE_RG
#     NSGs attached at subnet-create time.
#
# Private DNS zones are NOT created here — they are created in CORE_RG
# by infra-solution/main.bicep, alongside PEs / VM / KV.
#
# Whoever runs this script needs (once, at initial setup):
#   NETWORK_RG:  Contributor (subnet + VNet write)
#   CORE_RG:     Contributor on NSGs (write) + read on the RG
#
# Usage:
#   NETWORK_RG=test-network-rg CORE_RG=test-flosm-rg LOCATION=westus3 \
#       ./infra-vnet/deploy-network.sh
#
# The final "export ..." block at the end of the run is meant to be
# pasted (or eval'd) before running ./infra-solution/deploy.sh so the
# workload stack picks up the resource IDs via env → bicepparam.
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

NETWORK_RG="${NETWORK_RG:-test-network-rg}"
CORE_RG="${CORE_RG:-test-flosm-rg}"
LOCATION="${LOCATION:-westus3}"
export LOCATION CORE_RG

# Optional overrides threaded into network.bicepparam:
#   VNET_ADDRESS_PREFIX, PE_SUBNET_PREFIX, VM_SUBNET_PREFIX

echo "=== deploy-network.sh ==="
echo "Network RG:  ${NETWORK_RG} (${LOCATION})   [VNet + subnets]"
echo "Core RG:     ${CORE_RG}                     [NSGs]"

# Both RGs must exist before the cross-RG deployment can complete.
az group create -n "${NETWORK_RG}" -l "${LOCATION}" --output none
az group create -n "${CORE_RG}"    -l "${LOCATION}" --output none

DEPLOY_NAME="osm-network-$(date +%Y%m%d-%H%M%S)"
az deployment group create \
    --resource-group "${NETWORK_RG}" \
    --name "${DEPLOY_NAME}" \
    --template-file infra-vnet/network.bicep \
    --parameters infra-vnet/network.bicepparam \
    --output none

read_out() {
    az deployment group show -g "${NETWORK_RG}" -n "${DEPLOY_NAME}" \
        --query "properties.outputs.$1.value" -o tsv
}

VNET_ID=$(read_out vnetId)
PE_SUBNET_ID=$(read_out peSubnetId)
VM_SUBNET_ID=$(read_out vmSubnetId)
PE_NSG_ID=$(read_out peNsgId)
VM_NSG_ID=$(read_out vmNsgId)

echo ""
echo "=== Done ==="
echo "VNET_ID       = ${VNET_ID}"
echo "PE_SUBNET_ID  = ${PE_SUBNET_ID}"
echo "VM_SUBNET_ID  = ${VM_SUBNET_ID}"
echo "PE_NSG_ID     = ${PE_NSG_ID}"
echo "VM_NSG_ID     = ${VM_NSG_ID}"
echo ""
echo "─ Feed these into deploy.sh ─────────────────────────────────────"
echo "# Option A: let deploy.sh discover them from NETWORK_RG:"
echo "export NETWORK_RG='${NETWORK_RG}'"
echo ""
echo "# Option B: paste explicitly (BYO existing VNet):"
cat <<EOF
export VNET_RESOURCE_ID='${VNET_ID}'
export PE_SUBNET_ID='${PE_SUBNET_ID}'
export VM_SUBNET_ID='${VM_SUBNET_ID}'
EOF
