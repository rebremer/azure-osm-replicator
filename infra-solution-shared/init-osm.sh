#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# OSM initial load (VM edition)
# ─────────────────────────────────────────────────────────────────────────────
# Run on the always-on Ubuntu VM (osm-import-vm). Performs a one-time
# initial import of an OSM PBF extract into PostgreSQL using osm2pgsql in
# slim mode with a flat-nodes file. After this completes, hand off to
# update-osm.sh for daily replication.
#
# Steps:
#   1. azcopy login with the VM's user-assigned managed identity
#   2. Download the source PBF from blob storage to local NVMe
#   3. Run osm2pgsql --create --slim --flat-nodes against PostgreSQL
#
# Env vars (override on the command line as needed):
#   PGHOST, PGUSER, PGDATABASE                PostgreSQL connection
#   PGPASSWORD                                Optional. If unset, fetched
#                                             from Key Vault (see below).
#   KEY_VAULT_NAME                            Key Vault holding the PG
#                                             admin password secret. Used
#                                             when PGPASSWORD is not set.
#   PG_PASSWORD_SECRET_NAME                   default: pg-admin-password
#   UAI_CLIENT_ID                             VM's managed identity client id
#   STORAGE_ACCOUNT                           default: testpubliclandingzone
#   CONTAINER_NAME                            default: osmscanning
#   PBF_BLOB_PATH                             default: initial/planet-latest.osm.pbf
#   PBF_LOCAL_PATH                            default: /mnt/data/planet-latest.osm.pbf
#   SOURCE_PBF_URL                            Source PBF URL. Streamed into
#                                             blob storage if PBF_BLOB_PATH
#                                             does not yet exist. Any HTTPS
#                                             PBF works.
#                                             default: https://planet.openstreetmap.org/pbf/planet-latest.osm.pbf
#                                                      (full planet, ~80 GB)
#                                             alt:     https://download.geofabrik.de/europe/germany-latest.osm.pbf
#                                                      (Geofabrik regional extract, e.g. Germany ~4 GB)
#                                             When using a regional extract,
#                                             also point REPLICATION_SERVER at
#                                             the matching Geofabrik updates
#                                             URL (see below) and update
#                                             PBF_BLOB_PATH / PBF_LOCAL_PATH
#                                             so the filename matches.
#   REPLICATION_SERVER                        Daily diff source used by Step 5
#                                             (osm2pgsql-replication init).
#                                             default: https://planet.openstreetmap.org/replication/day/
#                                                      (matches the planet PBF above)
#                                             alt:     https://download.geofabrik.de/europe/germany-updates/
#                                                      (matches the Geofabrik regional PBF)
#   FLAT_NODES_PATH                           default: /mnt/data/nodes.bin
#   OSM2PGSQL_CACHE_MB                        default: 0
#                                             With --flat-nodes the -C node cache is unused;
#                                             0 frees RAM for OS page cache (nodes.bin / PBF).
#   OSM2PGSQL_PROCESSES                       default: 16
#   SKIP_DOWNLOAD                             default: 0
#                                             1 = skip the upstream fetch in
#                                             Step 1b. The blob at PBF_BLOB_PATH
#                                             must already exist; Step 2 still
#                                             downloads it to PBF_LOCAL_PATH.
#                                             Use this with a non-default
#                                             PBF_BLOB_PATH (e.g. a dated PBF
#                                             from N days ago) for a demo where
#                                             you want N days of replication
#                                             catch-up after init.
#   RESET_ALL                                 default: 0  (set 1 to wipe schema,
#                                             flat-nodes file, and seq-*/pending/
#                                             blobs before re-importing)
#   RESET_ALL_PBF                             default: 0  (with RESET_ALL=1,
#                                             also delete the source PBF blob
#                                             so it is re-fetched from the
#                                             upstream SOURCE_PBF_URL)
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

# UAI_CLIENT_ID: Client ID of the user-assigned managed identity attached
# to this VM. Not a secret — an attacker still needs Azure RBAC to use
# it — but resource-specific, so injected via /etc/profile.d/osm-env.sh
# by vm.bicep at deploy time. No default: fail fast if unset.
: "${UAI_CLIENT_ID:?Set UAI_CLIENT_ID (managed identity client ID)}"
STORAGE_ACCOUNT="${STORAGE_ACCOUNT:-testpubliclandingzone}"
CONTAINER_NAME="${CONTAINER_NAME:-osmscanning}"
PBF_BLOB_PATH="${PBF_BLOB_PATH:-initial/planet-latest.osm.pbf}"
PBF_LOCAL_PATH="${PBF_LOCAL_PATH:-/mnt/data/planet-latest.osm.pbf}"
# SOURCE_PBF_URL: upstream PBF. Defaults to the full planet from
# planet.openstreetmap.org. For a regional load, override to a
# Geofabrik extract, e.g.
#   export SOURCE_PBF_URL=https://download.geofabrik.de/europe/germany-latest.osm.pbf
# and also override REPLICATION_SERVER (see Step 5 below) to the
# matching Geofabrik updates URL.
SOURCE_PBF_URL="${SOURCE_PBF_URL:-https://planet.openstreetmap.org/pbf/planet-latest.osm.pbf}"
FLAT_NODES_PATH="${FLAT_NODES_PATH:-/mnt/data/nodes.bin}"
OSM2PGSQL_CACHE_MB="${OSM2PGSQL_CACHE_MB:-0}"
OSM2PGSQL_PROCESSES="${OSM2PGSQL_PROCESSES:-16}"
SKIP_DOWNLOAD="${SKIP_DOWNLOAD:-0}"
RESET_ALL="${RESET_ALL:-0}"
RESET_ALL_PBF="${RESET_ALL_PBF:-0}"

