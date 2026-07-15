#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# OSM replication updater (VM edition)
# ─────────────────────────────────────────────────────────────────────────────
# Run on the always-on Ubuntu VM (osm-import-vm). Designed to be invoked
# either manually or by a systemd timer (osm-update.timer → osm-update.service).
#
# Loops until the local replication state catches up to the upstream server,
# applying one daily diff per iteration. Exits cleanly when caught up.
#
# Env vars (typically loaded by systemd from /etc/osm-updater.env):
#   PGHOST, PGUSER, PGDATABASE                PostgreSQL connection
#   PGPASSWORD                                Optional. If unset, fetched
#                                             from Key Vault (see below).
#   KEY_VAULT_NAME                            Key Vault holding the PG
#                                             admin password secret. Used
#                                             when PGPASSWORD is not set.
#   PG_PASSWORD_SECRET_NAME                   default: pg-admin-password
#   REPLICATION_SERVER                        default: planet.openstreetmap.org daily
#                                             (https://planet.openstreetmap.org/replication/day/)
#                                             For a regional load, point at a
#                                             matching Geofabrik updates URL, e.g.
#                                             https://download.geofabrik.de/europe/germany-updates/
#   FLAT_NODES_PATH                           default: /mnt/data/nodes.bin
#                                              (PremiumV2 SSD, 10000 IOPS /
#                                              256 MB/s — sized for random
#                                              8-byte reads from --append.)
#   OSM2PGSQL_CACHE_MB                        default: 0   (with --flat-nodes
#                                              the in-memory node cache is
#                                              unused; per osm2pgsql manual)
#   OSM2PGSQL_PROCESSES                       default: 16
#   WORK_DIR                                  default: $HOME/osm-work
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

# ── Guard against terminal stop signals ──────────────────────────────
# During interactive perf-testing we've hit multiple runs where azcopy
# (and everything downstream) ended up in kernel state T
# ("do_signal_stop") after a stray Ctrl-Z inside a tmux pane, or after
# spurious SIGTTIN/SIGTTOU under certain tmux versions. Ignoring these
# signals for the duration of the run (and — via SIG_IGN inheritance —
# for every child process it execs, including azcopy) turns those
# fat-finger events into no-ops. Trap ONLY the terminal stop signals;
# SIGINT / SIGTERM are still honoured so Ctrl-C and `systemctl stop`
# work as expected.
trap '' TSTP TTIN TTOU

# ── Timestamped logger ───────────────────────────────────────────────
# Every diagnostic line is prefixed with a UTC timestamp + monotonic
# elapsed seconds since script start, so a hang in the journal/console
# log can be located in time without guessing.
SCRIPT_T0=$(date +%s)
log() {
    local now elapsed
    now=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
    elapsed=$(( $(date +%s) - SCRIPT_T0 ))
    printf '[%s +%5ds] %s\n' "$now" "$elapsed" "$*"
}

# ── Debug toggle ─────────────────────────────────────────────────────
# Set DEBUG=1 to re-enable the verbose diagnostics added during the
# IPv6/NAT/azcopy investigation: Step 2 preflight (DNS, IMDS, blob
# HEAD, replication state.txt probe), the 5-second pipeline watchdog
# with /proc/<pid>/io byte counters and live log tails, and the full
# pyosmium/azcopy log dump after the pipeline ends. Default 0 keeps
# the demo-clean output (just "Streaming diff..." and the result).
DEBUG="${DEBUG:-0}"
dlog() { [ "${DEBUG}" = "1" ] && log "$@"; return 0; }

REPLICATION_SERVER="${REPLICATION_SERVER:-https://planet.openstreetmap.org/replication/day/}"
# Keep nodes.bin on the PremiumV2 SSD at /mnt/data. The disk is sized
# (10000 IOPS, 256 MB/s) so --append's random 8-byte lookups are served
# from disk on every run, even after a VM stop/start wipes the page cache.
FLAT_NODES_PATH="${FLAT_NODES_PATH:-/mnt/data/nodes.bin}"
# With --flat-nodes the osm2pgsql in-memory node cache is unused, so set
# to 0 and let free RAM act as opportunistic OS page cache for hot pages
# of nodes.bin during this run.
OSM2PGSQL_CACHE_MB="${OSM2PGSQL_CACHE_MB:-0}"
OSM2PGSQL_PROCESSES="${OSM2PGSQL_PROCESSES:-16}"
WORK_DIR="${WORK_DIR:-${HOME}/osm-work}"
MALWARE_SCAN="${MALWARE_SCAN:-1}"
STORAGE_ACCOUNT="${STORAGE_ACCOUNT:-testpubliclandingzone}"
CONTAINER_NAME="${CONTAINER_NAME:-osmscanning}"
# UAI_CLIENT_ID: Client ID of the user-assigned managed identity attached
# to this VM. Not a secret — an attacker still needs Azure RBAC to use
# it — but resource-specific, so injected via /etc/profile.d/osm-env.sh
# by vm.bicep at deploy time. No default: fail fast if unset.
: "${UAI_CLIENT_ID:?Set UAI_CLIENT_ID (managed identity client ID)}"
MAX_SCAN_WAIT="${MAX_SCAN_WAIT:-300}"
SCAN_POLL_INTERVAL="${SCAN_POLL_INTERVAL:-15}"

