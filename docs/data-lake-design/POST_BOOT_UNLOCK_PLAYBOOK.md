# Post-boot remote unlock + reboot drill — playbook (`/data`, `/scratch`, `/lake`)

Implements the remote-unlock half of **DATA_LAKE_DESIGN.md §9 layer 1** for phase
**0b**, and the **§11.2 reboot drill**. Task **#4132** (`#4120-B`), child B of the
0b encryption epic **#4120**. Depends on child A (**#4131**) having encrypted the
three volumes first.

> **Execution boundary.** The reboot drill is an operator-invoked, production-facing
> action (physical + network access to the cell). This document and
> `scripts/luks-unlock/{unlock.sh,crypttab.reference}` are the *scriptable* recovery
> path and its verification; the deliberate reboot is run by the operator, tracked
> as an `Operator-Hold:` on #4132. `unlock.sh` is verified independently against a
> throwaway loopback LUKS device by `tests/luks_unlock_loopback.sh` — nothing here
> was executed against live volumes while authoring it.

---

## 1. Why post-boot unlock, and NOT `dropbear-initramfs`

The task title says "dropbear-initramfs remote unlock". The cell's hardware makes
that the wrong mechanism, and child A already recorded why
(`LUKS_LAYER1_PLAYBOOK.md` §3). Confirmed again read-only on the cell
2026-08-20 (`findmnt /`, `lsblk`):

- Root `/` is `/dev/mapper/ubuntu--vg--1-ubuntu--lv` (an LV on the SSD, sdd3),
  **plaintext**. `/boot` (sdd2) is plaintext too.
- `/data` (md0 RAID1), `/scratch` (sda), and the `/lake` LV are the encrypted
  targets — **none of them is root**.

`dropbear-initramfs` exists for exactly one job: unlock an encrypted **root** in
the initramfs so the machine can boot far enough to bring up its network. Here the
machine boots to a **full, normally-networked SSH login with no unlock at all** —
there is nothing for an initramfs SSH server to unlock, and the §11.2 "dark cell on
a lossy initramfs link" worst case does not exist for this layout.

So remote unlock is simply: **SSH into the already-booted cell over the real
network and run `unlock.sh`.** This is strictly more reliable than initramfs
unlock, because the box is up on its full network stack — a flaky SSH attempt does
not mean the box is dark and halted; it is running and reachable-when-the-link-
permits, with all `/data`-independent services already back.

`dropbear-initramfs` becomes necessary only if a future decision encrypts `/`
itself (out of scope for 0b, §9 layer 1). If that day comes it is a *new* child;
the data volumes still unlock post-boot regardless, because you never unlock data
volumes in the initramfs.

## 2. Boot-time gating (the one hard requirement)

Because the volumes are `noauto` (see `crypttab.reference` and §3 of the layer-1
playbook — a bare passphrase-prompt entry would block boot), on a reboot the cell
comes up with `/data` **unmounted**. Any service that bind-mounts `/data/...` must
therefore be prevented from starting against the empty mountpoint, or it will run
data-less until restarted.

The gate is procedural, and deliberately so — it cannot be automated without
putting the unlock key on the box, which §9 forbids:

1. **Data-dependent services must not auto-start on boot.** The operator confirms
   the deploy's start-on-boot path (the `auto-pull` systemd unit / compose
   `restart:` policy) is scoped so `/data`-bind-mounting containers do **not** come
   up before `/data` is mounted. Services that use only named docker volumes (which
   live on root, not `/data`) are unaffected and may start normally.
2. **`unlock.sh` is the single post-reboot bring-up path.** After it unlocks +
   mounts the three volumes, the operator brings the stack up — either
   `unlock.sh --start-stack` with `STACK_UP_CMD` set to the deploy's bring-up
   command, or the normal deploy path run by hand.

> This §2 boot-behaviour change touches the production start-on-boot config and is
> flagged for operator/manager review before it is applied — it is documented here,
> not silently rewired.

## 3. Post-reboot recovery procedure (the repeatable path)

From the operator's own machine, over the real network:

```
ssh aspirant@<cell>
sudo /home/aspirant/aspirant-deploy/scripts/luks-unlock/unlock.sh
# → prompts for each volume's passphrase, mounts /scratch /lake /data (data last)
sudo /home/aspirant/aspirant-deploy/scripts/luks-layer1/postcheck.sh --checksum /root/data.pre.sha256
# → confirms all three LUKS-active + mounted, /data intact
sudo /home/aspirant/aspirant-deploy/scripts/luks-unlock/unlock.sh --start-stack   # or the normal deploy bring-up
```

`unlock.sh` is idempotent: re-running after a dropped SSH session skips volumes
already open/mounted, so a mid-unlock link drop is recovered by simply running it
again. `unlock.sh --status` reports state without changing anything.

## 4. The reboot drill (§11.2 — operator-invoked)

The acceptance test for this child. Run once the volumes are actually encrypted
(child A ceremony complete):

1. Announce a maintenance window (services that depend on `/data` will be down
   between reboot and unlock).
2. `sudo reboot` the cell.
3. Wait for the cell to come back on the network (normal boot — no unlock needed to
   reach SSH). Note the wall-clock from reboot to SSH-answering.
4. SSH in over the **real degraded Wi-Fi link** (not a wired test) and run the §3
   procedure. **Measure and record:** number of SSH attempts needed, wall-clock
   from first attempt to all-three-mounted, and any link stalls mid-passphrase.
5. Confirm `postcheck.sh` reports all PASS and the stack is functional.
6. Record the measured numbers in the #4132 task comment (the §11.2 measurement
   requirement — "degraded Wi-Fi is real").

## 5. Fallback / recovery when the link flakes

The degraded USB-Wi-Fi link (~-83 dBm, ~40% loss, treated as permanent) means a
first SSH attempt can fail. In order:

1. **Retry — it is expected, not a fault.** Per §11.2, several attempts are normal.
   `unlock.sh` is idempotent, so retrying is always safe; a partial unlock is
   completed by re-running.
2. **The box is already up.** Unlike root-on-LUKS, a failed SSH attempt does not
   mean the cell is unreachable-and-halted. The OS is running; `/data`-independent
   services are already back; the encrypted volumes simply wait unmounted.
3. **Widen the window / try from a second network path** (e.g. phone hotspot) if
   the primary link is saturated — the cell is listening on its normal sshd, not a
   one-shot initramfs server, so there is no unlock timeout to race.
4. **Physical console** is the hard fallback: if the link is down entirely, the
   volumes wait encrypted-and-unmounted (services degraded, box **not** dark) until
   the operator can attend the console. Accepted residual cost (§9), materially
   smaller than the root-on-LUKS dark-cell case.
5. **Never a key in the chassis** (§9 / §11.2, non-negotiable): link flakiness is
   answered with patience, never by writing the unlock key to the cell.

## 6. Definition of done

- `unlock.sh` + `crypttab.reference` merged; `tests/luks_unlock_loopback.sh` green.
- The §2 boot-gating change reviewed and applied so no `/data`-dependent service
  auto-starts against an unmounted `/data`.
- The §4 reboot drill run by the operator over the real link, with the measured
  unlock time + attempt count recorded on #4132.
- `postcheck.sh` all PASS after the drill.

## 7. Scope boundaries

- **In:** the repeatable post-boot unlock command, its `noauto` crypttab/fstab
  reference, boot-gating guidance, the reboot drill spec + measurement, the flaky-
  link fallback playbook.
- **Out:** LUKS setup itself (#4131 / child A); KEK ceremony (#4120-C); layer-2
  envelope encryption (#4120-D); encrypting the OS root `/` and its
  `dropbear-initramfs` (not in §9 layer-1 scope for 0b — a future child if ever).

**Reference:** `DATA_LAKE_DESIGN.md` §9 (layer 1), §11.2 (reboot drill);
`LUKS_LAYER1_PLAYBOOK.md` §3 (why not dropbear), §5–6 (ceremony + postcheck).