# Make all azcopy commands authenticate via the VM's user-assigned MI
# without an interactive `azcopy login` step. azcopy only hits IMDS +
# the storage endpoint, so this works under ALZ egress lockdown where
# ARM (management.azure.com) is unreachable.
export AZCOPY_AUTO_LOGIN_TYPE="${AZCOPY_AUTO_LOGIN_TYPE:-MSI}"
export AZCOPY_MSI_CLIENT_ID="${AZCOPY_MSI_CLIENT_ID:-${UAI_CLIENT_ID}}"

# Helper: fetch an AAD bearer token for an Azure resource via IMDS using
# the VM's user-assigned managed identity. Avoids `az login --identity`,
# which calls ARM to enumerate tenants and hangs when ARM is blocked.
# Usage: imds_token https://storage.azure.com/
imds_token() {
    local resource="$1"
    curl -fsS --max-time 10 -H 'Metadata: true' \
        "http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=${resource}&client_id=${UAI_CLIENT_ID}" \
        | jq -r .access_token
}

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
# IMDS (link-local) and the KV private endpoint are both reachable
# without ARM access, and no secret material ever lives in shell
# history or systemd env files.
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
export PGSSLMODE="${PGSSLMODE:-require}"

PBF_BLOB_URL="https://${STORAGE_ACCOUNT}.blob.core.windows.net/${CONTAINER_NAME}/${PBF_BLOB_PATH}"

echo "=== OSM initial load (VM edition) ==="
echo "Started at:         $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
echo "Host:               $(hostname)"
echo "Source PBF URL:     ${SOURCE_PBF_URL}"
echo "PBF blob URL:       ${PBF_BLOB_URL}"
echo "PBF local path:     ${PBF_LOCAL_PATH}"
echo "Flat-nodes file:    ${FLAT_NODES_PATH}"
echo "PG host:            ${PGHOST}"
echo "osm2pgsql --cache:  ${OSM2PGSQL_CACHE_MB} MB"
echo "osm2pgsql -P:       ${OSM2PGSQL_PROCESSES}"

# ──────────────────────────────────────────────
# Performance: disable synchronous_commit for this role.
# Speeds up the pending-ways/relations postprocess phase, which does
# many small INSERTs. Initial load is otherwise COPY-bound, so the win
# is modest (~5–15%). Setting persists for the role; update-osm.sh
# benefits from the same setting.
# ──────────────────────────────────────────────
echo ""
echo "=== Configuring role default: synchronous_commit=off ==="
psql -h "$PGHOST" -U "$PGUSER" -d "$PGDATABASE" -v ON_ERROR_STOP=1 \
    -c "ALTER ROLE \"${PGUSER}\" SET synchronous_commit = off;"

# ──────────────────────────────────────────────
# Bootstrap the target database: reset the public schema and create
# the postgis + hstore extensions osm2pgsql needs.
#
# Refuses to run if planet_osm_* tables already exist (i.e. a previous
# import is live), so re-running init-osm.sh against a populated DB
# does not silently drop the rendered data.
#
# The extensions themselves must already be allow-listed in the
# server's azure.extensions parameter — postgres.bicep does this.
# ──────────────────────────────────────────────
echo ""
echo "=== Bootstrapping ${PGDATABASE}: reset public schema + extensions ==="
EXISTING=$(psql -h "$PGHOST" -U "$PGUSER" -d "$PGDATABASE" -tAX \
    -c "SELECT count(*) FROM pg_tables WHERE schemaname='public' AND tablename LIKE 'planet_osm_%';")
if [ "${EXISTING:-0}" != "0" ] && [ "${RESET_ALL}" != "1" ]; then
    echo "Found ${EXISTING} existing planet_osm_* table(s) — skipping schema reset."
    echo "Drop them manually or re-run with RESET_ALL=1 to wipe everything."