# Note: no per-run PG cache pre-warm here. In production the PG server
# runs continuously and stays hot from the daily replication traffic
# itself. For demo recovery after a true cold start (fresh deployment,
# PG stop/start, etc.) bring the cache to steady-state by running
# init-osm.sh — the initial import naturally warms shared_buffers and
# the PG host OS page cache as it builds the schema. The very first
# update-osm.sh run after a cold start will be slow; subsequent runs
# benefit from cumulative organic warming.

# ── PostgreSQL connection (override via env if needed) ────────────────
PGHOST="${PGHOST:-test-database-pg.postgres.database.azure.com}"
PGUSER="${PGUSER:-osmuser}"
PGDATABASE="${PGDATABASE:-osm}"
export PGHOST PGUSER PGDATABASE

# ── Key Vault holding the PG password ─────────────────────────────────
KEY_VAULT_NAME="${KEY_VAULT_NAME:-osm-updater-kv}"
PG_PASSWORD_SECRET_NAME="${PG_PASSWORD_SECRET_NAME:-pg-admin-password}"

# ──────────────────────────────────────────────
# Fetch PGPASSWORD from Key Vault if not already provided.
# Uses the VM's user-assigned managed identity via IMDS + Key Vault
# REST directly. We avoid `az login --identity` because it calls ARM
# (management.azure.com) to enumerate tenants/subscriptions, and ARM
# has no private endpoint — under ALZ egress lockdown that call hangs.
# IMDS (link-local) and the KV private endpoint are both reachable.
# ──────────────────────────────────────────────
if [ -z "${PGPASSWORD:-}" ]; then
    echo "Fetching PGPASSWORD from Key Vault ${KEY_VAULT_NAME}/${PG_PASSWORD_SECRET_NAME} via MSI ${UAI_CLIENT_ID}..."
    KV_TOKEN=$(curl -fsS --max-time 10 -H 'Metadata: true' \
        "http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=https://vault.azure.net&client_id=${UAI_CLIENT_ID}" \
        | jq -r .access_token)
    if [ -z "${KV_TOKEN}" ] || [ "${KV_TOKEN}" = "null" ]; then
        echo "ERROR: failed to acquire AAD token for vault.azure.net from IMDS." >&2
        exit 1
    fi
    PGPASSWORD=$(curl -fsS --max-time 15 -H "Authorization: Bearer ${KV_TOKEN}" \
        "https://${KEY_VAULT_NAME}.vault.azure.net/secrets/${PG_PASSWORD_SECRET_NAME}?api-version=7.4" \
        | jq -r .value)
    unset KV_TOKEN
    if [ -z "${PGPASSWORD}" ] || [ "${PGPASSWORD}" = "null" ]; then
        echo "ERROR: failed to fetch ${PG_PASSWORD_SECRET_NAME} from ${KEY_VAULT_NAME}." >&2
        exit 1
    fi
fi
export PGPASSWORD

mkdir -p "${WORK_DIR}"
cd "${WORK_DIR}"

echo "=== OSM replication updater (VM edition) ==="
echo "Started at:         $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
echo "Host:               $(hostname)"
echo "Replication server: ${REPLICATION_SERVER}"
echo "Flat-nodes file:    ${FLAT_NODES_PATH}"
echo "Work dir:           ${WORK_DIR}"
echo "osm2pgsql --cache:  ${OSM2PGSQL_CACHE_MB} MB"
echo "osm2pgsql -P:       ${OSM2PGSQL_PROCESSES}"

if [ ! -s "${FLAT_NODES_PATH}" ]; then
    echo "ERROR: flat-nodes file ${FLAT_NODES_PATH} missing or empty." >&2
    echo "Populate it from the initial planet import before running this updater." >&2
    exit 1
fi
FLAT_NODES_BYTES=$(stat -c%s "${FLAT_NODES_PATH}")
echo "Flat-nodes file present: ${FLAT_NODES_BYTES} bytes"

# ──────────────────────────────────────────────
# Step 0: Pre-warm the OS page cache for nodes.bin
# osm2pgsql --append's Node phase issues random 8-byte reads against
# nodes.bin. On Premium SSD v2 each cold read pays ~1 ms host-network
# latency, so a single-threaded cold run tops out around 3k nodes/s.
# After one full sequential pass the file lives in RAM (free RAM on
# E32-8s_v5 ≈ 256 GB ≫ ~50 GB nodes.bin), turning subsequent random
# lookups into ~50 ns RAM hits and pushing the Node phase to 60k+/s.
#
# A VM stop/deallocate (or reboot) wipes RAM, so we must redo this on
# every boot. Use vmtouch if installed (faster, gives stats); otherwise
# fall back to dd.
# ──────────────────────────────────────────────
echo ""
echo "=== Step 0: Pre-warming page cache for ${FLAT_NODES_PATH} ==="
WARM_T0=$(date +%s)
if command -v vmtouch >/dev/null 2>&1; then
    sudo vmtouch -t "${FLAT_NODES_PATH}"
else
    echo "vmtouch not installed; falling back to dd. Install with: sudo apt-get install -y vmtouch"
    dd if="${FLAT_NODES_PATH}" of=/dev/null bs=8M status=progress
