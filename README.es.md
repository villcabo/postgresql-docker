# PostgreSQL Docker

*Leer en [English](README.md).*

Stack de PostgreSQL parametrizable. La red y el volumen de datos son
**externos** — vos los creás manualmente — así mantenés control total
sobre MTU, opciones del driver, labels, backups y migraciones.

## Tabla de contenido

- [Características](#características)
- [Estructura](#estructura)
- [Inicio rápido](#inicio-rápido)
- [Variables de entorno](#variables-de-entorno)
- [Sincronizar `.env` con `.env.example`](#sincronizar-env-con-envexample)
- [Red (creación manual)](#red-creación-manual)
- [Volumen de datos (creación manual)](#volumen-de-datos-creación-manual)
- [Versión de PostgreSQL y layout de datos](#versión-de-postgresql-y-layout-de-datos)
- [Tuning (`POSTGRES_COMMAND` + pgtune)](#tuning-postgres_command--pgtune)
- [Logs](#logs)
- [Operación diaria](#operación-diaria)
- [Upgrade entre versiones mayores](#upgrade-entre-versiones-mayores)
- [Backups](#backups)
- [Troubleshooting](#troubleshooting)

## Características

- Un solo `docker-compose.yml`, parametrizado vía `.env`.
- Red externa (vos definís MTU, driver, subnet, labels).
- Volumen externo para datos (portable, inspeccionable, fácil de respaldar).
- Bind mount de un directorio del host para logs (`tail` desde el host).
- Tuning en runtime con una única variable `POSTGRES_COMMAND` (compatible con pgtune).
- Healthcheck con `pg_isready`.
- Funciona con cualquier tag de la imagen oficial `postgres` (PG 12 → 18+).

## Estructura

```
.
├── docker-compose.yml   # Stack parametrizado (un solo servicio)
├── .env.example         # Plantilla — copiar a .env
├── .env                 # Tu config local (gitignored)
├── scripts/             # Scripts helper (env-sync, pgtune-apply)
├── logs/                # Logs de PG (se crean al primer arranque, solo si los activás)
└── README.md
```

## Inicio rápido

De cero a producción local:

```bash
# 1. Clonar el repo
git clone git@github.com:villcabo/postgresql-docker.git
cd postgresql-docker

# 2. Crear tu archivo .env local (todo comentado → toma defaults del compose)
cp .env.example .env
$EDITOR .env                       # descomentás solo lo que querés sobreescribir

# 3. Crear la red externa de Docker (ajustar MTU según tu host / VPN)
docker network create \
  --driver bridge \
  --opt com.docker.network.driver.mtu=1500 \
  postgres_net

# 4. Crear el volumen externo de Docker para los datos
docker volume create postgres_data

# 5. Levantar el stack
docker compose up -d

# 6. Ver el arranque
docker compose logs -f postgres

# 7. Verificación
docker compose exec postgres pg_isready -U postgres
docker compose exec postgres psql -U postgres -c "SELECT version();"
```

Cuando hay updates en el repo:

```bash
git pull
./scripts/env-sync.sh                      # mergea variables nuevas en tu .env
docker compose pull                # baja la imagen del tag pinneado en .env
docker compose up -d
```

## Variables de entorno

Todas las variables viven en `.env` (copiado de `.env.example`). Todas son
opcionales — si no las definís, se aplican los defaults. El archivo
`.env.example` tiene la referencia completa con comentarios.

| Variable | Default | Propósito |
|---|---|---|
| `POSTGRES_VERSION` | `18-alpine` | Tag de la imagen |
| `POSTGRES_USER` | `postgres` | Superusuario (solo al primer boot) |
| `POSTGRES_PASSWORD` | `postgres` | Password del superusuario (solo al primer boot) |
| `POSTGRES_DB` | `postgres` | Base por defecto (solo al primer boot) |
| `POSTGRES_INITDB_ARGS` | *(vacío)* | Flags extra para `initdb` (solo al primer boot) |
| `POSTGRES_BIND_HOST` | `127.0.0.1` | Interfaz del host donde publicar el puerto |
| `POSTGRES_PORT` | `5432` | Puerto del host |
| `POSTGRES_NETWORK` | `postgres_net` | Nombre de la red externa de Docker |
| `POSTGRES_DATA_VOLUME` | `postgres_data` | Nombre del volumen externo de Docker |
| `POSTGRES_LOGS_DIR` | `./logs` | Directorio del host para los logs |
| `POSTGRES_COMMAND` | *(vacío)* | Flags extra `-c key=value` para tuning |
| `SHM_SIZE` | `256mb` | Tamaño de `/dev/shm` del contenedor |
| `STOP_GRACE_PERIOD` | `1m` | Segundos antes del SIGKILL al detener |
| `TZ` | `UTC` | Zona horaria |

Hardcodeado en `docker-compose.yml` (editá el archivo si los necesitás
diferentes): `container_name=postgres`, `hostname=postgres`,
`restart=unless-stopped`, mount target `/var/lib/postgresql`.

## Sincronizar `.env` con `.env.example`

Cuando `.env.example` recibe variables nuevas (después de un `git pull`),
corré `./scripts/env-sync.sh` para mergearlas en tu `.env` existente **sin perder
los valores que ya tenías seteados**.

```bash
./scripts/env-sync.sh              # interactivo: muestra diff y pide confirmación
./scripts/env-sync.sh -n           # dry-run: muestra el diff y sale, no escribe nada
./scripts/env-sync.sh -y           # no-interactivo: aplica sin preguntar (CI / scripts)
./scripts/env-sync.sh -y RUTA_AL_EXAMPLE RUTA_AL_ENV   # paths custom
```

Qué hace:

- Reconstruye `.env` usando la estructura, orden y comentarios de `.env.example`.
- Mantiene el valor de cada key que ya tenías descomentada en `.env`.
- Agrega cada key nueva del example (comentada, con su default).
- Preserva keys que solo existen en tu `.env` (custom o legacy) en una
  sección "Legacy / custom" al final — nada se pierde silenciosamente.
- **Muestra un diff unificado + un resumen** (preserved / added / orphan)
  **antes de escribir nada** y espera confirmación `[y/N]`.
- Se niega a aplicar en modo no-interactivo salvo que pases `-y`.
- Escribe un backup con timestamp `.env.bak.YYYYMMDD-HHMMSS` antes de
  sobreescribir `.env` (así nunca pisás backups anteriores).
- Sale con "no changes" si `.env` ya está sincronizado.

## Red (creación manual)

El compose declara la red como `external: true`. Creala antes del `up`,
ajustando las opciones a tu entorno.

```bash
# Básica
docker network create postgres_net

# Bridge con MTU custom (ej. para hosts con VPN / WireGuard)
docker network create \
  --driver bridge \
  --opt com.docker.network.driver.mtu=1450 \
  postgres_net

# Con subnet y gateway fijos
docker network create \
  --driver bridge \
  --subnet 172.28.0.0/24 \
  --gateway 172.28.0.1 \
  --opt com.docker.network.driver.mtu=1500 \
  postgres_net
```

Inspeccionar / borrar:

```bash
docker network inspect postgres_net
docker network rm postgres_net   # parar el stack primero
```

Docker NO permite cambiar la MTU en caliente — para modificarla, parás el
stack, borrás y recreás la red, después `docker compose up -d`.

## Volumen de datos (creación manual)

El volumen de datos también es externo. Lo creás manualmente:

```bash
# Driver local por defecto
docker volume create postgres_data

# Con labels para tooling de backup
docker volume create \
  --label project=postgres \
  --label backup=daily \
  postgres_data

# Bind-backed (mapea el volumen a un directorio específico del host)
docker volume create \
  --driver local \
  --opt type=none \
  --opt device=/srv/postgres-data \
  --opt o=bind \
  postgres_data
```

Inspeccionar:

```bash
docker volume inspect postgres_data
docker volume ls
```

**¿Por qué externo?** Mantenés control del ciclo de vida.
`docker compose down -v` no puede borrarlo. Podés mover el volumen entre
proyectos, conectar sidecars de backup o cambiar el driver sin tocar el
compose.

## Versión de PostgreSQL y layout de datos

PG 18 cambió el layout de datos de la imagen de Docker:

| Versión | Mount target (dentro del contenedor) |
|---|---|
| PG 18+ | `/var/lib/postgresql` *(el que usa este compose)* |
| PG ≤17 | `/var/lib/postgresql/data` |

`docker-compose.yml` tiene hardcodeado el target de PG 18+. Si necesitás
correr PG 17 o anterior, editá `docker-compose.yml` y cambiá:

```yaml
- postgres_data:/var/lib/postgresql
```

por:

```yaml
- postgres_data:/var/lib/postgresql/data
```

Un volumen inicializado para un layout **no** se puede reutilizar con el
otro — ver [Upgrade entre versiones mayores](#upgrade-entre-versiones-mayores).

## Tuning (`POSTGRES_COMMAND` + pgtune)

Todo el tuning de runtime pasa por una única variable: `POSTGRES_COMMAND`.
Se le pasa tal cual al binario `postgres` como argumentos extra
`-c key=value`. Así mantenemos todo en un solo lugar (`.env`) y evitamos
manejar archivos `postgresql.conf` dentro del contenedor.

### Paso 1 — Generar valores con pgtune

Abrí <https://pgtune.leopard.in.ua/> y completá el formulario:

| Campo | Qué elegir |
|---|---|
| **DB Version** | La versión mayor que corrés (16, 17, 18…) |
| **OS Type** | `Linux` |
| **DB Type** | `OLTP` (web apps), `Data warehouses`, `Mixed`, `Desktop` |
| **Total Memory (RAM)** | La RAM del host — o **la porción que querés dedicarle a PG** si el host corre otras cosas (ej. en una laptop de 30 GB poné `16 GB`, no `30 GB`) |
| **Number of CPUs** | `nproc` (threads en Linux) |
| **Number of Connections** | Conexiones concurrentes reales. **No la subas porque sí** para "arreglar" el agote del pool — ver más abajo. |
| **Data Storage** | `SSD` para cualquier setup moderno; `Network (SAN)` si es storage remoto |

Apretá **Generate** y copiá el bloque de la derecha.

### Paso 2 — Guardá la salida en `pgtune.txt` y aplicala

Guardá el bloque que te dio pgtune (el panel de la derecha, líneas
`key = value` — los comentarios no molestan) en un archivo `pgtune.txt`
en la raíz del repo, después corré:

```bash
./scripts/pgtune-apply.sh                # interactivo: preview + confirmación
./scripts/pgtune-apply.sh -n             # dry-run: solo preview
./scripts/pgtune-apply.sh -y             # no-interactivo (CI / scripts)
./scripts/pgtune-apply.sh INPUT ENV      # paths custom
```

Qué hace el script:

- Parsea cada línea `key = value` (saltea los comentarios y blancos).
- Arma `POSTGRES_COMMAND="-c key=value -c …"` como una sola línea.
- Calcula `SHM_SIZE = shared_buffers + 500 MB` automático (ver paso 3).
- Reemplaza `POSTGRES_COMMAND` / `SHM_SIZE` si ya están en `.env`, si no,
  los anexa.
- Muestra un diff unificado + resumen, pide confirmación `[y/N]`.
- Escribe un backup timestampeado `.env.bak.YYYYMMDD-HHMMSS` antes de
  aplicar.

Si preferís editar `.env` a mano, el equivalente es:

```bash
POSTGRES_COMMAND="-c max_connections=200 -c shared_buffers=2GB …"
```

Pegado como una sola línea, entre comillas.

> **Aviso:** pgtune a veces emite `wal_compression=lz4` y
> `io_method=io_uring`. Esos requieren que el binario `postgres` esté
> compilado con `--with-lz4` y `--with-liburing`. Si tu imagen no los
> tiene, editá `pgtune.txt` para sacar esas líneas antes de aplicar, o
> PG se va a negar a arrancar con un error claro.

### Paso 3 — No te olvides de `SHM_SIZE`

El `/dev/shm` del contenedor tiene que ser **≥ `shared_buffers`** o PG se
cae al alocar memoria compartida. Dejale algo de margen (≈ 500 MB). **El
`pgtune-apply.sh` del paso 2 ya lo hace por vos;** el equivalente manual
es:

```bash
# En .env, para shared_buffers=2GB:
SHM_SIZE=2500mb
```

### Paso 4 — Aplicar

```bash
# max_connections, shared_buffers y SHM_SIZE requieren restart completo:
docker compose down
docker compose up -d
```

Todo lo demás (work_mem, effective_cache_size, etc.) lo podés recargar sin
downtime:

```bash
docker compose exec postgres psql -U postgres -c "SELECT pg_reload_conf();"
```

### Paso 5 — Verificar la configuración en vivo

Confirmá que PG efectivamente tomó los valores:

```bash
# Chequear un parámetro puntual
docker compose exec postgres psql -U postgres -c "SHOW max_connections;"

# Tabla completa con los parámetros que toca pgtune
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

# Uso actual de conexiones (chequeo previo antes de subir max_connections)
docker compose exec postgres psql -U postgres -c "
  SELECT state, count(*) FROM pg_stat_activity GROUP BY state ORDER BY 2 DESC;"
```

### Sobre `max_connections`

Si estás chocando contra el techo de conexiones, **la solución casi nunca
es solo un número más grande**. Cada conexión es su propio proceso backend
(~10 MB base + work_mem en queries). Subir el techo come RAM de forma
lineal.

Síntomas de un leak del cliente y no falta real de capacidad:

```sql
-- Muchas sesiones colgadas en 'idle in transaction' o 'idle' = leak del pool
SELECT state, count(*) FROM pg_stat_activity GROUP BY state;
```

La fix correcta es **un pooler en modo transaction adelante de PG**
(pgbouncer, pgcat). 50 conexiones reales a PG pueden servir miles del lado
de la app.

## Logs

Por defecto PG escribe a stdout/stderr, que leés con
`docker compose logs -f postgres`.

Para que escriba archivos rotados en `./logs` del host, agregale flags de
logging al `POSTGRES_COMMAND`:

```bash
-c logging_collector=on \
-c log_directory=/var/log/postgresql \
-c log_filename=postgresql-%Y-%m-%d.log \
-c log_rotation_age=1d \
-c log_rotation_size=0
```

Después:

```bash
mkdir -p logs
sudo chown -R 70:70 logs   # UID de postgres en alpine
docker compose up -d
tail -f logs/postgresql-$(date +%F).log
```

Cambiá el directorio del host con `POSTGRES_LOGS_DIR` en `.env`.

## Operación diaria

```bash
# Start / stop
docker compose up -d
docker compose down           # NO borra el volumen ni la red externos
docker compose restart

# Estado y salud
docker compose ps
docker compose exec postgres pg_isready -U "$POSTGRES_USER"

# Shell de psql
docker compose exec postgres psql -U "$POSTGRES_USER" -d "$POSTGRES_DB"

# Shell del contenedor
docker compose exec postgres sh

# Actualizar imagen (pull de un patch nuevo)
docker compose pull
docker compose up -d
```

## Upgrade entre versiones mayores

`pg_upgrade` requiere los binarios de ambas versiones y un cambio de
layout entre PG 17 y PG 18. Lo más simple y seguro: **dump y restore**.

```bash
# 1. Dump desde la instancia vieja corriendo
docker compose exec postgres pg_dumpall -U "$POSTGRES_USER" > dump.sql

# 2. Parar y limpiar el volumen viejo
docker compose down
docker volume rm postgres_data
docker volume create postgres_data

# 3. Cambiar la versión en .env
#    POSTGRES_VERSION=18-alpine
# (y editar el mount target en docker-compose.yml si venís de PG <=17)

# 4. Arrancar la versión nueva (crea cluster vacío)
docker compose up -d
until docker compose exec -T postgres pg_isready -U "$POSTGRES_USER"; do sleep 1; done

# 5. Restore
cat dump.sql | docker compose exec -T postgres psql -U "$POSTGRES_USER" -d postgres
```

Para `pg_upgrade --link` in-place, ver los docs upstream:
<https://github.com/docker-library/postgres/issues/37>.

## Backups

Backup lógico rápido:

```bash
docker compose exec -T postgres pg_dumpall -U "$POSTGRES_USER" \
  | gzip > "backup-$(date +%F).sql.gz"
```

Snapshot a nivel volumen (parar la DB primero para consistencia):

```bash
docker compose stop postgres
docker run --rm -v postgres_data:/data -v "$PWD":/backup alpine \
  tar czf /backup/postgres_data-$(date +%F).tar.gz -C / data
docker compose start postgres
```

## Troubleshooting

**`Error: in 18+, these Docker images are configured to store database data…`**
Estás corriendo PG 18+ contra un volumen inicializado con el layout viejo
(PG ≤17). Opciones: (a) volvé a PG 17 y cambiá el mount target en
`docker-compose.yml` a `/var/lib/postgresql/data`; o (b) dump + volumen
limpio — ver [Upgrade](#upgrade-entre-versiones-mayores).

**`network postgres_net declared as external, but could not be found`**
Creá la red primero: `docker network create postgres_net`.

**`volume postgres_data declared as external, but could not be found`**
Creá el volumen primero: `docker volume create postgres_data`.

**El healthcheck falla apenas arranca**
Clusters grandes tardan más en arrancar. Subí `start_period` en
`docker-compose.yml` o mirá los logs: `docker compose logs postgres`.

**`Permission denied` en `./logs`**
El contenedor escribe como usuario `postgres` (UID 70 en alpine).
Fix: `sudo chown -R 70:70 ./logs`.

**Connection refused desde otro contenedor**
Conectalo a la misma red `postgres_net` y usalo con el hostname `postgres`
(o con el puerto publicado en el host).
