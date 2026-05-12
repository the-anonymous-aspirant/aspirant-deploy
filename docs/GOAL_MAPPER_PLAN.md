# Goal Mapper — Implementation Plan

*Status: Draft*
*Author: aspirant_developer*
*Date: 2026-05-12*
*Spec: [GOAL_MAPPER_SPEC.md](./GOAL_MAPPER_SPEC.md)*
*Architecture: [GOAL_MAPPER_ARCHITECTURE.md](./GOAL_MAPPER_ARCHITECTURE.md)*

---

## Overview

This plan sequences the implementation of the Goal Mapper feature into numbered steps grouped by track. Each step maps to one or more subtasks from epic #11899 and includes explicit dependencies, files touched, and acceptance criteria.

**Tracks:**
- **B** — Backend (aspirant-server, Go/Gin)
- **F** — Frontend (aspirant-client, Vue 3)
- **V** — Verification (integration tests)
- **G** — Closure gate

---

## B-Track: Backend

### B1 — Schema Migration + GORM Models

**Goal:** Create the four goal tables via GORM AutoMigrate and define the data models.

**Files touched:**
- `aspirant-server/data_models/goals.go` (new — Tree, Node, Edge, GoalComment structs)
- `aspirant-server/main.go` (add AutoMigrate call for goal models)

**Acceptance criteria:**
- Server starts without error and tables `trees`, `nodes`, `edges`, `goal_comments` exist in PostgreSQL.
- UUID primary keys, all indexes from the architecture DDL are present.
- `nodes.type` CHECK constraint enforced.
- Soft-delete (`deleted_at`) fields on all four models.

**Dependencies:** None.
**Effort:** Small.

---

### B2 — Tree + Node + Edge CRUD Endpoints

**Goal:** Implement the full CRUD API for trees, nodes, and edges including depth validation and edge-survival-on-delete.

**Files touched:**
- `aspirant-server/handlers/goals_trees.go` (new — POST/GET/PATCH/DELETE /goals/trees)
- `aspirant-server/handlers/goals_nodes.go` (new — POST/GET/PATCH/DELETE /goals/trees/{tree_id}/nodes, complete/uncomplete)
- `aspirant-server/handlers/goals_edges.go` (new — POST/GET/DELETE /goals/trees/{tree_id}/edges)
- `aspirant-server/data_functions/goals.go` (new — shared helpers: depth check, edge survival, sort_order assignment)
- `aspirant-server/main.go` (register route group under trustedRoutes)

**Acceptance criteria:**
- All tree endpoints return correct status codes (201, 200, 204) per the API contract.
- Node creation rejects depth > 5 with HTTP 422 + `max_depth_exceeded` error code.
- Soft-deleting a middle node reparents its children to the deleted node's parent (edge survival).
- Root node deletion returns 400 ("delete the tree instead").
- All queries filter by authenticated `user_id`; accessing another user's tree returns 404.
- Edges enforce UNIQUE(to_id) — single parent constraint.
- `sort_order` auto-assigned as `max(siblings) + 100` on creation.

**Dependencies:** B1.
**Effort:** Large.

---

### B3 — Comments Endpoints

**Goal:** Implement CRUD for goal comments attached to nodes.

**Files touched:**
- `aspirant-server/handlers/goals_comments.go` (new — POST/GET/PATCH/DELETE for comments)

**Acceptance criteria:**
- Comments scoped to authenticated user.
- `PATCH` sets `updated_at`; response includes the updated timestamp.
- `DELETE` is soft-delete (`deleted_at` set, record retained).
- `GET` filters `deleted_at IS NULL` by default.

**Dependencies:** B1 (needs nodes table to exist for FK).
**Effort:** Small.

---

### B4 — Completion Auto-Rollup Logic

**Goal:** Implement cascading auto-completion when all children are complete, plus manual override and revert.

**Files touched:**
- `aspirant-server/data_functions/goals.go` (add `cascadeCompletion`, `revertCompletion` helpers)
- `aspirant-server/handlers/goals_nodes.go` (integrate cascade into complete/uncomplete endpoints and node deletion)

