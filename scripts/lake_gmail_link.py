"""Write one Gmail run's attachment links into the catalog.

system_3 #11557. Security's rulings: c75385 on #11557 (A1-A8) and c75393 (A6
amended: a role of its own, in a step of its own, with A6a-A6c).

Why this exists
---------------
A Gmail run pulled with `--attachments` stores each fetched part as its own
`message_attachment` object, catalogued under `attachments/<sha256>`. Which
message and which part a blob came from is not in that row (its path is the
hash, so it can name no file, A1). This job writes that fact, one row per
part, into `gmail_attachment_links (message_id, part_id, sha256)`, which the
explorer's read-only role can read. Nothing else.

What it may touch, and nothing else
-----------------------------------
- **The run's `links.json`**, mounted read-only. Only parts the pull wrote and
  hashed are in its `links` list; a part refused at fetch (A4) is in
  `refused` and gets no row (A6b).
- **Its own catalog role** (`gmail_linker`): INSERT on `gmail_attachment_links`
  and nothing else, not even SELECT. The catalog owner creates the table, so
  the role owns nothing. No S3 key.

How a run goes
--------------
1. With its DSN missing, it writes nothing, says so in one line and exits 2.
2. It reads `links.json` and checks every link before connecting: exactly the
   three fields; a Gmail message id is lower-case hex, a part id is dotted
   digits, a sha256 is 64 lower-case hex. One malformed link, or two links
   giving one part different hashes, refuses the whole file (exit 1), named
   by the link's position only.
3. In ONE transaction, `INSERT ... ON CONFLICT DO NOTHING`, so a re-run, or a
   part a past run already linked, is a no-op (A6a). With no conflict target,
   on purpose: `ON CONFLICT (message_id, part_id) DO NOTHING` needs SELECT on
   those columns, which the role does not have (measured on a real Postgres 16
   by tests/lake_gmail_link_unit.sh: permission denied). The values reach SQL as
   literals, which the shape checks in step 2 make safe: hex, digits and dots
   only, never a quote.

The output is counts only (A8). It cannot say how many rows were new: that
would need SELECT, which the role does not have.

Usage
-----
    scripts/lake-skeleton.sh link-gmail <run dir>/links.json   # its own compose service
"""

from __future__ import annotations

import json
import os
import re
import sys

ENV_DSN = "LAKE_CATALOG_GMAIL_LINKER_DSN"
TABLE = "public.gmail_attachment_links"
LOG = "gmail-linker:"
BATCH = 500

FIELDS = ("message_id", "part_id", "sha256")
SHAPES = {
    "message_id": re.compile(r"^[0-9a-f]{1,32}$"),
    "part_id": re.compile(r"^[0-9]+(\.[0-9]+)*$"),
    "sha256": re.compile(r"^[0-9a-f]{64}$"),
}

EXIT_REFUSED = 1
EXIT_NO_DSN = 2


class BadLinks(Exception):
    """`str()` names a position in the file, never a value."""


def load_links(text: str) -> list[tuple[str, str, str]]:
    try:
        doc = json.loads(text)
    except ValueError:
        raise BadLinks("links.json is not JSON") from None
    links = doc.get("links") if isinstance(doc, dict) else None
    if not isinstance(links, list):
        raise BadLinks("links.json has no `links` list")
    by_part: dict[tuple[str, str], str] = {}
    for i, link in enumerate(links):
        if not isinstance(link, dict) or set(link) != set(FIELDS):
            raise BadLinks(f"link {i} does not have exactly the fields {', '.join(FIELDS)}")
        for field in FIELDS:
            value = link[field]
            if not isinstance(value, str) or not SHAPES[field].match(value):
                raise BadLinks(f"link {i}: {field} is not the expected shape")
        part = (link["message_id"], link["part_id"])
        if by_part.setdefault(part, link["sha256"]) != link["sha256"]:
            raise BadLinks(f"link {i} gives a part a second, different hash")
    return sorted((m, p, h) for (m, p), h in by_part.items())


def insert_sql(links: list[tuple[str, str, str]]) -> str:
    """One transaction of batched INSERT ... ON CONFLICT DO NOTHING. Every value
    passed load_links' shape checks, so none can carry a quote."""
    statements = []
    for start in range(0, len(links), BATCH):
        values = ", ".join(f"('{m}', '{p}', '{h}')" for m, p, h in links[start:start + BATCH])
        statements.append(f"INSERT INTO {TABLE} (message_id, part_id, sha256) VALUES {values} ON CONFLICT DO NOTHING")
    return "BEGIN; " + "; ".join(statements) + "; COMMIT;"


def write_links(con, alias: str, links: list[tuple[str, str, str]]) -> None:
    sql = insert_sql(links).replace("'", "''")
    con.execute(f"CALL postgres_execute('{alias}', '{sql}')")


# --- A6c: the role's bounds, proven by attempt -------------------------------

PROBE_ROW = "('ffffffffffffffff', '999', '" + "f" * 64 + "')"


def _execute(con, alias: str, sql: str) -> str | None:
    """Run `sql` on the attached catalog; the error text, or None. After a
    failure the session is rolled back, so the next attempt starts clean."""
    try:
        con.execute(f"CALL postgres_execute('{alias}', '{sql.replace(chr(39), chr(39) * 2)}')")
        return None
    except Exception as exc:  # noqa: BLE001
        try:
            con.execute(f"CALL postgres_execute('{alias}', 'ROLLBACK')")
        except Exception:  # noqa: BLE001 - nothing to roll back
            pass
        return str(exc) or type(exc).__name__


