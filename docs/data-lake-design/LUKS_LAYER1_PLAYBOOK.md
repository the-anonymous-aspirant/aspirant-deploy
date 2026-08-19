# LUKS layer-1 setup — playbook (`/data`, `/scratch`, lake SSD LV)

Implements **DATA_LAKE_DESIGN.md §9 layer 1** for phase **0b** (§11.1). Task
**#4131** (`#4120-A`), child A of the 0b encryption epic **#4120**. This child
ships LUKS-on-disk for the volumes that will hold real personal data; it blocks
child B (**#4132**, `dropbear-initramfs` remote unlock) and does not include
layer-2 envelope encryption (child C/D).

> **Execution boundary.** The luksFormat + reboot + unlock is an operator-invoked,
> production-facing, non-reversible ceremony. This document and the scripts under
> `scripts/luks-layer1/` are the *scriptable* pre-work and verification; the
> destructive steps are run by the operator, tracked as an `Operator-Hold:` on
> #4131. Nothing here was executed against live volumes while authoring it.

---

## 1. Ground truth vs. the task's premise

Read read-only on the cell 2026-08-19 (`lsblk` / `/proc/mdstat` / `vgs` / `df` /
`docker inspect`). The task body's three named volumes do not map onto the real
layout, and the corrections shape every decision below.

| Task premise | Reality on the cell | Consequence |
|---|---|---|
| `/data` is an LV to migrate | **md0 RAID1** (sdb+sdc), **rotational HDDs**, ext4, **125G real data used** of 1.8T | Not an LV. The one hard, downtime-bearing volume; carries production secrets/uploads/finance/penpot/backups. |
| `/scratch` is an LV / "SSD" | **sda**, raw ext4, **rotational HDD**, 47M used (synthetic lake-skeleton only) | Not an LV, not an SSD. Trivial: §11.0 designates scratch as destroy-on-disposal. |
| "the lake's SSD LV" exists | **Does not exist.** Only SSD is **sdd**; VG `ubuntu-vg-1` has **~130G VFree** | The lake LV is *created* here, greenfield, from the SSD's free extents. Zero data at risk. |
| (implied) targets need boot-time unlock | **None of the three is the OS root `/`** (root is a 100G LV on sdd) | The cell boots to normal, fully-networked SSH **without** any unlock. See §3. |

Distro confirmed **Ubuntu 24.04.4 LTS**, systemd, kernel 6.8, `cryptsetup 2.7.0`
— so the §9 "assume Debian/Ubuntu + `dropbear-initramfs`" assumption holds (that
package is child B's concern, not this child's — see §3).

`/data/aspirant/` holds live-mounted production state: `backend-secret`,
`nginx-secrets`, `finance`, `uploads`, `penpot`, `backups`, `remarkable`,
`browser_flows`, `assets`, `audio`, `models`, `ollama`, `kiwix`, `advisor`.
Encrypting `/data` therefore requires stopping every container that mounts it.

## 2. Per-volume migration recommendation

Ordered easiest → hardest; do them in this order so the risky one runs last,
after the ceremony (unmount → luksFormat → mount → unlock) is already rehearsed
twice on volumes where a mistake costs nothing.

1. **`/scratch` (sda) — fresh luksFormat.** Synthetic-only; correct disposal is
   destruction (§11.0 guardrail). `umount` → `luksFormat` → `luksOpen` →
   `mkfs.ext4` → mount → re-seed the lake-skeleton fixtures. No backup needed.
2. **lake SSD LV — create + luksFormat.** `lvcreate -L 120G -n lake ubuntu-vg-1`
   (leaving headroom on the SSD) → `luksFormat` → `luksOpen` → `mkfs.ext4` →
   mount at `/lake`. Greenfield; zero data at risk.
3. **`/data` (md0) — evacuate → luksFormat → restore.** This is the design's own
   endorsed path: §11.0 states plainly that *"a populated disk cannot be
   encrypted in place … retrofitting means evacuating the data, rebuilding the
   volume, and restoring."* Concretely: stop the stack → `restic backup` +
   `restic check` (a **verified-restorable** copy, not just a copy) → capture a
   `sha256sum` manifest → `umount` → `luksFormat /dev/md0` → `luksOpen` →
   `mkfs.ext4` → mount → `restic restore latest` → checksum-verify → bring the
   stack back.

   **On in-place `cryptsetup reencrypt`:** `2.7.0` *can* do
   `reencrypt --encrypt --reduce-device-size 32M /dev/md0` in place. It is
   deliberately **not** recommended here: a multi-hour in-place rewrite of two
   16-year-old HDDs (§10) with no verified-restorable fallback is the wrong risk
   trade for the one volume that holds real data. In-place trades an hour of copy
   time for the loss of a safety net; evacuate+restore keeps the net. If a future
   volume is large, healthy, and already-backed-up, revisit.

## 3. Boot safety — why `dropbear-initramfs` is *not* on this child's path

The §11.2 worst case — "cell stays dark on a lossy initramfs link until someone
attends physically" — is a property of **root-on-LUKS**, where the box cannot
boot far enough to bring up its normal network until the passphrase is entered in
the initramfs. **None of this child's three volumes is the root filesystem.**

So the boot sequence is: cell powers on → normal Ubuntu boot on the **full**
network stack (not the fragile initramfs network) → normal `sshd` answers →
operator SSHes into the **running** system and runs `cryptsetup luksOpen` +
`mount` (or `systemctl start` a `noauto` crypttab unit) for the three data
volumes → the `/data`-dependent services start.

Consequences, stated so child B is scoped correctly:

- **`dropbear-initramfs` (child B / #4132) is not required to encrypt these three
  volumes.** It becomes necessary only if/when `/` itself is encrypted. This
  child's remote-unlock proof is simply: SSH into the normally-booted cell and
  `luksOpen` — which is strictly more reliable than initramfs unlock because the
  box is up on its real network.
- The task's success criterion "prove SOMETHING can unlock the volumes remotely"
  is met by this post-boot SSH `luksOpen`, demonstrated once in the ceremony.
- crypttab entries for the three volumes MUST be `noauto` (or use a keyscript),
  never a bare passphrase prompt that would block boot — otherwise we
  *reintroduce* the dark-cell failure mode this child specifically avoids.

## 4. Degraded-Wi-Fi fallback (§11.2 standing constraint)

The cell is on a USB Wi-Fi dongle at ~-83 dBm / ~40% loss, no ethernet access,
treated as permanent. Because unlock here happens **post-boot on the full network
stack** (§3), reachability is far better than the initramfs case §11.2 worries
about — but the link is still the link. Fallbacks, in order:

1. **Retry patience.** Per §11.2, several SSH attempts are normal, not a fault.
   The runbook says so explicitly so an operator mid-outage does not misread
   retries as breakage.
2. **The box is already up.** Unlike root-on-LUKS, a failed SSH attempt does not
   mean the box is unreachable-and-halted — the OS is running and reachable-when-
   the-link-permits; services that do not depend on `/data` are already back.
3. **Physical console.** If the link is down hard, the volumes wait
   encrypted-and-unmounted (services degraded, box **not** dark) until the
   operator can attend the console. This is the accepted residual cost (§9),
   materially smaller here than the root-on-LUKS dark-cell case.
4. **Never a key in the chassis** (§9 / §11.2, non-negotiable): flakiness is
   answered with patience, never by putting the unlock key on the stolen-hardware.

## 5. Operator ceremony (the `Operator-Hold` steps)

Run from the cell after review. Scripts referenced live in
`scripts/luks-layer1/`.

1. `sudo scripts/luks-layer1/inventory.sh` — confirm the layout still matches §1.
2. `sudo scripts/luks-layer1/preflight.sh` — dry-run: readiness checks + the exact
   destructive command sequence. Resolve every `[WARN]` before proceeding.
3. **`/data` backup gate:** `restic backup /data` → `restic check` → capture the
   manifest: `find /data -type f -print0 | sort -z | xargs -0 sha256sum >
   /root/data.pre.sha256`. Do not proceed past this line for `/data` without a
   verified-restorable backup.
4. Encrypt in order: `preflight.sh --confirm scratch`, then `--confirm lake`,
   then the `/data` evacuate→restore by hand (the script refuses to automate the
   1.8T restore without an interactive verified-restore checkpoint).
5. Add `noauto` crypttab entries (§3) and `noauto` fstab mounts for the three
   mappers. **Reboot.**
6. After reboot, from **off-box over the real link**: SSH in, `cryptsetup
   luksOpen` each volume, mount, `systemctl start` the stack. Note time-to-unlock
   across a couple of attempts (§11.2 measurement).
7. `sudo scripts/luks-layer1/postcheck.sh --checksum /root/data.pre.sha256`.

## 6. Post-reboot verification (definition of done)

`postcheck.sh` must report **all PASS**:

- Each of `scratch_crypt`, `lake_crypt`, `data_crypt` is an active LUKS mapping,
  mounted at `/scratch`, `/lake`, `/data` respectively.
- `/data` checksums match the pre-reboot manifest (data intact).
- Post `luksOpen`, `cryptsetup status <name>` shows `type: LUKS2` on all three
  (the layer-1 read the `s3 audit encryption` equivalent will consume; #4120-C
  reads the volume-KEK layer from here).
- The post-boot SSH `luksOpen` was demonstrated at least once over the real link.

Only then does #4131 close. The full reboot **drill** with `dropbear-initramfs`
over the degraded link (the §11.2 acceptance criteria for root-on-LUKS) belongs
to child B / #4132; this child proves the non-root-volume unlock path.

## 7. Scope boundaries

- **In:** LUKS on `/scratch`, `/data`, a new lake SSD LV; post-boot remote-unlock
  proof; verified `/data` data integrity.
- **Out:** `dropbear-initramfs` package + initramfs-network drill (#4132 / child
  B); KEK generation for the layer-2 envelope (#4120-C); envelope machinery
  (#4120-D); encrypting the OS root `/` (not in §9 layer-1 scope for 0b).

**Reference:** `DATA_LAKE_DESIGN.md` §9 (layer 1), §10 (SMART/16y disks), §11.0
(guardrail), §11.1 (phase 0b), §11.2 (reboot-drill spec).
