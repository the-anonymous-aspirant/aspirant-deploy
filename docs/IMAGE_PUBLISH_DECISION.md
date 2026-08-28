# Image-Publish Lane Decision — GitHub-Side Merges on Image-Bearing Repos

**Status:** Proposed 2026-07-17. Merging this PR ratifies the recommendation
(option (a) + freshness backstop). If you prefer option (b), comment on the PR
instead of merging and the entry will be reworked.

**Origin:** system_3 task #2281, follow-up required by #2218 acceptance
(rebuild-on-DS-merge automation) and #2195 D1 gate 2 (comment 8986).

## Problem

Image publishing for the dev-box-built repos is coupled to a *local push
event*: a `pre-push` git hook builds and pushes the GHCR image when the
operator pushes to `main` from a clone with `core.hooksPath` configured. A
GitHub-side merge — UI merge button or system_3 auto-merge — fires no local
hook, so the merge lands with **no image published**. The cell's auto-pull
cron then either redeploys a stale `:latest` or has nothing new to pull; the
running deploy silently diverges from `main`.

This bit twice: aspirant-client PR #141 auto-merged with no image, and
aspirant-design-system PR #23's bootstrap publish was manual.

## Evidence

Each row is re-fetchable; paths are dev-box paths as of 2026-07-17.

- **E1** `aspirant-browser:scripts/git-hooks/pre-push` +
  `scripts/build-and-push-image.sh` — local publish lane, fires only on a
  local push to `refs/heads/main`; enabled per-clone via
  `git config core.hooksPath scripts/git-hooks`.
