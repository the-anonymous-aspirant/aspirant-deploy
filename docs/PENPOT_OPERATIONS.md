# Penpot Design Service — Operations

*Author: aspirant (via aspirant_engineer, system_3 #2195-B1)*
*Date: 2026-07-17*

Operational runbook for the five `penpot-*` compose services. What the
service is and how it is wired live in [PENPOT_SPEC.md](PENPOT_SPEC.md) and
[PENPOT_ARCHITECTURE.md](PENPOT_ARCHITECTURE.md); general stack operations
live in [OPERATIONS.md](OPERATIONS.md). This document covers the parts that
are specific to running, migrating, and restoring Penpot content.

Every procedure here was executed for real during the dev-box → cell
migration on 2026-07-16/17 (system_3 #2197); the gotchas are things that
actually happened.

## Lifecycle

Always target the penpot services explicitly:

```bash
cd /home/aspirant/aspirant-deploy
docker compose up -d penpot-postgres penpot-redis          # data layer only
docker compose up -d penpot-backend penpot-frontend        # app layer
docker compose up -d penpot-exporter                       # export rendering
```

An untargeted `docker compose up -d` recreates/pulls *every* service in the
project, including any whose image is not yet present locally — on a
degraded link that wedges the whole deploy (see the deploy-client lessons
in OPERATIONS.md §Gotchas).

The images are upstream `penpotapp/*` mirrored to
`ghcr.io/the-anonymous-aspirant/penpot-*` and pinned by sha256 digest.
There is no build lane for this service, and the auto-pull cron's
`docker compose pull` is a deliberate no-op for digest-pinned refs.
Upgrading Penpot = changing the digests in `docker-compose.yml` (one PR),
then pulling on the cell.

## Health

```bash
curl -sf http://127.0.0.1:9001/readyz        # frontend loopback publish
docker compose ps --format '{{.Service}} {{.Status}}' | grep penpot
```

The public path (`https://the-aspirant.com/admin/penpot/`) additionally
exercises the client-nginx `auth_request` gate and the Cloudflare hop; a
green loopback probe with a failing public path points at the client vhost
or the admin JWT, not at Penpot.

## Getting the images onto a host without a working registry pull

Preferred path is `docker compose pull` — use it whenever GHCR is reachable
at bulk speed. When it is not (the cell's Wi-Fi link degrades to a few KB/s
under interference; see system_3 #2195 for the incident), images move as
archives:

1. **Export on a healthy host with `skopeo`, not `docker save`.** On a
   containerd-store host, `docker save` of a digest-pulled image silently
   exports a ~12 KB manifest stub instead of the layers:

   ```bash
   skopeo copy docker-daemon:ghcr.io/the-anonymous-aspirant/penpot-postgres:15@sha256:1439… \
       docker-archive:penpot-postgres.tar
   gzip penpot-postgres.tar     # or: zstd -15 --long (≈17% smaller than gzip)
   ```

2. **Transfer** (see the degraded-link runbook below if the link is sick).

3. **Load, then register the digest.** `docker load` imports the layers but
   on an overlay2 store does **not** record a `RepoDigest`, so the
   digest-pinned `image:` refs in `docker-compose.yml` still do not resolve
   and compose will try to pull. Fix with a manifest-only pull — the layers
   are already local, so only the few-KB manifest and config come over the
   wire:

   ```bash
   gunzip -c penpot-postgres.tar.gz | docker load
   docker pull -q ghcr.io/the-anonymous-aspirant/penpot-postgres:15@sha256:1439…
   ```

   The manifest pull still needs GHCR reachability; on a flapping link,
   retry it in a loop rather than treating one failure as fatal.

## Content migration and restore

Validated end-to-end for the 2026-07-16 dev-box → cell move. The same
procedure is the disaster-restore path.

### Export (source instance)

```bash
# Database: custom-format dump from the penpot postgres container
docker exec <penpot-postgres-container> pg_dump -U penpot -d penpot -Fc \
    > penpot-$(date +%Y%m%d).dump

# Assets: tar the assets volume/directory
tar czf penpot-assets-$(date +%Y%m%d).tar.gz -C <assets-dir> .

# Evidence baseline for the restore check
docker exec <penpot-postgres-container> psql -U penpot -d penpot -tA -c \
  "select 'file',count(*) from file
   union all select 'project',count(*) from project
   union all select 'profile',count(*) from profile
   union all select 'file_media_object',count(*) from file_media_object
   union all select 'storage_object',count(*) from storage_object"
```

### Restore (target instance)

```bash
cd /home/aspirant/aspirant-deploy
docker compose up -d --no-deps penpot-postgres penpot-redis
docker compose exec -T penpot-postgres pg_isready -U penpot

# Safety convention: snapshot before any write, even into a "fresh" DB
docker compose exec -T penpot-postgres pg_dump -U penpot -d penpot -Fc \
    > /tmp/penpot-prerestore-$(date +%Y%m%dT%H%M%S).dump

docker compose exec -T penpot-postgres pg_restore -U penpot -d penpot \
    --clean --if-exists --no-owner < penpot-<date>.dump

# Assets land on the bind mount, owned by the backend's uid/gid
mkdir -p /data/aspirant/penpot/assets
tar xzf penpot-assets-<date>.tar.gz -C /data/aspirant/penpot/assets
sudo chown -R 1001:1001 /data/aspirant/penpot/assets
```

### Verify

- Row counts match the export baseline (query above).
- Asset parity: `find /data/aspirant/penpot/assets -type f | wc -l` matches
  the source; for byte-level certainty compare full `md5sum` manifests —
  `du -sb` totals differ across filesystems by directory-entry accounting
  even when every file is identical.
- Designs render: open the migrated file at
  `https://the-aspirant.com/admin/penpot/` and check the revision history.

### Cutover delta sync

The bulk export/restore above is not the end of the migration while the
source instance stays live: anything written on the source after the
export is absent from the target. This is not hypothetical — during the
2026-07-16/17 move, the transfer window was long enough for the main
design file to advance from revn 150 to 153 and gain three storage
objects on the source while the revn-150 dump was still in flight.

At cutover (immediately before pointing users at the target):

1. Stop writes on the source — stop the source backend, or simply stop
   using it; there is no multi-writer story.
2. Re-run the **export** steps. The DB dump is small (hundreds of KB for
   this content set) and ships fine even on a degraded link; the assets
   delta is only the storage objects created since the bulk copy
   (compare `md5sum` manifests, send the missing files).
3. Re-run the **restore** steps on the target (`pg_restore --clean` makes
   this idempotent), re-verify row counts and the file `revn` values
   against a fresh source baseline.

Skipping this step silently loses the source's post-export edits the
moment users start writing on the target — after that, the two histories
can no longer be merged (Penpot has no design-file merge).

### Secrets discipline

`PENPOT_SECRET_KEY` **must** travel with the content. Sessions and signed
asset URLs are derived from it; regenerating it on the target orphans every
signed URL in the restored database. The same applies to
`PENPOT_DB_PASSWORD` unless you deliberately rotate it before the target's
first `up` (the postgres image only applies it on initdb of an empty data
dir). Both live in `.env` (never committed).

## Degraded-link bulk transfer runbook

Symptom signature (2026-07-16 incident): small SSH exchanges work, but any
sustained flow dies after ~30 s — GHCR pulls, rsync (even with
`--bwlimit`), and large single scp all fail. Parallel streams do not help;
the radio link is aggregate-capped. The only order-of-magnitude fix is
physical (re-seat the USB Wi-Fi dongle / move the cell / ethernet). Do
**not** reset the Wi-Fi interface remotely — there is no recovery path if
it fails to re-associate.

Working pattern while degraded:

```bash
split -b 262144 -a4 --numeric-suffixes=1 archive.tar.gz chunks/c   # 256 KB chunks
# per chunk: scp with ControlMaster multiplexing — the persistent master
# survives the flow-killer; only sustained bulk dies
scp -o ControlMaster=auto -o ControlPath=/tmp/cm-%r -o ControlPersist=120 \
    -o ConnectTimeout=15 -o BatchMode=yes -P 41922 chunks/cNNNN <cell>:…/chunks/
# reconcile rounds: list cell-side chunks, resend the gaps, repeat
# reassemble on the cell, md5-verify, write an <archive>.ok marker
```

- 512 KB chunks stall (each send crosses the ~30 s kill window at the
  degraded rate); 256 KB passes. Measure before choosing a size.
- `zstd -15 --long` recompression of docker image archives saves ≈17% over
  gzip — worth it at single-digit KB/s.
- Hold the auto-pull cron off during long transfers so its
  `docker compose pull` does not compete for the link:

  ```bash
  ssh <cell> 'sudo flock -n /var/lib/aspirant-auto-pull/auto-pull.lock sleep 14400' &
  ```

- Drive the transfer from a detached (`setsid nohup`) shipper script that
  logs to a file, and watch the log — an interactive session riding a
  flapping link dies with the link.

## Account management

Registration is disabled. Accounts are managed on the backend container
over PREPL, as on the dev box:

```bash
docker compose exec penpot-backend python3 manage.py create-profile \
    --fullname "…" --email "…" --password "…"
docker compose exec penpot-backend python3 manage.py delete-profile --email "…"
```

## Backup

Three things constitute a full Penpot backup, and they must be captured as
a set (the DB references assets by storage-object id, and signed URLs
depend on the secret key):

| What | How | Where it lives |
|------|-----|----------------|
| Database | `pg_dump -U penpot -d penpot -Fc` | `penpot-postgres` container |
| Assets | tar of the assets dir | `/data/aspirant/penpot/assets` |
| Secrets | `.env` (`PENPOT_SECRET_KEY`, `PENPOT_DB_PASSWORD`) | `/home/aspirant/aspirant-deploy/.env` |

Restore = the migration procedure above.