fi
WARM_ELAPSED=$(( $(date +%s) - WARM_T0 ))
WARM_MBPS=$(( FLAT_NODES_BYTES / 1024 / 1024 / (WARM_ELAPSED > 0 ? WARM_ELAPSED : 1) ))
echo "Warm-up complete in ${WARM_ELAPSED}s (~${WARM_MBPS} MB/s effective)."
free -h || true

export PGPASSWORD="${PGPASSWORD}"
export PGSSLMODE="${PGSSLMODE:-require}"

# ──────────────────────────────────────────────
# Performance: disable synchronous_commit for this role.
# Diff replay is idempotent (re-fetched from osm2pgsql_properties on
# crash), so we don't need WAL fsync on every commit. ALTER ROLE makes
# the setting apply to every new connection osm2pgsql opens, without
# touching server parameters (which may be locked when HA is enabled).
# Reverse with: ALTER ROLE <user> RESET synchronous_commit;
# ──────────────────────────────────────────────
echo ""
echo "=== Configuring role default: synchronous_commit=off ==="
psql -h "$PGHOST" -U "$PGUSER" -d "$PGDATABASE" -v ON_ERROR_STOP=1 \
    -c "ALTER ROLE \"${PGUSER}\" SET synchronous_commit = off;"

# ──────────────────────────────────────────────
# Malware-scan setup (only if enabled)
# Uses Defender for Storage "Malware Scanning" on the configured blob
# container. Each downloaded diff + state.txt is uploaded, the result tag
# ("Malware Scanning scan result") is polled, and we proceed only after a
# clean verdict. Requires:
#   - VM has a managed identity (UAI_CLIENT_ID)
#   - That identity has "Storage Blob Data Contributor" on the container
# ──────────────────────────────────────────────
if [ "${MALWARE_SCAN}" = "1" ]; then
    if [ -z "${STORAGE_ACCOUNT}" ] || [ -z "${UAI_CLIENT_ID:-}" ]; then
        echo "ERROR: MALWARE_SCAN=1 requires STORAGE_ACCOUNT and UAI_CLIENT_ID." >&2
        exit 1
    fi
    # azcopy auths via IMDS (no ARM round-trip). We deliberately do NOT
    # `az login --identity` here — that call enumerates tenants via ARM
    # (management.azure.com), which has no private endpoint and hangs
    # under ALZ egress lockdown.
    export AZCOPY_AUTO_LOGIN_TYPE=MSI
    export AZCOPY_MSI_CLIENT_ID="${UAI_CLIENT_ID}"
    # Verbose azcopy logging to a known location so a hung upload leaves
    # a forensic trail (request IDs, retries, throttling, auth errors).
    export AZCOPY_LOG_LOCATION="${WORK_DIR}/azcopy-logs"
    export AZCOPY_JOB_PLAN_LOCATION="${WORK_DIR}/azcopy-plans"
    mkdir -p "${AZCOPY_LOG_LOCATION}" "${AZCOPY_JOB_PLAN_LOCATION}"
    # ALZ egress lockdown: azcopy's default startup checks reach out to
    # public endpoints that have no private-endpoint counterpart, and
    # hang on TCP connect the same way `az login --identity` hits ARM.
    #   - Update check: GET https://azcopyvnext.azureedge.net/latest/...
    #   - Anonymous crash/telemetry beacon
    # Both are disabled below. Concurrency is pinned so azcopy skips its
    # initial bandwidth benchmark (opens many parallel connections up
    # front — under a tight egress path this can also stall silently).
    export AZCOPY_UPDATE_CHECK=false
    export AZCOPY_DISABLE_HIERARCHICAL_SCAN=true
    export AZCOPY_CONCURRENCY_VALUE="${AZCOPY_CONCURRENCY_VALUE:-8}"
fi

# Helper: fetch an AAD bearer token for an Azure resource via IMDS using
# the VM's user-assigned managed identity.
imds_token() {
    local resource="$1"
    curl -fsS --max-time 10 -H 'Metadata: true' \
        "http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=${resource}&client_id=${UAI_CLIENT_ID}" \
        | jq -r .access_token
}

# Storage REST API version with blob index tags + OAuth source copies
# (x-ms-copy-source-authorization).
BLOB_API_VERSION='2021-12-02'

# blob_get_tag <blob-name> <tag-key>
# Prints the tag value (or empty string) for the given blob.
blob_get_tag() {
    local blob="$1" key="$2" tok xml
    tok=$(imds_token 'https://storage.azure.com/')
    if [ -z "${tok}" ] || [ "${tok}" = "null" ]; then
        return 1
    fi
    xml=$(curl -fsS --max-time 15 \
        -H "Authorization: Bearer ${tok}" \
        -H "x-ms-version: ${BLOB_API_VERSION}" \
        "https://${STORAGE_ACCOUNT}.blob.core.windows.net/${CONTAINER_NAME}/${blob}?comp=tags") || return 1
    # XML: <Tags><TagSet><Tag><Key>K</Key><Value>V</Value></Tag>...</TagSet></Tags>
    echo "${xml}" | grep -oP "(?<=<Tag><Key>${key}</Key><Value>)[^<]+" | head -n1
}