**Acceptance criteria:**
- Completing the last incomplete sibling auto-marks the parent complete (`manual_complete = false`).
- Cascade propagates upward through all ancestor levels.
- Manual completion (`POST .../complete`) sets `manual_complete = true` and does NOT cascade.
- Reverting completion (`POST .../uncomplete`) clears `completed_at` and propagates upward (auto-completed ancestors become incomplete).
- Response includes the list of all affected node IDs.

**Dependencies:** B2 (needs node CRUD + tree structure).
**Effort:** Medium.

---

### B5 — Timeline Filter Endpoint

**Goal:** Add server-side timeline filtering to the node list endpoint.

**Files touched:**
- `aspirant-server/handlers/goals_nodes.go` (add query param parsing + date range computation)
- `aspirant-server/data_functions/goals.go` (add `computePeriodBounds` using Go `time` package for ISO week/quarter math)

**Acceptance criteria:**
- `GET /goals/trees/{id}/nodes?period=quarter&value=2026-Q1&mode=planned` returns only nodes whose planned range intersects Q1.
- `mode=achieved` filters on `completed_at` within the period.
- `mode=combined` returns planned-but-not-yet-achieved nodes.
- ISO week boundaries use Monday as start (Go `time.ISOWeek()`).
- Missing or invalid params return 400 with descriptive error.

**Dependencies:** B2 (needs node list endpoint).
**Effort:** Medium.

---

## F-Track: Frontend

### F1 — Route + Tree List View

**Goal:** Add `/trusted/goals` route and the tree listing page.

**Files touched:**
- `aspirant-client/src/router/index.js` (add two route entries)
- `aspirant-client/src/views/trusted/goals/GoalTreeList.vue` (new)
- `aspirant-client/src/components/goals/TreeCard.vue` (new)
- `aspirant-client/src/composables/goals/useGoalTrees.js` (new — tree CRUD API calls)

**Acceptance criteria:**
- Navigating to `/trusted/goals` shows the user's trees as cards.
- Create, rename, and delete tree actions work.
- Route requires auth + Trusted role.
- Empty state shown when no trees exist.

**Dependencies:** B1 (tree endpoints must exist).
**Effort:** Small.

---

### F2 — Tree Switcher + Create/Rename/Save

**Goal:** Add a dropdown component that cycles between the user's trees from within the canvas view.

**Files touched:**
- `aspirant-client/src/components/goals/TreeSwitcher.vue` (new)
- `aspirant-client/src/views/trusted/goals/GoalTreeCanvas.vue` (new — canvas view shell)

**Acceptance criteria:**
- Dropdown lists all user trees by name.
- Selecting a tree navigates to `/trusted/goals/{id}`.
- Inline rename via the switcher.

**Dependencies:** F1 (tree list composable).
**Effort:** Small.

---

### F3 — Graph Canvas + Zoom/Pan

**Goal:** Integrate Vue Flow to render the goal tree as an interactive, zoomable graph.

**Files touched:**
- `aspirant-client/src/components/goals/Canvas.vue` (new — Vue Flow wrapper)
- `aspirant-client/src/components/goals/CanvasNode.vue` (new — custom node slot content)
- `aspirant-client/src/composables/goals/useGoalNodes.js` (new — node CRUD API)
- `aspirant-client/src/composables/goals/useGoalEdges.js` (new — edge API)
- `aspirant-client/src/composables/goals/useCanvasLayout.js` (new — dagre layout computation)
- `aspirant-client/package.json` (add `@vue-flow/core`, `@vue-flow/layout`)

**Acceptance criteria:**
- Tree renders as a top-down hierarchical graph via dagre layout.
- Zoom (scroll) and pan (drag background) work.
- Nodes display: name, type icon, color bar, completion indicator.
- Edges rendered as directed lines between parent→child.
- Clicking a node opens the detail panel (F5).

