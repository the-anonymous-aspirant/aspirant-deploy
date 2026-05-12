# Goal Mapper — Architecture

*Status: Draft*
*Author: aspirant_developer*
*Date: 2026-05-12*
*Spec: [GOAL_MAPPER_SPEC.md](./GOAL_MAPPER_SPEC.md)*

---

## 1. Service Topology

The Goal Mapper extends the existing aspirant-server (Go/Gin) with new endpoints under `/goals/`. No new service is introduced.

```
┌─────────────────────────────────────────────┐
│  aspirant-client (Vue 3 / Vuetify / Vite)   │
│  /trusted/goals → GoalMapper module         │
│                                             │
│  New modules:                               │
│  - src/views/trusted/goals/                 │
│  - src/components/goals/                    │
└──────────────┬──────────────────────────────┘
               │ HTTP (Nginx proxy: /api/ → server:8080)
               ▼
┌─────────────────────────────────────────────┐
│  aspirant-server (Go/Gin)                   │
│  Port 8080                                  │
│                                             │
│  New route group: trustedRoutes /goals/     │
│  - handlers/goals_trees.go                  │
│  - handlers/goals_nodes.go                  │
│  - handlers/goals_edges.go                  │
│  - handlers/goals_comments.go              │
│  - data_models/goals.go                     │
│  - data_functions/goals.go                  │
└──────────────┬──────────────────────────────┘
               │ PostgreSQL wire protocol
               ▼
┌─────────────────────────────────────────────┐
│  PostgreSQL 16 (shared instance)            │
│                                             │
│  New tables (owned by server):              │
│  - trees                                    │
│  - nodes                                    │
│  - edges                                    │
│  - comments (goals)                         │
└─────────────────────────────────────────────┘
```

---

## 2. Library Choices

### 2.1 Graph Library — Choice Matrix

**Phase 1 dimensions:**

| Dimension | Definition | Weight |
|---|---|---|
| Custom node renderer | Can render arbitrary Vue components or SVG inside nodes (required for future hand-drawn visuals) | must-pass |
| Declarative API | Data-driven rendering (pass nodes/edges array, library handles layout) | 0.30 |
| Bundle size | Gzipped transfer size added to the client | 0.25 |
| Layout algorithms | Built-in hierarchical/tree layout without manual positioning | 0.25 |
| Vue interop | First-class Vue 3 bindings or trivial integration via refs | 0.20 |

**Phase 2 candidates:**

| Dimension (weight) | Cytoscape.js | Vue Flow (react-flow port) | d3-force |
|---|---|---|---|
| Custom node renderer (must-pass) | ✗ Canvas-based; custom rendering requires HTML overlay layer with manual positioning | ✓ Slots-based custom nodes; any Vue component renders as a node | ✗ SVG-only; custom nodes require manual foreignObject wiring |
| Declarative API (0.30) | Medium — imperative `cy.add()` calls, adapters needed for reactive data | High — `<VueFlow :nodes="nodes" :edges="edges" />` with v-model | Low — force simulation requires manual tick/render loop |
| Bundle size (0.25) | ~170 kB min+gz (core + layout extensions) | ~45 kB min+gz (core) | ~30 kB min+gz (d3-force + d3-hierarchy) |
| Layout algorithms (0.25) | Excellent — dagre, breadthfirst, cose built-in or via extensions | Good — dagre layout via `@vue-flow/layout` addon (~8 kB extra) | Manual — d3-hierarchy provides tree coords but no edge routing |
| Vue interop (0.20) | Poor — vanilla JS lib, requires wrapper component with lifecycle sync | Excellent — native Vue 3 library, Composition API, TypeScript | Medium — headless, mount SVG to a ref manually |
| **Recommendation** | Fails must-pass — canvas nodes can't host Vue slots | **Chosen** — meets all criteria with smallest integration cost | Too manual for a data-driven tree UI |

**§ Recommendation:** Vue Flow. It is the only candidate that passes the must-pass dimension (custom node renderer via Vue slots) while also providing a declarative, reactive API native to Vue 3. The dagre layout addon covers the hierarchical tree requirement.

**§ Decision:** Vue Flow (`@vue-flow/core` + `@vue-flow/layout`).

**§ Open questions parked:**
- Hand-drawn SVG node style is out-of-scope for v1 but Vue Flow's slot system accommodates it without library change.

