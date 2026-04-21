# PostgreSQL Docker

Parameterized PostgreSQL stack. Network and data volume are **external** —
you create them manually — so you keep full control over MTU, driver
options, labels, backups, and migrations.

## Table of contents

- [Features](#features)
- [Layout](#layout)
- [Quick start](#quick-start)
- [Environment variables](#environment-variables)
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
├── logs/                # PG log files (created on first run, only if enabled)
└── README.md
```

## Quick start

```bash
# 1. Copy env template (everything commented — defaults kick in)
cp .env.example .env

# 2. Create the external network (adjust MTU to your needs)
docker network create \
  --driver bridge \
  --opt com.docker.network.driver.mtu=1450 \
  postgres_net

# 3. Create the external data volume
docker volume create postgres_data

# 4. Start
docker compose up -d

# 5. Follow logs
docker compose logs -f postgres
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

All runtime tuning goes through `POSTGRES_COMMAND`. It's passed verbatim to
the `postgres` binary as extra arguments.

Generate values with [pgtune](https://pgtune.leopard.in.ua/) and paste them
into `.env`:

```bash
POSTGRES_COMMAND="-c max_connections=200 -c shared_buffers=2GB -c effective_cache_size=6GB -c maintenance_work_mem=512MB -c checkpoint_completion_target=0.9 -c wal_buffers=16MB -c default_statistics_target=100 -c random_page_cost=1.1 -c effective_io_concurrency=200 -c work_mem=2621kB -c huge_pages=off -c min_wal_size=1GB -c max_wal_size=4GB -c max_worker_processes=4 -c max_parallel_workers_per_gather=2 -c max_parallel_workers=4 -c max_parallel_maintenance_workers=2"
```

To reload most settings without a restart:

```bash
docker compose exec postgres psql -U "$POSTGRES_USER" -c "SELECT pg_reload_conf();"
```

Parameters that require a restart (`shared_buffers`, `max_connections`, …):

```bash
docker compose restart postgres
```

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