else
    if [ "${EXISTING:-0}" != "0" ]; then
        echo "RESET_ALL=1: dropping ${EXISTING} existing planet_osm_* table(s) via schema reset."
    fi
    psql -h "$PGHOST" -U "$PGUSER" -d "$PGDATABASE" -v ON_ERROR_STOP=1 <<'SQL'
DROP SCHEMA IF EXISTS public CASCADE;
CREATE SCHEMA public;
CREATE EXTENSION IF NOT EXISTS postgis;
CREATE EXTENSION IF NOT EXISTS hstore;
SQL
    echo "Schema reset complete; postgis + hstore enabled."
fi

# ──────────────────────────────────────────────
# RESET_ALL: also wipe the on-disk flat-nodes file and the replication
# blobs (seq-*/ and pending/) in the storage container. The source PBF
# blob is kept by default so we don't re-download the PBF from upstream
# (~4 GB for Germany, ~80 GB for a full planet);
# set RESET_ALL_PBF=1 to delete that too.
# ──────────────────────────────────────────────
if [ "${RESET_ALL}" = "1" ]; then
    echo ""
    echo "=== RESET_ALL=1: wiping flat-nodes file + replication blobs ==="
    if [ -f "${FLAT_NODES_PATH}" ]; then
        echo "Removing ${FLAT_NODES_PATH} ($(stat -c%s "${FLAT_NODES_PATH}") bytes)..."
        sudo rm -f "${FLAT_NODES_PATH}"
    fi

    # Use azcopy (MSI via AZCOPY_AUTO_LOGIN_TYPE) for deletes — it only
    # talks to IMDS + the storage endpoint, no ARM round-trip.
    for PREFIX in "seq-" "pending/"; do
        echo "Deleting blobs under ${CONTAINER_NAME}/${PREFIX}* ..."
        azcopy remove "https://${STORAGE_ACCOUNT}.blob.core.windows.net/${CONTAINER_NAME}/${PREFIX}" \
            --recursive=true >/dev/null || true
    done

    if [ "${RESET_ALL_PBF}" = "1" ]; then
        echo "RESET_ALL_PBF=1: deleting source PBF blob ${PBF_BLOB_PATH}..."
        azcopy remove "https://${STORAGE_ACCOUNT}.blob.core.windows.net/${CONTAINER_NAME}/${PBF_BLOB_PATH}" \
            >/dev/null 2>&1 || true
    fi
    echo "Wipe complete."
fi

# ──────────────────────────────────────────────
# Step 1: azcopy auth is configured via AZCOPY_AUTO_LOGIN_TYPE=MSI +
# AZCOPY_MSI_CLIENT_ID at the top of this script — no explicit login
# step needed, and we avoid `az login --identity` (which calls ARM and
# hangs under ALZ egress lockdown).
# ──────────────────────────────────────────────

# ─────────────────────────────────────────────
# Step 1b: Ensure the source PBF is present in blob storage.
#
# Always checks whether ${PBF_BLOB_PATH} exists in the container. If it
# does, we reuse it. If it does not, we stream it from upstream
# (SOURCE_PBF_URL) straight into the container so it never touches
# local disk on the way in (which lets Defender for Storage malware-scan
# the upload and tag it before Step 2 reads it back).
#
# SKIP_DOWNLOAD=1 short-circuits the check — the caller asserts the
# blob already exists (typically a dated PBF for a catch-up demo).
# Step 2 will then download that existing blob to PBF_LOCAL_PATH; if it
# is missing, azcopy will fail there.
# ─────────────────────────────────────────────
echo ""
echo "=== Step 1b: Ensuring ${PBF_BLOB_PATH} exists in ${STORAGE_ACCOUNT}/${CONTAINER_NAME} ==="
if [ "${SKIP_DOWNLOAD}" = "1" ]; then
    echo "SKIP_DOWNLOAD=1 — caller asserts the blob already exists; not verifying."
else
    # Blob HEAD via REST + IMDS token (no `az`, no ARM dependency).
    STORAGE_TOKEN=$(imds_token 'https://storage.azure.com/')
    if [ -z "${STORAGE_TOKEN}" ] || [ "${STORAGE_TOKEN}" = "null" ]; then
        echo "ERROR: failed to acquire AAD token for storage.azure.com from IMDS." >&2
        exit 1
    fi
    HTTP_STATUS=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 15 \
        -H "Authorization: Bearer ${STORAGE_TOKEN}" \
        -H 'x-ms-version: 2021-12-02' \
        -I "${PBF_BLOB_URL}")
    unset STORAGE_TOKEN
    case "${HTTP_STATUS}" in
        200) BLOB_EXISTS=true ;;
        404) BLOB_EXISTS=false ;;
        *)
            echo "ERROR: unexpected HTTP ${HTTP_STATUS} from blob HEAD ${PBF_BLOB_URL}" >&2
            exit 1
            ;;
    esac
    if [ "${BLOB_EXISTS}" = "true" ]; then
        echo "Blob already present — skipping upstream download."
    else
        echo "Streaming ${SOURCE_PBF_URL} → ${PBF_BLOB_URL}"
        # curl → azcopy pipe: no local copy of the unscanned PBF.
        # --fail makes curl exit non-zero on HTTP errors; -L follows redirects.
        set -o pipefail
        curl -fSL "${SOURCE_PBF_URL}" \
          | azcopy copy "${PBF_BLOB_URL}" --from-to=PipeBlob --overwrite=true
        set +o pipefail
        echo "Upload complete."
    fi
