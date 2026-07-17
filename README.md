# azure-osm-replicator

Azure reference implementation for keeping a planet-scale OpenStreetMap
PostGIS database current via daily OSM replication diffs (default source:
[planet.openstreetmap.org](https://planet.openstreetmap.org/), with
[Geofabrik](https://download.geofabrik.de/) regional extracts as the
drop-in alternative), using `osm2pgsql --append --slim --flat-nodes` on
a scheduled Linux VM backed by Azure Database for PostgreSQL Flexible
Server.

## Quick start

1. Provision networking, storage, PG Flex Server, and the import VM
   ([infra-vnet/](infra-vnet/) then [infra-solution/](infra-solution/)) —
   `bash infra-vnet/deploy-network.sh` then
   `bash infra-solution/deploy.sh` (set `DEPLOY_STORAGE=1 DEPLOY_PG=1`
   for greenfield storage + PG). See [Deploy](#deploy) below.
2. On the PG Flex Server, run the four one-time prerequisites — see
   [Prerequisites](#prerequisites-one-time-on-the-pg-flex-server):
   create the target database, allow-list `postgis` + `hstore`, reset
   the `public` schema and enable the extensions, and set
   `max_wal_size=16384` + `max_parallel_maintenance_workers=4`.
3. Run [init-osm.sh](init-osm.sh) on the VM (~30 min for Germany on
   the **D8ds_v5 / P30** baseline — no scale-up/scale-down dance
   needed; the same SKU handles both init and daily updates).
4. Run [update-osm.sh](update-osm.sh) daily (wire to a systemd timer);
   Step 0 pre-warms `nodes.bin` into the OS page cache so each
   replication day finishes in ~120 s.
5. Deallocate the VM between runs — `/mnt/data` survives stop/start
   so `nodes.bin` does not need re-importing.

For the rationale behind each step (page-cache mechanics,
`synchronous_commit=off`, why CAJ was rejected) see
[Performance reference](#performance-reference) and
[Why VM](#why-vm-not-container-apps-job-not-always-on).
For a full-planet build see [Scaling to planet](#scaling-to-planet).

## Architecture

Two resource groups, one Azure region:

```
┌─ NETWORK_RG ─────────────┐   ┌─ CORE_RG ─────────────────────────────────────┐
│  VNet + 2 subnets        │   │  osm-import-vm  (Ubuntu 24.04, E32-8s_v5)     │
│    - vm-subnet           │◄──┤    /mnt/data → 256 GiB Premium SSD v2         │
│    - pe-subnet           │   │    Standard Static PIP  (SSH-in, IPv4 egress) │
│  NSGs (attached to subnets   │    UAMI  (KV read, Storage Blob Data Owner)   │
│  but resource-defined in     │                                               │
│  CORE_RG via cross-RG        │  Storage account  (blob, Defender-scanned)    │
│  bicep module — day-2 you    │  PG Flex Server   (v17, D8ds_v5, P30)         │
│  edit rules from CORE_RG)    │  Key Vault        (RBAC, PE-only, holds       │
│                              │                    pg-admin-password)          │
│                              │  Private endpoints:  blob, PG, KV             │
│                              │  Private DNS zones + VNet links               │
└──────────────────────────┘   └───────────────────────────────────────────────┘

External:  OSM replication server (HTTPS) — daily .osc.gz diffs
           default: planet.openstreetmap.org (full planet)
           alt:     download.geofabrik.de (regional extract, e.g. Germany)
```

- **One Linux VM** (`Standard_E32-8s_v5`) runs both the one-time initial
  import and the daily updater. Deallocated between runs; started a few
  minutes before each scheduled update.
- **PostgreSQL Flexible Server** (`Standard_D8ds_v5`, P30 storage,
  publicNetworkAccess=Disabled) stores `planet_osm_*` tables.
- **One Premium SSD managed disk on the VM** (`/mnt/data`) holds
  `nodes.bin` and per-iteration diffs. Survives deallocate/start.
- **No NAT Gateway** (target env forbids it) and **no Bastion**. The
  VM's Standard PIP provides deterministic IPv4 egress + SSH inbound.
  In the end state a VNet-attached VPN retires the PIP
  (`ENABLE_PUBLIC_IP=false`).
- **Infra split:** [infra-vnet/](infra-vnet/) owns VNet + subnets and
  writes NSGs cross-RG into `CORE_RG` so day-2 the solution owner needs
  only Contributor on `CORE_RG` (+ subnet-join on `NETWORK_RG`).
  [infra-solution/](infra-solution/) owns everything else (DNS zones,
  PEs, VM, KV, and optionally storage + PG).

## Deploy

**Two scripts, run once each.** All defaults are override-able via env vars
(see [`infra-solution/main.bicepparam`](infra-solution/main.bicepparam)
and [`infra-solution/deploy.sh`](infra-solution/deploy.sh) for the full list).

```bash
# ── 1. network foundation (once, needs Contributor on both RGs) ──
export NETWORK_RG=test-osm-netwerk-rg
export CORE_RG=test-osm-solution-rg
export LOCATION=westus3
bash infra-vnet/deploy-network.sh

# ── 2. workload (storage + PG + VM + KV + PEs) ──
export STORAGE_RG=$CORE_RG   PG_RG=$CORE_RG    # co-locate everything
export STORAGE_ACCOUNT_NAME='mystorageacct'    # globally unique, 3-24 lowercase alnum
export PG_SERVER_NAME='my-pg-01'               # globally unique DNS name
export DEPLOY_STORAGE=1 DEPLOY_PG=1            # 0 to re-use existing
export PG_ADMIN_PASSWORD='<pg password>'       # stored in KV, fetched by init-osm.sh
export USE_SSH_KEY=true
export SSH_PUBLIC_KEY="$(cat ~/osm-vm-key.pub)"
# Test-env conveniences (skip for production):
export KV_ENABLE_PURGE_PROTECTION=false        # so teardown can `az keyvault purge`
export KV_NAME_PREFIX=osm-updater-kv2          # bump if a prior KV is soft-deleted
bash ./infra-solution/deploy.sh
```

The script prints the VM's public IP + `ssh` command at the end.
`init-osm.sh` and `update-osm.sh` are pre-installed in the VM home
directory by the CustomScript extension in
[infra-solution/modules/vm.bicep](infra-solution/modules/vm.bicep),
and `/etc/profile.d/osm-env.sh` exports every runtime variable
(UAMI client ID, KV name, PG host, storage account, …) so a fresh
SSH shell can just run `./init-osm.sh`.

Cloud-init in [infra-solution/modules/cloud-init.yaml](infra-solution/modules/cloud-init.yaml)
installs `osm2pgsql`, `azcopy`, `pyosmium`, `azure-cli`, `psql`, `jq`,
then formats and mounts `/mnt/data`.

`az deployment group what-if` confirms the deploy is idempotent
(0 creates, 0 deletes against the existing RG).

### Teardown

```bash
az group delete -n test-osm-solution-rg --yes --no-wait
az group delete -n test-osm-netwerk-rg  --yes --no-wait
# With KV_ENABLE_PURGE_PROTECTION=false the KV name is instantly reusable:
az keyvault purge -n <the-kv-name-from-deploy> --location westus3
```

## Run on the VM

### Prerequisites (one-time, on the PG Flex Server)

1. Create the target database (e.g. `osm`) on the Flex Server.
2. Allow-list `postgis` and `hstore` in the server's
   `azure.extensions` parameter (Server parameters blade or
   `az postgres flexible-server parameter set`).
3. Connect to the new database and reset the `public` schema +
   enable the extensions:

   ```sql
   DROP SCHEMA public CASCADE;
   CREATE SCHEMA public;

   CREATE EXTENSION IF NOT EXISTS postgis;
   CREATE EXTENSION IF NOT EXISTS hstore;
   ```
4. Tune two server parameters that materially speed up the
   initial load (no restart required):

   | Parameter                          | Value      | Why                                                                 |
   | ---------------------------------- | ---------- | ------------------------------------------------------------------- |
   | `max_wal_size`                     | `16384` MB | Removes checkpoint stalls during the Node COPY phase.               |
   | `max_parallel_maintenance_workers` | `4`        | Parallel `CREATE INDEX` in the postprocess phase (biggest single win). |

   Combined with the **D8ds_v5** baseline (8 vCores / 32 GiB RAM)
   and **P30** Premium SSD v1 storage (1 TiB / 5,000 IOPS / 200 MB/s),
   Germany init lands at **~30 min**. No scale-up/scale-down dance is
   required: the same SKU handles both init and daily updates.
   `maintenance_work_mem` on Azure PG Flex is capped at 2 GB regardless
   of tier and doesn't need to be touched.

### Run

```bash
ssh osmadmin@<vm-pip>
export PGHOST=... PGUSER=... PGDATABASE=osm PGPASSWORD='...'

./init-osm.sh        # one-time initial import
./update-osm.sh      # daily (wire to systemd timer)
```

[init-osm.sh](init-osm.sh) downloads the PBF from blob, runs
`osm2pgsql -c --slim --flat-nodes`, and refuses to overwrite an
existing `nodes.bin`. [update-osm.sh](update-osm.sh) pre-warms the
page cache (Step 0, see below), then loops `pyosmium-get-changes` →
`osm2pgsql --append` until caught up, persisting the replication
sequence in `osm2pgsql_properties`. With `MALWARE_SCAN=1` each diff
is routed via blob storage and waits for a clean Defender verdict.

The upstream source is controlled by two env vars, both defaulting to
the full planet from planet.openstreetmap.org:

| Env var             | Default (full planet)                                       | Alternative (Geofabrik region, e.g. Germany)              |
| ------------------- | ----------------------------------------------------------- | --------------------------------------------------------- |
| `SOURCE_PBF_URL`    | `https://planet.openstreetmap.org/pbf/planet-latest.osm.pbf`| `https://download.geofabrik.de/europe/germany-latest.osm.pbf` |
| `REPLICATION_SERVER`| `https://planet.openstreetmap.org/replication/day/`         | `https://download.geofabrik.de/europe/germany-updates/`   |

Always change **both** together — the replication server must match
the PBF's coverage area. When switching to a regional extract, also
adjust `PBF_BLOB_PATH` / `PBF_LOCAL_PATH` so the filename reflects
the source (e.g. `initial/germany-latest.osm.pbf`).

## Storage layout

| Path                  | Backing                                   | Purpose                                          |
| --------------------- | ----------------------------------------- | ------------------------------------------------ |
| `/mnt/data/nodes.bin` | Premium SSD managed disk (256 GiB+, LUN 0)| osm2pgsql flat-nodes — random 8-byte reads       |
| `/mnt/data/*.osm.pbf` | same disk                                 | Source PBF for initial import                    |
| `/mnt/data/*.osc.gz`  | same disk                                 | Per-iteration replication diffs                  |
| `pg_data` (in PG)     | PG Flex Server P30 storage                | `planet_osm_*` rendered tables + `nodes`/`ways`  |

`/mnt/data` is ext4 (label `osm-data`), mounted via `/etc/fstab`
(`LABEL=osm-data … nofail,discard`).

PG `max_connections=200`. **The VM, the PG Flex Server, and the blob
storage account must all be in the same Azure region** — cross-region
latency on every libpq round-trip and every blob read defeats the
performance numbers in this document.

## Cost (USD/month, May 2026)

| Resource                         | Always-on  | Scheduled (1 h/day) |
| -------------------------------- | ---------- | ------------------- |
| VM E32-8s_v5                     | ~$1,400    | ~$60                |
| VM data disk 256 GiB Premium     | ~$40       | ~$40                |
| PG D8ds_v5 + P40 storage         | ~$650      | ~$650               |
| Log Analytics + bandwidth        | <$20       | <$20                |
| **Total**                        | **~$2,100**| **~$800**           |

Scheduled column assumes the VM is deallocated outside a ~1 h daily
window (start → update → deallocate). The Premium SSD keeps
`nodes.bin` durable across the cycle.

## Operations

- **TODO — Secrets**: move `PGPASSWORD` from env var to Key Vault,
  fetched at runtime via the VM's managed identity.
- **TODO — VM SSH auth**: replace the local `osmadmin` password with
  Entra ID login (`AADSSHLoginForLinux` + RBAC) and `az ssh vm`.
- **Patching**: Ubuntu `unattended-upgrades` + Azure Update Manager.
- **Monitoring**: Defender for Cloud (`MDE.Linux`) + Log Analytics
  workspace `osm-updater-logs`. Alert on `osm-update.service` failure
  or run time > 90 min once the systemd timer is wired up.
- **Backup**: PG Flex Server PITR covers the rendered tables. To reset
  for testing, drop the `planet_osm_*` schema, delete
  `/mnt/data/nodes.bin`, and re-run [init-osm.sh](init-osm.sh).
- **DR**: rebuild = re-run [init-osm.sh](init-osm.sh) (~40 min Germany,
  ~8-12 h planet). PG Flex has its own PITR.

Defender for Cloud auto-creates a few artifacts (`MDE.Linux` extension,
JIT NSG, PE NICs, Malware Scanning tags) — intentionally not in Bicep.

---

## Performance reference

Single Germany replication day (~5-6 MB diff), end-to-end
`update-osm.sh` wall time, on the current sizing
(E32-8s_v5, Premium SSD v2 750 MB/s, PG **D8ds_v5 + P30 throughout**,
tuned `max_wal_size` + `max_parallel_maintenance_workers`,
`synchronous_commit=off`):

| Operation                                       | Germany (measured) |
| ----------------------------------------------- | ------------------ |
| Initial load (`init-osm.sh`)                    | **~30 min**        |
| Warm-up (`vmtouch -t nodes.bin`, ~50 GB)        | **~1 min**         |
| One day of replication (`update-osm.sh`, warm)  | **~120 s**         |
| 5 days catch-up (warm)                          | **~7 min**         |
| One day, warm cache, default `synchronous_commit` | ~250 s           |
| One day, cold cache (no Step 0 warm-up)         | ~25 min            |
| One day, cold cache, NFS (Azure Files) — old    | aborted            |
| One day, Container Apps Job, NFS                | unstable — see *Why VM* |

Planet numbers on the same architecture (E32-8s_v5 VM, Premium SSD v2,
PG **D8ds_v5 + P40 throughout**) are captured below from an actual
run — see [Planet, measured (2026-07)](#planet-measured-2026-07).

### Planet, measured (2026-07)

Actual numbers from a full-planet build against the same architecture,
with PG at `D8ds_v5` (8 vCore / 32 GiB) on P40 storage for **both**
initial load and steady-state updates, and the VM at `E32-8s_v5`:

| Operation                                                | Planet (measured, D8ds_v5 PG)     |
| -------------------------------------------------------- | --------------------------------- |
| **Initial load (`init-osm.sh`) on D8ds_v5 PG**           | **~13–14 h**                      |
|   ├─ Reading input files (nodes + ways + relations)      | 8 h 18 m                          |
|   │   ├─ 10.73 B nodes                                    | 16 m (~11.0 M/s)                  |
|   │   ├─ 1.20 B ways                                      | 2 h 26 m (~137 k/s)               |
|   │   └─ 14.54 M relations                                | 5 h 36 m (~721 /s)                |
|   └─ Postprocessing (cluster + geom/osm_id indexes + ANALYZE) | ~4–5 h (polygon is the long tail) |
| One day of replication (warm) on D8ds_v5 PG              | **~30 min**                       |
| Warm-up (`vmtouch -t nodes.bin`, ~112 GiB)               | **~12 s** (from OS page cache)    |

Run captured 2026-07-16 (`planet-latest.osm.pbf`, osm2pgsql 1.11.0,
PostGIS 3.6 on PostgreSQL 17.10). Full log preserved in
`~/osm-work/init-osm.log` on the VM.

Notes:
- **D8ds_v5 handles init directly** — no scale-up-then-down dance is
  needed. Sustained PG CPU stayed at ≈ 15 % and RAM at ≈ 30 % during
  the read phase; P40 storage (7,500 IOPS / 250 MB/s) is the actual
  bottleneck. The four postprocessing tables cluster and index in
  parallel; `planet_osm_polygon` is the long tail (~3–4 h alone).
- The `D8ds_v5` VM-side I/O ceiling (12,800 IOPS / 288 MB/s uncached)
  still exceeds P40's throughput cap, so the COPY phase runs at the
  same speed as it would on `D16ds_v5`. D16 only helps the parallel
  `CREATE INDEX` step and shaves ~1–2 h off total wall time — not
  worth the compute cost for a one-off init.
- Optional speed-up: bump PG to `D16ds_v5` for init only via
  `az postgres flexible-server update` (online, ~1–2 min restart),
  then scale back to `D8ds_v5` for daily updates. Skip this unless
  init wall time is on the critical path.
- Each daily update on the planet dataset is roughly one order of
  magnitude larger than the Germany-extract number above because the
  daily diff itself is ~50–100 MB and the affected geometry set spans
  the whole planet.
- Steady-state PG cache-hit ratio at ~93 % on 780 GB DB with 8 GiB
  `shared_buffers` — indexes fit in RAM, heap pages spill to P40.

**Takeaway:** for a daily-cron VM that deallocates between runs, the
two levers that matter are:

1. **Warm `nodes.bin` into RAM at boot** (`vmtouch -t`, ~70 s on a
   750 MB/s Premium SSD v2). Without this, the Node phase stays at
   ~3k/s for the entire run.
2. **`ALTER ROLE … SET synchronous_commit = off`** for the import role.
   Removes per-commit WAL fsync wait from the pending-ways/relations
   phase.

Neither requires scaling the VM or PG SKU. PG metrics during a daily
run show CPU < 5% and disk IOPS < 1% — the database is not the
bottleneck for steady-state updates.

---

## Scaling to planet

Germany was the validation target. The same architecture scales to
the full planet, but several sizing assumptions change. See
[Performance reference](#performance-reference) for the measured
Germany numbers and the corresponding planet estimates side-by-side.

### Resource targets for planet

| Resource         | Germany (current)             | Planet (recommended)                                   |
| ---------------- | ----------------------------- | ------------------------------------------------------ |
| VM SKU           | E32-8s_v5 (32 vCPU / 256 GB)  | **E32s_v5** (full 32 cores) for init; back to E32-8s_v5 for daily |
| `/mnt/data` size | 256 GB Premium SSD v2         | **512 GB** Premium SSD v2 (~108 GB nodes.bin + ~80 GB PBF during init + headroom) |
| `/mnt/data` IOPS | 3000                          | 3000 (still random-read latency-bound, not IOPS-bound) |
| `/mnt/data` MB/s | 750                           | **1200** (warm-up reads ~110 GB; 1200 MB/s ≈ 90 s)     |
| PG SKU           | D8ds_v5 (8 vCPU / 32 GB)      | **D8ds_v5** unchanged — measured OK for planet init and daily (bump to `D16ds_v5` only if init wall time is critical) |
| PG storage       | P30 (1 TiB / 5,000 IOPS)      | **P40** (2 TB / 7,500 IOPS / 250 MB/s) — capacity-driven |
| PG params        | `max_wal_size=16384`, `max_parallel_maintenance_workers=4` | Same, plus `max_wal_size=32768` during init |

### Why these numbers

- **VM RAM (256 GB is enough).** Planet `nodes.bin` is ~108 GB today
  and grows ~10 GB/year, so the existing E32 family (256 GB) has
  ~140 GB headroom — enough for the page cache plus PBF read
  buffering, and ~10 years of growth. No need to jump to E64s_v5.
  Switch from `E32-8s_v5` (8 active vCPU) to `E32s_v5` (full 32) for
  the duration of init so `osm2pgsql`'s parallel processing phase
  uses all cores; switch back for daily.
- **VM disk MB/s.** Warm-up time = `nodes.bin size / disk MB/s`.
  Germany: 50 GB / 750 MB/s ≈ 67 s (measured ~60 s). Planet at
  750 MB/s = ~150 s; at 1200 MB/s = ~90 s. Premium SSD v2 caps at
  1200 MB/s on a single disk, which is the right ceiling.
- **VM disk IOPS.** Even at 100 % cache miss the warm-up is sequential,
  so MB/s is what matters; runtime random reads after warm-up hit RAM,
  not the disk. 3000 IOPS is sufficient.
- **PG SKU.** `CREATE INDEX` on `planet_osm_*` is the dominant init
  phase, and the pending-ways/relations apply is the dominant update
  phase — both want PG CPU + RAM. The **D8ds_v5** baseline
  (8 cores / 32 GiB RAM, ~8 GiB shared_buffers) handles Germany init
  in ~30 min and the full planet in ~13–14 h (see measured numbers
  above); daily updates stay PG-side hot via OS page cache. P40
  storage (7,500 IOPS / 250 MB/s) is the actual bottleneck during
  init, so bumping to D16ds_v5 shaves only ~1–2 h off planet init
  and is not worth the doubled compute cost for daily runs. Bump PG
  only if init wall time is on the critical path.
- **PG storage.** Planet base + indexes ≈ 1.5 TB, so capacity alone
  forces you off P30 — P40 (2 TB) is the natural step up and its
  bundled 7,500 IOPS / 250 MB/s comfortably cover init WAL and daily
  updates. Premium SSD v2 is only worth it if you want to tune IOPS
  independently of size; for this workload P40 is simpler.
- Run logs are appended via `tee -a ~/osm-work/{init,update}-osm.log`.
  Growth is negligible (~5–20 KB per daily run), so no rotation is
  configured. Switch to a dated filename or add `logrotate` if you
  prefer per-run logs.

### What does **not** need to change

- Architecture (VM + Flex Server + private endpoints + UAI).
- Bicep modules: only param values change (`vmSize`, `dataDiskSizeGB`,
  `dataDiskThroughputMBps`, `pgSkuName`, `pgStorageSizeGB`).
- Scripts: [init-osm.sh](init-osm.sh) and [update-osm.sh](update-osm.sh)
  are size-agnostic. The defaults already target the full planet
  (`SOURCE_PBF_URL` = `https://planet.openstreetmap.org/pbf/planet-latest.osm.pbf`,
  `REPLICATION_SERVER` = `https://planet.openstreetmap.org/replication/day/`);
  no script changes needed. Only override these two env vars (as a
  pair) if you want a Geofabrik regional extract instead.
- Defender for Cloud, JIT, malware scan, logging — unchanged.

### What to watch during the first planet run

1. **Page-cache resident pages**: `vmtouch /mnt/data/nodes.bin`
   after warm-up should show 100 % resident and stay that way.
   Watch via `watch -n 60 'vmtouch /mnt/data/nodes.bin | tail -2'`.
2. **PG IOPS / Storage Throughput consumed %** during init's index
   phase. If sustained > 80 %, bump PG storage IOPS.
3. **VM uncached disk MB/s** during warm-up. If `iostat -x 1` shows
   `/mnt/data` saturating before 1200 MB/s, the disk is the cap, not
   the VM.

If any of these saturate, scale the dimension that saturated — not
the others.

---

## Why VM (not Container Apps Job, not always-on)

Azure Container Apps Job was measured and rejected. CAJ mounts
`nodes.bin` over NFS, and the cgroup/NFS-client combination silently
evicts warmed pages between iterations of the same job — see the
CAJ row in [What was tried and discarded](#what-was-tried-and-discarded)
for the iteration timings. There is no platform knob to pin pages
(`RLIMIT_MEMLOCK` is fixed at 64 KB on CAJ).

The VM avoids both issues: `nodes.bin` lives on a local block device,
and the kernel page cache only reclaims under real memory pressure —
with 256 GB RAM and a 50-100 GB working set there is none, so pages
stay resident for the entire VM uptime. SSH, `top`, `iostat`,
`journalctl`, and `mlock` are all available for debugging.

Always-on VM was the original design but cold-cache reads from the
Premium SSD are fast enough that paying ~$1,000/mo just to preserve
cache is not worth it. Default mode is now:
deallocate → start before scheduled run → update → deallocate.

### What was tried and discarded

- **NFS share for `nodes.bin`** (Azure Files Premium 4.1, mounted at
  `/mnt/flatnodes`). Worked when warm but ~5× slower on cold starts
  than the local Premium SSD v2 on `/mnt/data` (every random 8-byte
  read paid a ~5 ms NFS RTT vs ~1 ms on Premium SSD v2). Removed in
  favour of the local Premium SSD v2. Storage account, file PE, and
  `privatelink.file.core.windows.net` zone deleted.
- **Azure Container Apps Job (May 2 2026).** Workload profile E32
  (32 vCPU / 256 GiB), container limit 16 vCPU / 200 GiB, NFS-mounted
  `nodes.bin`, explicit `vmtouch -t` prewarm:

  | Iteration | Time   | `vmtouch` resident pages |
  | --------- | ------ | ------------------------ |
  | Prewarm   | 575 s  | 102 GB / 102 GB → 100 %  |
  | 1         |  98 s  | warm                     |
  | 2         | 668 s  | **0 / 102 GB → 0 %**     |

  Net effect: every iteration after the first is a 10-min cold-NFS
  scan, on top of a 10-min prewarm at job start. A 10-day catch-up
  becomes ~2 hours instead of the ~15 min that warm cache should give.
  Also: no `kubectl exec`-style debugging, logs only via Log Analytics,
  `RLIMIT_MEMLOCK` fixed at 64 KB so `mlock` pinning is impossible.
  All CAJ-era code is preserved under [old_serverless/](old_serverless/).
- **No flat-nodes (PG `planet_osm_nodes` only).** Works for Germany
  (~6 GB table). For the planet the table is 200-300 GB → either need
  a 256+ GiB-RAM PG SKU or it's just as slow as cold NFS. Moves the
  always-on RAM cost to the DB without saving anything.
- **AKS pod with node affinity.** Technically viable but adds
  cluster-management overhead the team doesn't have.