---

### 2.2 Markdown Library — Choice Matrix

**Phase 1 dimensions:**

| Dimension | Definition | Weight |
|---|---|---|
| XSS-safe output | Must produce sanitized HTML by default or integrate trivially with DOMPurify | must-pass |
| Bundle size | Gzipped transfer size | 0.30 |
| Custom link handling | Ability to intercept/transform links (e.g., open external links in new tab) | 0.25 |
| Plugin ecosystem | Available extensions for task lists, tables, etc. | 0.25 |
| Ease of integration | Drop-in usage with Vue (v-html or component wrapper) | 0.20 |

**Phase 2 candidates:**

| Dimension (weight) | marked | markdown-it | micromark |
|---|---|---|---|
| XSS-safe output (must-pass) | ✓ Built-in sanitizer since v4 (`{sanitize: true}` deprecated but DOMPurify pairing is standard) | ✓ HTML disabled by default; linkify plugin is safe; pair with DOMPurify for user content | ✓ Produces HTML tokens, not raw HTML; safe by construction but requires hast pipeline for rendering |
| Bundle size (0.25) | ~8 kB min+gz | ~12 kB min+gz (core) | ~5 kB min+gz (core) but ~15 kB with html/gfm extensions |
| Custom link handling (0.25) | Medium — renderer override for `link()` method | Good — `renderer.rules.link_open` hook; clean API | Complex — requires custom compiler plugin in unified pipeline |
| Plugin ecosystem (0.25) | Limited — few official plugins, community forks | Excellent — markdown-it-task-lists, -footnote, -anchor, etc. | Growing — via micromark-extension-* but less mature |
| Ease of integration (0.20) | High — `marked.parse(md)` returns HTML string | High — `md.render(src)` returns HTML string | Medium — lower level, requires assembly of extensions |
| **Recommendation** | Viable but weaker plugin story | **Chosen** — best balance of safety, plugins, and API clarity | Over-engineered for rendering user descriptions |

**§ Recommendation:** markdown-it. Mature plugin ecosystem covers future needs (task lists in descriptions, footnotes), the link-open hook cleanly handles the "open external in new tab" pattern, and integration is a single function call.

**§ Decision:** markdown-it + DOMPurify (sanitize rendered HTML before `v-html` injection).

**§ Open questions parked:**
- Task list checkbox support in descriptions (use `markdown-it-task-lists` plugin when needed).

---

### 2.3 Date Library — Choice Matrix

**Phase 1 dimensions:**

| Dimension | Definition | Weight |
|---|---|---|
| ISO week math | Correct `getISOWeek`, `startOfISOWeek`, week-year boundaries | must-pass |
| Tree-shaking | Only pay for functions actually imported (dead-code elimination via ESM) | 0.30 |
| Bundle size (used subset) | Size of the ~10 functions needed (startOf/endOf week/month/quarter, format, parse) | 0.30 |
| Locale support | Can format dates in user's locale without pulling all locales | 0.20 |
| API ergonomics | Immutable, functional API; no prototype pollution or global state | 0.20 |

**Phase 2 candidates:**

