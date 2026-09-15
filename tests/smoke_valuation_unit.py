#!/usr/bin/env python3
"""Unit test for the valuation smoke check's assertion logic (#5921).

The acceptance for the smoke check is not just "passes on the fixed stack" — a
check that passes on a stack we know was broken is worthless. So this pins the
other half: the pure assertion functions REJECT the exact shapes today's pre-fix
stack returned (#5920's 404, #5919's 502), without re-breaking production to
prove it. If someone loosens an assertion until the check can no longer see those
failures, this reds.
"""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "scripts"))
import smoke_valuation_e2e as smoke  # noqa: E402

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


def main() -> int:
    print("contract assertion catches #5920:")
    test_contract_catches_5920_404()
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
