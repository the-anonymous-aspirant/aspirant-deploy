# Penpot Design Service — Specification

*Status: Approved*
*Author: aspirant (via aspirant_engineer, system_3 #2195)*
*Date: 2026-07-16*

---

## Motivation

The design system work (Penpot mockups, design tokens, component libraries) currently runs on the dev box as a localhost-only compose stack, reachable only through an SSH tunnel. Moving it to aspirant-cell makes the designs viewable and editable remotely over a secure channel, and serves as the pre-flight component migration for the wider system_3 relocation plan (system_3 #2192).

---

## Scope

### In Scope

- Run the upstream Penpot 2.16.2 stack (frontend, backend, exporter, dedicated postgres:15, dedicated redis:7) as part of the production compose project.
- Migrate all existing content (Penpot database + uploaded assets) from the dev box, byte-identical, including the `PENPOT_SECRET_KEY` so sessions and signed asset URLs survive.
- Public access at `https://the-aspirant.com/admin/penpot/` — the apex origin, TLS at the Cloudflare edge, admin-gated (`auth_request`) client-nginx location proxying to the frontend (lands in aspirant-client, same feature). This is the sole public entry point — `design.the-aspirant.com` is decommissioned (see DECISIONS.md).
- A Penpot card on the admin page that opens `/admin/penpot/` in a new tab (Penpot's canvas needs a full browser tab, not an iframe embed).

### Out of Scope

- Building or forking Penpot images — upstream `penpotapp/*` images pinned by sha256 digest are used as-is; there is no GHCR build lane for this service.
- SMTP / email verification — registration stays disabled; accounts are managed via `manage.py` (PREPL) as on the dev box.
- Multi-user access control beyond Penpot's own login — the instance remains single-operator.

---

## Service Surface

Penpot is a third-party application; we do not define its API. The operational surface we own:

| Surface | Where | Auth |
|---------|-------|------|
| Design UI | `https://the-aspirant.com/admin/penpot/` | Admin `auth_request` gate, then Penpot login (registration disabled) |
| On-cell debug | `http://127.0.0.1:9001` (loopback only) | Penpot login |
| Admin CLI | `docker exec aspirant-online-penpot-backend-1 python3 /opt/penpot/backend/manage.py …` | shell access to the cell |
| Health probe | `curl -sf http://127.0.0.1:9001/readyz` on the cell | none (loopback) |

---

## Constraints

- **Path-bearing public URI.** Penpot's docs only show root-of-(sub)domain deployments, but 2.16.2 was empirically verified to run under a subpath: relative asset refs, hash routing, and `public-uri = ensure_path_slash(penpotPublicURI || fallback)` in the compiled bundle; login, websocket, and signed asset URLs all stay inside the prefix (spike evidence, system_3 #2198 comment 8700). Requires the client-nginx `config.js` override AND the path-bearing `PENPOT_PUBLIC_URI` here — the two must agree.
- **`PENPOT_PUBLIC_URI` must match the browser origin+path** or session cookies bind to the wrong host and login silently fails (dev-box lesson, `~/penpot/README.md`).
- **Secret migration, not regeneration.** `PENPOT_SECRET_KEY` signs sessions and asset URLs; `PENPOT_DB_PASSWORD` is baked into the restored database. Both migrate from the dev-box `.env`.
- **Memory.** JVM backend and headless-chromium exporter get 2 GiB caps each; the full sub-stack budget is ≤ 5.75 GiB against ~11 GiB available.
- **Images pinned by digest** (dev-box #1874 lesson: `:latest` drift). The auto-pull cron's `docker compose pull` is a deliberate no-op for these services.

---

## Acceptance Criteria

1. All five `penpot-*` containers run `Up` under the `aspirant-online` compose project; `/readyz` on the loopback publish returns OK.
2. Existing services are unaffected (`tests/integration.sh` green on the cell before and after).
3. Migrated content verifies: the system_3-mockups file (and its revision counter) is present on the cell instance and renders (verified at #2195-B1).
4. Operator can log in at `https://the-aspirant.com/admin/penpot/` from a remote browser and open the migrated designs (verified at #2195-C1).
