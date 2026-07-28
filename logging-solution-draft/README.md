# logging-solution

Stream the always-on VM's `update-osm.service` output into the Log Analytics
workspace already deployed by `infra-solution/` (Bicep) or `infra-solution-tf/`
(Terraform) — **without touching either IaC stack, and without modifying
`update-osm.sh`**.

## How it works

```
update-osm.sh (stdout+stderr)
        │
        ▼
osm-update.service (systemd)
        │  captures unit output
        ▼
   journald
        │  ForwardToSyslog=yes (Ubuntu default)
        ▼
   rsyslog → /var/log/syslog
        │
        ▼
Azure Monitor Agent (AMA)  ← installed by this folder
        │  applies the syslog DCR ↓
        ▼
Log Analytics workspace, `Syslog` table
```

The only side of the pipeline that isn't already in place after the workload
deployment is the AMA extension plus a Data Collection Rule + association. This
folder adds them via `az cli` only.

## What gets deployed

| Resource | Type | Notes |
|---|---|---|
| System-assigned identity on the VM | (VM property) | Added only if not already present. AMA authenticates with it by default. The existing UAMI keeps working for KV / Storage in `update-osm.sh`. |
| `AzureMonitorLinuxAgent` | VM extension | Auto-upgrade enabled. |
| `osm-syslog-dcr` | `Microsoft.Insights/dataCollectionRules` | Ingests facilities `user`, `daemon`, `syslog`, `cron`, `local0` at severity `Info+` into the workspace. |
| `osm-syslog-dcra` | `Microsoft.Insights/dataCollectionRuleAssociations` | Binds the DCR to the VM. |

`Microsoft.Insights` is registered on the subscription if not already.

## Prerequisites

- `az cli` logged in to the same subscription as the workload (`az login`).
- The workload (`infra-solution/` or `infra-solution-tf/`) is already deployed
  — this script only wires logging into what's there; it does **not** create
  the VM or the workspace.

## Usage

```bash
# From the repo root
bash logging-solution-draft/deploy-logging.sh
```

Defaults (overridable via env vars) match `infra-solution/main.bicepparam`:

| Env var | Default |
|---|---|
| `CORE_RG` | `test-flosm-rg` |
| `LOCATION` | `westus3` |
| `VM_NAME` | `osm-import-vm` |
| `LAW_NAME` | `osm-updater-logs` |
| `DCR_NAME` | `osm-syslog-dcr` |
| `DCRA_NAME` | `osm-syslog-dcra` |
| `SUBSCRIPTION_ID` | `az account show --query id` |

For the Terraform stack, set `CORE_RG=test-osm-solution-tf-rg` before running.

The script is idempotent — safe to re-run.

## Verify

**AMA provisioning:**

```bash
az vm extension show -g test-flosm-rg --vm-name osm-import-vm \
    --name AzureMonitorLinuxAgent --query provisioningState -o tsv
# expect: Succeeded
```

**DCR association:**

```bash
az monitor data-collection rule association list \
    --resource "$(az vm show -g test-flosm-rg -n osm-import-vm --query id -o tsv)" \
    -o table
```

**On the VM (SSH):**

```bash
# Is journald forwarding to syslog?
grep -E '^#?ForwardToSyslog' /etc/systemd/journald.conf
systemctl status rsyslog

# Recent unit output that AMA should have captured:
journalctl -u osm-update.service -n 50 --no-pager
tail -n 50 /var/log/syslog
```

**In the workspace** (Portal → Logs, or `az monitor log-analytics query`):

```kusto
Syslog
| where TimeGenerated > ago(1h)
| where ProcessName in ("systemd", "update-osm") or SyslogMessage has "osm-update"
| project TimeGenerated, Computer, SeverityLevel, ProcessName, SyslogMessage
| order by TimeGenerated asc
```

The first records land ~5–10 min after AMA finishes provisioning and the next
`update-osm.service` run produces output.

## Interactive runs (SSH / tmux)

Under systemd, output is captured automatically. When you invoke
`./update-osm.sh` interactively, output goes to your terminal and is **not**
picked up. Two ways to route interactive runs through the same pipeline:

```bash
# One-off:
./update-osm.sh 2>&1 | logger -t osm-update

# Or wrap the whole session:
exec > >(tee >(logger -t osm-update)) 2>&1
./update-osm.sh
```

Both land in `Syslog` with `ProcessName == "osm-update"`.

## Teardown

```bash
bash logging-solution-draft/nuke-logging.sh
```

Removes the DCR association, the DCR, and the AMA extension. Leaves the
workspace, the VM's system-assigned identity, and the RP registration in
place (all harmless).

## Cost

- `AzureMonitorLinuxAgent` extension: free.
- DCR + association: free.
- Log Analytics ingestion: pay-as-you-go per GB against the existing
  workspace. The `update-osm.service` stream is small (kilobytes per
  iteration); expect negligible cost.
