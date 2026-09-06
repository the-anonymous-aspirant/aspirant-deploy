#!/usr/bin/env python3
"""Assert that the PINNED lake client image still satisfies Dockerfile-LakeDuckDB.

Runs INSIDE the image the compose file pins, with the repo mounted read-only at
/repo. Task #4290.

The gap this closes: `Dockerfile-LakeDuckDB` is a first-party build, not a
mirror, and nothing rebuilds or republishes it. Editing the Dockerfile changes
what the *source* declares; the pinned digest keeps serving whatever was pushed
last. Between 2026-08-24 and 2026-08-27 that divergence was one pip package
(`cryptography`, added by #4134) and it killed both `lake-skeleton.sh seed` and
`lake-skeleton.sh ingest` at import — while every suite in tests/ stayed green,
because every one of them installs its dependencies into `python:3.11-slim` at
test time and none of them had ever run the pinned image.

So the assertions are derived from the Dockerfile rather than listed here. A
hardcoded `import cryptography, boto3, duckdb` would close this instance; the
class is "the Dockerfile declares something the published image does not have",
and the next dependency has to be covered without anyone remembering to come
back and edit this file.

Nothing here reaches the network — the probe is expected to be run with
`--network none`. That is load-bearing for the extension checks: DuckDB will
happily fetch a missing extension from extensions.duckdb.org and report success,
which on the cell's link is precisely the failure this checks against. Since
#5366 the extensions are supplied by a read-only mount of the host duckdb cache
at /root/.duckdb/extensions (not baked at build time), so the entry point mounts
that cache alongside --network none; a LOAD that succeeds here proves the mount
supplies them without any fetch.

Usage (see tests/lake_client_image_unit.sh, which is the entry point):
    docker run --rm --network none -v "$PWD:/repo:ro" \\
        -v "$HOME/.duckdb/extensions:/root/.duckdb/extensions:ro" \\
        --entrypoint python <image> /repo/tests/lake_client_image_probe.py
"""

import re
import sys

DOCKERFILE = "/repo/Dockerfile-LakeDuckDB"

fails = 0


def pass_(label):
    print(f"  [PASS] {label}")


def fail(label, detail=""):
    global fails
    print(f"  [FAIL] {label}" + (f" — {detail}" if detail else ""))
    fails += 1


def read_dockerfile():
    with open(DOCKERFILE, encoding="utf-8") as fh:
        text = fh.read()
    # Join backslash continuations so a future multi-line pip install parses.
    return re.sub(r"\\\n", " ", text)


def parse_requirements(text):
    """Every `name==version` pinned on a `pip install` line."""
    reqs = {}
    for line in text.splitlines():
        if not re.match(r"^\s*RUN\s+pip\s+install\b", line):
            continue
        for token in line.split():
            m = re.fullmatch(r"([A-Za-z0-9][A-Za-z0-9._-]*)==([^\s]+)", token)
            if m:
                reqs[m.group(1)] = m.group(2)
    return reqs


def parse_extensions(text):
    """Every extension the image declares, LOADed from the mounted host cache.

    Since #5366 the extensions are no longer `install_extension`-ed at build
    time (that reached extensions.duckdb.org, which the cell cannot) — they are
    mounted read-only from the host duckdb cache and LOADed at run time. The
    Dockerfile declares the set on a `# LAKE_EXTENSIONS: ...` marker line so the
    probe still checks each one LOADs offline from that mount.
    """
    exts = set()
    for m in re.finditer(r"^\s*#\s*LAKE_EXTENSIONS:\s*(.+)$", text, re.MULTILINE):
        exts.update(m.group(1).split())
    return sorted(exts)


def parse_base_python(text):
    m = re.search(r"^\s*FROM\s+python:(\d+)\.(\d+)", text, re.MULTILINE)
    return (int(m.group(1)), int(m.group(2))) if m else None


def main():
    text = read_dockerfile()
    reqs = parse_requirements(text)
    extensions = parse_extensions(text)
    base = parse_base_python(text)

    # Positive controls. An empty parse would sail through every loop below and
    # report a clean bill of health for an image it never looked at — the exact
    # shape of green-lie this whole file exists to stop. Refuse to run instead.
    if "duckdb" not in reqs:
        sys.exit(
            f"probe is broken, not the image: parsed {len(reqs)} pinned requirement(s) "
            f"from {DOCKERFILE} and duckdb was not among them — the parser has drifted "
            f"from the Dockerfile's syntax"
        )
    if "ducklake" not in extensions:
        sys.exit(
            f"probe is broken, not the image: parsed {len(extensions)} declared extension(s) "
            f"from {DOCKERFILE}'s `# LAKE_EXTENSIONS:` marker and ducklake was not among them"
        )
    if base is None:
        sys.exit(f"probe is broken, not the image: no `FROM python:X.Y` line in {DOCKERFILE}")

    print(f"pinned image vs {DOCKERFILE} ({len(reqs)} requirement(s), "
          f"{len(extensions)} extension(s)):")

    # --- the base interpreter ------------------------------------------------
    running = sys.version_info[:2]
    if running == base:
        pass_(f"base interpreter is python {base[0]}.{base[1]}")
    else:
        fail(f"base interpreter is python {running[0]}.{running[1]}, "
             f"Dockerfile says {base[0]}.{base[1]}",
             "the published image was built from a different base")

    # --- the pip requirements -----------------------------------------------
    # importlib.metadata keys on the DISTRIBUTION name, which is what the
    # Dockerfile pins — no dist-name-to-module-name table to keep in sync, and
    # the version comparison catches a republish from a stale Dockerfile that a
    # bare `import` would wave through.
    from importlib.metadata import PackageNotFoundError, version

    for name in sorted(reqs):
        want = reqs[name]
        try:
            got = version(name)
        except PackageNotFoundError:
            fail(f"{name}=={want} is not installed in the pinned image",
                 "rebuild and republish the image, then repin the digest "
                 "(docs/LAKE_SKELETON.md § Republishing the client image)")
            continue
        if got == want:
            pass_(f"{name}=={want}")
        else:
            fail(f"{name} is {got} in the pinned image, Dockerfile pins {want}",
                 "the published image predates the Dockerfile")

    # --- the duckdb extensions (mounted from the host cache, #5366) ----------
    # Only reachable if duckdb itself imported; skipping is honest here, a
    # cascade of confusing extension failures is not.
    try:
        import duckdb
    except ImportError as exc:
        print(f"  [SKIP] baked extensions — duckdb does not import ({exc})")
    else:
        conn = duckdb.connect()
        for ext in extensions:
            try:
                conn.load_extension(ext)
            except Exception as exc:  # noqa: BLE001 — any load failure is the finding
                fail(f"extension '{ext}' does not load from the pinned image",
                     f"{type(exc).__name__}: {str(exc).splitlines()[0][:160]}")
            else:
                pass_(f"extension '{ext}' loads offline")

    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
