# PostgreSQL Docker

Parameterized PostgreSQL stack. Network and data volume are **external** —
you create them manually — so you keep full control over MTU, driver options,
labels, backups, and migrations.

## Table of contents

- [Features](#features)
- [Layout](#layout)
- [Quick start](#quick-start)
- [Environment variables](#environment-variables)
- [Network (manual creation)](#network-manual-creation)
- [Data volume (manual creation)](#data-volume-manual-creation)
- [PostgreSQL version and mount path](#postgresql-version-and-mount-path)
- [Configuration (`custom.conf`)](#configuration-customconf)
- [Logs](#logs)
- [Operations](#operations)
- [Upgrading between major versions](#upgrading-between-major-versions)
- [Backups](#backups)
- [Troubleshooting](#troubleshooting)

## Features

- Single-file `docker-compose.yml`, fully parameterized via `.env`.
- External network (you set MTU, driver, subnet, labels).
- External named volume for data (portable, inspectable, easy to back up).
- Bind-mounted host directory for logs (tail from host).
- Bind-mounted `custom.conf`, read-only.
- Healthcheck via `pg_isready`.
- Works with any `postgres` image tag (PG 12 → 18+).

## Layout

```
.
├── docker-compose.yml   # Parameterized stack (single service)
├── .env.example         # Template — copy to .env
├── .env                 # Your local config (gitignored)
├── custom.conf          # Custom postgresql.conf
├── logs/                # PG log files (created on first run)
└── README.md
```

## Quick start

```bash
# 1. Copy env template and edit values
cp .env.example .env
$EDITOR .env

# 2. Create the external network (adjust MTU to your needs)
docker network create \
  --driver bridge \
  --opt com.docker.network.driver.mtu=1450 \
  postgres_net

# 3. Create the external data volume
docker volume create postgres_data

# 4. (Optional) prepare the logs directory
mkdir -p logs

# 5. Start
docker compose up -d

# 6. Follow logs
docker compose logs -f postgres
```

## Environment variables

All variables live in `.env`. See `.env.example` for documented defaults.

| Variable | Purpose | Example |
|---|---|---|
| `COMPOSE_PROJECT_NAME` | Project name in `docker compose ls` | `postgres` |
| `CONTAINER_NAME` | Container and hostname | `postgres18` |
| `POSTGRES_VERSION` | Image tag | `18-alpine`, `17-alpine`, `16-alpine` |
| `POSTGRES_DATA_TARGET` | Mount path inside container (version dependent) | `/var/lib/postgresql` (PG 18+) or `/var/lib/postgresql/data` (PG ≤17) |
| `POSTGRES_USER` / `POSTGRES_PASSWORD` / `POSTGRES_DB` | Superuser + initial DB (applied on first boot) | `postgres` |
| `POSTGRES_INITDB_ARGS` | Extra `initdb` flags (first boot only) | `--encoding=UTF8 --locale=C` |
| `POSTGRES_BIND_HOST` | Host IP to publish on | `127.0.0.1` local, `0.0.0.0` LAN |
| `POSTGRES_PORT` | Host port | `5432` |
| `POSTGRES_NETWORK` | Name of the external docker network | `postgres_net` |
| `POSTGRES_DATA_VOLUME` | Name of the external docker volume | `postgres_data` |
| `POSTGRES_LOGS_DIR` | Host directory for logs | `./logs` |
| `POSTGRES_CONFIG_FILE` | Path to the custom `postgresql.conf` | `./custom.conf` |
| `SHM_SIZE` | `/dev/shm` size for the container | `1gb` |
| `RESTART_POLICY` | Docker restart policy | `unless-stopped` |
| `STOP_GRACE_PERIOD` | Time before SIGKILL on stop | `1m` |
| `TZ` | Timezone | `UTC`, `America/La_Paz` |

## Network (manual creation)

The compose file declares the network as `external: true`. Create it before
`up`, adjusting the options to your environment.

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

If you need to change MTU later, you must recreate the network (Docker doesn't
allow in-place MTU changes): `docker compose down`, remove and recreate the
network, `docker compose up -d`.

## Data volume (manual creation)

The data volume is also external. Create it manually:

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
cannot wipe the volume. You can move the volume between projects, attach
backup sidecars, or swap drivers without touching the compose file.

## PostgreSQL version and mount path

PG 18 changed the Docker image's data layout:

| Version | Mount path inside container | Why |
|---|---|---|
| PG 18+ | `/var/lib/postgresql` | New layout — data lives in `/var/lib/postgresql/<MAJOR>/docker` subdirectories to support `pg_upgrade --link` across major versions on a single mount. |
| PG ≤17 | `/var/lib/postgresql/data` | Legacy layout — `PGDATA` directly at the mount point. |

Set `POSTGRES_DATA_TARGET` accordingly. An existing volume initialized for one
layout **cannot** be reused by the other — see
[Upgrading between major versions](#upgrading-between-major-versions).

## Configuration (`custom.conf`)

The file `./custom.conf` is bind-mounted read-only at
`/etc/postgresql/postgresql.conf` and loaded via `-c config_file=...`.

Tune it with [pgtune](https://pgtune.leopard.in.ua/) or by hand. Reload after
changes:

```bash
# Reload most parameters without restart
docker compose exec postgres psql -U "$POSTGRES_USER" -c "SELECT pg_reload_conf();"

# For parameters that require restart (shared_buffers, max_connections, etc.)
docker compose restart postgres
```

## Logs

Logs go to `./logs/` on the host via `logging_collector=on`. Files rotate
daily as `postgresql-YYYY-MM-DD.log`.

```bash
ls logs/
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
PG 17 and PG 18. The simplest and safest approach is **dump and restore**.

```bash
# 1. Dump from the old running instance
docker compose exec postgres pg_dumpall -U "$POSTGRES_USER" > dump.sql

# 2. Stop and remove the old data
docker compose down
docker volume rm postgres_data
docker volume create postgres_data

# 3. Switch version and mount target in .env
#    POSTGRES_VERSION=18-alpine
#    POSTGRES_DATA_TARGET=/var/lib/postgresql

# 4. Boot the new version (creates empty cluster)
docker compose up -d
# Wait until healthy
until docker compose exec -T postgres pg_isready -U "$POSTGRES_USER"; do sleep 1; done

# 5. Restore
cat dump.sql | docker compose exec -T postgres psql -U "$POSTGRES_USER" -d postgres
```

For in-place `pg_upgrade --link`, see the upstream image docs:
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
(PG ≤17). Options: (a) go back to `POSTGRES_VERSION=17-alpine` and
`POSTGRES_DATA_TARGET=/var/lib/postgresql/data`; or (b) dump + fresh volume
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
`sudo chown -R 70:70 ./logs` or pick a directory you own with group access.

**Connection refused from another container**
Attach that container to the same `postgres_net` network and use
`${CONTAINER_NAME}` as the hostname (e.g. `postgres18:5432`).
