# Goal Mapper — Specification

*Status: In Review*
*Author: aspirant_developer*
*Date: 2026-05-12*

---

## 1. Problem Statement

There is no tool in the Aspirant platform for tracking personal goals as structured, living artifacts. Goals exist as scattered notes or mental models with no visibility into progress, decomposition, or timeline adherence.

The Goal Mapper fills this gap: a user-scoped, graph-based goal tracker that lets a user grow a root goal into milestones and steps, visualize the entire tree on a zoomable canvas, filter by time period (planned vs. achieved), and track completion with automatic rollup semantics.

This feature lives under `/trusted/` (logged-in scope) — it is personal data, not platform admin.

*Origin: Victor's request in epic #11899, 2026-05-12.*

---

## 2. Data Model

### Table: `trees`

| Column | Type | Nullable | Description |
|--------|------|----------|-------------|
| id | UUID | No | Primary key |
| user_id | UUID | No | FK → users.id; ownership scope |
| name | VARCHAR(255) | No | Display name for the tree |
| root_node_id | UUID | Yes | FK → nodes.id; set after first node creation |
| created_at | TIMESTAMPTZ | No | Creation timestamp |
| updated_at | TIMESTAMPTZ | No | Last modification |

**Indexes:** `user_id` (all queries are user-scoped)

### Table: `nodes`

| Column | Type | Nullable | Description |
|--------|------|----------|-------------|
| id | UUID | No | Primary key |
| tree_id | UUID | No | FK → trees.id |
| name | VARCHAR(255) | No | Short label shown on canvas |
| type | VARCHAR(20) | No | One of: `goal`, `milestone`, `step` |
| color | VARCHAR(7) | Yes | Hex color override (e.g. `#4A90D9`); null = inherit from ancestor goal |
| planned_start | DATE | Yes | Start of planned period |
| planned_end | DATE | Yes | End of planned period |
| completed_at | TIMESTAMPTZ | Yes | Null if incomplete; set on completion |
| manual_complete | BOOLEAN | No | Default false; true = user overrode auto-completion |
| description | TEXT | No | Markdown body; pre-populated from template on creation |
| created_at | TIMESTAMPTZ | No | Creation timestamp |
| updated_at | TIMESTAMPTZ | No | Last modification |

**Indexes:** `tree_id`, `(tree_id, type)`, `(tree_id, completed_at)` for timeline filter

### Table: `edges`

| Column | Type | Nullable | Description |
|--------|------|----------|-------------|
| id | UUID | No | Primary key (edges have identity for deletion-survival) |
| from_id | UUID | No | FK → nodes.id (parent) |
| to_id | UUID | No | FK → nodes.id (child) |
| tree_id | UUID | No | FK → trees.id (denormalized for fast tree-scoped queries) |
| created_at | TIMESTAMPTZ | No | When the edge was created |

**Constraints:** UNIQUE(from_id, to_id); both from_id and to_id must belong to the same tree_id.

**Indexes:** `tree_id`, `from_id`, `to_id`

### Table: `comments`

| Column | Type | Nullable | Description |
|--------|------|----------|-------------|
| id | UUID | No | Primary key |
| node_id | UUID | No | FK → nodes.id |
| user_id | UUID | No | FK → users.id |
| body | TEXT | No | Markdown content |
| created_at | TIMESTAMPTZ | No | Creation timestamp |

**Indexes:** `node_id` (list comments for a node)

### Relationships

- A **tree** has one root node and many nodes.
- A **node** has zero or more parent edges and zero or more child edges (DAG, not strict tree).
- An **edge** connects exactly two nodes in the same tree.
- A **comment** belongs to exactly one node.
- All data is scoped by `user_id` — queries always filter on the authenticated user.

---

## 3. Behavior Contracts

### Auto-Completion (Strict with Manual Override)

- A node's `completed_at` is automatically set when ALL direct children have non-null `completed_at`.
- This cascades upward: completing the last sibling marks the parent, which may mark the grandparent, etc.
- A user can manually mark a node complete at any time (`manual_complete = true`). This does NOT cascade — only the targeted node is affected.
- A user can revert auto-completion by toggling a node back to incomplete. This clears `completed_at` and propagates upward (parent becomes incomplete if it was auto-completed).
- Leaf nodes (no children) can only be completed manually.

### Edge Survival on Delete