fi

# ─────────────────────────────────────────────
# Step 2: Download PBF from blob to local NVMe
# Keep PBF on /mnt/data (Premium SSD) for fast sequential read during import.
# Idempotent: if PBF_LOCAL_PATH already exists with non-zero size, the
# blob download is skipped. Delete the local file to force a re-fetch.
# ──────────────────────────────────────────────
if [ -s "${PBF_LOCAL_PATH}" ]; then
    echo ""
    echo "=== Step 2: Local PBF already present — skipping blob download ==="
    echo "Using existing: $(stat -c%s "${PBF_LOCAL_PATH}") bytes at ${PBF_LOCAL_PATH}"
else
    echo ""
    echo "=== Step 2: Downloading PBF from blob ==="
    mkdir -p "$(dirname "${PBF_LOCAL_PATH}")"
    azcopy copy "${PBF_BLOB_URL}" "${PBF_LOCAL_PATH}" --overwrite=true
    if [ ! -s "${PBF_LOCAL_PATH}" ]; then
        echo "ERROR: PBF download produced empty/missing file at ${PBF_LOCAL_PATH}." >&2
        echo "       Check that the blob exists at ${PBF_BLOB_URL}." >&2
        exit 1
    fi
    echo "Download complete: $(stat -c%s "${PBF_LOCAL_PATH}") bytes"
fi

# ──────────────────────────────────────────────
# Step 3: Refuse to overwrite an existing flat-nodes file
# osm2pgsql -c (--create) drops & re-creates the schema and the flat-nodes
# file. Guard against accidentally wiping a populated database.
# ──────────────────────────────────────────────
if [ -s "${FLAT_NODES_PATH}" ] && [ "${RESET_ALL}" != "1" ]; then
    echo "ERROR: ${FLAT_NODES_PATH} already exists ($(stat -c%s "${FLAT_NODES_PATH}") bytes)." >&2
    echo "       Initial load would drop the existing schema and overwrite this file." >&2
    echo "       Move/delete it explicitly, or re-run with RESET_ALL=1, to re-import." >&2
    exit 1
fi
mkdir -p "$(dirname "${FLAT_NODES_PATH}")"

# ──────────────────────────────────────────────
# Step 4: Run osm2pgsql initial load
# --slim + --flat-nodes is required so subsequent --append runs (in
# update-osm.sh) can resolve node references without keeping all nodes
# in PG.
# ──────────────────────────────────────────────
echo ""
echo "=== Step 4: osm2pgsql initial load ==="
T0=$(date +%s)
osm2pgsql -c --slim \
    --number-processes "${OSM2PGSQL_PROCESSES}" \
    -C "${OSM2PGSQL_CACHE_MB}" \
    --flat-nodes "${FLAT_NODES_PATH}" \
    -U "${PGUSER}" \
    -H "${PGHOST}" \
    -d "${PGDATABASE}" \
    "${PBF_LOCAL_PATH}"
echo "osm2pgsql completed in $(( $(date +%s) - T0 ))s"

# ──────────────────────────────────────────────
# Step 5: Seed replication state in osm2pgsql_properties
# update-osm.sh refuses to run without these rows. Initialise them from
# the configured replication server so the first --append knows where to
# resume.
#
# Default matches SOURCE_PBF_URL (full planet, daily). For a Geofabrik
# regional extract, override REPLICATION_SERVER to the matching
# `-updates/` path, e.g.
#   export REPLICATION_SERVER=https://download.geofabrik.de/europe/germany-updates/
# ──────────────────────────────────────────────
REPLICATION_SERVER="${REPLICATION_SERVER:-https://planet.openstreetmap.org/replication/day/}"
echo ""
echo "=== Step 5: osm2pgsql-replication init (server ${REPLICATION_SERVER}) ==="
osm2pgsql-replication init \
    -d "${PGDATABASE}" \
    -H "${PGHOST}" \
    -U "${PGUSER}" \
    --server "${REPLICATION_SERVER}"

echo ""
echo "=== Done ==="
echo "Flat-nodes file: $(stat -c%s "${FLAT_NODES_PATH}") bytes at ${FLAT_NODES_PATH}"
echo "Next: run update-osm.sh"