**Dependencies:** B2 (node/edge endpoints), F2 (canvas view shell).
**Effort:** Large.

---

### F4 — Node Creation Flow

**Goal:** Allow users to create nodes from the canvas with type selection and markdown template pre-population.

**Files touched:**
- `aspirant-client/src/components/goals/NodeCreationDialog.vue` (new)

**Acceptance criteria:**
- Dialog triggered from canvas (button or context menu).
- User selects type (goal/milestone/step), name, parent, dates.
- Description auto-filled with the appropriate markdown template per type.
- Depth-5 warning shown before submit; 422 gracefully displayed if rejected.
- New node appears on canvas after creation.

**Dependencies:** F3 (canvas must exist), B2 (node creation endpoint).
**Effort:** Small.

---

### F5 — Node Detail Panel

**Goal:** Slide-out panel showing full node details with editing capabilities.

**Files touched:**
- `aspirant-client/src/components/goals/NodeDetailPanel.vue` (new)
- `aspirant-client/src/components/goals/CompletionToggle.vue` (new)
- `aspirant-client/src/components/goals/ColorPicker.vue` (new)
- `aspirant-client/src/components/goals/MarkdownViewer.vue` (new — markdown-it + DOMPurify)
- `aspirant-client/src/components/goals/MarkdownEditor.vue` (new — textarea with live preview)
- `aspirant-client/package.json` (add `markdown-it`, `dompurify`)

**Acceptance criteria:**
- Panel opens when a canvas node is clicked.
- Displays: name (editable), type badge, color picker, planned dates (date pickers), completion toggle, rendered markdown description, edit mode for description.
- Color picker shows inherited color with option to override or clear.
- Completion toggle reflects auto vs. manual state.
- All edits persist via PATCH endpoint on blur/submit.

**Dependencies:** F3 (canvas integration), B4 (completion cascade for toggle behavior).
**Effort:** Medium.

---

### F6 — Timeline Filter Chrome

**Goal:** Toolbar above the canvas that applies ISO time period filtering.

**Files touched:**
- `aspirant-client/src/components/goals/TimelineFilter.vue` (new)
- `aspirant-client/src/composables/goals/useTimelineFilter.js` (new — date-fns period math)
- `aspirant-client/package.json` (add `date-fns`)

**Acceptance criteria:**
- Period selector: day / ISO week / month / quarter / year / custom range.
- Mode toggle: planned / achieved / combined.
- Applying filter dims non-matching nodes on canvas (not hidden — preserves graph context).
- Clear button resets to show all nodes.
- Period values use ISO format (2026-W20, 2026-Q1, etc.).

**Dependencies:** F3 (canvas to dim nodes), B5 (timeline filter endpoint).
**Effort:** Medium.

---

### F7 — Comments Section

**Goal:** Show and manage comments within the node detail panel.

**Files touched:**
- `aspirant-client/src/components/goals/CommentList.vue` (new)
- `aspirant-client/src/composables/goals/useGoalComments.js` (new — comment CRUD API)

**Acceptance criteria:**
- Comments listed chronologically under the node detail panel.
- Add new comment with markdown body.
- Edit existing comments (shows "(edited)" indicator when `updated_at` is set).
- Delete (soft) a comment.

**Dependencies:** F5 (node detail panel), B3 (comments endpoint).
**Effort:** Small.

---

## V-Track: Verification

### V1 — Integration Test: Full Lifecycle

**Goal:** End-to-end test covering create tree → add nodes → mark complete → assert auto-rollup → assert timeline filter.

**Files touched:**
- `aspirant-server/handlers/goals_integration_test.go` (new)

**Acceptance criteria:**
- Test creates a tree, adds a 3-level hierarchy (goal → milestone → step).
- Completes all steps under one milestone; asserts milestone auto-completes.
- Completes remaining milestones; asserts goal auto-completes.
- Applies timeline filter; asserts correct nodes returned.
- All assertions pass in CI.

**Dependencies:** B1, B2, B4, B5.
**Effort:** Medium.

