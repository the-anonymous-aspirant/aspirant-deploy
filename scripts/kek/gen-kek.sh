#!/usr/bin/env bash
#
# KEK generation ceremony -- DATA_LAKE_DESIGN.md §9 layer 2, task #4133 (#4120-C).
#
# Generates ONE 32-byte AES-256 key-encryption-key (KEK) from the OS CSPRNG and
# prints it to stdout in three transcription-friendly encodings plus a short
# verification fingerprint. It writes NOTHING to disk -- the KEK is never at rest
# on the cell (§9). Whatever consumes stdout (the operator's terminal, a token
# loader) is the only place the key ever lives; close the terminal / clear
# scrollback when the ceremony is done.
#
#   EXECUTION BOUNDARY. This script is the *generation half* of an operator-
#   invoked, production-secret ceremony. Run it ONLY inside the interactive
#   custody window (operator present, ready to place custody immediately), so
#   the live KEK's in-memory lifetime is seconds, not the length of a hold. Do
#   NOT run it and then wait -- see the Operator-Hold in KEK_CEREMONY.md.
#
# Usage:
#   scripts/kek/gen-kek.sh [--kek-version N]
#
# Depends only on python3's standard library (secrets/os.urandom == getrandom).
# No third-party package, so it runs on the bare cell without a venv.

set -euo pipefail

KEK_VERSION=1
while [ "$#" -gt 0 ]; do
  case "$1" in
    --kek-version) KEK_VERSION="${2:?--kek-version needs a value}"; shift 2 ;;
    -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

command -v python3 >/dev/null 2>&1 || { echo "python3 not found" >&2; exit 1; }

# Harden the process against leaving the key on disk:
#  - no core dumps (a crash must not spill the key into a core file)
#  - a private umask for any accidental file the shell might create
ulimit -c 0 2>/dev/null || true
umask 077

echo "=============================================================="
echo " KEK generation ceremony -- §9 layer 2 -- $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "=============================================================="
echo
echo "This key is NOT written to disk. Place it in off-cell custody NOW"
echo "(hardware token, or written down and physically secured), verify the"
echo "fingerprint, then wipe this terminal's scrollback."
echo

KEK_VERSION="$KEK_VERSION" python3 - <<'PY'
import base64
import hashlib
import os
import secrets

kek_version = int(os.environ["KEK_VERSION"])

# 32 bytes of CSPRNG output. secrets.token_bytes and os.urandom both draw from
# getrandom(2) -- the kernel CSPRNG, seeded from hardware entropy.
kek = secrets.token_bytes(32)

b64 = base64.b64encode(kek).decode()
hexs = kek.hex()
# Grouped hex: 16 groups of 4, easier to transcribe by hand without losing place.
grouped = " ".join(hexs[i:i + 4] for i in range(0, len(hexs), 4))
# A short, NON-secret fingerprint: first 8 bytes of SHA-256(KEK). Safe to log,
# to read back over the phone, and to compare after custody placement. It does
# NOT reveal the key (one-way hash, truncated).
fp = hashlib.sha256(kek).hexdigest()[:16]

print(f"kek_version : {kek_version}")
print(f"algorithm   : AES-256-GCM (32-byte key)")
print()
print("KEK (base64):")
print(f"    {b64}")
print()
print("KEK (hex, grouped -- for writing down):")
print(f"    {grouped}")
print()
print(f"fingerprint : sha256(KEK)[:8] = {fp}")
print("              ^ NON-secret. Record this in the task comment so the")
print("                recovery drill can prove it read back the same key.")
PY

echo
echo "Custody checklist (mirror of the Operator-Hold on the task):"
echo "  1. Place the KEK on the hardware token, OR write down the grouped hex"
echo "     and physically secure it off-cell."
echo "  2. Read the key back from custody and confirm the fingerprint matches."
echo "  3. Signal completion so the recovery drill can run and this terminal"
echo "     can be closed / scrollback cleared. Nothing persisted the KEK here."
