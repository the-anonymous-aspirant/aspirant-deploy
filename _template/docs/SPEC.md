# {Service Name} — Specification

*Status: Draft | In Review | Approved*
*Author: {name}*
*Date: {YYYY-MM-DD}*

---

## Motivation

Why does this service exist? What problem does it solve?

<!-- 2-3 sentences. Link to any prior discussion or context. -->

---

## Scope

### In Scope

- {What this service will do}
- {What endpoints/capabilities it provides}

### Out of Scope

- {What this service will NOT do}
- {What belongs to other services}

---

## API Endpoints

| Method | Endpoint | Description | Auth |
|--------|----------|-------------|------|
| `GET` | `/health` | Health check | No |
| `POST` | `/{resource}` | Create resource | TBD |
| `GET` | `/{resource}` | List resources | TBD |
| `GET` | `/{resource}/{id}` | Get single resource | TBD |
| `DELETE` | `/{resource}/{id}` | Delete resource | TBD |

### Request/Response Examples

```bash
# Health check
curl http://localhost:{port}/health

# Create resource
curl -X POST http://localhost:{port}/{resource} \
  -H "Content-Type: application/json" \
  -d '{"field": "value"}'
```

---

## Data Model

### Table: `{table_name}`

| Column | Type | Nullable | Description |
|--------|------|----------|-------------|
| id | UUID / INT | No | Primary key |
| created_at | TIMESTAMPTZ | No | Creation timestamp |
| updated_at | TIMESTAMPTZ | No | Last modification |

### Indexes

- `{column}` — {reason for index}

---

## Configuration

| Variable | Default | Required | Description |
|----------|---------|----------|-------------|
| `DB_HOST` | `postgres` | Yes | PostgreSQL hostname |
| `DB_USER` | — | Yes | Database username |
| `DB_PASSWORD` | — | Yes | Database password |
| `DB_NAME` | `aspirant_online_db` | Yes | Database name |

---

## Constraints

- **Max file size:** {if applicable}
- **Rate limits:** {if applicable}
- **Memory budget:** {e.g., 2 GB container limit}
- **Dependencies:** PostgreSQL, {other services}

---

## Acceptance Criteria

- [ ] Health endpoint returns service status
- [ ] CRUD operations work for primary resource
- [ ] Error cases return meaningful messages
- [ ] Docker image builds and runs via docker-compose
- [ ] Service integrates with existing PostgreSQL instance