- Deleting node B in path A→B→C results in new edges A→C for every (parent of B, child of B) pair.
- The deleted node's edges are removed; new edges are created with fresh `created_at` timestamps.
- If B is a leaf, deletion simply removes the A→B edge.
- If B is the root, deletion is not allowed (delete the tree instead).

### Color Inheritance

- Color is set on a root goal node. All descendants inherit this color unless explicitly overridden.
- Resolution order: node's own `color` field → nearest ancestor with a non-null `color` → tree default (no color / system default).
- Changing a goal's color updates all descendants that don't have an explicit override (resolved at render time, not stored).

### Multiple Trees

- A user can have many trees. Only one tree is displayed on the canvas at a time.
- A tree switcher UI allows cycling between trees or creating a new one.
- Trees are completely independent — no cross-tree edges.

### Authentication and Authorization

- Only the authenticated user can see, create, modify, or delete their own trees, nodes, edges, and comments.
- All API endpoints filter by the JWT-authenticated `user_id`. There is no sharing between users.
- Attempting to access another user's tree returns 404 (not 403, to avoid leaking existence).

### Time Periods and Timeline Filter

- Time periods are ISO-standard: day, ISO week, month, quarter, year, or a custom date range.
- **Planned filter:** A node matches if its `[planned_start, planned_end]` interval intersects the selected period.
- **Achieved filter:** A node matches if its `completed_at` timestamp falls within the selected period.
- **Combined filter:** "Planned for Q1 AND not yet achieved" = planned intersects Q1 AND `completed_at` is null.
- Nodes that don't match the active filter are dimmed on the canvas, not hidden (preserves graph context).

---

## 4. API Surface

All endpoints are under `/api/` and require JWT authentication. Responses follow the standard error shape defined in `CONVENTIONS.md`.

### Trees

| Method | Path | Description |
|--------|------|-------------|
| `POST` | `/goals/trees` | Create a new tree |
| `GET` | `/goals/trees` | List all trees for the authenticated user |
| `GET` | `/goals/trees/{id}` | Get a single tree (includes root_node_id) |
| `PATCH` | `/goals/trees/{id}` | Update tree name |
| `DELETE` | `/goals/trees/{id}` | Delete tree and all its nodes/edges/comments |

**Create payload:**
```json
{ "name": "2026 Yearly Goals" }
```

**Response:** Full tree object with generated `id`, `created_at`, `root_node_id: null`.

### Nodes

| Method | Path | Description |
|--------|------|-------------|
| `POST` | `/goals/trees/{tree_id}/nodes` | Create a node in a tree |
| `GET` | `/goals/trees/{tree_id}/nodes` | List all nodes in a tree |
| `GET` | `/goals/trees/{tree_id}/nodes/{id}` | Get a single node with computed color |
| `PATCH` | `/goals/trees/{tree_id}/nodes/{id}` | Update node fields |
| `DELETE` | `/goals/trees/{tree_id}/nodes/{id}` | Delete node (edge survival applies) |
| `POST` | `/goals/trees/{tree_id}/nodes/{id}/complete` | Mark node complete (manual override) |
| `POST` | `/goals/trees/{tree_id}/nodes/{id}/uncomplete` | Revert completion |

**Create payload:**
```json
{
  "name": "Learn Spanish to B2",
  "type": "goal",
  "color": "#4A90D9",
  "planned_start": "2026-01-01",
  "planned_end": "2026-12-31",
  "parent_ids": []
}
```

The `description` field is auto-populated from the node-type template on creation. Subsequent `PATCH` calls can modify it.

**Timeline filter (query params on list):**
```
GET /goals/trees/{tree_id}/nodes?period=quarter&value=2026-Q1&mode=planned
GET /goals/trees/{tree_id}/nodes?period=custom&start=2026-01-01&end=2026-03-31&mode=achieved
```

### Edges

| Method | Path | Description |
|--------|------|-------------|
| `POST` | `/goals/trees/{tree_id}/edges` | Create an edge between two nodes |
| `GET` | `/goals/trees/{tree_id}/edges` | List all edges in a tree |
| `DELETE` | `/goals/trees/{tree_id}/edges/{id}` | Delete a specific edge |

**Create payload:**
```json
{ "from_id": "uuid-parent", "to_id": "uuid-child" }
```

### Comments

| Method | Path | Description |
|--------|------|-------------|
| `POST` | `/goals/nodes/{node_id}/comments` | Add a comment to a node |
| `GET` | `/goals/nodes/{node_id}/comments` | List comments for a node |
| `DELETE` | `/goals/comments/{id}` | Delete a comment |

