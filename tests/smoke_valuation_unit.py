#!/usr/bin/env python3
"""Unit test for the valuation smoke check's assertion logic (#5921).

The acceptance for the smoke check is not just "passes on the fixed stack" — a
check that passes on a stack we know was broken is worthless. So this pins the
other half: the pure assertion functions REJECT the exact shapes today's pre-fix
stack returned (#5920's 404, #5919's 502), without re-breaking production to
prove it. If someone loosens an assertion until the check can no longer see those
failures, this reds.
"""
import os
import re
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "scripts"))
import smoke_valuation_e2e as smoke  # noqa: E402

# The aspirant-client checkout whose origin/main the contract is reconciled against.
# It is read with `git grep origin/main`, so a shared checkout sitting on another
# agent's branch does not change the answer.
CLIENT_DIR = Path(os.environ.get("ASPIRANT_CLIENT_DIR", "/home/aspirant/aspirant-client"))
CLIENT_REF = os.environ.get("ASPIRANT_CLIENT_REF", "origin/main")
_PREFIX = "/api/commander/valuation-statement"

PASSED = 0
FAILED = 0


def check(cond: bool, label: str) -> None:
    global PASSED, FAILED
    if cond:
        PASSED += 1
        print(f"  ok    {label}")
    else:
        FAILED += 1
        print(f"  FAIL  {label}")


def test_contract_catches_5920_404():
    # The whole of #5920: /decide answered 404 (no route) where a registered route
    # answers 401. The contract assertion must reject the 404 and accept the 401.
    check(smoke.contract_route_ok(401) is True, "401 (route present, auth required) passes")
    check(smoke.contract_route_ok(404) is False, "404 (missing hop, #5920) fails")
    check(smoke.contract_route_ok(200) is True, "200 passes (route present)")


def test_extract_catches_5919_502():
    # The whole of #5919: a valid Member upload 502'd at the 30s ceiling. Any
    # non-200 from /extract must fail the check, and it must name the failure.
    expect = {"ocr_used": True, "min_filled": 0, "outcomes": {"no_text", "partial"}}
    errs_502 = smoke.extract_ok(expect, 502, {})
    check(bool(errs_502), "502 from extract fails (the #5919 symptom)")
    check(any("502" in e or "504" in e for e in errs_502), "the 502/504 failure is named")
    errs_504 = smoke.extract_ok(expect, 504, {})
    check(bool(errs_504), "504 (genuine timeout) also fails")


def test_extract_field_floor():
    # A 200 that came back empty when fields were expected is still a failure —
    # a green HTTP status is not a working extraction (the #5915 lesson).
    expect = {"ocr_used": True, "min_filled": 3, "outcomes": {"partial", "extracted"}}
    empty = {"diagnostics": {"ocr_used": True, "outcome": "partial"}, "fields": []}
    check(bool(smoke.extract_ok(expect, 200, empty)), "200 with 0 fields fails when 3 expected")
    good = {"diagnostics": {"ocr_used": True, "outcome": "partial"},
            "fields": [{"key": "a", "value": "x"}, {"key": "b", "value": "y"}, {"key": "c", "value": "z"}]}
    check(smoke.extract_ok(expect, 200, good) == [], "200 with 3 filled fields passes")


def test_extract_ocr_flag_and_outcome():
    expect = {"ocr_used": True, "min_filled": 0, "outcomes": {"no_text"}}
    # ocr_used mismatch is a real regression (OCR silently stopped running).
    doc = {"diagnostics": {"ocr_used": False, "outcome": "no_text"}, "fields": []}
    check(bool(smoke.extract_ok(expect, 200, doc)), "ocr_used=False fails when OCR expected")
    # An unexpected outcome (e.g. unrecognised where no_text expected) fails.
    doc2 = {"diagnostics": {"ocr_used": True, "outcome": "unrecognised"}, "fields": []}
    check(bool(smoke.extract_ok(expect, 200, doc2)), "unexpected outcome fails")


def test_decide_classification():
    # decide must classify: a raster scan reported as digital (ocr_required False)
    # is the kind of cross-service drift this check exists to catch.
    expect = {"ocr_required": True, "subkind": "raster_scan"}
    check(smoke.decide_ok(expect, {"ocr_required": True, "no_text_subkind": "raster_scan"}) == [],
          "correct scan classification passes")
    check(bool(smoke.decide_ok(expect, {"ocr_required": False, "no_text_subkind": None})),
          "a scan misreported as digital fails")


def test_contract_list_covers_the_client_endpoints():
    # The contract list must name /decide and GET operator-defaults — the two hops
    # #5920 was missing. If a future edit drops one from the list, the served-surface
    # probe can no longer see its absence, so pin their presence here.
    paths = {p for _, p in smoke.CLIENT_COMMANDER_CONTRACT}
    check("/api/commander/valuation-statement/decide" in paths, "contract lists /decide")
    check(("GET", "/api/commander/valuation-statement/operator-defaults") in smoke.CLIENT_COMMANDER_CONTRACT,
          "contract lists GET operator-defaults")


