# Dataset intake record — the first real datasets for the encrypted lake

Task #4269 (`#4238-A1`), layer 0 of the phase-1 real-data epic (system_3 #4238).
Read by `#4238-D1` (the first real load) and by anyone asking, years later,
*why is this in the lake and who said it could be?*

This record is **operator-gated**. An agent can inventory what exists on the
cell, propose a classification, and lay out the consequences; only the operator
can name the first dataset and affirm its sensitivity and retention in writing.
Until the affirmation block in a dataset's section is filled in, that section is
a proposal and **no manifest may cite its `dataset_id`**.

## How a section binds to a load

Each section below names one `dataset_id`. The ingest runner
(`REAL_DATA_INGEST.md`) requires that id in every manifest and writes it into
every `asset_inventory` row it creates, so the catalog joins back here. The
fields a section carries are exactly the ones a manifest needs
(`dataset_id`, `source`, `retention_class`, `jurisdiction`, and a per-record
`sensitivity`), plus the two the manifest cannot express and the operator has
to answer: *whose* personal data this is, and *whether keep-forever is
affirmed for this dataset specifically*.

| status | meaning |
|---|---|
| `PROPOSED` | Agent-drafted from a read of the cell. Not loadable. |
| `AFFIRMED` | Operator has answered the affirmation block; cite the comment. Loadable by D1. |
| `DECLINED` | Operator said no. Kept so the reasoning is not re-derived. |
| `DEFERRED` | Not for the first round; revisit after the named precondition. |

## The classification rule of record