| Dimension (weight) | date-fns | Day.js | Luxon |
|---|---|---|---|
| ISO week math (must-pass) | ✓ `getISOWeek`, `startOfISOWeekYear`, `eachWeekOfInterval` with `{weekStartsOn: 1}` | ✓ via `isoWeek` plugin — `dayjs().isoWeek()`, `.startOf('isoWeek')` | ✓ `DateTime.fromISO().weekNumber`, `.startOf('week')` with locale-aware Monday start |
| Tree-shaking (0.30) | Excellent — each function is a separate ESM export; bundler includes only what's imported | Poor — monolithic UMD/ESM; plugins are side-effect imports that resist tree-shaking | Poor — single 70 kB module, no granular exports |
| Bundle size (0.30) | ~3-5 kB for the ~10 functions needed (verified via bundlephobia per-export analysis) | ~7 kB core + ~2 kB plugins (isoWeek, quarterOfYear) = ~9 kB regardless of usage | ~23 kB min+gz (entire library loads) |
| Locale support (0.20) | Per-locale imports: `import { sv } from 'date-fns/locale'`; only loaded locale ships | Built-in via dayjs/locale/*; ~1 kB per locale, manual import | Built-in via Intl API; no extra bundle but requires browser Intl support |
| API ergonomics (0.20) | Functional, immutable — `addDays(date, 7)` returns new Date | Mutable-ish chain — `dayjs().add(7, 'day')` returns new instance but plugin system mutates prototype | OOP — `DateTime.plus({days: 7})`; immutable but heavy class hierarchy |
| **Recommendation** | **Chosen** — optimal tree-shaking and ISO week support, smallest effective bundle | Viable but plugins break tree-shaking promise | Over-sized for this use case |

**§ Recommendation:** date-fns. Best tree-shaking story means the timeline filter only ships the functions it calls. ISO week support is first-class without plugins. The functional API avoids hidden state.

**§ Decision:** date-fns v4.

**§ Open questions parked:**
- The task description mentions "already in client from kvitto" — if kvitto is later integrated into aspirant-client, date-fns would already be present. This is not a blocker; date-fns is the correct choice on its own merits.

---

### 2.4 Backend Boundary — Choice Matrix

**Phase 1 dimensions:**

| Dimension | Definition | Weight |
|---|---|---|
| Data ownership simplicity | Single DB owner for goals tables; no cross-service auth or data federation | must-pass |
| Deployment cost | Infrastructure delta: new container, CI pipeline, port allocation, monitoring | 0.35 |
| Development velocity | Time to first working endpoint; reuse of existing auth, middleware, patterns | 0.35 |
| Future scale boundary | How cleanly can goals be extracted later if traffic/complexity warrants | 0.15 |
| Auth complexity | Additional authentication/authorization machinery needed | 0.15 |

**Phase 2 candidates:**

| Dimension (weight) | A: Extend aspirant-server | B: New aspirant-goals service (Go) | C: New aspirant-goals service (Python/FastAPI) |
|---|---|---|---|
| Data ownership (must-pass) | ✓ Server already owns user-scoped tables; goals tables follow same GORM auto-migrate pattern | ✓ New service owns its tables, but needs server's `users` table for FK; requires shared-DB pattern or duplicate auth | ✓ Same shared-DB story as B; UUID PKs avoid collision per CONVENTIONS.md |
| Deployment cost (0.35) | Zero — no new container, no new CI, no new port | High — new repo, new Dockerfile, new CI workflow, port 8089, docker-compose entry, GHCR package | High — same as B plus Python runtime overhead |
| Development velocity (0.35) | High — reuse existing JWT middleware, ValidateRole, DB connection, handler patterns; first endpoint in <1 hour | Low — must bootstrap repo, wire auth (either duplicate JWT verification or add internal auth proxy), set up GORM from scratch | Low — same bootstrap cost as B; different ORM (SQLAlchemy) adds schema divergence risk |
| Future scale boundary (0.15) | Medium — handlers are in `handlers/goals_*.go`, separable by file move later | High — already isolated by design | High — already isolated |
| Auth complexity (0.15) | Zero — `trustedRoutes` group already validates JWT + Trusted role | Medium — must verify JWT independently or proxy through server | Medium — same as B |
| **Recommendation** | **Chosen** — zero overhead, full reuse, clean file separation allows future extraction | Premature separation for a single-user system | Wrong runtime for a Go-dominated platform |

**§ Recommendation:** Extend aspirant-server. The goals feature is user-scoped data behind the same auth boundary. Creating a separate service for a single-user platform adds deployment complexity with no compensating benefit. CONVENTIONS.md already establishes that the server owns user-scoped tables, and the existing `trustedRoutes` group provides the exact auth level needed.

**§ Decision:** Extend aspirant-server with `/goals/` route group under `trustedRoutes`.

**§ Open questions parked:**
- If goals ever become a multi-user/shared feature, extraction to a dedicated service would be justified. The file-per-domain handler pattern (`handlers/goals_*.go`) keeps extraction cheap.

---

## 3. Database Schema (DDL)

Tables are created by GORM `AutoMigrate` on server startup. The DDL below is the target schema in PostgreSQL syntax for reference and review.

```sql
-- Trees: top-level container for a goal hierarchy
CREATE TABLE trees (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID NOT NULL,
    name VARCHAR(255) NOT NULL,
    root_node_id UUID,
    editing_session_id VARCHAR(64),
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    deleted_at TIMESTAMPTZ
);

CREATE INDEX idx_trees_user_id ON trees(user_id);
CREATE INDEX idx_trees_user_id_deleted_at ON trees(user_id, deleted_at);

-- Nodes: individual items in a tree (goal, milestone, step)
CREATE TABLE nodes (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tree_id UUID NOT NULL REFERENCES trees(id) ON DELETE CASCADE,
    parent_id UUID REFERENCES nodes(id) ON DELETE SET NULL,
    name VARCHAR(255) NOT NULL,
    type VARCHAR(20) NOT NULL CHECK (type IN ('goal', 'milestone', 'step')),
    color VARCHAR(7),
    sort_order INTEGER NOT NULL DEFAULT 0,
    planned_start DATE,
    planned_end DATE,
    completed_at TIMESTAMPTZ,
    manual_complete BOOLEAN NOT NULL DEFAULT false,
    description TEXT NOT NULL DEFAULT '',
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    deleted_at TIMESTAMPTZ
);

CREATE INDEX idx_nodes_tree_id ON nodes(tree_id);
CREATE INDEX idx_nodes_tree_id_type ON nodes(tree_id, type);
CREATE INDEX idx_nodes_tree_id_completed_at ON nodes(tree_id, completed_at);
CREATE INDEX idx_nodes_parent_id_sort_order ON nodes(parent_id, sort_order);

-- Edges: materialized parent-child relationships for graph traversal
CREATE TABLE edges (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    from_id UUID NOT NULL REFERENCES nodes(id) ON DELETE CASCADE,
    to_id UUID NOT NULL REFERENCES nodes(id) ON DELETE CASCADE,
    tree_id UUID NOT NULL REFERENCES trees(id) ON DELETE CASCADE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT edges_to_id_unique UNIQUE (to_id)
);

CREATE INDEX idx_edges_tree_id ON edges(tree_id);
CREATE INDEX idx_edges_from_id ON edges(from_id);

-- Comments: per-node discussion/notes
CREATE TABLE goal_comments (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    node_id UUID NOT NULL REFERENCES nodes(id) ON DELETE CASCADE,
    user_id UUID NOT NULL,
    body TEXT NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ,
    deleted_at TIMESTAMPTZ
);

CREATE INDEX idx_goal_comments_node_id ON goal_comments(node_id);
CREATE INDEX idx_goal_comments_node_id_deleted_at ON goal_comments(node_id, deleted_at);
```

**Notes:**
- Table named `goal_comments` (not `comments`) to avoid collision with any future platform-wide comments table.
- `user_id` references are not FK-constrained to `users` because GORM manages the `users` table with auto-increment integer IDs. Goals use UUIDs per the Python service convention (CONVENTIONS.md §Database). The server validates user existence at the application layer via JWT claims.
- `ON DELETE CASCADE` from trees to nodes/edges ensures tree deletion is atomic.
- `ON DELETE SET NULL` on `nodes.parent_id` supports the edge-survival reattachment logic (application code handles the reparenting before soft-delete sets the parent to null).

**GORM model note:** Since the server currently uses auto-increment integers (GORM default), the goals models will use `gorm:"type:uuid;default:gen_random_uuid()"` tags to override. This is consistent with the spec's UUID requirement and CONVENTIONS.md's allowance for UUID PKs when cross-service compatibility matters.

---

## 4. API Contract

All endpoints require JWT authentication and Trusted role. Prefix: `/goals/`.

### 4.1 Trees

#### POST /goals/trees

Create a new tree.

**Request:**
```json
{
  "name": "2026 Yearly Goals"
}
```

**Response (201):**
```json
{
  "id": "550e8400-e29b-41d4-a716-446655440000",
  "user_id": "a1b2c3d4-...",
  "name": "2026 Yearly Goals",
  "root_node_id": null,
  "editing_session_id": null,
  "created_at": "2026-05-12T10:00:00Z",
  "updated_at": "2026-05-12T10:00:00Z"
}
```

#### GET /goals/trees

List all trees for the authenticated user.

**Response (200):**
```json
{
  "items": [
    {
      "id": "550e8400-...",
      "name": "2026 Yearly Goals",
      "root_node_id": "660e8400-...",
      "created_at": "2026-05-12T10:00:00Z",
      "updated_at": "2026-05-12T10:00:00Z"
    }
  ],
  "total": 1,
  "page": 1,
  "page_size": 20
}
```

#### GET /goals/trees/{id}

**Response (200):** Single tree object (same shape as list item).

#### PATCH /goals/trees/{id}

**Request:**
```json
{ "name": "2026 Goals (revised)" }
```

**Response (200):** Updated tree object.

#### DELETE /goals/trees/{id}

Soft-deletes the tree and cascades `deleted_at` to all nodes, edges, and comments.

**Response (204):** Empty.

---

### 4.2 Nodes

#### POST /goals/trees/{tree_id}/nodes

**Request:**
```json
{
  "name": "Learn Spanish to B2",
  "type": "goal",
  "color": "#4A90D9",
  "planned_start": "2026-01-01",
  "planned_end": "2026-12-31",
  "parent_id": null
}
```

**Response (201):**
```json
{
  "id": "770e8400-...",
  "tree_id": "550e8400-...",
  "parent_id": null,
  "name": "Learn Spanish to B2",
  "type": "goal",
  "color": "#4A90D9",
  "sort_order": 100,
  "planned_start": "2026-01-01",
  "planned_end": "2026-12-31",
  "completed_at": null,
  "manual_complete": false,
  "description": "## Why it matters\n\n...",
  "created_at": "2026-05-12T10:01:00Z",
  "updated_at": "2026-05-12T10:01:00Z"
}
```

**Error (422) — depth exceeded:**
```json
{
  "error": {
    "code": "max_depth_exceeded",
    "message": "Maximum tree depth of 5 levels exceeded.",
    "details": { "current_depth": 5 }
  }
}
```

#### GET /goals/trees/{tree_id}/nodes

List all active nodes in a tree. Supports timeline filter query params.

**Query params:**
| Param | Values | Description |
|---|---|---|
| `period` | `day`, `week`, `month`, `quarter`, `year`, `custom` | Time period granularity |
| `value` | `2026-W20`, `2026-Q1`, `2026-03`, `2026` | Period identifier (ISO format) |
| `start` | `2026-01-01` | Custom range start (when period=custom) |
| `end` | `2026-03-31` | Custom range end (when period=custom) |
| `mode` | `planned`, `achieved`, `combined` | Filter mode |

**Response (200):**
```json
{
  "items": [...],
  "total": 12,
  "page": 1,
  "page_size": 100
}
```

#### GET /goals/trees/{tree_id}/nodes/{id}

**Response (200):** Single node with `resolved_color` (computed from inheritance chain).

```json
{
  "id": "770e8400-...",
  "resolved_color": "#4A90D9",
  ...
}
```

#### PATCH /goals/trees/{tree_id}/nodes/{id}

Partial update. Any subset of: `name`, `type`, `color`, `sort_order`, `planned_start`, `planned_end`, `description`.

**Request:**
```json
{ "name": "Learn Spanish to B1", "planned_end": "2026-06-30" }
```

**Response (200):** Updated node.

#### DELETE /goals/trees/{tree_id}/nodes/{id}

Soft-delete with edge survival (children reparented to deleted node's parent).

**Response (204):** Empty.

#### POST /goals/trees/{tree_id}/nodes/{id}/complete

Mark node as manually complete.

**Response (200):**
```json
{
  "id": "770e8400-...",
  "completed_at": "2026-05-12T14:30:00Z",
  "manual_complete": true,
  ...
}
```

#### POST /goals/trees/{tree_id}/nodes/{id}/uncomplete

Revert completion. Cascades upward (auto-completed ancestors become incomplete).

**Response (200):** Updated node with `completed_at: null`.

---

### 4.3 Edges

#### POST /goals/trees/{tree_id}/edges

**Request:**
```json
{ "from_id": "770e8400-...", "to_id": "880e8400-..." }
```

**Response (201):**
```json
{
  "id": "990e8400-...",
  "from_id": "770e8400-...",
  "to_id": "880e8400-...",
  "tree_id": "550e8400-...",
  "created_at": "2026-05-12T10:02:00Z"
}
```

#### GET /goals/trees/{tree_id}/edges

**Response (200):** `{ "items": [...], "total": 11 }`

#### DELETE /goals/trees/{tree_id}/edges/{id}

**Response (204):** Empty.

---

### 4.4 Comments

#### POST /goals/nodes/{node_id}/comments

**Request:**
```json
{ "body": "Finished the first module today." }
```

**Response (201):**
```json
{
  "id": "aa0e8400-...",
  "node_id": "770e8400-...",
  "user_id": "a1b2c3d4-...",
  "body": "Finished the first module today.",
  "created_at": "2026-05-12T14:00:00Z",
  "updated_at": null
}
```

#### GET /goals/nodes/{node_id}/comments

**Response (200):** `{ "items": [...], "total": 3, "page": 1, "page_size": 20 }`

#### PATCH /goals/comments/{id}

**Request:**
```json
{ "body": "Finished the first module — scored 85%." }
```

**Response (200):** Updated comment with `updated_at` set.

#### DELETE /goals/comments/{id}

**Response (204):** Soft-delete.

---

### 4.5 Session Lock

#### POST /goals/trees/{id}/session

Acquire or take over an editing session.

**Request:**
```json
{ "session_id": "browser-tab-uuid-abc123" }
```

**Response (200):**
```json
{ "acquired": true, "expires_at": "2026-05-12T11:00:00Z" }
```

**Response (409) — another session active:**
```json
{
  "error": {
    "code": "conflict",
    "message": "Another editing session is active.",
    "details": { "existing_session_id": "other-uuid", "takeover_allowed": true }
  }
}
```

#### DELETE /goals/trees/{id}/session

Release the editing session.

**Response (204):** Empty.

**Session expiry:** 30 minutes of inactivity. The server checks `updated_at` on the tree record; if the session hasn't touched the tree in 30 minutes, the lock is considered stale and a new session can acquire without takeover.

---

## 5. Frontend Module Structure

```
src/
├── views/
│   └── trusted/
│       └── goals/
│           ├── GoalTreeList.vue        # /trusted/goals — tree listing
│           └── GoalTreeCanvas.vue      # /trusted/goals/:id — canvas view
├── components/
│   └── goals/
│       ├── TreeCard.vue                # Tree card for the list view
│       ├── Canvas.vue                  # Vue Flow wrapper (zoom/pan/layout)
│       ├── CanvasNode.vue             # Custom Vue Flow node (slot content)
│       ├── NodeDetailPanel.vue         # Slide-out drawer for node editing
│       ├── NodeCreationDialog.vue      # Create-node modal
│       ├── TimelineFilter.vue          # Period selector toolbar
│       ├── CompletionToggle.vue        # Checkmark/progress ring button
│       ├── ColorPicker.vue             # Color with inheritance display
│       ├── MarkdownViewer.vue          # markdown-it rendered content
│       ├── MarkdownEditor.vue          # Textarea with live preview
│       ├── CommentList.vue             # Comments section in detail panel
│       └── TreeSwitcher.vue            # Dropdown to switch active tree
└── composables/
    └── goals/
        ├── useGoalTrees.js             # Tree CRUD API calls + state
        ├── useGoalNodes.js             # Node CRUD + completion logic
        ├── useGoalEdges.js             # Edge management
        ├── useGoalComments.js          # Comment CRUD
        ├── useTimelineFilter.js        # Period math (date-fns), filter state
        ├── useCanvasLayout.js          # dagre layout computation
        └── useSessionLock.js           # Session acquire/release/heartbeat
```

**Router additions** (in `src/router/index.js`):

```javascript
{
  path: '/trusted/goals',
  component: () => import('../views/trusted/goals/GoalTreeList.vue'),
  meta: { requiresAuth: true, role: 'Trusted' }
},
{
  path: '/trusted/goals/:id',
  component: () => import('../views/trusted/goals/GoalTreeCanvas.vue'),
  meta: { requiresAuth: true, role: 'Trusted' }
}
```

---

## 6. Key Implementation Details

### Auto-Completion Cascade

When a node is marked complete (manually or via last-sibling trigger):

1. Set `completed_at = now()` on the target node.
2. Query siblings: `SELECT COUNT(*) FROM nodes WHERE parent_id = ? AND deleted_at IS NULL AND completed_at IS NULL`.
3. If count = 0 (all siblings complete), recursively mark parent complete with `manual_complete = false`.
4. Repeat upward until a parent has incomplete siblings or root is reached.
5. Return the full list of affected node IDs so the frontend can update the canvas in one repaint.

### Edge Survival on Delete

When soft-deleting node B (where A→B→C):

1. Find B's children: `SELECT id FROM nodes WHERE parent_id = B.id AND deleted_at IS NULL`.
2. For each child C: `UPDATE nodes SET parent_id = B.parent_id WHERE id = C.id`.
3. Delete old edge record (B→C), create new edge record (A→C).
4. Set `B.deleted_at = now()`.
5. Delete the A→B edge record.

### Timeline Filter (Server-Side)

The filter computes date boundaries from the period+value params and applies:

```sql
-- mode=planned
WHERE (planned_start <= :period_end AND planned_end >= :period_start)

-- mode=achieved
WHERE completed_at >= :period_start AND completed_at < :period_end

-- mode=combined
WHERE (planned_start <= :period_end AND planned_end >= :period_start)
  AND completed_at IS NULL
```

ISO week boundaries use Go's `time.ISOWeek()` and `time.Date()` with Monday as week start.

### Color Resolution

Computed at query time, not stored:

```sql
-- Recursive CTE for resolved color
WITH RECURSIVE ancestors AS (
    SELECT id, parent_id, color FROM nodes WHERE id = :node_id
    UNION ALL
    SELECT n.id, n.parent_id, n.color
    FROM nodes n JOIN ancestors a ON n.id = a.parent_id
    WHERE n.deleted_at IS NULL
)
SELECT color FROM ancestors WHERE color IS NOT NULL LIMIT 1;
```

For the list-all-nodes endpoint, the server resolves colors in a single tree traversal (DFS from root) rather than per-node CTE, avoiding N+1.

---

## 7. Migration Order

Development phases, each independently deployable:

| Phase | Scope | Deliverable | Depends on |
|---|---|---|---|
| **M1** | Backend: schema + tree CRUD | `handlers/goals_trees.go`, GORM models, AutoMigrate | — |
| **M2** | Backend: node CRUD + edges | `handlers/goals_nodes.go`, `handlers/goals_edges.go`, depth validation, edge survival logic | M1 |
| **M3** | Backend: comments + completion cascade | `handlers/goals_comments.go`, auto-completion, timeline filter | M2 |
| **M4** | Backend: session lock | `POST/DELETE /goals/trees/{id}/session`, expiry logic | M1 |
| **M5** | Frontend: tree list + routing | `GoalTreeList.vue`, `TreeCard.vue`, router entries | M1 |
| **M6** | Frontend: canvas + layout | `Canvas.vue`, `CanvasNode.vue`, Vue Flow integration, dagre layout | M2, M5 |
| **M7** | Frontend: node detail + editing | `NodeDetailPanel.vue`, markdown rendering, color picker, completion toggle | M3, M6 |
| **M8** | Frontend: timeline filter | `TimelineFilter.vue`, `useTimelineFilter.js` with date-fns | M3, M6 |
| **M9** | Frontend: comments | `CommentList.vue`, `useGoalComments.js` | M3, M7 |
| **M10** | Integration: session lock UI | `useSessionLock.js`, conflict prompt | M4, M6 |

**Critical path:** M1 → M2 → M3 → M6 → M7 → M8 (backend-first enables frontend parallelism from M5 onward).

---

## 8. Spec Cross-References

| Architecture decision | Spec section |
|---|---|
| Extend aspirant-server (no new service) | §4 "All endpoints under `/api/`"; §3 "Authentication and Authorization" (JWT, single user scope) |
| Vue Flow for graph | §5 "Graph Layout" — custom node renderers, zoomable/pannable, declarative |
| markdown-it for descriptions | §2 "nodes.description: TEXT" rendered as markdown; §5 "Node Detail Panel" — rendered markdown description |
| date-fns for timeline | §3 "Time Periods and Timeline Filter" — ISO week, quarter, custom range |
| UUID primary keys | §2 all tables use UUID; CONVENTIONS.md §Database "UUID for Python services" — goals tables follow this pattern despite being in Go |
| Session lock expiry = 30 min | §3 "Session Locking" — "duration TBD in architecture phase — likely 30 minutes" → confirmed |
| `goal_comments` table name | §2 "comments" table + CONVENTIONS.md §Database "Table Naming" — disambiguated to avoid platform collision |
| Node type CHECK constraint | §2 "type: one of goal, milestone, step" |
| Depth limit = 5, HTTP 422 | §3 "Depth Limit" |
| Soft-delete cascade on tree DELETE | §3 "Soft Delete and Edge Survival" |
