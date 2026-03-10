# Aspirant Deploy Specification

## Purpose

Centralized orchestration for the Aspirant platform. This repo provides the single source of truth for how all services are composed, configured, and deployed together.

## Scope

This repo contains **no application code**. It provides:

- Docker Compose configurations (production and development)
- Environment variable templates
- Platform-wide architecture documentation
- Cross-service connection documentation

## Requirements

### Functional

- **Production deployment** using pre-built GHCR images with `docker compose up -d`
- **Development deployment** building from sibling repo directories with `docker compose -f docker-compose.dev.yml up -d`
- **Partial startup** for running a subset of services during development
- **Environment isolation** between production and development (separate volumes, ports)

### Non-Functional

- Dev PostgreSQL must use port 5433 to avoid conflicts with any local PostgreSQL instance
- Dev volumes must be suffixed with `-dev` to prevent data mixing
- All service health endpoints must be reachable individually and through the server proxy

## Services Managed

| Service | Repository | Image |
|---------|-----------|-------|
| server | [aspirant-server](https://github.com/the-anonymous-aspirant/aspirant-server) | `ghcr.io/the-anonymous-aspirant/aspirant-server:latest` |
| client | [aspirant-client](https://github.com/the-anonymous-aspirant/aspirant-client) | `ghcr.io/the-anonymous-aspirant/aspirant-client:latest` |
| transcriber | [aspirant-transcriber](https://github.com/the-anonymous-aspirant/aspirant-transcriber) | `ghcr.io/the-anonymous-aspirant/aspirant-transcriber:latest` |
| commander | [aspirant-commander](https://github.com/the-anonymous-aspirant/aspirant-commander) | `ghcr.io/the-anonymous-aspirant/aspirant-commander:latest` |
| translator | [aspirant-translator](https://github.com/the-anonymous-aspirant/aspirant-translator) | `ghcr.io/the-anonymous-aspirant/aspirant-translator:latest` |
| postgres | (official image) | `postgres:16` |

## Standards

All Aspirant platform repositories follow the conventions defined in [aspirant-meta](https://github.com/the-anonymous-aspirant/aspirant-meta), including documentation structure, Git workflow, and development philosophy.
