# CLAUDE.md

## About

This is the deployment and orchestration repo for the Aspirant platform. It contains no application code — only Docker Compose configurations, environment templates, and architecture documentation.

## What This Repo Does

- **docker-compose.yml** — Production deployment using pre-built GHCR images
- **docker-compose.dev.yml** — Local development building from sibling repo directories
- **.env.example** — Environment variable template
- **docs/** — Platform-wide architecture and connection documentation

## Conventions

Follow [aspirant-meta](https://github.com/the-anonymous-aspirant/aspirant-meta) for development philosophy, naming conventions, and documentation standards.

## Service Repos

| Service | Repo | Port |
|---------|------|------|
| Server (API gateway) | `../aspirant-server` | 8081→8080 |
| Client (frontend) | `../aspirant-client` | 80 |
| Transcriber | `../aspirant-transcriber` | 8082→8000 |
| Commander | `../aspirant-commander` | 8083→8000 |
| Translator | `../aspirant-translator` | 8084→8000 |

## Common Commands

```bash
# Production
docker compose pull && docker compose up -d

# Development (requires sibling repos cloned)
docker compose -f docker-compose.dev.yml up -d

# Logs
docker compose logs -f <service>

# Health checks
curl localhost:8081/health
curl localhost:8082/health
curl localhost:8083/health
curl localhost:8084/health
```

## Important

- Never commit `.env` — it contains credentials
- The dev compose expects service repos as sibling directories
- PostgreSQL runs on port 5433 in dev (5432 in prod) to avoid conflicts
