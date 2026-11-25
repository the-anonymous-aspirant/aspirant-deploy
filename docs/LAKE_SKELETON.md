# Lake Skeleton — Garage + DuckLake on scratch storage

Phase-0 substrate for the walkable data-lake interface
(`docs/data-lake-design/DATA_LAKE_DESIGN.md` §11.1 phase 0).

This stack exists so the operator can click through `aspirant-explorer` and
disagree with it while disagreement is still cheap. It holds **only
obviously-synthetic fixtures**, and it is built to be thrown away.

---

## Why it is safe to run this before encryption exists

§11.0 binds: *real personal data must not land on unencrypted storage*, and a
populated disk cannot be encrypted in place. The skeleton is exempt not by
permission but by construction — three properties, each one structural rather
than a matter of discipline:

| Guardrail | How it is enforced |
|---|---|
| Storage is a scratch path expected to be destroyed | Everything lives under `/scratch/lake-skeleton/`. `lake-skeleton.sh` **refuses to start** if `LAKE_SKELETON_ROOT` points at `/data`, the real lake's volume. |
| Nothing real can arrive quietly | Fixtures are self-labelling (`SYNTHETIC — Ada Notarealperson`, dates in 2999, `FAKE-RECORD-00n`). The acceptance check fails if any fixture row stops looking fake. |
| The skeleton cannot outlive itself | Separate compose project (`aspirant-lake-skeleton`), so the `*/5` auto-pull cron that re-ups the production project can neither upgrade it nor resurrect it after teardown. `destroy` removes containers, volumes, and the scratch tree. |

**The moment you want to demo with a real medical PDF, phase 0b is due** — that
is §11.0's stated trigger, not an exception to be made once.

---

## Shape

Three services on a project-local bridge network, **no host ports** (§4 — the
cell's 80 is already internet-exposed, 8081 and 8999 were until system_3 #8801, and the lake must not join
them):

| Service | Image | Role |
|---|---|---|
| `garage` | `ghcr.io/the-anonymous-aspirant/garage:v2.3.0` | S3 object store. Data + metadata both on scratch. |
| `catalog` | `ghcr.io/the-anonymous-aspirant/lake-catalog-postgres:16-alpine` | DuckLake catalog database (`lake_catalog_skeleton`). |
| `duckdb` | built locally from `Dockerfile-LakeDuckDB` → `aspirant-lake-duckdb:local` | On-demand DuckDB client (`client` profile); the query engine, not a server. |

**Two are mirrors we pull; the third is ours, so we build it.** `garage` and
`catalog` come from GHCR pinned by digest — the cell cannot reach Docker Hub
(its Wi-Fi dongle TLS-times-out against `registry-1.docker.io` while GHCR answers
in under a second), so those upstream images are staged from the dev box and
pinned, which also keeps the stack off the surprise-upgrade path §4 warns about.
Upgrading either means re-mirroring.