**Create payload:**
```json
{ "body": "Finished the first module today." }
```

---

## 5. UX Surface

### Views and Components

| Component | Purpose |
|-----------|---------|
| **Tree List** | Shows all user's trees as cards. Create/rename/delete actions. Entry point after navigating to `/trusted/goals`. |
| **Tree Canvas** | Zoomable, pannable graph visualization of the active tree. Nodes rendered as colored cards; edges as directed lines. |
| **Tree Switcher** | Dropdown or sidebar that cycles between trees without leaving the canvas view. |
| **Node Detail Panel** | Slide-out panel showing: name, type badge, color picker, planned dates, completion status, rendered markdown description (editable), and comments list. |
| **Timeline Filter Chrome** | Toolbar above the canvas: period selector (day/week/month/quarter/year/custom), mode toggle (planned/achieved/combined), apply/clear buttons. |
| **Completion Toggle** | Button in node detail panel and on the canvas node card. Shows auto-completed state vs. manual override. |
| **Color Picker** | In node detail panel. Shows inherited color with option to override. Clear button to revert to inheritance. |
| **Node Creation Dialog** | Triggered from canvas (right-click or button). Selects type, name, parent(s), dates. Pre-populates description from template. |

### Navigation

- Route: `/trusted/goals` → Tree List
- Route: `/trusted/goals/{tree_id}` → Tree Canvas with that tree loaded
- Node detail panel is an overlay/drawer, not a separate route.

### Graph Layout

- Library choice deferred to Architecture phase (S2). Constraints: must support custom node renderers (for future hand-drawn SVG nodes), zoomable/pannable, declarative API preferred.
- Default layout: top-down hierarchical (root at top, children below).
- Nodes show: name, type icon, color bar, completion indicator (checkmark or progress ring).

---

## 6. Pre-Populated Templates

When a node is created, its `description` field is pre-populated with a markdown template based on the node's `type`. The user can edit freely after creation.

### Goal

```markdown
## Why it matters

What is the deeper motivation behind this goal? Why now?

## What success looks like

Describe the concrete outcome that means this goal is achieved.

## Next steps

Create milestones to break this goal into provable checkpoints.
```

### Milestone

```markdown
## What this milestone proves

What capability or progress does completing this milestone demonstrate?

## Next steps

Add the sequence of tasks needed to reach this milestone.
```

### Step

```markdown
## Definition of done

What specific, observable condition means this step is complete?

## Notes

Any context, links, or considerations for executing this step.
```

---

## 7. Open Questions

1. **Graph cycles** — The data model allows a DAG (multiple parents). Should we enforce strict tree structure (single parent) or allow multiple parents? The epic says "tree-of-trees" which suggests strict tree, but `parent_ids` (plural) in the task description implies DAG. *Recommendation: start with single-parent tree; add DAG later if needed.*

2. **Soft delete vs. hard delete** — Should deleted nodes/trees be permanently removed or soft-deleted with a `deleted_at` column? Affects undo capability and data recovery.

3. **Maximum tree depth** — Should there be a limit on nesting depth (e.g., goal → milestone → step → sub-step → sub-sub-step...)? The epic mentions "sub-step" but doesn't bound it.

4. **Offline/conflict resolution** — If the feature is used on multiple devices, how do concurrent edits resolve? Not relevant for v1 (single user, single session) but affects schema design if we want optimistic locking later.

5. **Node reordering** — Siblings in the graph have no explicit order. Should there be a `position` or `sort_order` field for controlling display order within a parent's children?

6. **Comment editing** — The API surface includes create and delete but not update. Should comments be editable after creation?

---

## 8. Out of Scope

From the epic (verbatim):
- Custom hand-drawn node visuals — architecture must accommodate, but default lib visuals are acceptable for v1.
- Sharing trees between users (collaborative goals).
- Notifications / reminders when a planned_end approaches.
- Export to PDF / image.
- Tagging or labels orthogonal to the goal hierarchy.
- Mobile-optimized canvas (basic responsive is enough; rich touch-first interaction is later).

Additional (identified during spec writing):
- Recurring goals (templates that reset per time period).
- Goal dependencies across trees.
- Analytics or reporting dashboards (completion rates, velocity).
- Integration with external tools (calendar sync, task managers).
- Undo/redo history beyond what the browser provides.
- Real-time collaboration or WebSocket push updates.
