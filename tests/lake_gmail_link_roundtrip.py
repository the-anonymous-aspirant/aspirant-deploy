"""The Gmail attachment linker against a real Postgres, as its own role.

system_3 #11557; security c75385 A6 as amended in c75393 (A6a-A6c). Run by
tests/lake_gmail_link_unit.sh, which starts a throwaway postgres:16-alpine,
runs lake-skeleton.sh's own bootstrap_gmail_linker_role against it, and hands
this script three DSNs on its environment: the linker's, the owner's (to read
what the linker wrote) and explorer_ro's.

Every id and hash is invented. Nothing here reaches the real lake.
"""

from __future__ import annotations

import contextlib
import io
import json
import os
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))

import duckdb  # noqa: E402

import lake_gmail_link as link  # noqa: E402

LINKER_DSN = os.environ["LAKE_CATALOG_GMAIL_LINKER_DSN"]
OWNER_DSN = os.environ["TEST_OWNER_DSN"]
RO_DSN = os.environ["TEST_RO_DSN"]

PASSED = 0
FAILED = 0


def check(label: str, ok: bool, detail: str = "") -> None:
    global PASSED, FAILED
    print(f"[{'PASS' if ok else 'FAIL'}] {label}" + (f" — {detail}" if detail else ""))
    if ok:
        PASSED += 1
    else:
        FAILED += 1


def attach(dsn: str, alias: str):
    con = duckdb.connect()
    con.execute("LOAD postgres")
    con.execute(f"ATTACH '{dsn}' AS {alias} (TYPE postgres)")
    return con


def rows() -> list[tuple]:
    con = attach(OWNER_DSN, "own")
    return sorted(
        con.execute("SELECT * FROM postgres_query('own', 'SELECT message_id, part_id, sha256 FROM public.gmail_attachment_links')").fetchall()
    )


def sha(c: str) -> str:
    return c * 64


def run(doc, env=None) -> tuple[int, str]:
    with tempfile.TemporaryDirectory() as tmp:
        path = Path(tmp) / "links.json"
        path.write_text(doc if isinstance(doc, str) else json.dumps(doc), "utf-8")
        out = io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(out):
            code = link.main([str(path)], env={link.ENV_DSN: LINKER_DSN} if env is None else env)
    return code, out.getvalue()


LINKS = {
    "links": [
        {"message_id": "18f00000000000a1", "part_id": "1", "sha256": sha("a")},
        {"message_id": "18f00000000000a1", "part_id": "2", "sha256": sha("b")},
        # Two parts, one blob: two rows.
        {"message_id": "18f00000000000a2", "part_id": "0.1", "sha256": sha("a")},
    ],
    # A part refused at fetch (A4) is metadata only and gets no row (A6b).
    "refused": [{"message_id": "18f00000000000a2", "part_id": "2", "reason": "size_mismatch"}],
}
WANT = sorted((x["message_id"], x["part_id"], x["sha256"]) for x in LINKS["links"])


def main() -> int:
    print("the bootstrap made what A6 says:")
    con = attach(OWNER_DSN, "own")
    cols = [r[0] for r in con.execute(
        "SELECT * FROM postgres_query('own', 'SELECT column_name FROM information_schema.columns "
        "WHERE table_schema = ''public'' AND table_name = ''gmail_attachment_links'' ORDER BY ordinal_position')"
    ).fetchall()]
    check("the table has exactly (message_id, part_id, sha256)", cols == ["message_id", "part_id", "sha256"], str(cols))
    owner = con.execute(
        "SELECT * FROM postgres_query('own', 'SELECT tableowner FROM pg_tables WHERE tablename = ''gmail_attachment_links''')"
    ).fetchone()[0]
    check("the catalog owner owns it", owner == "ducklake", owner)

    print("\nthe job writes a run's links, once:")
    code, out = run(LINKS)
    check("a run's links: exit 0", code == 0, out.strip())
    check("exactly the written parts have rows; the refused part has none (A6b)", rows() == WANT, str(rows()))
    check("the output is a count", out.strip() == "gmail-linker: 3 link(s) written or already present", out.strip())
    code, out = run(LINKS)
    check("a re-run is a no-op through ON CONFLICT DO NOTHING (A6a)", code == 0 and rows() == WANT, out.strip())
    code, _ = run({"links": LINKS["links"][:1] + [{"message_id": "18f00000000000a3", "part_id": "1", "sha256": sha("c")}]})
    check("a run overlapping a past one adds only its new part", code == 0 and len(rows()) == 4, str(len(rows())))

    print("\nthe job refuses a malformed file and writes nothing:")
    before = rows()
    for label, doc in (
        ("a quote in a part id", {"links": [{"message_id": "18f00000000000b1", "part_id": "1'); DROP TABLE public.gmail_attachment_links; --", "sha256": sha("d")}]}),
        ("a file name as an extra field", {"links": [{"message_id": "18f00000000000b1", "part_id": "1", "sha256": sha("d"), "name": "x.pdf"}]}),
        ("an upper-case hash", {"links": [{"message_id": "18f00000000000b1", "part_id": "1", "sha256": sha("D")}]}),
        ("one part, two hashes", {"links": [
            {"message_id": "18f00000000000b1", "part_id": "1", "sha256": sha("d")},
            {"message_id": "18f00000000000b1", "part_id": "1", "sha256": sha("e")},
        ]}),
        ("not JSON", "{"),
    ):
        code, out = run(doc)
        check(f"{label}: refused, exit 1", code == 1 and "wrote nothing" in out, out.strip())
        check(f"{label}: no value is echoed", "DROP" not in out and "x.pdf" not in out and sha("d") not in out)
    check("nothing was written by the refused files", rows() == before)
    code, out = run(LINKS, env={})
    check("no DSN: exit 2, nothing written", code == 2 and rows() == before, out.strip())
    code, out = run({"links": []})
    check("no links: exit 0 without connecting", code == 0 and "0 links" in out, out.strip())

    print("\nA6c, as the role itself (the probes verify runs):")
    lc = attach(LINKER_DSN, "gl")
    before = rows()
    for label, ok, detail in link.prove_bounds(lc, "gl"):
        check(label, ok, detail)
    check("the probes left no row", rows() == before)

    # The question security left to a test: does DO NOTHING WITH a conflict
    # target need SELECT? The job does not use one; this records the answer.
    error = link._execute(
        lc, "gl",
        f"BEGIN; INSERT INTO {link.TABLE} VALUES {link.PROBE_ROW}; "
        f"INSERT INTO {link.TABLE} VALUES {link.PROBE_ROW} ON CONFLICT (message_id, part_id) DO NOTHING; ROLLBACK;",
    )
    print("[INFO] ON CONFLICT (message_id, part_id) DO NOTHING as gmail_linker: "
          + ("succeeds" if error is None else ("permission denied" if "permission denied" in error.lower() else "fails")))

    print("\nthe explorer's role reads the table:")
    ro = attach(RO_DSN, "ro")
    n = ro.execute("SELECT count(*) FROM ro.public.gmail_attachment_links").fetchone()[0]
    check("explorer_ro can SELECT gmail_attachment_links", n == len(before), str(n))

    print()
    if FAILED:
        print(f"FAILED: {FAILED} failed, {PASSED} passed")
        return 1
    print(f"{PASSED} passed, 0 failed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