def _refused(error: str | None) -> tuple[bool, str]:
    if error is None:
        return False, "it SUCCEEDED"
    if "permission denied" in error.lower():
        return True, "permission denied"
    return False, "not a permission refusal"


def prove_bounds(con, alias: str, role: str = "gmail_linker") -> list[tuple[str, bool, str]]:
    """Security's A6c (c75393 on #11557), as the role itself, over `con` with
    the role's DSN attached as `alias`. Every write runs inside a transaction
    that is always rolled back, so even a wrong grant leaves no row."""
    results = []
    insert = f"INSERT INTO {TABLE} (message_id, part_id, sha256) VALUES {PROBE_ROW}"
    error = _execute(con, alias, f"BEGIN; {insert}; {insert} ON CONFLICT DO NOTHING; ROLLBACK;")
    results.append((
        "Gmail linker role can INSERT, and INSERT ... ON CONFLICT DO NOTHING of an existing key succeeds",
        error is None,
        "both inserts ran, rolled back" if error is None else ("permission denied" if "permission denied" in error.lower() else "failed"),
    ))
    for label, sql in (
        ("SELECT", f"SELECT 1 FROM {TABLE} LIMIT 1"),
        ("UPDATE", f"BEGIN; UPDATE {TABLE} SET part_id = '0' WHERE false; ROLLBACK;"),
        ("DELETE", f"BEGIN; DELETE FROM {TABLE} WHERE false; ROLLBACK;"),
    ):
        ok, detail = _refused(_execute(con, alias, sql))
        results.append((f"Gmail linker role CANNOT {label} gmail_attachment_links", ok, detail))

    # From pg_catalog, which every role can read: an attached catalog's
    # information_schema lists only the tables the role holds a privilege on,
    # which for this role is its own one table.
    others = sorted(
        r[0] for r in con.execute(
            f"SELECT * FROM postgres_query('{alias}', "
            "'SELECT tablename FROM pg_catalog.pg_tables WHERE schemaname = ''public''')"
        ).fetchall()
        if r[0] != TABLE.split(".", 1)[1]
    )
    if not others:
        results.append(("Gmail linker role CANNOT insert into another catalog table", False, "no other table to probe"))
    else:
        target = others[0]
        ok, detail = _refused(_execute(con, alias, f'BEGIN; INSERT INTO public."{target}" DEFAULT VALUES; ROLLBACK;'))
        results.append(("Gmail linker role CANNOT insert into another catalog table", ok, f"{target}: {detail}"))

    owned = con.execute(
        f"SELECT count(*) FROM postgres_query('{alias}', "
        f"'SELECT 1 FROM pg_catalog.pg_class c JOIN pg_catalog.pg_roles r ON r.oid = c.relowner "
        f"WHERE r.rolname = current_user')"
    ).fetchone()[0]
    results.append(("Gmail linker role owns no table", owned == 0, f"{owned} relation(s) owned"))
    flags = con.execute(
        f"SELECT * FROM postgres_query('{alias}', "
        f"'SELECT rolname, rolsuper, rolcreaterole, rolcreatedb, rolbypassrls FROM pg_catalog.pg_roles "
        f"WHERE rolname = current_user')"
    ).fetchone()
    results.append((
        f"Gmail linker connects as {role}, with no superuser, create or bypass flag",
        flags is not None and flags[0] == role and not any(flags[1:]),
        f"role {flags[0] if flags else None}",
    ))
    return results


def main(argv: list[str] | None = None, env=None) -> int:
    argv = sys.argv[1:] if argv is None else argv
    env = os.environ if env is None else env
    if len(argv) != 1:
        print(f"usage: {LOG.rstrip(':')} <links.json>", file=sys.stderr)
        return EXIT_REFUSED
    dsn = env.get(ENV_DSN, "")
    if not dsn or dsn == "pending":
        print(f"{LOG} {ENV_DSN} is not set (run 'lake-skeleton.sh up'); wrote nothing", file=sys.stderr)
        return EXIT_NO_DSN
    try:
        with open(argv[0], encoding="utf-8") as fh:
            links = load_links(fh.read())
    except OSError as exc:
        print(f"{LOG} cannot read the links file ({type(exc).__name__}); wrote nothing", file=sys.stderr)
        return EXIT_REFUSED
    except BadLinks as exc:
        print(f"{LOG} refused: {exc}; wrote nothing", file=sys.stderr)
        return EXIT_REFUSED
    if not links:
        print(f"{LOG} 0 links in the run; nothing to write")
        return 0

    import duckdb

    con = duckdb.connect()
    con.execute("LOAD postgres")
    try:
        con.execute(f"ATTACH '{dsn}' AS cat (TYPE postgres)")
        write_links(con, "cat", links)
    except Exception as exc:  # noqa: BLE001 - never echo the DSN; the type is enough
        print(f"{LOG} catalog write failed ({type(exc).__name__}); nothing committed", file=sys.stderr)
        return EXIT_REFUSED
    print(f"{LOG} {len(links)} link(s) written or already present")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