# blob_delete <blob-name>  (best-effort; ignores errors)
blob_delete() {
    local blob="$1" tok
    tok=$(imds_token 'https://storage.azure.com/') || return 0
    curl -sS -o /dev/null --max-time 15 -X DELETE \
        -H "Authorization: Bearer ${tok}" \
        -H "x-ms-version: ${BLOB_API_VERSION}" \
        "https://${STORAGE_ACCOUNT}.blob.core.windows.net/${CONTAINER_NAME}/${blob}" || true
}

# blob_sync_copy <src-url> <dst-blob-name>
# Server-side synchronous copy. Source is authenticated with the same
# IMDS token via x-ms-copy-source-authorization, so no SAS is needed.
blob_sync_copy() {
    local src_url="$1" dst_blob="$2" tok http
    tok=$(imds_token 'https://storage.azure.com/')
    if [ -z "${tok}" ] || [ "${tok}" = "null" ]; then
        return 1
    fi
    http=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 60 -X PUT \
        -H "Authorization: Bearer ${tok}" \
        -H "x-ms-copy-source: ${src_url}" \
        -H "x-ms-copy-source-authorization: Bearer ${tok}" \
        -H "x-ms-requires-sync: true" \
        -H "x-ms-version: ${BLOB_API_VERSION}" \
        -H 'Content-Length: 0' \
        "https://${STORAGE_ACCOUNT}.blob.core.windows.net/${CONTAINER_NAME}/${dst_blob}")
    case "${http}" in
        201|202) return 0 ;;
        *) echo "ERROR: sync copy returned HTTP ${http} for ${dst_blob}" >&2; return 1 ;;
    esac
}

wait_for_scan() {
    local blob="$1"
    local elapsed=0
    local result=""
    while [ "${elapsed}" -lt "${MAX_SCAN_WAIT}" ]; do
        result=$(blob_get_tag "${blob}" 'Malware Scanning scan result' || echo "")
        if [ -n "${result}" ]; then
            echo "Scan result for ${blob}: ${result}"
            if [ "${result}" = "Malicious" ]; then
                echo "ERROR: malware detected in ${blob}! Aborting." >&2
                exit 1
            elif [ "${result}" != "No threats found" ]; then
                echo "WARNING: unexpected scan result for ${blob}: ${result}"
            fi
            return 0
        fi
        echo "Scan not complete yet for ${blob}. Waiting ${SCAN_POLL_INTERVAL}s... (${elapsed}/${MAX_SCAN_WAIT}s)"
        sleep "${SCAN_POLL_INTERVAL}"
        elapsed=$((elapsed + SCAN_POLL_INTERVAL))
    done
    echo "WARNING: scan did not complete for ${blob} within ${MAX_SCAN_WAIT}s. Proceeding with caution."
}

ITERATION=0
PREV_SEQ=""