`aspirant-lake-duckdb` is **built from this repo's `Dockerfile-LakeDuckDB`** on
the next `lake-skeleton.sh` run (#4475) — the one image here whose source can
change under a normal PR, so it is the one we build rather than pin. Editing that
Dockerfile takes effect immediately, with no push-to-GHCR-and-repin step: the
running image is always the current Dockerfile. That closes the gap that made
`seed`/`ingest` die for three days behind an un-republished digest (#4134/#4290).
No consumer outside this skeleton pulls it from GHCR, so the publish lane was
retired (system_3 #10808): see § The client image is built locally.

### Versions and why these ones

| Component | Pin | Source |
|---|---|---|
| Garage | `v2.3.0` | Current stable per the [Garage quick-start](https://garagehq.deuxfleurs.fr/documentation/quick-start/); latest semver tag on Docker Hub. |
| DuckDB | `1.5.4` | Current stable. DuckLake v1.0 requires ≥ 1.5.2. |
| DuckLake | v1.0 | [ducklake.select](https://ducklake.select/) stable. |
| Catalog Postgres | `16-alpine` | Matches the fleet's existing Postgres major. |

### The client image is built locally (#4475)

`docker-compose.lake-skeleton.yml` builds `Dockerfile-LakeDuckDB` locally, so a
change to the Dockerfile (a pip pin, a baked extension, the base tag) takes
effect on the next `lake-skeleton.sh` run with no republish. The GHCR republish
lane, `scripts/publish-lake-client.sh` (#4441), was retired by system_3
#10808. Nothing pulls the image from GHCR any more, and its repin wrote the
pin that `tests/lake_client_image_unit.sh` now refuses.

`tests/lake_client_image_unit.sh` builds the client image and probes it, failing
when the built image is missing something the Dockerfile declares. It went in
after the omission that motivated all this (#4290) — #4134 added
`cryptography==46.0.3` on 2026-08-24 and did not repin, so `seed` and `ingest`
both died at `import` inside the container for three days while every suite in
`tests/` stayed green. None of them had ever run the pinned image; they all
pip-install their dependencies into `python:3.11-slim` at test time.

### Two deliberate divergences from the design spec

1. **Separate compose file, not a `lake` service group in `docker-compose.yml`**
   (§4 says the latter). Teardown becomes `compose down -v` instead of a diff
   against the production stack, and the auto-pull cron cannot touch it. §4's
   substantive requirements — pinned images, docker-network only, no new public
   ports — are all honoured. When the *real* lake ships, it should follow §4 and
   live in the production compose; this divergence is skeleton-only.

2. **Garage metadata on the scratch spindle, not the SSD LV** (§4 wants the LV,
   because metadata is hot random I/O and the `/data` disks are 2010-era WD
   Greens). Carving an LV for a stack whose purpose is to be destroyed would
   leave state outside the one path we intend to delete. Performance is
   irrelevant at fixture scale. The real lake should take §4's advice.

---

## Operating it

Run from a checkout on the cell (`~/aspirant-deploy` post-merge):

```bash
scripts/lake-skeleton.sh up       # start + bootstrap bucket, key, catalog
scripts/lake-skeleton.sh verify   # acceptance checks
scripts/lake-skeleton.sh explorer-env sync  # copy the explorer's credentials into .env
scripts/lake-skeleton.sh rotate-explorer-ro  # new explorer_ro password (see "Rotating")
scripts/lake-skeleton.sh explorer-decrypt-up  # recreate explorer-api able to decrypt (needs the KEK)
scripts/lake-skeleton.sh status   # containers, published ports, disk use
scripts/lake-skeleton.sh down     # stop, keep data
scripts/lake-skeleton.sh destroy  # stop and delete every byte it owns; refuses real data (see Teardown)
```

`up` is idempotent: it generates `garage.toml` and the credentials env-file only
when absent, assigns a Garage cluster layout only when the node has no role yet,
and creates the bucket and access key only when they do not already exist.

A rebuild from an empty `$LAKE_SKELETON_ROOT` issues **new** explorer
credentials. The explorer reads them from this checkout's `.env`, not from the
skeleton's env file, so `up` ends by comparing the two. When they differ, run
`explorer-env sync` and recreate `explorer-api` (system_3 #9074).

### The explorer's read-only credentials

`up` issues **three** Garage keys, over two buckets, and two catalog identities:

| identity | grant | used by |
|---|---|---|
| `lake-skeleton-rw` | `RW` on the bronze bucket and on the staging bucket | fixtures, verify, the skeleton itself, staging promotion (#4121-E) |
| `lake-skeleton-explorer-ro` | `R` only, on bronze | `explorer-api` (the mediated bridge, #2409-D2) |
| `lake-skeleton-explorer-staging-wo` | `W` only, on the staging bucket | `explorer-api`'s upload path (#4121-B) |
| `ducklake` | catalog owner | the skeleton |
| `explorer_ro` | `SELECT` only | `explorer-api` |

The read-only pair is what makes the lake bridge a mediated **read** path rather
than a mediated read-write one. That distinction is the basis on which the
bridge was authorised, so it is issued here rather than by hand.

It is issued here for a specific reason: both credentials once existed only as
manual artifacts on a single host. `destroy` and `up` is an acceptance
criterion of this skeleton — rebuilding is how its correctness is shown — so a
bound that lives in one machine's memory disappears on exactly the operation
this document tells you to perform, and nothing would have reported it.

`verify` proves the bound rather than restating it: it attempts a `PUT` with the
read-only key and a `CREATE TABLE` with the read-only role, and **fails if
either succeeds**. It also checks each can still read, because a credential that
can do nothing is a broken explorer wearing the costume of a working guardrail.

### The staging bucket and the explorer's write-only key

Uploads (#4121) need a key that can write. Garage grants a key per **bucket**,
with no prefix ACL, so a write key on bronze could overwrite any sealed blob.
The fence is therefore a second bucket, `lake-skeleton-staging`
(`LAKE_S3_STAGING_BUCKET`). The explorer's third key can write there and
nowhere else. The ingest runner stays the only writer to bronze; it reads,
promotes and deletes out of staging.

The key is write-only, not read-write, on purpose: `sensitivity=high` uploads
wait in staging, unwrapped, until the operator-attended promotion run, and a
key that cannot read staging cannot hand them back out of a compromised
`explorer-api`. The cost, measured on this Garage version (2026-11-02): such a
key can create, upload, complete and abort a multipart upload, but is denied
`ListParts` and `ListMultipartUploads`, so resume keeps its own ledger of part
ETags rather than asking Garage.

**Write-only is not append-only.** The same measurement found the key can
`DeleteObject` (and so overwrite) an object it wrote in staging. Confidentiality
holds, but a compromised `explorer-api` could replace or delete a staged upload
between completion and promotion. The integrity of a staged object therefore
rests on the upload ledger's per-part SHA-256 and on promotion re-verifying the
whole object against it before it enters bronze (#4121-C/E). `verify` prints
this as a `[measured]` line on every run, so a Garage upgrade that changes it
shows up there.

`up` refuses outright if `LAKE_S3_STAGING_BUCKET` names the bronze bucket.

`up` re-asserts the grants in both directions on every run, and `verify` proves
each one by attempting it: a multipart upload into staging must succeed;
reading or listing staging, and reading or writing bronze, must be denied; the
runner must be able to read and delete the probe. `explorer-env sync` copies
`LAKE_S3_STAGING_BUCKET` and `EXPLORER_S3_STAGING_*` into the deploy `.env`
with the read-only pair, all or nothing.

Credentials (Garage access keys, catalog passwords) are generated at `up` and
written to `/scratch/lake-skeleton/lake-skeleton.env`, mode 600. They live on
the scratch path with everything else, so `destroy` takes them too — a fresh
`up` mints new ones. The stack has held real records since the first ingest
(#4271), so these are live credentials. Never pass one on a command line or print
one, and rotate any that leaks.

### The staging lister: what waits in staging, in the catalog (system_3 #11615)

An upload waits in staging until an attended promotion run moves it into
bronze, and until then no explorer page could show it: the explorer reads the
catalog, and the catalog knew only promoted files. `lake-skeleton.sh
list-staged` mirrors staging into two catalog tables the explorer's read-only
role can read:

- `staged_uploads`: one row per staged upload, from its `manifest.json` only:
  `upload_id`, `bucket`, `sensitivity`, `source_filename`, `mime`,
  `size_bytes`, `upload_time`.
- `staged_uploads_read`: one row, `read_at`, `interval_seconds`,
  `upload_count` and `skipped_count`, so the page can say when staging was
  last read and show the list as out of date when a run has failed.
  `skipped_count` is how many uploads the run found but could not read (no
  manifest, or one that does not parse): the page counts them as waiting
  rather than showing nothing (design c75275 on system_3 #12113). The run's
  log names their upload ids only. `up` adds the column to a catalog made
  before it, nullable with no default, so a row an older lister wrote reads
  `NULL`, "not recorded". **Deploy order:** run `up` on the cell before
  deploying a lister that writes the column. The other order makes each
  run's write fail, so `read_at` ages and the page says "out of date" until
  `up` runs (security c75284 on system_3 #12113).

Security's conditions (c71659 on #11611, c71693 on #11615), and how they are
met:

- **A key of its own,** `lake-skeleton-staging-lister`: read on staging only.
  `up` re-asserts `deny --write` on staging and `deny --read --write` on bronze
  every run. It never uses the promotion runner's key, which can write the
  whole lake.
- **Listings and manifests only, never a payload object.** A staged `high`
  upload is plaintext.
- **A catalog role of its own,** `staging_lister`: `SELECT, INSERT, DELETE` on
  `staged_uploads`, `SELECT, INSERT, UPDATE` on `staged_uploads_read`, nothing
  else. `up` creates both tables as `ducklake`, the catalog owner, so the role
  owns neither and `explorer_ro` can read both.
- **One transaction per run, after a listing that succeeded:** every row
  deleted (`DELETE`, not `TRUNCATE`), the new rows inserted, the stamp
  updated. A failed run writes nothing, so `read_at` ages. An upload promoted
  or removed by hand drops out at the next run. A manifest that cannot be read
  is left out, by id.
- **Logs carry counts and upload ids, never a file name.** Errors are logged by
  type only, since an error's text can quote an object key.
- **Fail closed:** with its key or its role missing, it writes nothing, says so
  in one line and exits 2.

It runs in its own compose service, `staging-lister`, which holds only those
two credentials. Cron runs it every 5 minutes (`INTERVAL_SECONDS = 300` in
`scripts/lake_list_staged.py`; the line lives in system_3's
`cron/crontab.manifest`). `verify` proves the bounds by attempt:

- the key can list staging, and is refused a write there and any read of
  bronze;
- the role is refused an insert into another catalog table;
- `explorer_ro` can read both tables;
- the role owns neither.

### The Gmail attachment linker (system_3 #11557)

A Gmail run pulled with `--attachments` (`docs/GMAIL_INGEST.md`) stores each
attachment part as its own `message_attachment` object under
`attachments/<sha256>`. Which message and part a blob came from is written
separately, after a fully successful ingest, into one table:

- `gmail_attachment_links`: `message_id`, `part_id`, `sha256`, and nothing
  else. It holds no file name, type or size. Each column is CHECKed to its
  shape, and the key is `(message_id, part_id)`.

Security's A6 (c75385 on #11557, amended in c75393), and how it is met:

- **A catalog role of its own,** `gmail_linker`: `INSERT` on
  `gmail_attachment_links` and nothing else, not even `SELECT`. `up` creates
  the table as `ducklake`, so the role owns nothing and `explorer_ro` can read
  it. The ingest itself still attaches as `ducklake`; moving it off the owner
  is not part of this.
- **Its own step and its own service,** `gmail-linker`, which holds only that
  role's DSN: `lake-skeleton.sh link-gmail <run>/links.json`. Only that file
  is mounted, read-only, at `/source/links.json`. The run's directory, with
  the export and the attachment blobs, never is.
- **Writes are `INSERT ... ON CONFLICT DO NOTHING`, with no conflict target,**
  in one transaction, so a re-run is a no-op. A conflict target would need
  `SELECT` on its columns: measured on Postgres 16, it is refused without it.
- **A link row only for a part the pull wrote and hashed** (A6b). Parts refused
  at fetch are listed apart in `links.json` and get no row.
- **The run directory goes only after both steps succeed** (A6a). See
  `scripts/gmail/gmail_pull_and_ingest.sh`; `--link-run=<run id>` repeats the
  link step for a kept run.

`verify` proves the role's bounds as the role itself (A6c): an insert of an
existing key with `ON CONFLICT DO NOTHING` succeeds; `SELECT`, `UPDATE` and
`DELETE` on the table, and an `INSERT` into another catalog table, are
refused; the role owns no relation and has no superuser, create or bypass
flag. Every write it attempts is rolled back. `explorer_ro` can read the
table. `tests/lake_gmail_link_unit.sh` runs the same probes, and the job,
against a throwaway Postgres 16 with `up`'s own bootstrap.

### Rotating the explorer's credentials (system_3 #11381)

When a leak exposes the explorer's catalog password or its read-only key, the
new values must travel the way the old ones should have: never in an argv,
never on screen, never in a terminal's scrollback (security c69918 on system_3
#11368). `env_set` writes with bash builtins only, so neither
`rotate-explorer-ro` nor `explorer-env sync` puts a value in any process's
command line.

The catalog password, in one sitting, because explorer-api cannot open a new
catalog connection between the first step and the last:

All three steps are the **operator's**. `explorer-env sync` in particular is
operator only: it reads every line of the served `.env` into bash, and no
agent's process may read that file (security ruling C, system_3 c61658 on #9979).

```bash
scripts/lake-skeleton.sh rotate-explorer-ro   # new password: catalog + skeleton env
scripts/lake-skeleton.sh explorer-env sync    # operator only: copy it into this checkout's .env
( read -rs LAKE_KEK_HEX; export LAKE_KEK_HEX   # recreate explorer-api, decrypt on
  export LAKE_KEK_FINGERPRINT=<ceremony fingerprint, sha256(KEK)[:16]>
  scripts/lake-skeleton.sh explorer-decrypt-up )
```

Without decrypt-on-read, the last step is
`docker compose --profile explorer up -d --force-recreate explorer-api`.
A plain recreate of a decrypting explorer-api turns decrypt off.

The read-only key has no verb. Garage keys are looked up by name, so first
rename the old key (`garage key rename <id> lake-skeleton-explorer-ro-retired-<date>`).
Then `garage key create lake-skeleton-explorer-ro > <0600 file> 2>&1`, because
create prints the secret. Grant the new key what the old one had (`R` on bronze,
deny `W`), and write the pair into the skeleton env from that file in-process.
Then run the same `explorer-env sync` and recreate. Delete the old key only after
explorer-api is healthy on the new one, and run `verify`, which proves the new
key can read and cannot write.

### The explorer's decryption key (#10777)

`explorer-api` serves a `sensitivity=high` object's contents only while it
holds the lake KEK. Without it, it shows the object's metadata and refuses
`/content`. That is how every recreate brings it up. To turn decrypt-on-read
on:

```bash
( read -rs LAKE_KEK_HEX; export LAKE_KEK_HEX   # type the grouped hex; not echoed
  export LAKE_KEK_FINGERPRINT=<ceremony fingerprint, sha256(KEK)[:16]>
  scripts/lake-skeleton.sh explorer-decrypt-up )
```

Run it as written, in parentheses. The subshell is the point: the verb's own
`unset LAKE_KEK_HEX` clears only its copy, so a bare `export` would leave the
real key in your terminal. A later `seed` from that terminal, the one verb that
skips the tmpfs staging, would then pass it into a container's environment,
which dockerd keeps on the unencrypted root disk (security review on system_3
#10777).

The verb uses the same staging as `ingest` (`stage_real_kek`):
1. It writes the key to a 0600 file under `$XDG_RUNTIME_DIR`, and refuses if
   that directory is not tmpfs.
2. It unsets `LAKE_KEK_HEX`.
3. It recreates `explorer-api` from this checkout with
   `up -d --wait --force-recreate --no-deps`.
4. Once the service is healthy, it deletes the file.

The container sees:
- `LAKE_ENVELOPE_DECRYPT=1`;
- `LAKE_KEK_FILE=/run/secrets/lake_kek`, a read-only mount of that file;
- the fingerprint.

The key is never in the container's environment: dockerd writes a container's
environment to the unencrypted root disk, and `docker inspect` shows it to the
docker group (security c64754 on system_3 #8814).

Healthy means the key is loaded. The explorer loads it in its startup hook,
before it serves `/health`. A wrong key or fingerprint refuses to boot. The
verb then deletes the key file and recreates `explorer-api` with decrypt off,
with neither the key file nor the fingerprint in compose's environment. It
prints one line saying the explorer is back with decrypt off, and still exits
non-zero, because decrypt-on failed (system_3 #12202, security c75726). Before
this, a mistyped key left the service stopped.

**Decrypt does not survive a recreate.** After the verb, the key is only in the
running container, never on the cell's disks, which is the custody rule of
`docs/data-lake-design/KEK_CEREMONY.md` §3. Any `up` without the verb, including an auto-pull of a new
`explorer-api` image, recreates the service with decrypt off: it keeps serving
metadata and refusing contents. Turning decrypt back on is always the operator
running the verb again with the key. A restart of the same container cannot
start either: its mount names the deleted file, and the mount uses
`create_host_path: false`, so the restart fails with "no such file or
directory" and creates nothing. The service then stays stopped (`Exited`) until
a recreate: `docker compose --profile explorer up -d --force-recreate
explorer-api` brings it back with decrypt off (system_3 #12202).

So the verb creates the decrypt-on container with restart policy `no`
(`EXPLORER_API_RESTART=no` on its one compose call) and the label
`aspirant.explorer.decrypt=on`, which compose derives from the key mount's
own variable (system_3 #12203, security c75726). After a crash or a reboot it
stays exited rather than failing to restart, and a host-side unit can tell
it apart from the plain container by the policy and the label together.
Every other recreate, the verb's own recovery included, gets
`unless-stopped` and an empty label. The verb holds
`$XDG_RUNTIME_DIR/explorer-api-decrypt.lock` for its whole run, and refuses
if something else holds it. The host-side unit that will bring the container
back with decrypt off (system_3 #12207, the next PR) takes the same lock, so
the two never recreate it at once. Until that unit is installed, the
recovery after a crash or a reboot is still the recreate above.

Two side effects while decrypt is on, measured on the #10777 rig:
- The mounted file stays readable inside the container until it stops, because
  the mount holds the deleted tmpfs inode. Anyone who can `docker exec` into
  `explorer-api` can read the key. The docker group could already read the
  process's memory, so this adds no new reader.
- `docker cp` to or from `explorer-api` fails, because it re-mounts the
  container's binds and the host file is gone. Use `docker exec -i ... < file`
  instead.

### What `verify` proves

1. The Garage bucket round-trips an object byte-identically.
2. The DuckLake catalog is queryable via DuckDB through the Postgres catalog.
3. **Parquet actually landed in Garage** — asserted by listing the bucket, not
   inferred from a successful `SELECT`, which would not distinguish a real S3
   write from a local spill.
4. Catalog metadata really lives in Postgres (`ducklake_*` tables), which is
   what makes the lake multiplayer (§7) and what the explorer will attach to.
5. Snapshots are recorded — time-travel is the skeleton's stand-in for object
   versioning (§7).
6. Every fixture row is still self-labelling as synthetic (§11.0).

### What `verify-at-rest` proves (#4273)

`verify` above proves the skeleton is a working lake. `verify-at-rest` proves a
different, narrower thing: that what actually landed on disk is *encrypted*,
not merely that the pipeline that writes it claims to encrypt. It runs two
independently-executed checks and combines them into one verdict, because one
script cannot make both claims — see #4273-B1's task body for why the split is
by execution context, not tidiness:

**Layer 1 — is the volume itself encrypted?** Run on the **host**, as the
invoking user, via `findmnt`/`lsblk` against the device backing **each of the
three data directories** the compose file bind-mounts — `garage/data`,
`garage/meta` and `catalog` under `$LAKE_SKELETON_ROOT` — because they are
three mounts that can sit on three volumes, and a verdict resolved from the
root alone would call all three encrypted the day only the root is (#4525,
from #4301 F7). Each is resolved from its path, not from a hardcoded name
list, because the three-name list in `scripts/luks-layer1/postcheck.sh`
answers a different question (are the *real* lake's three ceremony volumes
mapped) that has no entry for this skeleton's root at all. The device's whole
dependency chain is walked (`lsblk -s`), so an LVM volume on a LUKS physical
volume — the real lake's ceremony shape — reads as engaged; the PASS/SKIP line
prints the chain it saw. Layer 1 is PASS only when all three directories are
on dm-crypt; one plain directory is a SKIP for the layer, and a directory that
does not exist or cannot be resolved is a FAIL.

**Layer 2 — is what's stored actually ciphertext, and does it agree with the
catalog?** Run **inside the client container** (`scripts/lake_verify_at_rest.py`,
#4299), against the catalog and Garage directly — never through the explorer's
decrypting read path, which would report a plaintext write as encrypted. The
checks, numbered as the report prints them: **0** the catalog is not empty —
zero rows is a FAIL, never a vacuous green (#4524); **1** every `high` row
declares an envelope, and a `sensitivity` outside the catalog vocabulary fails
here and is checked as `high` from then on, fail closed (#4524); **2** the
stored object is `AOBJ` ciphertext; **3/3b** no plaintext hides under a `high`
row, no `normal` row carries a wrapped DEK, and the content address is compared
twice — whole object and past the header — which catches a forged five-byte
header over *this row's* plaintext, but not a forged header over other bytes
(#4301 F3: that is what check 6 is for); **4** the row's `kek_version` agrees
with the envelope header; **5** the DEK actually unwraps under the KEK in
custody; **6** with that DEK the stored object decrypts to the row's content
address — the one exact check, which no forgery shape survives (#4524); **7**
every object under `bronze/blobs/` has a catalog row, listed from the bucket
itself, so a blob nobody catalogued cannot hide from the catalog-driven checks
(#4524). When `LAKE_KEK_FINGERPRINT` is set the supplied KEK is checked against
it first: a mismatch is reported as an input error and the run is NOT GREEN,
rather than every `high` row reading as data loss under a mistyped key.

**A SKIP is never a PASS, on either layer.** Layer 1 SKIPs (rather than
failing outright) when a data directory resolves but has no dm-crypt in its
chain — the expected, correct result for this skeleton, whose root is
deliberately plain `/scratch` (§11.0). Layer 2 SKIPs checks 5 and 6 when no KEK is in custody
for this run, and check 6 alone when a KEK is held but the image cannot
decrypt (#4290). Either SKIP keeps the combined verdict at NOT GREEN: the point of the
check is exactly to distinguish "provably encrypted" from "nobody looked", and
folding a SKIP into green would erase that distinction on the one surface that
exists to preserve it.

**Expected result on this skeleton today: NOT GREEN**, and that is the harness
working, not a bug to chase — all three data directories are on plain
`/dev/sda` (layer 1: `0 of 3 data directories on dm-crypt`, SKIP), and every
`sensitivity=high` fixture is sealed under a throwaway KEK that no longer
exists anywhere: with no KEK supplied layer 2's checks 5 and 6 **SKIP** (not
fail — nothing was proven either way), and with any KEK supplied on an image
that can decrypt, check 5 **FAILs** those three rows as data loss. See #4301's
findings comment on #4273 for the live runs this predicts.

The verb builds the client image as its own step before layer 2 (#4475, was a
pinned-digest pull per #4525/#4301 F6): a build failure is reported as "the
image could not be built — the harness did not run", which is NOT GREEN but is
not a finding about the lake, rather than surfacing as a failed layer 2 with the
build noise mixed into the harness's report.

---

## The fixture set

`scripts/lake-skeleton.sh seed` regenerates everything in one command. It is
idempotent — blobs are content-addressed so they land at the same key every
time, and the tables are replaced rather than appended to.

Layout follows §2's medallion mapping rather than approximating it: **binary
blobs live once in bronze**, content-addressed at
`bronze/blobs/sha256/ab/cd/<hash>`, and only their *derived artifacts* appear in
silver. A PDF is not copied three times to "promote" it.

**Bronze** — 8 content-addressed blobs: 2 PDFs, 2 images plus their 2
thumbnails, 1 WAV, 1 JSON message export. They are real files, not stand-ins:
the PNGs decode, the PDFs open to a page of visible text. Both are synthesized
in pure Python (`zlib` + `struct` for PNG, hand-written object syntax for PDF)
so the client image needs no image-processing stack for three fixture pictures.

**Silver** — `asset_inventory` (one row per blob: hash, key, source path, mime,
size, kind, **sensitivity**, ingest timestamp, run id, plus the phase-1
provenance columns — dataset id, sensitivity source, retention class,
jurisdiction, KEK version), `extracted_text`,
`image_metadata` (dimensions, camera, thumbnail ref), `audio_transcripts`,
`messages` (unified across telegram/sms/email per §2, with an attachment blob
ref), `finance_transactions` (a typed table export standing in for a Postgres
source), and `ingest_runs` (the connector ledger §8.6's page reads).

The schema of `asset_inventory` and `ingest_runs`, and the rule that decides a
blob's sensitivity at intake, are **not** declared here — they live in
`scripts/lake/catalog.py` and are shared with the real ingest runner (#4271) and
the explorer's real-record views (#4272). The seed imports them like every other
writer, so seeding exercises the real contract rather than a copy of it. See
[data-lake-design/REAL_DATA_CATALOG.md](data-lake-design/REAL_DATA_CATALOG.md).

**Gold** — `gold_finance_monthly`, `gold_timeline`, `gold_source_freshness`
(green/amber/red, which is what the Overview page renders).

§2 is explicit that `sensitivity=high` is **a column, not a folder convention**,
so the one high-sensitivity fixture (a synthetic medical note) sits at the same
path layout as everything else and differs only in that column. That is
deliberately the harder case for the explorer to get right.

### How "obviously fake" is enforced

Not by discipline — by a check that fails closed. `verify` walks every VARCHAR
column of every fixture table and asserts each distinct value is self-labelling:
it carries `SYNTHETIC`, `FAKE-`, or the impossible year `2999`, or it is a
structural value (a hash, an object key, or a known enum like `image/png`).
Anything else is reported as a leak and fails the run.

This matters more than it looks. The guardrail's real failure mode is not
someone loading a real medical PDF on day one — it is realism creeping in one
column at a time until a screenshot becomes ambiguous. A check that fails on
unrecognised prose catches that; a code review of the fixture file does not.

`verify` also asserts that every blob's bytes actually hash to its own key. A
blob whose content does not match its content address would make provenance
(§8.5) a lie, and the check is cheap.

Running `verify` on an **unseeded** stack skips the coverage block rather than
failing it — the teardown drill exercises exactly that state.

---

## Finding: DuckLake inlines small writes into the catalog by default

Discovered while building this stack, and it matters well beyond it.

DuckLake's data inlining is **on by default with a row limit of 10**
([docs](https://ducklake.select/docs/stable/duckdb/advanced_features/data_inlining)).
Writes under that limit are stored as rows in the catalog database and never
reach the object store at all. The first run of the acceptance check caught it
exactly this way: three fixture rows queried back perfectly while
`ducklake_data_file` was empty and the bucket held nothing under `bronze/`.

This stack therefore attaches with `DATA_INLINING_ROW_LIMIT 0`, and asserts the
result rather than trusting it.

**Why it matters for the real lake**, beyond making a test honest:

- §9's envelope encryption operates on objects the ingest-runner encrypts before
  `PUT`. Inlined rows never become objects, so with stock settings a small write
  of `sensitivity=high` data would land **unencrypted in the catalog Postgres**,
  bypassing layer 2 entirely. Crypto-erasure (destroy the wrapped DEK) would not
  reach it either.
- §6/§7 assume the catalog is small and the Postgres backup protects "the lake's
  brain", not its body. Inlining silently makes the catalog hold data.
- §9's exit story rests on data being parquet any engine can read. Inlined rows
  are DuckLake-internal tables.

None of this is a DuckLake defect — inlining is a sensible small-write
optimization. But the encryption design assumes object-store-or-nothing, so
whichever epic implements the real ingest path should set the inlining limit
explicitly and assert on `ducklake_data_file`, exactly as `verify` does here.

---

## Teardown, and why it is an acceptance criterion

The skeleton's safety argument is only as good as its disposability, so
disposability is tested rather than asserted:

```bash
scripts/lake-skeleton.sh destroy
ls /scratch/lake-skeleton          # must not exist
docker ps -a --filter name=lake-skeleton-   # must be empty
scripts/lake-skeleton.sh up && scripts/lake-skeleton.sh verify   # green again
```

A skeleton that cannot be recreated from an empty scratch path is one whose
state has quietly leaked somewhere else — which is exactly the failure §11.0
warns about. Run the destroy-and-recreate cycle whenever the stack's definition
changes, not only the first time.

`destroy` uses `sudo rm -rf` on the scratch tree: Postgres and Garage write as
their own container users, so the tree is not owned by the invoking user.

**`destroy` refuses real data (system_3 #12471).** Since 2026-10-30 this tree
holds the operator's real records (#11565), so the cycle above is for a
skeleton of fixtures only. `destroy` checks before it stops anything:

- The path must be the skeleton's own. It is resolved first, so a symlink
  cannot redirect the delete. It must be at least two levels deep and off
  `/data`, and it may hold only what the script creates (`catalog`, `config`,
  `garage`, `promote-spool`, `lake-skeleton.env`, `deploy-env.bak-*` and the
  marker below). Anything else is refused, with or without confirmation.
- The data must be disposable. Either `garage/data` and `catalog` are empty,
  or the tree carries `.fixtures-only`. `up` writes that marker only on a root
  that did not exist, and every verb that can bring real data (`ingest`,
  `promote`, `list-staged`, `link-gmail`, `explorer-env`,
  `rotate-explorer-ro`, `explorer-decrypt-up`, and any verb added later)
  removes it before it runs.
- Otherwise it needs `LAKE_SKELETON_DESTROY_REAL_DATA=<the resolved path>`,
  the exact path, so that "1" or "yes" cannot stand in for reading what is
  about to go. Make a copy first.

`tests/lake_skeleton_destroy_unit.sh` covers each case with a fake `docker`
and a fake `sudo` that cannot delete outside its own temp directory.

---

## What this is not

- **Not the real lake.** No connector points at it, no real source writes to it,
  and nothing it holds is backed up — by design (§6 backups protect data that
  exists; fixtures are regenerable).
- **Not a persistence guarantee.** Treat every `up` as potentially starting from
  nothing. If a fixture matters enough to preserve, it belongs in the repo as
  seed code, not in the skeleton's storage.
- **Not reachable from production.** It is on its own bridge network,
  deliberately not attached to `aspirant-online_default` (§9 threat model).