- **E2** `aspirant-design-system:scripts/git-hooks/pre-push` +
  `scripts/build-and-push-image.sh` (`Dockerfile.histoire` →
  `ghcr.io/the-anonymous-aspirant/aspirant-histoire`) — same pattern
  (system_3 #2218).
- **E3** `aspirant-client` has **no publish hook at all** (no
  `core.hooksPath`, no build-and-push script). Its image build is a
  *two-repo staged build*: `package.json:14` declares
  `"@aspirant/design-system": "file:../aspirant-design-system"` (since
  client PR #139), and the sibling must be pre-built (`npm ci`,
  `npm run tokens:build`, vite build) before the client's `npm ci`
  resolves. Working recipe (git-archive both repos into a staged context,
  build DS first) recorded in system_3 #2195/#2221 evidence, used for the
  `sha-1ab774c` and `sha-4b6db29` pushes of 2026-07-16/17.
- **E4** `build-image.yml` workflows exist on aspirant-client/-server/
  -commander (GitHub API, 2026-07-17). Server and commander runs are green
  (last: 2026-07-09, 2026-06-25). The client workflow **fails on every
  push since 2026-07-11 (runs 29–32)**: Rollup cannot resolve
  `@aspirant/design-system/tokens.css` — the `file:` sibling is absent in
  the CI checkout (run 32 job log). Per operator direction 2026-07-16
  (system_3 #2198), images are built and pushed **locally by design** and
  CI fixes are out of scope; this row is context, not a remediation path.
- **E5** system_3 `auto_merge_settings` (2026-07-17): enabled=true for
  aspirant-client, -server, -commander, -browser, -deploy; **false** for
  aspirant-design-system (the current mitigation). GitHub-side merges are
  therefore a *routine* landing path on two dev-box-built repos (client,
  browser).
- **E6** system_3 `scripts/aspirant_auto_redeploy.py` (#1017-B1) — pull
  side only: polls registry `:latest` vs the running container's digest
  and redeploys on drift. Covers client/server/commander; assumes a fresh
  image was already pushed.
- **E7** system_3 `scripts/deploy_freshness_sweep.py` (#1354, #1959) —
  compares the *running image's Created timestamp* against *main HEAD's
  commit timestamp*. It is an age metric: it cannot distinguish
  "image never published" from "published but not yet deployed", does no
  SHA comparison against GHCR, and has no aspirant-histoire row.
- **E8** Cell-side transport is currently degraded: GHCR pulls are dead on
  the link; images were chunk-shipped and `docker load`ed (system_3 #2234
  comment 8995, #2221 comment 8993). Fixing publish does not by itself fix
  deploy while the link is down — that half is tracked in system_3 #2234.
- **E9** `aspirant-deploy:CONVENTIONS.md:729` — "Every service that has a
  Docker image in docker-compose.yml **must** have a CI workflow" — is
  stale against the 2026-07-16 local-publish direction (last substantive
  touch: PR #20).

## Findings

- `client + browser publish lane` :: a GitHub-side merge publishes no
  image :: publish is coupled to a local push event that GitHub-side
  merges never fire, while auto-merge is enabled on both repos (E1, E3,
  E5).
- `aspirant-client` :: no *automated* publish lane exists at all — hook
  absent, CI red and out of scope by direction :: every client image since
  2026-07-11 has been a manual two-repo staged build (E3, E4).
- `dev-box crons` :: the existing automation closes only the deploy half
  :: nothing compares what `main` requires against what GHCR actually
  holds at SHA granularity (E6, E7).
- `deploy_freshness_sweep` :: a missed publish eventually surfaces as
  "deploy lag", mis-attributed and late, and never for histoire :: age
  metric, no SHA check, no DS row (E7).
- `CONVENTIONS.md §CI/CD` :: contradicts the operator's local-publish
  direction :: written when CI publish was the intended lane (E9).

## Options

### (a) Dev-box post-merge publish poller (recommended)

A dev-box cron (same operational shape as `aspirant_auto_redeploy.py`:
flock, heartbeat, anomaly rows, cron-registry entry) that, every N minutes,
for each of aspirant-client / -browser / -design-system:

1. Reads `origin/main` HEAD SHA via `gh api`.
2. Checks GHCR for an image tagged `sha-<short>` (the tag both existing
   build scripts already push).
3. On a gap: stages a fresh `git archive` checkout (never the operator's
   working tree — for the client, the two-repo staged context from E3),
   builds, pushes `:latest` + `:sha-<short>`.

The SHA-existence check makes the poller idempotent against the pre-push
hooks: a locally-pushed merge already has its image, so the poller no-ops.
Hooks become a fast path; the poller is the correctness guarantee.

Pros: closes the hole for *every* merge path; auto-merge can stay enabled
(and could eventually be re-enabled for the DS repo); survives the
unattended-6-months criterion; proven cron pattern.

Cons / requirements: the dev box becomes build-critical (disk hygiene,
Docker cache growth); needs a GHCR token with `write:packages` (the
dev-box `gh` token lacks the scope — the cell PAT works, per system_3
reference notes); build failures must surface via the existing anomaly
lane rather than silently skipping.

### (b) Enforce local-push-only merges + freshness alert

Document local-push-only merges for image-bearing repos in CONVENTIONS.md,
keep (and extend) auto-merge exclusion, and add a GHCR-`:latest`-SHA vs
main-HEAD freshness check that alerts on drift.

Pros: no new build infrastructure.

Cons: "enforcement" remains convention — nothing technically blocks a
GitHub UI merge (branch-protection required-checks would need the CI lane
that is out of scope by direction); requires disabling auto-merge on
client and browser, a throughput regression on the two most active
image-bearing repos; alert-only means time-to-recover depends on an
operator acting; fails the unattended-6-months criterion.

## Decision (proposed)

**Option (a), with (b)'s freshness alert as backstop**: build the post-merge
publish poller, and extend `deploy_freshness_sweep.py` with a SHA-granular
publish-lag metric (GHCR `:latest` revision vs main HEAD) plus an
aspirant-histoire row, so a wedged poller is itself detected. Keep
aspirant-design-system's auto-merge disabled until the poller has published
at least one real merge unattended.

## Remediation (unfiled task titles — listed for filing, not filed)

1. **Dev-box post-merge image-publish poller for aspirant-client /
   -browser / -design-system (GHCR SHA-gap driven)** — kind: feature.
   Lands system_3-side (`scripts/` + install-cron + registry entry, per
   the `aspirant_auto_redeploy.py` precedent).
2. **deploy_freshness_sweep: add GHCR-vs-main publish-lag SHA metric and
   an aspirant-histoire row** — kind: feature, system_3-side.
3. **Realign CONVENTIONS.md §CI/CD with the local-publish direction and
   document the publish-poller lane** — kind: docs, aspirant-deploy
   (subsumes E9; carries option (b)'s documentation half regardless of
   the (a)/(b) choice).
4. *(only if the operator prefers (b))* **Disable auto-merge for
   aspirant-client and aspirant-browser and document local-push-only
   merges** — kind: chore.

Git-log walk per surface (procedure_investigation.md §3 step 3, run
2026-07-17): `aspirant_auto_redeploy.py` last touched #1017-B1 (793d3f9),
`deploy_freshness_sweep.py` last touched #1959 (7585c43),
`CONVENTIONS.md` last touched PR #20 (b71f2b7) — none already contains a
publish lane, SHA metric, or updated CI/CD text; no remediation item is
already fixed.

## Addendum 2026-08-28 — a fourth publish surface the inventory missed (#4441)

`aspirant-lake-duckdb` is a first-party image this document's inventory does
not list. It predates the decision and does not live in a repo of its own:
`Dockerfile-LakeDuckDB` sits inside **aspirant-deploy** and publishes to a
GHCR package of a different name, which `docker-compose.lake-skeleton.yml`
then consumes **by digest**.

That third element is what makes it a different shape rather than a missing
row. `scripts/aspirant_publish_poller.py`'s `RepoConfig` (system_3, task
#2346-A1) assumes *clone name == GHCR package name == build-context root* and
has no concept of a compose pin to update after a push. Adding the lake client
to `REPOS` is therefore not a one-line append: either `RepoConfig` grows a
variant carrying `(context_repo, dockerfile, package, pin_file)`, or the lake
client gets its own poller arm. That work is system_3-side and is routed
there; #4441 covers the aspirant-deploy half.

The cost of the omission is measured, not hypothetical: PR #68 (2026-08-24)
added `cryptography` to the Dockerfile and did not repin, and
`lake-skeleton.sh seed` and `ingest` died at `import` inside the container for
three days while every suite in `tests/` stayed green (#4290). PR #51
(2026-07-18) had done the same edit correctly — nothing failed a procedure,
because there was no procedure, only a habit.

Two things now exist that did not:

- `tests/lake_client_image_unit.sh` (#4290) — the **detection** half. It
  compares the pin against the Dockerfile and fails when the published image
  is behind it.
- `scripts/publish-lake-client.sh` (#4441) — the **production** half. Build,
  verify, publish, repin, re-verify as one command, with the push gated on an
  explicit flag *and* a probed `write:packages` scope, and the repin welded to
  the push so it cannot be the step that is skipped.

Neither closes the automation gap this document's option (a) describes; they
make the manual lane correct and loud while the poller question is open. The
`write:packages` credential remains unprovisioned — measured 2026-08-28,
`gh auth status` reports scopes `gist`, `read:org`, `repo` — so open question 2
below is still open, and it now gates a second surface.

## Open questions for the operator

1. Ratify (a) + backstop (merge this PR), or prefer (b) (comment)?
2. For the poller's GHCR push auth: reuse the cell PAT on the dev box, or
   mint a dedicated `write:packages` PAT for the poller?