Every reference in this epic says "`high` vs `normal` per `DATA_LAKE_DESIGN.md`
§9". Stated plainly, because a reader will look for it: **that file does not
exist on this cell.** Read 2026-08-27 — not under `docs/data-lake-design/`, not
in the system_3 `documents` table, not in `aspirant-explorer/docs`; every hit is
a citation of it. What §9 pins, as echoed by the tasks that implemented it
(#4120, #4134) and by `aspirant-explorer/docs/DECISIONS.md`, is the
*mechanism*: `high` ⇒ per-object DEK, AES-256-GCM, KEK-wrapped, served only
through the explorer API; `normal` ⇒ stored as-is, presigned URL.

The *classification* — which bytes are `high` — comes from two operator-sourced
rules, and this record applies them:

1. **The bucket rule** (operator direction 2026-08-19 on #3617, adopted as
   #4121's intake contract): `photos` / `finance` / `medical` → `high`;
   `docs` / `general` → `normal`.
2. **The fail-closed rule** (`REAL_DATA_CATALOG.md`): anything not confidently
   `normal` is `high`. Applied here to the case the bucket rule does not name:
   **personal data of anyone other than the operator is `high`**, always. The
   2026-07-18 ruling put the whole lake under EU jurisdiction; a family
   member's voice note or a partner's job application is third-party personal
   data under that law regardless of which bucket it would land in.

Over-classifying costs one key unwrap on read. Under-classifying writes
someone's personal data to disk in the clear, and no later fix un-writes it.
Where this record is unsure it says `high` and says why.

## Four facts about the cell that shape the decision

Read directly on 2026-08-27; each one changes what "load the first dataset"
would actually do.

**1. Layer 1 is not there.** `lsblk`: `/scratch` is `sda`, plain ext4;
`/data` is `md0` (RAID1 of two rotational HDDs), plain ext4. No `dm-crypt`
anywhere. #4131 (LUKS, operator-invoked reboot) has a playbook and has not been
run. `scripts/lake-skeleton.sh verify-at-rest` reports `layer 1: NOT GREEN`.
**Consequence: today, a `normal` object is plaintext on a spinning disk.** For
the first load, the sensitivity column is the *only* encryption.

**2. The real lake has nowhere to live yet.** The only lake on the cell is the
phase-0 skeleton at `/scratch/lake-skeleton`, whose charter
(`LAKE_SKELETON.md`, "Not the real lake") is: nothing real writes to it, nothing
it holds is backed up, and the script **refuses** a root on `/data` (§11.0).
The LUKS playbook creates the real lake's volume as a fresh SSD LV (`/lake`)
during the same ceremony as fact 1. So the first real load has to choose:
load into the skeleton as an explicitly interim, unbacked-up home, or wait for
#4131. That choice is part of the ask below.

**3. No `high` object is currently openable.** All three `sensitivity=high`
rows in the skeleton are sealed under a KEK that is no longer in anyone's
custody (#4299/#4300 finding; harness check 5 `SKIP`). The runner refuses a
manifest containing any `high` record when no KEK is loaded — correctly. So a
`high` dataset needs the #4133 ceremony (generate, wrap, put the KEK off-cell)
**before** its load, not after. A `normal`-only dataset needs no key.

**4. The runner's object ceiling.** `lake_ingest.py` reads each file whole
into memory and stores it with a single `put_object`. Objects are bounded by
RAM and S3's single-PUT limit (5 GB); a multi-hundred-GB file is out of reach
until the runner streams (#4121's multipart lane is the browser path, not this
one).

## Candidate register

Everything under `/data/aspirant/` and in the two Postgres instances that is
real data. Sizes and counts from `find`/`du` on 2026-08-27. Third-party =
personal data of someone other than the operator (family/partner per the
registered users `jenny`, `robert`, `maria`, `vinoly`).

| # | source | shape | bucket → class | third-party personal data | note |
|---|---|---|---|---|---|
| A | `/data/aspirant/finance/seed_data/` | 6 CSV, 40 KB — accounts, categories, payee patterns (+ `.bak`) | finance → **high** | no (operator's own banking config; payee patterns name merchants, not people) | smallest real `high` dataset that exists |
| B | `/data/aspirant/remarkable/xochitl/` | 1,967 files, 1.4 GB — `.rm` notebooks + metadata (≈105 documents), 141 PDF, 54 EPUB | notes → **high**; books → normal | notebooks: unknown until read (personal notes may name people); books: no | tablet sync frozen since 2026-03-13; books are third-party *copyrighted*, not third-party *personal* |
| C | `/data/aspirant/files/` (`shared/`, `users/`) | 117 files, 117 MB — 66 EPUB, 11 PDF, PNG, MP3, CSV, DOCX | mixed → **high** (fail-closed) | **yes** — `users/` is per-member; PDFs include valuation inputs (`processed_valuations`, owner `jenny`) | per-user subtrees must be split into per-owner datasets before any load |
| D | `/data/aspirant/audio/` | 47 WEBM, 19 MB — `voice_messages` from the member message board | voice → **high** | **yes** — family members' voices | third-party biometric-adjacent data; needs the member's own say |
| E | `/data/aspirant/assets/` | 78 PNG, 42 MB — `avatars/`, `icons/`, `games/`, site images | general → normal, **except `avatars/` → high** | avatars: yes (member-drawn self-icons) | split: site/game assets normal, avatars high |
| F | `/data/aspirant/uploads/` | 29 files, 4.4 MB — system_3 operator uploads (screenshots) | general → **high** (fail-closed) | unlikely (operator's own screenshots), unverified | screenshots can carry anything; read before declaring normal |
| G | `/data/aspirant/backups/aspirant_db/*.dump` | 4 pg dumps, ~4.4 MB each — `users` 10, `jobs` 436 (`vinoly`), `finance_transactions` 11,858, `pushup_entries` 56 (`robert`), `processed_valuations` 75 (`jenny`), `messages` 10, `voice_messages` 47 | mixed → **high** | **yes** — every registered member | a backup, not a dataset: one blob holding four people's data with no per-record sensitivity; lake `keep-forever` on it is a GDPR commitment on their behalf |
| H | `/data/aspirant/penpot/assets/` (+ `backups/penpot/`) | 73 files, 91 MB — PNG uploads and content-addressed blobs; DB 13 MB (`penpot/ship/`, 1.3 GB, is build output, excluded) | design assets → normal; DB dump → high (account records) | DB: operator account only, as far as known | operator's own design work |
| I | `/data/aspirant/advisor/uploads/` | 21 files, 7.6 MB — advisor RAG documents | unknown → **high** (fail-closed) | unknown | contents never inventoried; read before classifying |
| J | `/data/aspirant/browser_flows/` | 1,723 files, 135 MB — JSON/PNG/TXT/HTML captures of automated browser runs | general → normal *if* the flows are logged-out public pages | possible (a logged-in flow captures the account it ran as) | machine-generated; low value as a first dataset |
| K | `/data/aspirant/kiwix/wikipedia_en_all_maxi_2026-02.zim` | 1 file, 124 GB | public → normal | no | out of reach (fact 4); re-downloadable, so keep-forever is moot |
| — | `/data/aspirant/ollama/` (6.4 GB), `models/`, `histoire-ship/`, `nginx-secrets/`, `backend-secret/` | model weights, build output, secrets | not data | — | excluded: not datasets, and secrets never enter the lake |

## What the first load should be, and why (Recommend)

The purpose of D1 is to prove the round trip **and** the at-rest encryption on
real bytes. A `normal`-only dataset proves the round trip and nothing about
encryption; a `high` dataset with a KEK in custody proves both. So:

- **First: candidate A as `DS-2026-0001`.** Real, tiny, `high` by the bucket
  rule, the operator's own, no third party. Its load exercises the envelope
  path, the `kek_version` column, and harness checks 1–5 end to end in
  seconds. It requires the #4133 KEK ceremony first — which D1 needs anyway.
- **Second, same round: candidate H's design assets as `DS-2026-0002`,
  `normal`.** Real, operator-authored, non-personal, 91 MB across 73 files —
  a volume the runner can carry, exercising the `normal` lane, the skip-on-rerun
  path, and the explorer's presigned reads. Nothing personal touches disk in
  the clear.
- **Defer C, D, E-avatars, G** until each affected member's data has its own
  section and the operator has affirmed keep-forever *for that person's data*.
  A blanket 2026-07-18 "keep everything forever" was the operator's ruling
  about the operator's lake; it did not speak for jenny, robert, maria or
  vinoly, and the record should not pretend it did.
- **Defer B, F, I** until read: each is probably the operator's own, but
  "probably" is the word the fail-closed rule exists for.
- **Decline K** for the reason in fact 4, revisit if the runner streams.

Two alternatives the operator may prefer instead: name a real personal dataset
of their own (B, the notebooks) as the first `high` load; or load nothing until
#4131 gives the real lake an encrypted volume. Both are coherent; the record
just needs to say which.

---

## DS-2026-0001 — finance configuration

**Status: `PROPOSED`**

| field | value |
|---|---|
| `dataset_id` | `DS-2026-0001` |
| `source` | `cell:/data/aspirant/finance/seed_data` — mounted read-only into the `finance` container as `/app/seed_data` |
| volume / shape | 6 CSV files, 40 KB total: `accounts.csv` (account_id, account_name, bank, account_type), `categories.csv` (payee_pattern, category), `payee_normalization.csv` (payee_pattern, canonical_payee), and three dated `.bak` copies of the first two |
| sensitivity | **`high`** — `finance` bucket. Names the operator's banks and accounts. Every record declared explicitly in the manifest; none left to the default. |
| third-party personal data | **No.** Payee patterns name merchants and institutions. No family/partner data. |
| jurisdiction | `EU` (2026-07-18 ruling) |
| retention | `keep-forever` proposed. The `.bak` copies are included deliberately: they are the only history these files have. |
| preconditions | KEK in custody (#4133 ceremony) — the runner refuses otherwise. Destination decided (fact 2). |
| what it proves for D1 | envelope-on-PUT, `wrapped_dek`/`kek_version` rows, harness checks 1–5 including the unwrap, explorer's authed read of a `high` object |

Manifest, once affirmed:

```json
{
  "dataset_id": "DS-2026-0001",
  "source": "cell:/data/aspirant/finance/seed_data",
  "retention_class": "keep-forever",
  "jurisdiction": "EU",
  "root": "/data/aspirant/finance/seed_data",
  "records": [
    {"path": "accounts.csv", "sensitivity": "high", "mime": "text/csv"},
    {"path": "accounts.csv.bak.2026-06-18", "sensitivity": "high", "mime": "text/csv"},
    {"path": "categories.csv", "sensitivity": "high", "mime": "text/csv"},
    {"path": "categories.csv.bak.2026-06-18", "sensitivity": "high", "mime": "text/csv"},
    {"path": "categories.csv.bak.2026-06-19-064159", "sensitivity": "high", "mime": "text/csv"},
    {"path": "payee_normalization.csv", "sensitivity": "high", "mime": "text/csv"}
  ]
}
```

**Operator affirmation** (fill in, or answer on #4269 and an agent copies the
citation here):

- [ ] Named as a first dataset: yes / no
- [ ] Sensitivity `high` affirmed (or overridden to: ___ )
- [ ] Contains no third-party personal data: affirmed
- [ ] `keep-forever` affirmed for this dataset (or narrowed to: ___ )
- [ ] Destination for the first load: skeleton at `/scratch/lake-skeleton` (interim, unbacked-up) / wait for #4131's `/lake` LV
- Affirmed by: ___ on ___ (comment link: ___ )

---

## DS-2026-0002 — Penpot design assets

**Status: `PROPOSED`**

| field | value |
|---|---|
| `dataset_id` | `DS-2026-0002` |
| `source` | `cell:/data/aspirant/penpot/assets` — the Penpot object store (uploaded images, fonts, exports) |
| volume / shape | 73 files, 91 MB. PNG images plus content-addressed blobs without extensions, as Penpot stores them; MIME to be sniffed at manifest-authoring time rather than guessed from names. **Excludes** `penpot/postgres/`, `backups/penpot/*.dump` (account records) and `penpot/ship/` (build output). |
| sensitivity | **`normal`** — operator-authored design artifacts, `docs`/`general` bucket. Declared explicitly per record. If a manifest-authoring pass finds a photograph of a person among the assets, that record is `high` under the bucket rule and this section is amended before the load. |
| third-party personal data | **Not expected.** To be confirmed by the same manifest-authoring pass (a font or a UI mock is not personal data; a photo could be). |
| jurisdiction | `EU` |
| retention | `keep-forever` proposed |
| preconditions | Destination decided (fact 2). No KEK needed. |
| what it proves for D1 | the `normal` lane at real volume, content-addressed dedup, skip-on-rerun, presigned explorer reads, and — because layer 1 is absent — that the operator accepts *this* data in the clear on disk for now |

Manifest: generated by walking `penpot/assets` at load time (73 entries, all
`"sensitivity": "normal"`), attached to #4274 when produced.

**Operator affirmation:**

- [ ] Named as a first dataset: yes / no
- [ ] Sensitivity `normal` affirmed — and, given fact 1, affirmed as acceptable in plaintext on disk until #4131
- [ ] Contains no third-party personal data: affirmed (subject to the manifest pass)
- [ ] `keep-forever` affirmed for this dataset (or narrowed to: ___ )
- Affirmed by: ___ on ___ (comment link: ___ )

---

## Deferred and declined

Recorded so the reasoning is not re-derived. Each becomes its own section, with
its own `dataset_id`, when its precondition clears.

| candidate | status | precondition to revisit |
|---|---|---|
| B reMarkable notebooks | `DEFERRED` | a read pass to say whether the notebooks name third parties; then the operator names it as a `high` dataset of their own |
| C member files, D voice messages, E `avatars/`, G `aspirant_db` dumps | `DEFERRED` | one section **per member** (jenny / robert / maria / vinoly), each with retention affirmed for that person's data; G additionally needs a decision on whether a whole-DB dump belongs in the lake at all versus §6 backups |
| F operator uploads, I advisor documents | `DEFERRED` | a read pass; both are probably the operator's own and both are `high` until then |
| J browser-flow captures | `DEFERRED` | confirm the flows ran logged-out; low value as a first dataset either way |
| K Wikipedia ZIM | `DECLINED` for round one | runner streams large objects (fact 4); and it is public and re-downloadable, so `keep-forever` protects nothing |

## What this record did not do

Load anything, author a manifest against live paths, or read the contents of
any candidate beyond file names, counts, and CSV header rows. The read passes
named above are D1's or a follow-up's, and they should be done by an agent
reading with the operator's leave, not by this inventory.
