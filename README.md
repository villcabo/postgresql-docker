# PostgreSQL Docker

*Read this in [Español](README.es.md).*

Parameterized PostgreSQL stack. Network and data volume are **external** —
you create them manually — so you keep full control over MTU, driver
options, labels, backups, and migrations.

## Table of contents

- [Features](#features)
- [Layout](#layout)
- [Quick start](#quick-start)
- [Environment variables](#environment-variables)
- [Syncing `.env` with `.env.example`](#syncing-env-with-envexample)
- [Network (manual creation)](#network-manual-creation)
- [Data volume (manual creation)](#data-volume-manual-creation)
- [PostgreSQL version and data layout](#postgresql-version-and-data-layout)
- [Tuning (`POSTGRES_COMMAND` + pgtune)](#tuning-postgres_command--pgtune)
- [Logs](#logs)
- [Operations](#operations)
- [Upgrading between major versions](#upgrading-between-major-versions)
- [Backups](#backups)
- [Troubleshooting](#troubleshooting)

## Features

- Single-file `docker-compose.yml`, parameterized via `.env`.
- External network (you set MTU, driver, subnet, labels).
- External named volume for data (portable, inspectable, easy to back up).
- Bind-mounted host directory for logs (tail from host).
- Runtime tuning via a single `POSTGRES_COMMAND` variable (pgtune-friendly).
- Healthcheck via `pg_isready`.
- Works with any `postgres` image tag (PG 12 → 18+).

## Layout

```
.
├── docker-compose.yml   # Parameterized stack (single service)
├── .env.example         # Template — copy to .env
├── .env                 # Your local config (gitignored)
├── scripts/             # Helper scripts (env-sync, pgtune-apply)
├── logs/                # PG log files (created on first run, only if enabled)
└── README.md
```

## Quick start

End-to-end from zero:

```bash
# 1. Clone the repo
git clone git@github.com:villcabo/postgresql-docker.git
cd postgresql-docker

# 2. Create your local env file (everything commented → defaults from compose)
cp .env.example .env
$EDITOR .env                       # uncomment what you want to override

# 3. Create the external docker network (set MTU to fit your host / VPN)
docker network create \
  --driver bridge \
  --opt com.docker.network.driver.mtu=1500 \
  postgres_net

# 4. Create the external docker volume for data
docker volume create postgres_data

# 5. Bring the stack up
docker compose up -d

# 6. Watch it boot
docker compose logs -f postgres

# 7. Sanity check
docker compose exec postgres pg_isready -U postgres
docker compose exec postgres psql -U postgres -c "SELECT version();"
```

Pulling new updates later:

```bash
git pull
./scripts/env-sync.sh                      # merge any new variables into your .env
docker compose pull                # pull the image tag pinned in .env
docker compose up -d
```

## Environment variables

All variables live in `.env` (copy from `.env.example`). Every one is
optional — defaults apply when unset. See `.env.example` for the full
reference with comments.

| Variable | Default | Purpose |
|---|---|---|
| `POSTGRES_VERSION` | `18-alpine` | Image tag |
| `POSTGRES_USER` | `postgres` | Superuser (first-boot only) |
| `POSTGRES_PASSWORD` | `postgres` | Superuser password (first-boot only) |
| `POSTGRES_DB` | `postgres` | Default DB (first-boot only) |
| `POSTGRES_INITDB_ARGS` | *(empty)* | Extra `initdb` flags (first-boot only) |
| `POSTGRES_BIND_HOST` | `127.0.0.1` | Host interface to publish on |
| `POSTGRES_PORT` | `5432` | Host port |
| `POSTGRES_NETWORK` | `postgres_net` | External docker network name |
| `POSTGRES_DATA_VOLUME` | `postgres_data` | External docker volume name |
| `POSTGRES_LOGS_DIR` | `./logs` | Host dir for log files |
| `POSTGRES_COMMAND` | *(empty)* | Extra `-c key=value` flags for runtime tuning |
| `SHM_SIZE` | `256mb` | `/dev/shm` size for the container |
| `STOP_GRACE_PERIOD` | `1m` | Seconds before SIGKILL on stop |
| `TZ` | `UTC` | Time zone |

Hardcoded in `docker-compose.yml` (edit the file if you need them different):
`container_name=postgres`, `hostname=postgres`, `restart=unless-stopped`,
data mount target `/var/lib/postgresql`.

## Syncing `.env` with `.env.example`

When `.env.example` gains new variables (pulled from upstream), run
`./scripts/env-sync.sh` to merge them into your existing `.env` **without losing
the values you already set**.

```bash
./scripts/env-sync.sh              # interactive: shows a unified diff, asks to confirm
./scripts/env-sync.sh -n           # dry-run: shows the diff and exits, never writes
./scripts/env-sync.sh -y           # non-interactive: apply without asking (CI / scripts)
./scripts/env-sync.sh -y PATH_TO_EXAMPLE PATH_TO_ENV   # custom paths
```

What it does:

- Rebuilds `.env` using the structure, order and comments of `.env.example`.
- Keeps the value of every key you already have uncommented in `.env`.
- Adds every new key from the example (commented, with its default).
- Preserves keys that exist only in your `.env` (custom or legacy) in a
  "Legacy / custom" section at the bottom — nothing is silently lost.
- **Shows a unified diff + a summary** (preserved / added / orphan counts)
  **before writing anything** and waits for `[y/N]` confirmation.
- Refuses to apply non-interactively unless `-y` is given.
- Writes a timestamped backup `.env.bak.YYYYMMDD-HHMMSS` before overwriting
  `.env` (so older backups are never clobbered).
- Exits with "no changes" if `.env` is already in sync.

## Network (manual creation)

The compose file declares the network as `external: true`. Create it before
`up`, adjusting options to your environment.

```bash
# Basic
docker network create postgres_net

# Bridge with custom MTU (e.g. for VPN / WireGuard hosts)
docker network create \
  --driver bridge \
  --opt com.docker.network.driver.mtu=1450 \
  postgres_net

# With fixed subnet and gateway
docker network create \
  --driver bridge \
  --subnet 172.28.0.0/24 \
  --gateway 172.28.0.1 \
  --opt com.docker.network.driver.mtu=1500 \
  postgres_net
```

Inspect / delete:

```bash
docker network inspect postgres_net
docker network rm postgres_net   # stop the stack first
```

Docker does NOT allow in-place MTU changes — to change it, stop the stack,
remove and recreate the network, then `docker compose up -d`.

## Data volume (manual creation)

The data volume is external. Create it manually:

```bash
# Default local driver
docker volume create postgres_data

# With labels for backup tooling
docker volume create \
  --label project=postgres \
  --label backup=daily \
  postgres_data

# Bind-backed (map the volume to a specific host directory)
docker volume create \
  --driver local \
  --opt type=none \
  --opt device=/srv/postgres-data \
  --opt o=bind \
  postgres_data
```

Inspect:

```bash
docker volume inspect postgres_data
docker volume ls
```

**Why external?** You stay in control of lifecycle. `docker compose down -v`
cannot wipe it. You can move the volume between projects, attach backup
sidecars, or swap drivers without touching the compose file.

## PostgreSQL version and data layout

PG 18 changed the Docker image's data layout:

| Version | Mount target (inside container) |
|---|---|
| PG 18+ | `/var/lib/postgresql` *(what this compose uses)* |
| PG ≤17 | `/var/lib/postgresql/data` |

`docker-compose.yml` hardcodes the PG 18+ target. If you need to run PG 17
or older, edit `docker-compose.yml` and change:

```yaml
- postgres_data:/var/lib/postgresql
```

to:

```yaml
- postgres_data:/var/lib/postgresql/data
```

A volume initialized for one layout **cannot** be reused by the other — see
[Upgrading between major versions](#upgrading-between-major-versions).

## Tuning (`POSTGRES_COMMAND` + pgtune)

All runtime tuning goes through a single env var: `POSTGRES_COMMAND`. It is
passed verbatim to the `postgres` binary as extra `-c key=value` arguments.
This keeps everything in one place (`.env`) and avoids juggling
`postgresql.conf` files inside the container.

### Step 1 — Generate values with pgtune

Open <https://pgtune.leopard.in.ua/> and fill the form:

| Field | What to pick |
|---|---|
| **DB Version** | The major version you run (16, 17, 18…) |
| **OS Type** | `Linux` |
| **DB Type** | `OLTP` (web apps), `Data warehouses`, `Mixed`, `Desktop` |
| **Total Memory (RAM)** | Your host RAM — or the **share you want PG to use** if the host runs other things (e.g. on a 30 GB laptop, plug in `16 GB`, not `30 GB`) |
| **Number of CPUs** | `nproc` (threads on Linux) |
| **Number of Connections** | Realistic concurrent connections. **Do not just bump this** to "fix" pool exhaustion — see below. |
| **Data Storage** | `SSD` for any modern setup; `Network (SAN)` for remote storage |

Click **Generate** and copy the right-hand block.

### Step 2 — Save pgtune output to `pgtune.txt` and apply

Save the block pgtune gave you (the right-hand panel, `key = value` lines —
comments are fine) into a file called `pgtune.txt` at the repo root, then
run:

```bash
./scripts/pgtune-apply.sh                # interactive: preview + confirm
./scripts/pgtune-apply.sh -n             # dry-run: preview only
./scripts/pgtune-apply.sh -y             # non-interactive (CI / scripts)
./scripts/pgtune-apply.sh INPUT ENV      # custom paths
```

The script:

- Parses every `key = value` line (skipping pgtune's comments / blanks).
- Builds `POSTGRES_COMMAND="-c key=value -c …"` as a single line.
- Computes `SHM_SIZE = shared_buffers + 500 MB` automatically (see step 3).
- Replaces `POSTGRES_COMMAND` / `SHM_SIZE` in `.env` if present, else
  appends them.
- Shows a unified diff + summary, asks for `[y/N]` confirmation.
- Writes a timestamped backup `.env.bak.YYYYMMDD-HHMMSS` before applying.

If you prefer to edit `.env` by hand, the equivalent is just:

```bash
POSTGRES_COMMAND="-c max_connections=200 -c shared_buffers=2GB …"
```

Pasted as one line, quoted.

> **Heads up:** pgtune sometimes emits `wal_compression=lz4` and
> `io_method=io_uring`. These require the `postgres` binary to be built
> with `--with-lz4` and `--with-liburing`. If your image doesn't have
> them, edit `pgtune.txt` to remove those lines before applying, or PG
> will refuse to start with a clear error.

### Step 3 — Don't forget `SHM_SIZE`

The container's `/dev/shm` must be **≥ `shared_buffers`** or PG will crash
allocating shared memory. Add some headroom (≈ 500 MB). **The
`pgtune-apply.sh` script in step 2 already does this for you;** the
manual equivalent is:

```bash
# In .env, for shared_buffers=2GB:
SHM_SIZE=2500mb
```

### Step 4 — Apply

```bash
# max_connections, shared_buffers and SHM_SIZE require a full restart:
docker compose down
docker compose up -d
```

For everything else (work_mem, effective_cache_size, etc.) you can reload
without downtime:

```bash
docker compose exec postgres psql -U postgres -c "SELECT pg_reload_conf();"
```

### Step 5 — Verify the running config

Confirm PG actually picked up the values:

```bash
# Spot-check one parameter
docker compose exec postgres psql -U postgres -c "SHOW max_connections;"

# Full table of the parameters pgtune touches
docker compose exec postgres psql -U postgres -c "
  SELECT name, setting, unit
  FROM pg_settings
  WHERE name IN (
    'max_connections','shared_buffers','effective_cache_size',
    'maintenance_work_mem','work_mem','wal_buffers',
    'min_wal_size','max_wal_size','checkpoint_completion_target',
    'random_page_cost','effective_io_concurrency','default_statistics_target',
    'max_worker_processes','max_parallel_workers',
    'max_parallel_workers_per_gather','max_parallel_maintenance_workers',
    'huge_pages'
  )
  ORDER BY name;"

# Current connection usage (sanity-check before raising max_connections)
docker compose exec postgres psql -U postgres -c "
  SELECT state, count(*) FROM pg_stat_activity GROUP BY state ORDER BY 2 DESC;"
```

### A note on `max_connections`

If you're hitting the connection cap, **the answer is almost never just a
bigger number**. Each connection is its own backend process (~10 MB
baseline + work_mem in queries). Raising the cap eats RAM linearly.

Symptoms of a client-side leak rather than a real capacity problem:

```sql
-- Many sessions stuck in 'idle in transaction' or 'idle' = pool leak
SELECT state, count(*) FROM pg_stat_activity GROUP BY state;
```

The proper fix is a **transaction-mode pooler in front of PG** (pgbouncer,
pgcat). 50 real PG connections can serve thousands of app-side ones.

## Logs

By default PG writes to stdout/stderr, which you read with
`docker compose logs -f postgres`.

To write rotated files to `./logs` on the host, append logging flags to
`POSTGRES_COMMAND`:

```bash
-c logging_collector=on \
-c log_directory=/var/log/postgresql \
-c log_filename=postgresql-%Y-%m-%d.log \
-c log_rotation_age=1d \
-c log_rotation_size=0
```

Then:

```bash
mkdir -p logs
sudo chown -R 70:70 logs   # alpine postgres UID
docker compose up -d
tail -f logs/postgresql-$(date +%F).log
```

Change the host directory via `POSTGRES_LOGS_DIR` in `.env`.

## Operations

```bash
# Start / stop
docker compose up -d
docker compose down           # keeps the external volume and network
docker compose restart

# Status and health
docker compose ps
docker compose exec postgres pg_isready -U "$POSTGRES_USER"

# psql shell
docker compose exec postgres psql -U "$POSTGRES_USER" -d "$POSTGRES_DB"

# Container shell
docker compose exec postgres sh

# Update image (pull newer patch)
docker compose pull
docker compose up -d
```

## Upgrading between major versions

`pg_upgrade` requires both old and new binaries and a layout switch between
PG 17 and PG 18. Simplest and safest: **dump and restore**.

```bash
# 1. Dump from the old running instance
docker compose exec postgres pg_dumpall -U "$POSTGRES_USER" > dump.sql

# 2. Stop and wipe the old data volume
docker compose down
docker volume rm postgres_data
docker volume create postgres_data

# 3. Bump the version in .env
#    POSTGRES_VERSION=18-alpine
# (and edit the mount target in docker-compose.yml if moving from PG <=17)

# 4. Boot the new version (creates empty cluster)
docker compose up -d
until docker compose exec -T postgres pg_isready -U "$POSTGRES_USER"; do sleep 1; done

# 5. Restore
cat dump.sql | docker compose exec -T postgres psql -U "$POSTGRES_USER" -d postgres
```

For in-place `pg_upgrade --link`, see upstream docs:
<https://github.com/docker-library/postgres/issues/37>.

## Backups

Quick logical backup:

```bash
docker compose exec -T postgres pg_dumpall -U "$POSTGRES_USER" \
  | gzip > "backup-$(date +%F).sql.gz"
```

Volume-level snapshot (stop the DB first for consistency):

```bash
docker compose stop postgres
docker run --rm -v postgres_data:/data -v "$PWD":/backup alpine \
  tar czf /backup/postgres_data-$(date +%F).tar.gz -C / data
docker compose start postgres
```

## Troubleshooting

**`Error: in 18+, these Docker images are configured to store database data…`**
You're running PG 18+ against a volume initialized under the legacy layout
(PG ≤17). Either go back to PG 17 (and change the mount target in
`docker-compose.yml` to `/var/lib/postgresql/data`), or dump + fresh volume
— see [Upgrading](#upgrading-between-major-versions).

**`network postgres_net declared as external, but could not be found`**
Create the network first: `docker network create postgres_net`.

**`volume postgres_data declared as external, but could not be found`**
Create the volume first: `docker volume create postgres_data`.

**Healthcheck fails immediately**
Large clusters take longer to start. Increase `start_period` in
`docker-compose.yml` or check logs: `docker compose logs postgres`.

**Permission denied on `./logs`**
The container writes as the `postgres` user (UID 70 on alpine). Fix:
`sudo chown -R 70:70 ./logs`.

**Connection refused from another container**
Attach that container to the same `postgres_net` network and use
`postgres` (the container hostname) or the published port on the host.
