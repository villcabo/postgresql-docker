# PostgreSQL docker
Define docker compose postgresql versions

Start container
```
docker compose up -d
```

Stop and destroy container
```
docker compose down
```

## Environments

Create a `.env` file and follow next properties:

```
PG_VERSION=alpine
PG_PORT=0.0.0.0:5432

PG_USER=postgres
PG_PASS=postgres
```