---

### V2 — Integration Test: Edge Survival

**Goal:** Verify that deleting a middle node reconnects its children to its parent.

**Files touched:**
- `aspirant-server/handlers/goals_integration_test.go` (extend)

**Acceptance criteria:**
- Creates A→B→C chain.
- Soft-deletes B.
- Asserts C's parent_id is now A.
- Asserts edge A→C exists and edge A→B and B→C are removed.
- B has `deleted_at` set.

**Dependencies:** B2.
**Effort:** Small.

---

### V3 — Integration Test: User Isolation

**Goal:** Verify that one user cannot see or modify another user's trees.

**Files touched:**
- `aspirant-server/handlers/goals_integration_test.go` (extend)

**Acceptance criteria:**
- User A creates a tree.
- User B attempts GET/PATCH/DELETE on User A's tree — all return 404.
- User B's tree list does not include User A's trees.

**Dependencies:** B2.
**Effort:** Small.

---

## G-Track: Closure

### G1 — Closure Verification

**Goal:** Final smoke test confirming all tracks deliver a working feature.

**Files touched:** None (manual verification by Victor).

**Acceptance criteria:**
- All B, F, V subtasks merged and passing CI.
- Victor can: create a tree, build a goal→milestone→step chain, mark items complete (sees rollup), apply timeline filter, add/edit comments, delete a middle node (sees edge survival), switch between trees.
- No regressions in existing features.

**Dependencies:** All of B1-B5, F1-F7, V1-V3.
**Effort:** Small (manual walkthrough).

---

## Dependency Graph

```
B1 ─────┬─── B2 ───┬─── B3
        │           ├─── B4 ─── (feeds F5 completion)
        │           └─── B5 ─── (feeds F6 filter)
        └─── B4* (only needs trees table from B1 for session lock)
             │
F1 ─── F2 ──┘
             │
B2 + F2 ─── F3 ───┬─── F4
                   ├─── F5 ───── F7
                   ├─── F6
                   └─── (session lock UI, deferred to M10)

V1 ← B1, B2, B4, B5
V2 ← B2
V3 ← B2

G1 ← everything
```

**Critical path:** B1 → B2 → B4 → F3 → F5 → F7 (longest chain).

---

## Milestone Schedule

| Milestone | Steps included | Checkpoint |
|-----------|---------------|------------|
| **MS1 — Data layer ready** | B1 | Server starts, tables exist, models compile. |
| **MS2 — Core API functional** | B2, B3 | Full CRUD works via curl/Postman. Trees, nodes, edges, comments all operational. |
| **MS3 — Smart behaviors** | B4, B5 | Auto-completion cascade + timeline filter verified server-side. |
| **MS4 — Canvas renders** | F1, F2, F3 | User can log in, see tree list, open a tree, see the graph on canvas with zoom/pan. |
| **MS5 — Interactive editing** | F4, F5, F6, F7 | Full editing experience: create nodes, edit details, markdown, comments, timeline filter, color theming. |
| **MS6 — Confidence gate** | V1, V2, V3 | All integration tests green in CI. |
| **MS7 — Ship** | G1 | Victor smoke-tests, confirms feature complete. |

---

## Effort Summary

| Size | Steps | Estimated time per step |
|------|-------|------------------------|
| Small | B1, B3, F1, F2, F4, F7, V2, V3, G1 | 1-2 hours each |
| Medium | B4, B5, F5, F6, V1 | 3-5 hours each |
| Large | B2, F3 | 6-10 hours each |

**Total estimated effort:** ~50-70 hours across all tracks.

---

## Notes

- Session lock UI (architecture phase M10) is intentionally omitted from the core implementation subtasks (B1-B5, F1-F7). It can be added as a follow-up once the core feature ships.
- The backend can be developed and tested independently before frontend work begins, but F1 can start as soon as B1 lands (tree list only needs tree CRUD).
- All frontend components follow the composable pattern: API logic in `useGoal*.js`, presentation in `.vue` components.
