# azure-osm-replicator

Azure reference implementation for keeping a planet-scale OpenStreetMap
PostGIS database current via daily Geofabrik / OSM replication diffs,
using `osm2pgsql --append --slim --flat-nodes` on a scheduled Linux VM
backed by Azure Database for PostgreSQL Flexible Server.

## Quick start

1. Provision storage, PG Flex Server, networking, and the import VM
   ([infra/](infra/)) — `bash infra/deploy.sh` (set `DEPLOY_STORAGE=1
   DEPLOY_PG=1` for greenfield).
2. On the PG Flex Server, run the four one-time prerequisites — see
   [Prerequisites](#prerequisites-one-time-on-the-pg-flex-server):
   create the target database, allow-list `postgis` + `hstore`, reset
   the `public` schema and enable the extensions, and set
   `max_wal_size=16384` + `max_parallel_maintenance_workers=4`.
3. Run [init-osm.sh](init-osm.sh) on the VM (~20 min for Germany on
   the **D16ds_v5 / P30** baseline — no scale-up/scale-down dance
   needed; the same SKU handles both init and daily updates).
4. Run [update-osm.sh](update-osm.sh) daily (wire to a systemd timer);
   Step 0 pre-warms `nodes.bin` into the OS page cache so each
   replication day finishes in ~120 s.
5. Deallocate the VM between runs — `/mnt/data` survives stop/start
   so `nodes.bin` does not need re-importing.

For the rationale behind each step (page-cache mechanics,
`synchronous_commit=off`, why CAJ was rejected) see
[Cold cache vs warm cache](#cold-cache-vs-warm-cache-why-step-0-matters),
[Performance reference](#performance-reference), and
[Why VM](#why-vm-not-container-apps-job-not-always-on).
For a full-planet build see [Scaling to planet](#scaling-to-planet).

## Architecture

```
┌──────────────────────────────────────────────────────────────────────┐
│  test-flosm-rg  (single Azure region)                                │
│                                                                      │
│  ┌──────────────────────────────────┐                                │
│  │  osm-import-vm                   │                                │
│  │  Ubuntu 24.04                    │                                │
│  │  Standard_E32-8s_v5 (128 GB RAM) │                                │
│  │                                  │                                │
│  │  /mnt/data  ── 256 GiB Premium ──┼── nodes.bin  (~70 GB DE)       │
│  │             SSD managed disk     │   germany-latest.osm.pbf       │
│  │                                  │   per-iteration .osc.gz        │
│  │  init-osm.sh / update-osm.sh     │                                │
│  └──────┬───────────────────────────┘                                │
│         │ libpq via private endpoint                                 │
│         ▼                                                            │
│  ┌──────────────────────┐    ┌───────────────────────────────────┐   │
│  │ PE → PG Flex Server  │    │ PE → testpubliclandingzone        │   │
│  │ test-database-pg     │    │ blob (Defender malware-scanned)   │   │
│  │ D16ds_v5 / P30 / v17 │    │ container: osmscanning            │   │
│  └──────────────────────┘    └───────────────────────────────────┘   │
└──────────────────────────────────────────────────────────────────────┘

External:  Geofabrik replication server (HTTPS) — daily .osc.gz diffs
```

- **One Linux VM** (`Standard_E32-8s_v5`) runs both the one-time initial
  import and the daily updater. Deallocated between runs; started a few
  minutes before each scheduled update.
- **Azure Database for PostgreSQL Flexible Server** stores the rendered
  geodata (`planet_osm_*` tables).
- **One Premium SSD managed disk on the VM** (`/mnt/data`) holds
  `nodes.bin` and per-iteration diffs. Survives deallocate/start.
- All infra is captured in [infra/](infra/) Bicep.

## Deploy (see **TODO — Secrets** how to improve secrets mgnt)

```bash
export VM_ADMIN_PASSWORD='...'
bash infra/deploy.sh                       # against existing storage + PG

DEPLOY_STORAGE=1 DEPLOY_PG=1 \
PG_ADMIN_PASSWORD='...' \
bash infra/deploy.sh                       # full greenfield
```

Cloud-init in [infra/modules/cloud-init.yaml](infra/modules/cloud-init.yaml)
installs `osm2pgsql`, `azcopy`, `pyosmium`, `azure-cli`, `psql`, `jq`,
then formats and mounts `/mnt/data`.

`az deployment group what-if` confirms the deploy is idempotent
(0 creates, 0 deletes against the existing RG).

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

   Combined with the **D16ds_v5** baseline (16 vCores / 64 GiB RAM)
   and **P30** Premium SSD v1 storage (1 TiB / 5,000 IOPS / 200 MB/s),
   Germany init lands at **~20 min**. No scale-up/scale-down dance is
   required: the same SKU handles both init and daily updates.
   `maintenance_work_mem` is already capped at 2 GB on D16ds_v5 and
   doesn't need to be touched.

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
The replication source (`REPLICATION_SERVER`) defaults to Geofabrik
Germany; switch to [planet.openstreetmap.org](https://planet.openstreetmap.org/replication/day/)
for a full-planet load.

### Cold cache vs warm cache (why Step 0 matters)

`osm2pgsql --append`'s Node phase issues **single-threaded random
8-byte reads** against `nodes.bin`. Each read pays one round-trip to
the disk:

| State of `nodes.bin` | Per-op latency | Effective rate    |
| -------------------- | -------------- | ----------------- |
| In OS page cache     | ~50 ns (RAM)   | 60-100k+ nodes/s  |
| On Premium SSD v2    | ~1 ms          | ~3k nodes/s       |

That 20-30× gap is the difference between a 2-minute daily update and
a 30-minute one. Provisioning more disk IOPS does **not** help — the
phase is single-threaded and latency-bound, not IOPS-bound.

A VM stop/deallocate (and any reboot) wipes RAM, so the page cache is
cold on every boot. [update-osm.sh](update-osm.sh) Step 0 sequentially
reads `nodes.bin` once via `vmtouch -t` to populate the cache. At
~750 MB/s (the disk's provisioned throughput, capped by the VM's
~865 MB/s uncached limit on `Standard_E32-8s_v5`) this costs ~70 s for
a 50 GB Germany flat-nodes file; bumping the disk's provisioned MB/s
shortens it proportionally up to the VM cap. After warm-up every
subsequent random lookup is a RAM hit.

A second piece of the same story: `osm2pgsql --append` runs many small
INSERTs against PG during the postprocess phase, each blocking on WAL
fsync. [update-osm.sh](update-osm.sh) sets
`ALTER ROLE <user> SET synchronous_commit = off` so commits return as
soon as the WAL record is in PG memory. Replay is idempotent
(re-fetched from `osm2pgsql_properties` on crash), so the durability
trade-off is acceptable for this workload.


## Storage layout

| Path                  | Backing                                   | Purpose                                          |
| --------------------- | ----------------------------------------- | ------------------------------------------------ |
| `/mnt/data/nodes.bin` | Premium SSD managed disk (256 GiB+, LUN 0)| osm2pgsql flat-nodes — random 8-byte reads       |
| `/mnt/data/*.osm.pbf` | same disk                                 | Source PBF for initial import                    |
| `/mnt/data/*.osc.gz`  | same disk                                 | Per-iteration replication diffs                  |
| `pg_data` (in PG)     | PG Flex Server P30 storage                | `planet_osm_*` rendered tables + `nodes`/`ways`  |

`/mnt/data` is ext4 (label `osm-data`), mounted via `/etc/fstab`
(`LABEL=osm-data … nofail,discard`).

## Sizing

| Component          | Initial import           | Steady-state daily      |
| ------------------ | ------------------------ | ----------------------- |
| VM                 | E32-8s_v5 (current)      | E16s_v5 (resize down)   |
| VM data disk       | 256+ GiB Premium SSD     | 64-128 GiB Premium SSD  |
| PG SKU             | D16ds_v5                 | D16ds_v5                |
| PG storage         | P30 (~5,000 IOPS)        | P40 for planet          |

PG `max_connections=200`. **The VM, the PG Flex Server, and the blob
storage account must all be in the same Azure region** — cross-region
latency on every libpq round-trip and every blob read defeats the
performance numbers in this document.

## Cost (USD/month, May 2026)

| Resource                         | Always-on  | Scheduled (1 h/day) |
| -------------------------------- | ---------- | ------------------- |
| VM E32-8s_v5                     | ~$1,400    | ~$60                |
| VM data disk 256 GiB Premium     | ~$40       | ~$40                |
| PG D16ds_v5 + P30 storage        | ~$950      | ~$950               |
| Log Analytics + bandwidth        | <$20       | <$20                |
| **Total (Germany)**              | **~$2,400**| **~$1,100**         |

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
(E32-8s_v5, Premium SSD v2 750 MB/s, PG **D16ds_v5 + P30 throughout**,
tuned `max_wal_size` + `max_parallel_maintenance_workers`,
`synchronous_commit=off`):

| Operation                                       | Germany (measured) |
| ----------------------------------------------- | ------------------ |
| Initial load (`init-osm.sh`)                    | **~20 min**        |
| Warm-up (`vmtouch -t nodes.bin`, ~50 GB)        | **~1 min**         |
| One day of replication (`update-osm.sh`, warm)  | **~120 s**         |
| 5 days catch-up (warm)                          | **~7 min**         |
| One day, warm cache, default `synchronous_commit` | ~250 s           |
| One day, cold cache (no Step 0 warm-up)         | ~25 min            |
| One day, cold cache, NFS (Azure Files) — old    | aborted            |
| One day, Container Apps Job, NFS                | unstable — see *Why VM* |

Same dimensions extrapolated to planet sizing (E64s_v5 / 1200 MB/s,
PG D32ds_v5 + P40 throughout) — see
[Scaling to planet](#scaling-to-planet) for the full sizing rationale:

| Operation                                       | Planet (estimated) |
| ----------------------------------------------- | ------------------ |
| Initial load                                    | **8-12 h**         |
| Warm-up (`vmtouch -t nodes.bin`, ~110 GB)       | **~90 s**          |
| One day of replication (warm)                   | **~60 min**        |
| 5 days catch-up (warm)                          | **~5 h**           |
| One day, cold cache                             | many hours         |

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
| PG SKU           | D16ds_v5 (16 vCPU / 64 GB)    | **D32ds_v5** (32 vCPU / 128 GB) for init and daily     |
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
  phase — both want PG CPU + RAM. D16ds_v5 (16 cores / 64 GiB RAM,
  ~16 GiB shared_buffers) brings Germany init to ~20 min and keeps
  daily updates PG-side hot via OS page cache. For planet, scale up
  to D32ds_v5 and leave it there — daily diffs are ~20× Germany.
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
  are size-agnostic. Only `PBF_BLOB_PATH` and `REPLICATION_SERVER`
  change (`https://planet.openstreetmap.org/replication/day/`).
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