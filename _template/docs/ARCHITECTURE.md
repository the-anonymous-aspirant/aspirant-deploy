# {Service Name} — Architecture

*Date: {YYYY-MM-DD}*

---

## System Context

Where this service sits in the overall stack:

```
┌──────────┐         ┌──────────────┐         ┌──────────┐
│  Client   │         │ {This Service}│         │ Postgres  │
│  :80      │         │  :{port}      │────────▶│  :5432    │
└──────────┘         └──────────────┘         └──────────┘
                            │
                            ▼
                     ┌──────────────┐
                     │  {Storage}    │
                     │  volume/S3    │
                     └──────────────┘
```

---

## Internal Structure

```
{service}/
├── app/
│   ├── main.py          # Application entrypoint and lifespan
│   ├── config.py         # Environment variable settings
│   ├── database.py       # Database engine and session
│   ├── models.py         # ORM models
│   ├── schemas.py        # Request/response schemas
│   ├── routes.py         # API endpoint definitions
│   └── {domain}.py       # Domain-specific logic
├── Dockerfile-{Name}
└── requirements.txt
```

---

## Data Flow

```
1. Client sends request
         │
         ▼
2. FastAPI route validates input
         │
         ▼
3. Business logic processes request
         │
         ▼
4. Database read/write via SQLAlchemy
         │
         ▼
5. Response returned to client
```

<!-- Replace with a more specific flow diagram for your service -->

---

## Key Design Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Framework | FastAPI | Async support, auto-generated docs, Pydantic validation |
| ORM | SQLAlchemy | Shared DB with Go backend, mature ecosystem |
| Base image | python:3.11-slim | Compatibility with ML/native libs (not Alpine) |
| Primary key | UUID | Avoids collision with Go auto-increment IDs |

---

## Resource Requirements

| Resource | Requirement | Notes |
|----------|------------|-------|
| RAM | {amount} | {what consumes it} |
| Disk | {amount} | {data stored} |
| CPU | {profile} | {compute characteristics} |
| Port | {host}:{container} | {protocol} |

---

## Security Considerations

- **Authentication:** {None / JWT / API key — and why}
- **Network access:** {Local only / Public / Via proxy}
- **Data sensitivity:** {What data is stored, any PII concerns}