while true; do
    ITERATION=$((ITERATION + 1))
    ITER_T0=$(date +%s)
    echo ""
    echo "############################################################"
    echo "# Iteration ${ITERATION}"
    echo "############################################################"
    free -h || true

    # ──────────────────────────────────────────────
    # Step 1: Read current replication state from PG
    # ──────────────────────────────────────────────
    echo ""
    echo "=== Step 1: Fetching replication sequence from database ==="

    SEQ_NUMBER=$(psql -h "$PGHOST" -U "$PGUSER" -d "$PGDATABASE" -t -A \
        -c "SELECT value FROM osm2pgsql_properties WHERE property = 'replication_sequence_number';")
    SEQ_TIMESTAMP=$(psql -h "$PGHOST" -U "$PGUSER" -d "$PGDATABASE" -t -A \
        -c "SELECT value FROM osm2pgsql_properties WHERE property = 'replication_timestamp';")

    if [ -z "$SEQ_NUMBER" ] || [ -z "$SEQ_TIMESTAMP" ]; then
        echo "ERROR: could not retrieve replication state from database." >&2
        exit 1
    fi

    echo "Current replication sequence number: ${SEQ_NUMBER}"
    echo "Current replication timestamp:       ${SEQ_TIMESTAMP}"

    if [ -n "$PREV_SEQ" ] && [ "$SEQ_NUMBER" = "$PREV_SEQ" ]; then
        echo "Sequence did not advance from ${PREV_SEQ}. Caught up — exiting loop."
        break
    fi
    PREV_SEQ="$SEQ_NUMBER"

    echo "${SEQ_NUMBER}" > sequence.state

    LOCAL_DIFF="${WORK_DIR}/changes.osc.gz"
    LOCAL_STATE="${WORK_DIR}/state.txt"
    rm -f "${LOCAL_DIFF}" "${LOCAL_STATE}"

    # ──────────────────────────────────────────────
    # Step 2: Fetch one daily diff + matching state.txt.
    #
    # pyosmium-get-changes exit codes:
    #   0 = success, new diff written
    #   3 = no new changes available (caught up)
    #
    # Two paths:
    #   MALWARE_SCAN=1 → stream straight to blob (no unscanned bytes ever
    #                    touch local disk). After the scan verdict clears,
    #                    download the now-trusted blob to local and apply.
    #   MALWARE_SCAN=0 → write directly to local disk and apply. No blob
    #                    round-trip.
    # ──────────────────────────────────────────────
    echo ""
    echo "=== Step 2: Fetching one daily diff + state.txt ==="

    if [ "${MALWARE_SCAN}" = "1" ]; then
        # ── Pre-flight diagnostics (DEBUG=1 only) ──────────────────
        # Verbose probes added during the IPv6/NAT/azcopy hang
        # investigation. Now that the pipeline is healthy, suppressed
        # by default. Re-enable with DEBUG=1.
        if [ "${DEBUG}" = "1" ]; then
            log "preflight: pyosmium-get-changes version = $(pyosmium-get-changes --version 2>&1 | head -n1 || echo '?')"
            log "preflight: azcopy version              = $(azcopy --version 2>&1 | head -n1 || echo '?')"
            log "preflight: AZCOPY_LOG_LOCATION         = ${AZCOPY_LOG_LOCATION}"

            STORAGE_HOST="${STORAGE_ACCOUNT}.blob.core.windows.net"
            log "preflight: resolving DNS for ${STORAGE_HOST}"
            getent hosts "${STORAGE_HOST}" || log "preflight: WARN DNS lookup failed for ${STORAGE_HOST}"

            REPL_HOST=$(echo "${REPLICATION_SERVER}" | awk -F/ '{print $3}')
            log "preflight: resolving DNS for ${REPL_HOST} (v4)"
            getent ahostsv4 "${REPL_HOST}" | awk '{print $1}' | sort -u || log "preflight: WARN no IPv4 for ${REPL_HOST}"
            log "preflight: resolving DNS for ${REPL_HOST} (v6)"
            getent ahostsv6 "${REPL_HOST}" | awk '{print $1}' | sort -u || log "preflight: WARN no IPv6 for ${REPL_HOST}"

            log "preflight: IMDS token for https://storage.azure.com/ ..."
            T0=$(date +%s%3N)
            if STORAGE_TOKEN=$(imds_token 'https://storage.azure.com/') && [ -n "${STORAGE_TOKEN}" ] && [ "${STORAGE_TOKEN}" != "null" ]; then
                log "preflight: IMDS token OK ($(( $(date +%s%3N) - T0 )) ms, len=${#STORAGE_TOKEN})"
            else
                log "preflight: ERROR IMDS token fetch failed ($(( $(date +%s%3N) - T0 )) ms)"
            fi
            unset STORAGE_TOKEN

            log "preflight: HEAD probe on container ${CONTAINER_NAME}"
            T0=$(date +%s%3N)
            PROBE_TOKEN=$(imds_token 'https://storage.azure.com/' || true)
            PROBE_HTTP=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 15 \
                -H "Authorization: Bearer ${PROBE_TOKEN}" \
                -H "x-ms-version: ${BLOB_API_VERSION}" \
                -X HEAD \
                "https://${STORAGE_HOST}/${CONTAINER_NAME}?restype=container" || echo "curl_fail")
            log "preflight: container HEAD → HTTP ${PROBE_HTTP} ($(( $(date +%s%3N) - T0 )) ms)"
            unset PROBE_TOKEN

            log "preflight: GET state.txt from replication server (small, no auth)"
            T0=$(date +%s%3N)
            REPL_HTTP=$(curl -4 -sS -o /dev/null -w '%{http_code}' --max-time 15 \
                "${REPLICATION_SERVER}state.txt" || echo "curl_fail")
            log "preflight: replication state.txt → HTTP ${REPL_HTTP} ($(( $(date +%s%3N) - T0 )) ms)"
        fi

        # Naming strategy: final blobs live under seq-<NEXT_SEQ>/ so the
        # prefix matches the Geofabrik sequence the diff transitions *to*
        # (e.g. diff 4794→4795 + state.txt for 4795 → "seq-4795/"). This
        # mirrors Geofabrik's own URL convention (000/004/795.state.txt)
        # and keeps the audit trail unambiguous.
        #
        # We don't know NEXT_SEQ until pyosmium finishes, so the diff is
        # first streamed to a unique pending/ path, then server-side
        # copied to its final name once NEXT_SEQ is known.
        PENDING_ID="${SEQ_NUMBER}-$(date +%s)-$$"
        PENDING_DIFF_NAME="pending/${PENDING_ID}/changes.osc.gz"
        PENDING_DIFF_URL="https://${STORAGE_ACCOUNT}.blob.core.windows.net/${CONTAINER_NAME}/${PENDING_DIFF_NAME}"

        log "Streaming diff via pyosmium-get-changes | azcopy → ${PENDING_DIFF_URL}"

        # Run pyosmium and azcopy as separate background processes
        # joined by a named pipe, instead of a shell pipeline. This lets
        # us monitor each PID independently and print which side is
        # alive while the other has exited — turning an opaque hang
        # into a localised one.
        FIFO="${WORK_DIR}/diff-fifo.$$"
        rm -f "${FIFO}"
        mkfifo "${FIFO}"

        PYO_LOG="${WORK_DIR}/pyosmium.log"
        AZC_LOG="${WORK_DIR}/azcopy.log"
        PYO_RC_FILE="${WORK_DIR}/pyosmium.rc"
        AZC_RC_FILE="${WORK_DIR}/azcopy.rc"
        rm -f "${PYO_LOG}" "${AZC_LOG}" "${PYO_RC_FILE}" "${AZC_RC_FILE}"

        # pyosmium writes osc.gz bytes to the FIFO. stderr → PYO_LOG.
        (
            set +e
            pyosmium-get-changes \
                --server "${REPLICATION_SERVER}" \
                -f sequence.state \
                --size 1 \
                --format osc.gz \
                -v \
                -o - > "${FIFO}" 2> "${PYO_LOG}"
            echo $? > "${PYO_RC_FILE}"
        ) &
        PYO_PID=$!

        # azcopy reads osc.gz bytes from the FIFO and PUTs to blob.
        # stdout+stderr → AZC_LOG. Debug log level forces request/retry
        # detail into ${AZCOPY_LOG_LOCATION}.
        (
            set +e
            azcopy copy "${PENDING_DIFF_URL}" \
                --from-to=PipeBlob \
                --overwrite=true \
                --log-level=DEBUG \
                --output-level=default \
                < "${FIFO}" > "${AZC_LOG}" 2>&1
            echo $? > "${AZC_RC_FILE}"
        ) &
        AZC_PID=$!

        dlog "spawned pyosmium pid=${PYO_PID}, azcopy pid=${AZC_PID}, fifo=${FIFO}"

        # Watchdog: while at least one side is alive, periodically print
        # liveness + byte counters from /proc/<pid>/io. Cadence and
        # detail depend on DEBUG: 5s with log tails when DEBUG=1, 30s
        # without tails otherwise.
        proc_io() {
            # $1=pid, $2=field (rchar|wchar|read_bytes|write_bytes)
            awk -v k="$2:" '$1==k {print $2}' "/proc/$1/io" 2>/dev/null || echo '?'
        }
        if [ "${DEBUG}" = "1" ]; then
            WATCH_INTERVAL=5
        else
            WATCH_INTERVAL=30
        fi
        WATCH_T0=$(date +%s)
        while kill -0 "${PYO_PID}" 2>/dev/null || kill -0 "${AZC_PID}" 2>/dev/null; do
            PYO_STATE=$(kill -0 "${PYO_PID}" 2>/dev/null && echo RUNNING || echo EXITED)
            AZC_STATE=$(kill -0 "${AZC_PID}" 2>/dev/null && echo RUNNING || echo EXITED)
            PYO_WCHAR=$(proc_io "${PYO_PID}" wchar)
            AZC_WCHAR=$(proc_io "${AZC_PID}" wchar)
            if [ "${DEBUG}" = "1" ]; then
                AZC_RCHAR=$(proc_io "${AZC_PID}" rchar)
                PYO_LAST=$(tail -n1 "${PYO_LOG}" 2>/dev/null || true)
                AZC_LAST=$(tail -n1 "${AZC_LOG}" 2>/dev/null || true)
                log "watch t=$(( $(date +%s) - WATCH_T0 ))s pyo=${PYO_STATE}(wchar=${PYO_WCHAR}) azc=${AZC_STATE}(rchar=${AZC_RCHAR} wchar=${AZC_WCHAR}) | pyo: ${PYO_LAST} | azc: ${AZC_LAST}"
            else
                log "  pipeline t=$(( $(date +%s) - WATCH_T0 ))s pyo=${PYO_STATE} (${PYO_WCHAR}B) azc=${AZC_STATE} (${AZC_WCHAR}B uploaded)"
            fi
            sleep "${WATCH_INTERVAL}"
        done

        wait "${PYO_PID}" 2>/dev/null || true
        wait "${AZC_PID}" 2>/dev/null || true
        rm -f "${FIFO}"

        PYOSMIUM_RC=$(cat "${PYO_RC_FILE}" 2>/dev/null || echo 1)
        AZCOPY_RC=$(cat "${AZC_RC_FILE}"  2>/dev/null || echo 1)
        log "pipeline done: pyosmium_rc=${PYOSMIUM_RC} azcopy_rc=${AZCOPY_RC}"
        # Verbose post-mortem only when DEBUG=1, or when something
        # actually failed (pyosmium != 0 and != 3, since 3 = caught up).
        PYO_FAILED=0
        [ "${PYOSMIUM_RC}" != "0" ] && [ "${PYOSMIUM_RC}" != "3" ] && PYO_FAILED=1
        if [ "${DEBUG}" = "1" ] || [ "${PYO_FAILED}" = "1" ] || [ "${AZCOPY_RC}" != "0" ]; then
            log "--- pyosmium.log (full) ---"
            cat "${PYO_LOG}" || true
            log "--- azcopy.log (tail 80) ---"
            tail -n 80 "${AZC_LOG}" || true
            log "--- azcopy detailed log dir: ${AZCOPY_LOG_LOCATION} ---"
            ls -lt "${AZCOPY_LOG_LOCATION}" 2>/dev/null | head -n 5 || true
        fi

        if [ "${PYOSMIUM_RC}" = "3" ]; then
            echo "pyosmium-get-changes returned 3 — no new diffs. Caught up."
            # Best-effort cleanup of the (likely empty) pending blob.
            blob_delete "${PENDING_DIFF_NAME}"
            break
        fi
        if [ "${PYOSMIUM_RC}" != "0" ]; then
            echo "ERROR: pyosmium-get-changes failed with exit code ${PYOSMIUM_RC}." >&2
            exit "${PYOSMIUM_RC}"
        fi
        if [ "${AZCOPY_RC}" != "0" ]; then
            echo "ERROR: azcopy upload failed with exit code ${AZCOPY_RC}." >&2
            exit "${AZCOPY_RC}"
        fi

        NEXT_SEQ=$(tr -dc '0-9' < sequence.state)
        echo "Streamed diff. Next sequence: ${NEXT_SEQ}"

        # Promote the pending diff to its final, audit-friendly name.
        # Server-side sync copy is near-instant within the same account
        # and produces a fresh blob write — which re-triggers the
        # Defender for Storage malware-scan event on the destination.
        BLOB_PREFIX="seq-${NEXT_SEQ}"
        DIFF_BLOB_NAME="${BLOB_PREFIX}/changes.osc.gz"
        DIFF_BLOB_URL="https://${STORAGE_ACCOUNT}.blob.core.windows.net/${CONTAINER_NAME}/${DIFF_BLOB_NAME}"
        echo "Promoting pending diff → ${DIFF_BLOB_URL}"
        blob_sync_copy "${PENDING_DIFF_URL}" "${DIFF_BLOB_NAME}"
        blob_delete "${PENDING_DIFF_NAME}"

        # Stream state.txt directly to its final name (NEXT_SEQ is known).
        STATE_BLOB_NAME="${BLOB_PREFIX}/state.txt"
        STATE_BLOB_URL="https://${STORAGE_ACCOUNT}.blob.core.windows.net/${CONTAINER_NAME}/${STATE_BLOB_NAME}"
        PADDED=$(printf "%09d" "$NEXT_SEQ")
        STATE_URL="${REPLICATION_SERVER}${PADDED:0:3}/${PADDED:3:3}/${PADDED:6:3}.state.txt"
        echo "Streaming state.txt ${STATE_URL} → ${STATE_BLOB_URL}"
        curl -4 -fsSL "$STATE_URL" \
          | azcopy copy "${STATE_BLOB_URL}" --from-to=PipeBlob --overwrite=true

        # Gate: wait for clean malware-scan verdict on the final blobs.
        echo ""
        echo "=== Step 2b: Waiting for malware-scan verdict ==="
        wait_for_scan "${DIFF_BLOB_NAME}"
        wait_for_scan "${STATE_BLOB_NAME}"

        # Now safe to materialise the scanned blobs locally for osm2pgsql.
        # Explicit --from-to=BlobLocal skips source auto-detection. Visible
        # logging surfaces auth / DNS / TCP hangs to the terminal (the
        # AZCOPY_UPDATE_CHECK=false env var above is what actually prevents
        # the classic multi-minute stall to the public azcopyvnext CDN).
        echo "Downloading scanned diff + state to local work dir..."
        azcopy copy "${DIFF_BLOB_URL}"  "${LOCAL_DIFF}" \
            --from-to=BlobLocal --overwrite=true \
            --check-md5=NoCheck --log-level=INFO --output-level=essential
        azcopy copy "${STATE_BLOB_URL}" "${LOCAL_STATE}" \
            --from-to=BlobLocal --overwrite=true \
            --check-md5=NoCheck --log-level=INFO --output-level=essential
        echo "Diff size: $(stat -c%s "${LOCAL_DIFF}") bytes"
    else
        # No-scan path: write directly to local disk.
        set +e
        pyosmium-get-changes \
            --server "${REPLICATION_SERVER}" \
            -f sequence.state \
            --size 1 \
            --format osc.gz \
            -o "${LOCAL_DIFF}"
        PYOSMIUM_RC=$?
        set -e

        if [ "$PYOSMIUM_RC" = "3" ] || { [ "$PYOSMIUM_RC" != "0" ] && [ ! -s "${LOCAL_DIFF}" ]; }; then
            echo "pyosmium-get-changes returned ${PYOSMIUM_RC} with no diff written. Caught up."
            break
        fi
        if [ "$PYOSMIUM_RC" != "0" ]; then
            echo "ERROR: pyosmium-get-changes failed with exit code ${PYOSMIUM_RC}." >&2
            exit "$PYOSMIUM_RC"
        fi

        NEXT_SEQ=$(tr -dc '0-9' < sequence.state)
        echo "Local diff written. Next sequence: ${NEXT_SEQ}"
        echo "Diff size: $(stat -c%s "${LOCAL_DIFF}") bytes"

        PADDED=$(printf "%09d" "$NEXT_SEQ")
        STATE_URL="${REPLICATION_SERVER}${PADDED:0:3}/${PADDED:3:3}/${PADDED:6:3}.state.txt"
        echo "Fetching state.txt: ${STATE_URL}"
        curl -4 -fsSL "$STATE_URL" -o "$LOCAL_STATE"
    fi

    # ──────────────────────────────────────────────
    # Step 3: Apply diff to PostgreSQL
    # ──────────────────────────────────────────────
    echo ""
    echo "=== Step 3: Applying changes to database ==="

    # osm2pgsql --append is largely silent for the entire 10-30 min
    # per iteration (unlike --create which streams per-object progress).
    # Under systemd, the journal therefore looks frozen between the
    # "Setting up table" lines and the final "osm2pgsql took N s"
    # summary. To give observability we run osm2pgsql in the background
    # and, while it's alive, poll pg_stat_activity every 60s to print a
    # single compact heartbeat line into the journal. Under tmux this
    # is redundant with what the user already sees, but harmless.
    STEP3_LOG="${WORK_DIR}/osm2pgsql-step3.log"
    rm -f "${STEP3_LOG}"

    osm2pgsql --append --slim \
        --number-processes "${OSM2PGSQL_PROCESSES}" \
        --cache "${OSM2PGSQL_CACHE_MB}" \
        --flat-nodes "${FLAT_NODES_PATH}" \
        --log-progress=true \
        -d "${PGDATABASE}" \
        -H "${PGHOST}" \
        -U "${PGUSER}" \
        "${LOCAL_DIFF}" > "${STEP3_LOG}" 2>&1 &
    OSM_PID=$!
    STEP3_T0=$(date +%s)

    # Heartbeat loop: single-line summary of the top active PG sessions
    # belonging to ${PGUSER} (ordered by query_start). Cheap query,
    # 300s cadence → ~1 line every 5 min, ~6 lines per iteration.
    # NB: uses POSIX '[[:space:]]+' rather than PG E-strings (E'\\s+')
    # because bash + psql double-quote escaping made the latter collapse
    # to plain 's+', which regexp_replace then turned every 's' in the
    # query text into a space (making osm2pgsql → "o m2pg ql", etc).
    HB_INTERVAL="${HB_INTERVAL:-300}"
    while kill -0 "${OSM_PID}" 2>/dev/null; do
        sleep "${HB_INTERVAL}"
        kill -0 "${OSM_PID}" 2>/dev/null || break
        HB=$(psql -h "${PGHOST}" -U "${PGUSER}" -d "${PGDATABASE}" \
            -X -A -t -F '|' -c "
            SELECT string_agg(
                pid || '/' || state || '/' || COALESCE(wait_event,'run')
                || '/' || to_char(now()-query_start,'MI:SS')
                || ' ' || left(regexp_replace(query,'[[:space:]]+',' ','g'),80),
                ' || '
                ORDER BY query_start)
            FROM pg_stat_activity
            WHERE usename='${PGUSER}' AND pid <> pg_backend_pid()
              AND state <> 'idle';" 2>/dev/null || echo "(psql heartbeat probe failed)")
        log "  Step 3 heartbeat: t=$(( $(date +%s) - STEP3_T0 ))s  pg=[${HB:-no-active-sessions}]"
    done

    wait "${OSM_PID}"
    OSM_RC=$?

    # Emit osm2pgsql's own stdout/stderr into the journal, in one
    # burst at the end. Useful for the final "Reading time / Overall
    # memory / osm2pgsql took N s" summary regardless of shell.
    if [ -s "${STEP3_LOG}" ]; then
        echo "--- osm2pgsql output ---"
        cat "${STEP3_LOG}"
        echo "--- end osm2pgsql output ---"
    fi

    if [ "${OSM_RC}" != "0" ]; then
        echo "ERROR: osm2pgsql --append failed with exit code ${OSM_RC}." >&2
        exit "${OSM_RC}"
    fi

    # ──────────────────────────────────────────────
    # Step 4: Advance osm2pgsql_properties (osm2pgsql --append does NOT do this)
    # ──────────────────────────────────────────────
    echo ""
    echo "=== Step 4: Advancing osm2pgsql_properties replication state ==="

    NEW_SEQ="$NEXT_SEQ"
    NEW_TS=$(sed -n 's/^timestamp=//p' "$LOCAL_STATE" | sed 's/\\:/:/g')

    if [ -z "$NEW_SEQ" ] || [ -z "$NEW_TS" ]; then
        echo "ERROR: could not derive new seq/timestamp." >&2
        echo "seq=${NEW_SEQ}" >&2
        cat "$LOCAL_STATE" >&2
        exit 1
    fi

    echo "Updating osm2pgsql_properties: seq=${NEW_SEQ}, ts=${NEW_TS}"

    psql -h "$PGHOST" -U "$PGUSER" -d "$PGDATABASE" -v ON_ERROR_STOP=1 \
        -v seq="${NEW_SEQ}" -v ts="${NEW_TS}" <<'SQL'
INSERT INTO osm2pgsql_properties (property, value)
VALUES ('replication_sequence_number', :'seq')
ON CONFLICT (property) DO UPDATE SET value = EXCLUDED.value;

INSERT INTO osm2pgsql_properties (property, value)
VALUES ('replication_timestamp', :'ts')
ON CONFLICT (property) DO UPDATE SET value = EXCLUDED.value;
SQL

    echo "Iteration ${ITERATION} complete (applied seq ${SEQ_NUMBER} → ${NEW_SEQ}) in $(( $(date +%s) - ITER_T0 ))s."
done

echo ""
echo "=== Pipeline complete ==="
echo "Finished at:      $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
echo "Total iterations: ${ITERATION}"