def test_async_submit():
    # #8246: the async hop must be checked, and its 404 is the silent one, because
    # the client falls back to the sync /extract on exactly that status.
    job, errs = smoke.submit_ok(404, {})
    check(job is None and any("5920" in e for e in errs), "submit 404 fails, naming the #5920 class")
    job, errs = smoke.submit_ok(202, {"job_id": "abc"})
    check(job == "abc" and errs == [], "submit 202 with job_id passes")
    job, errs = smoke.submit_ok(202, {})
    check(job is None and bool(errs), "submit 202 without job_id fails")
    job, errs = smoke.submit_ok(502, {"job_id": "abc"})
    check(job is None and bool(errs), "submit 502 fails")


def test_job_poll_states():
    check(smoke.job_state(200, {"status": "done", "result": {"documents": [{}]}})[0] == "done",
          "done job is terminal-done")
    st, detail = smoke.job_state(200, {"status": "failed", "error": "boom"})
    check(st == "failed" and detail == "boom", "failed job is terminal-failed and carries its error")
    check(smoke.job_state(200, {"status": "running"})[0] == "pending", "running job keeps polling")
    check(smoke.job_state(502, {})[0] == "pending", "transient 502 keeps polling, as the client does")
    check(smoke.job_state(404, {})[0] == "fatal", "404 (job gone / not the caller's, #5986) is fatal")
    check(smoke.job_state(401, {})[0] == "fatal", "401 (session gone) is fatal")


def _normalise(path: str) -> str:
    path = path.split("?", 1)[0]
    path = re.sub(r"\$\{[^}]*\}", ":id", path)
    return path.replace("smoke-probe-id", ":id")


def client_paths() -> set[str] | None:
    """Every commander valuation path the client's source calls, normalised (query
    dropped, `${...}` and the contract's probe id both read as `:id`). Matched only
    when the path opens a string literal, so prose mentions in comments are skipped.
    None when the client source cannot be read."""
    try:
        out = subprocess.run(
            ["git", "-C", str(CLIENT_DIR), "grep", "-h", "-o", "-E",
             r"""[`'"]/api/commander/valuation-statement[^`'"]*""", CLIENT_REF, "--", "src"],
            capture_output=True, text=True, timeout=30)
    except (OSError, subprocess.TimeoutExpired):
        return None
    if out.returncode != 0:
        return None
    return {_normalise(m[1:]) for m in out.stdout.split()}


def missing_from_contract(paths: set[str], contract) -> set[str]:
    return paths - {_normalise(p) for _, p in contract}


def test_contract_reconciles_with_the_client():
    # #8246: line 71's "the reconcile check" did not exist until now, which is how
    # extract-async and jobs/:id went unlisted. Method-agnostic on purpose: the
    # client splits URLs across lines and picks one by ternary, so a method
    # parse would be the fragile part. A path the contract lacks is a hop Part A
    # cannot see go missing.
    paths = client_paths()
    if paths is None:
        # Fail closed: a reconcile that cannot read the client reads green otherwise.
        check(False, f"client source readable at {CLIENT_DIR} ({CLIENT_REF}); "
                     "set ASPIRANT_CLIENT_DIR to an aspirant-client checkout")
        return
    # Positive control: the client is known to call /decide, so an empty or
    # wrong-root read cannot pass as "nothing missing".
    check(f"{_PREFIX}/decide" in paths, f"reconcile read the client ({len(paths)} paths)")
    missing = missing_from_contract(paths, smoke.CLIENT_COMMANDER_CONTRACT)
    check(not missing, "every client path is in the contract"
          + (f"; missing {sorted(missing)}" if missing else ""))
    # Negative control: the pre-#8246 contract (without the async hops) must red.
    pre = [(m, p) for m, p in smoke.CLIENT_COMMANDER_CONTRACT
           if "extract-async" not in p and "/jobs/" not in p]
    check(missing_from_contract(paths, pre) == {f"{_PREFIX}/extract-async", f"{_PREFIX}/jobs/:id"},
          "the pre-#8246 contract reds on exactly extract-async and jobs/:id")


def main() -> int:
    print("contract assertion catches #5920:")
    test_contract_catches_5920_404()
    print("async submit (#8246):")
    test_async_submit()
    print("job poll states (#8246):")
    test_job_poll_states()
    print("contract reconciles with the client source (#8246):")
    test_contract_reconciles_with_the_client()
    print("extract assertion catches #5919:")
    test_extract_catches_5919_502()
    print("a green status with no fields is still a failure:")
    test_extract_field_floor()
    print("ocr flag + outcome:")
    test_extract_ocr_flag_and_outcome()
    print("decide classification:")
    test_decide_classification()
    print("contract list completeness:")
    test_contract_list_covers_the_client_endpoints()

    print()
    if FAILED:
        print(f"FAILED: {FAILED} failed, {PASSED} passed")
        return 1
    print(f"{PASSED} passed, 0 failed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
