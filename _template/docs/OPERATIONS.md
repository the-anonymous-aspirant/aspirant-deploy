# {Service Name} — Operations Guide

How to set up, run, test, validate, and debug this service.

---

## Setup

### Prerequisites

- Docker and Docker Compose
- Access to the `.env` file with database credentials
- {Any additional prerequisites}

### First-Time Setup

```bash
# 1. Clone the repository
git clone https://github.com/the-anonymous-aspirant/aspirant-online.git
cd aspirant-online

# 2. Ensure .env file exists with required variables
# See SPEC.md → Configuration for the full list

# 3. Build the service image
docker compose -f docker-compose.dev.yml build {service}

# 4. Start the service (with dependencies)
docker compose -f docker-compose.dev.yml up {service}
```

---

## How to Run

### Development

```bash
# Build and run with dev compose (builds from source)
docker compose -f docker-compose.dev.yml up {service}
```

### Production

```bash
# Pull pre-built image and run
docker compose up -d {service}
```

### Access Points

| Endpoint | URL |
|----------|-----|
| API root | http://localhost:{port} |
| Health check | http://localhost:{port}/health |
| API docs (Swagger) | http://localhost:{port}/docs |

---

## How to Test

### Health Check

```bash
curl http://localhost:{port}/health
# Expected: {"status": "ok", ...}
```

### Manual API Testing

```bash
# Create a resource
curl -X POST http://localhost:{port}/{resource} \
  -F "file=@sample.ext"

# List resources
curl http://localhost:{port}/{resource}

# Get single resource
curl http://localhost:{port}/{resource}/{id}

# Delete resource
curl -X DELETE http://localhost:{port}/{resource}/{id}
```

### Automated Tests

```bash
# {How to run the test suite — fill in when tests exist}
# docker compose exec {service} pytest
```

---

## How to Validate

### Service Health

```bash
# Check container is running
docker compose ps {service}

# Check health endpoint
curl http://localhost:{port}/health
```

### Database Schema

```bash
# Connect to PostgreSQL and verify tables exist
docker compose exec postgres psql -U $DB_USER -d $DB_NAME -c "\dt"

# Check specific table structure
docker compose exec postgres psql -U $DB_USER -d $DB_NAME -c "\d {table_name}"
```

### Integration Verification

```bash
# Verify the service can reach PostgreSQL
curl http://localhost:{port}/health | jq '.database'
# Expected: "connected"
```

---

## How to Debug

### Logs

```bash
# Follow service logs
docker compose logs -f {service}

# Last 100 lines
docker compose logs --tail 100 {service}

# All services
docker compose logs -f
```

### Database Inspection

```bash
# Connect to database
docker compose exec postgres psql -U $DB_USER -d $DB_NAME

# Useful queries:
SELECT * FROM {table_name} ORDER BY created_at DESC LIMIT 10;
SELECT status, COUNT(*) FROM {table_name} GROUP BY status;
```

### Container Shell

```bash
# Open a shell inside the running container
docker compose exec {service} /bin/sh

# Check file system, environment, processes
ls /data/
env | grep DB_
ps aux
```

### Verbose Logging

```bash
# If the service supports log levels, set to DEBUG
# Add to docker-compose environment:
#   LOG_LEVEL: DEBUG
```

---

## Gotchas

<!-- Add non-obvious things that will save time debugging. Examples below — replace with real ones. -->

| Gotcha | Explanation |
|--------|-------------|
| `DB_HOST` must be `postgres` in Docker | Docker Compose networking uses service names as hostnames. `localhost` won't work inside a container |
| Container needs to be rebuilt after code changes | Dev compose builds from source — run `docker compose build {service}` after editing code |
| First startup may be slow | {e.g., model download, dependency compilation, migration} |
| Volume data persists across restarts | `docker compose down` does NOT delete volumes. Use `docker volume rm {volume}` to wipe data |
| Port conflicts | Check nothing else is using port {port}: `lsof -i :{port}` |
