"""Tests for scripts/lib/plan-estimate.py and scripts/plan-estimate.sh (#738):
the plan's structured estimate line, read back, and the impact comparison line."""
import ast
import importlib.util
import json
import shutil
import subprocess
import time
from pathlib import Path

import pytest

REPO = Path(__file__).resolve().parent.parent
LIB = REPO / "scripts" / "lib" / "plan-estimate.py"
SH = REPO / "scripts" / "plan-estimate.sh"
FIX = REPO / "tests" / "fixtures" / "plan-estimate"


def _load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


pe = _load("plan_estimate", LIB)

KEYS = {"schema", "status", "source", "changed", "line", "text", "est", "tok",
        "meta", "scope", "problems"}
NOTE = ("interim: actuals stop at the impact step and count only the "
        "transcripts cost-report read")


def _fix(name):
    return pe.read_file(FIX / name)


def _bounds(c):
    return (c["class"], c["low"], c["high"])


def _section(*lines, heading="### Size estimate"):
    return "\n".join(["# Issue-1: inline", "", heading, *lines, ""])


def _run(*args):
    return subprocess.run(["bash", str(SH), *map(str, args)],
                          capture_output=True, text=True, check=False)


# 1-5: the named cases

def test_confirmed_estimate_wins_when_tighten_changed_it():
    r = _fix("confirmed-changed.md")
    assert (r["status"], r["source"], r["changed"]) == ("present", "confirmed", True)
    assert _bounds(r["est"]) == ("time", 4, 6)
    assert _bounds(r["tok"]) == ("tokens", 10000000, 14000000)
    assert r["scope"]["est"]["raw"] == "3-5h"
    assert r["text"] == "- Estimate (confirmed): {est: 4-6h, tok: 10-14M}"
    lines = (FIX / "confirmed-changed.md").read_text(encoding="utf-8").split("\n")
    assert lines[r["line"] - 1] == r["text"]
    for decoy in ("90-99h", "1-2h", "7-8h", "50-60h"):
        assert decoy not in json.dumps(r["meta"]) + json.dumps(r["scope"])


def test_scope_estimate_stands_when_tighten_did_not_change_it():
    r = _fix("confirmed-same.md")
    assert (r["source"], r["changed"]) == ("confirmed", False)
    assert (r["est"]["low"], r["est"]["high"]) == (8, 8)
    assert (r["tok"]["low"], r["tok"]["high"]) == (500000, 500000)
    r = _fix("scope-only.md")
    assert (r["status"], r["source"], r["changed"], r["scope"]) == (
        "present", "scope", None, None)
    assert r["tok"]["class"] == "placeholder"


def test_latest_revision_wins():
    r = _fix("two-revisions.md")
    assert (r["source"], r["changed"]) == ("confirmed", False)
    assert (r["est"]["low"], r["est"]["high"]) == (16, 24)
    assert (r["tok"]["low"], r["tok"]["high"]) == (30000000, 40000000)
    r = pe.read_estimate(_section(
        "- Estimate (scope): {est: 1h, tok: 1M}",
        "- Estimate (confirmed): {est: 2h, tok: 2M}",
        "- Estimate (scope): {est: 3h, tok: 3M}"))
    assert (r["status"], r["source"]) == ("present", "scope")
    assert (r["est"]["raw"], r["tok"]["raw"]) == ("3h", "3M")


def test_legacy_prose_is_absent():
    text = (FIX / "legacy-prose.md").read_text(encoding="utf-8")
    assert sum(1 for x in text.split("\n") if x.startswith("- ")) >= 5
    r = pe.read_estimate(text)
    assert r["status"] == "absent"
    assert r["problems"] == []
    for k in KEYS - {"schema", "status", "problems"}:
        assert r[k] is None, k


def test_quoted_format_is_absent():
    r = _fix("quoted-format.md")
    assert (r["status"], r["problems"]) == ("absent", [])


# 6-15: the edges

NEAR_MISSES = [
    "- Estimate (scope): est 3-5h, tok 8-12M",
    "- Estimate (scope): {est: 3-5h, tok: 8-12M} (rough)",
    "- estimate (scope): {est: 3-5h, tok: 8-12M}",
    "Estimate (scope): {est: 3-5h, tok: 8-12M}",
    "- Estimate(scope): {est: 3-5h, tok: 8-12M}",
    # Final review #1: a braced est/tok block under a drifted label, in the section.
    "- Estimate: {est: 3-5h, tok: 8-12M}",
    "- Scope estimate: {est: 3-5h, tok: 8-12M}",
    "- Estimated (scope): {est: 3-5h, tok: 8-12M}",
    "- {est: 3-5h, tok: 8-12M}",
    "- {tok: 8-12M}",
]


def test_braced_block_outside_the_section_is_not_an_estimate():
    r = pe.read_estimate(_section("- [ ] leaf {est: 3h, tok: 1M}", heading="## Tasks"))
    assert (r["status"], r["problems"]) == ("absent", [])


@pytest.mark.parametrize("bad", NEAR_MISSES)
def test_last_estimate_shaped_line_decides(bad):
    r = pe.read_estimate(_section(bad))
    assert (r["status"], r["line"], r["text"]) == ("unreadable", 4, bad)
    assert [p["line"] for p in r["problems"]] == [4]
    assert r["source"] is None and r["est"] is None and r["meta"] is None


def test_near_miss_fixture_and_order():
    r = _fix("near-miss.md")
    assert (r["status"], r["line"]) == ("unreadable", 1)
    assert len(r["problems"]) == 1
    good = "- Estimate (scope): {est: 3-5h, tok: 8-12M}"
    bad = "- Estimate (confirmed): {est: 4-6h, tok: 10-14M} plus a note"
    r = pe.read_estimate(_section(good, bad))
    assert (r["status"], r["line"]) == ("unreadable", 5)
    r = pe.read_estimate(_section(bad, good))
    assert (r["status"], r["source"], r["line"]) == ("present", "scope", 5)
    assert len(r["problems"]) == 1 and r["problems"][0]["line"] == 4


@pytest.mark.parametrize("line,heading", [
    ("- **Estimate (scope):** {est: 3-5h, tok: 8-12M}", "### Size estimate"),
    ("- **Estimate (scope)**: {est: 3-5h, tok: 8-12M}", "### Size estimate"),
    ("- Estimate (scope): `{est: 3-5h, tok: 8-12M}`", "### Size estimate"),
    ("- Estimate (scope): {est: \"3-5h\", tok: '8-12M'}", "### Size estimate"),
    ("* Estimate (scope): {est: 3-5h, tok: 8-12M}", "### Size estimate"),
    ("+ Estimate (scope): {est: 3-5h, tok: 8-12M}", "### Size estimate"),
    ("- Estimate (scope): {est: 3-5h, tok: 8-12M}", "## Size estimate"),
    ("- Estimate (scope): {est: 3-5h, tok: 8-12M}", "### Size estimate (revision 2)"),
])
def test_wrappers_models_write_are_read(line, heading):
    r = pe.read_estimate(_section(line, heading=heading))
    assert (r["status"], r["source"]) == ("present", "scope")
    assert _bounds(r["est"]) == ("time", 3, 5)
    assert _bounds(r["tok"]) == ("tokens", 8000000, 12000000)


def test_line_under_another_heading_is_not_an_estimate():
    # Tighten amendment A7 overrides test 7's `absent`: an estimate-shaped
    # line outside a size section is reported, never silently absent.
    r = pe.read_estimate(_section("- Estimate (scope): {est: 3-5h, tok: 8-12M}",
                                  heading="### Sizing"))
    assert (r["status"], r["line"], r["source"]) == ("unreadable", 4, None)
    assert len(r["problems"]) == 1


def test_values_go_through_the_one_classifier(monkeypatch):
    calls = []
    sentinel = {"sentinel": True}

    def fake(key, value):
        calls.append((key, value))
        return sentinel

    monkeypatch.setattr(pe.wbs_parser, "classify_estimate", fake)
    r = pe.read_estimate(_section("- Estimate (scope): {est: \" 3-5h \", tok: 8-12M}"))
    assert r["est"] is sentinel and r["tok"] is sentinel
    assert calls == [("est", "3-5h"), ("tok", "8-12M")]


def test_non_string_values_reach_the_classifier_unchanged(monkeypatch):
    calls = []
    monkeypatch.setattr(pe.wbs_parser, "classify_estimate",
                        lambda k, v: calls.append((k, v)) or {"class": "x"})
    pe.read_estimate(_section("- Estimate (scope): {est: [1h, 2h], tok: 1M}"))
    assert calls == [("est", ["1h", "2h"]), ("tok", "1M")]


@pytest.mark.parametrize("body,est,tok", [
    ("{est: ?, tok: 12000000}", "placeholder", "unparseable"),
    ("{est: 30m}", "non-time", "absent"),
    ("{est: [1h, 2h], tok: 1M}", "unparseable", "tokens"),
])
def test_non_estimates_are_reported_per_key(body, est, tok):
    r = pe.read_estimate(_section(f"- Estimate (scope): {body}"))
    assert r["status"] == "present"
    assert (r["est"]["class"], r["tok"]["class"]) == (est, tok)


def test_unknown_keys_pass_through():
    r = pe.read_estimate(_section(
        "- Estimate (scope): {tok: 8-12M, prod: 400, est: 3-5h, tests: 600}"))
    assert r["status"] == "present"
    assert set(r["meta"]) == {"tok", "prod", "est", "tests"}
    assert (r["est"]["class"], r["tok"]["class"]) == ("time", "tokens")


def test_crlf_bytes_read_as_lf(tmp_path):
    lf = (FIX / "confirmed-changed.md").read_bytes()
    crlf = tmp_path / "crlf.md"
    crlf.write_bytes(lf.replace(b"\n", b"\r\n"))
    assert pe.read_file(crlf) == _fix("confirmed-changed.md")


def test_result_has_exactly_the_contract_keys():
    for name, status in (("confirmed-changed.md", "present"),
                         ("legacy-prose.md", "absent"),
                         ("near-miss.md", "unreadable")):
        r = _fix(name)
        assert set(r) == KEYS
        assert (r["schema"], r["status"]) == (1, status)
        assert all(isinstance(p["line"], int) for p in r["problems"])


IMPACT_FORMS = {
    "confirmed-changed.md": (
        "- Estimate vs actual (interim): agent time est 4-6h vs actual <agent wall>; "
        "tokens est 10-14M vs actual <cost> [estimate confirmed, changed from scope; "
        + NOTE + "]"),
    "confirmed-same.md": (
        "- Estimate vs actual (interim): agent time est 8h vs actual <agent wall>; "
        "tokens est 0.5M vs actual <cost> [estimate confirmed, unchanged; " + NOTE + "]"),
    "scope-only.md": (
        "- Estimate vs actual (interim): agent time est 3-5h vs actual <agent wall>; "
        "tokens est not measured (tok is a placeholder) vs actual <cost> "
        "[estimate not confirmed; " + NOTE + "]"),
    "legacy-prose.md": "- Estimate vs actual (interim): no structured estimate",
    "near-miss.md": (
        "- Estimate vs actual (interim): not measured "
        "(estimate line unreadable at plan line 1)"),
}


def test_impact_line_forms():
    for name, want in IMPACT_FORMS.items():
        assert pe.impact_line(_fix(name)) == want, name
    orphan = pe.read_estimate(_section("- Estimate (confirmed): {est: 30m}"))
    assert pe.impact_line(orphan) == (
        "- Estimate vs actual (interim): agent time est not measured "
        "(est is not in h, d or w) vs actual <agent wall>; tokens est not measured "
        "(no tok value) vs actual <cost> [estimate confirmed, no scope line; "
        + NOTE + "]")
    assert pe.IMPACT_LABEL == "- Estimate vs actual (interim):"
    assert pe.INTERIM_NOTE == NOTE


EXITS = {"confirmed-changed.md": 0, "confirmed-same.md": 0, "scope-only.md": 0,
         "two-revisions.md": 0, "legacy-prose.md": 1, "quoted-format.md": 1,
         "near-miss.md": 3, "unanchored.md": 3}


def _main(capsys, *args):
    """`main` in-process: (exit code, stdout, stderr)."""
    try:
        code = pe.main([str(a) for a in args])
    except SystemExit as e:
        code = e.code
    out, err = capsys.readouterr()
    return code, out, err


def test_cli_modes_exit_codes_and_streams(capsys):
    assert {p.name for p in FIX.glob("*.md")} == set(EXITS)
    for name, code in EXITS.items():
        path = FIX / name
        want = pe.read_file(path)
        outs = {}
        for args in ((path,), ("--json", path), ("--impact-line", path)):
            got, out, err = _main(capsys, *args)
            assert (got, err) == (code, ""), (name, args, err)
            assert out.endswith("\n") and out.count("\n") == 1
            assert "\r" not in out
            outs[args[0]] = out
        assert outs[path] == outs["--json"]
        assert json.loads(outs["--json"]) == want
        assert outs["--impact-line"] == pe.impact_line(want) + "\n"
    good = FIX / "near-miss.md"
    for args in ((FIX / "missing.md",), (FIX,), (), (good, good), ("--bogus", good),
                 ("--json", "--impact-line", good)):
        got, out, err = _main(capsys, *args)
        assert (got, out) == (2, ""), args
        assert err.splitlines()[-1].startswith("plan-estimate: "), (args, err)
        if args == (FIX / "missing.md",):
            assert "cannot read" in err


def test_wrapper_runs_the_module():
    path = FIX / "confirmed-changed.md"
    p = _run("--impact-line", path)
    assert (p.returncode, p.stderr) == (0, "")
    assert p.stdout == pe.impact_line(pe.read_file(path)) + "\n"
    p = _run(FIX / "missing.md")
    assert (p.returncode, p.stdout) == (2, "")


def test_hostile_line_is_fast():
    text = _section("- Estimate (scope): {" + "a" * 200000,
                    " " * 200000 + "x")
    t = time.monotonic()
    pe.read_estimate(text)
    assert time.monotonic() - t < 2


def test_hostile_heading_and_unclosed_fences_are_fast():
    t = time.monotonic()
    pe.read_estimate(_section("# a" + " " * 200000 + "x"))
    pe.read_estimate(_section(*["```py"] * 8000))
    assert time.monotonic() - t < 2


def test_unclosed_fence_hides_what_follows():
    r = pe.read_estimate(_section("```text", "- Estimate (scope): {est: 3-5h, tok: 8-12M}"))
    assert r["status"] == "absent"


# 16-20: tighten additions

def test_crash_exits_4_not_absent(tmp_path):
    # A copy of the reader and its wrapper beside a parser that fails to load.
    (tmp_path / "lib").mkdir()
    shutil.copy(SH, tmp_path / SH.name)
    shutil.copy(LIB, tmp_path / "lib" / LIB.name)
    (tmp_path / "lib" / "wbs-parser.py").write_text(
        "raise RuntimeError('planted')\n", encoding="utf-8")
    p = subprocess.run(["bash", str(tmp_path / SH.name), str(FIX / "confirmed-changed.md")],
                       capture_output=True, text=True, check=False,
                       env={"PATH": "/usr/bin:/bin"})
    assert (p.returncode, p.stdout) == (4, "")
    assert p.stderr == "plan-estimate: internal error: RuntimeError: planted\n"


def test_meta_walk_problems_are_reported():
    r = pe.read_estimate(_section("- Estimate (scope): {est: 3-5h tok: 8-12M}"))
    assert r["status"] == "present"
    assert any("','" in p["message"] and p["line"] == 4 for p in r["problems"])
    # Final review #2: a fixed reason (no `;` or quotes from the walk), for both keys.
    assert pe.impact_line(r) == (
        "- Estimate vs actual (interim): agent time est not measured "
        "(est block problem at plan line 4) vs actual <agent wall>; tokens est not measured "
        "(tok block problem at plan line 4) vs actual <cost> [estimate not confirmed; "
        + NOTE + "]")
    r = pe.read_estimate(_section("- Estimate (scope): {est: 3-5h, tok: 1M, est: 4h}"))
    assert any("more than once" in p["message"] for p in r["problems"])
    assert r["est"]["raw"] == "4h"


def test_unanchored_labelled_lines_are_unreadable():
    r = _fix("unanchored.md")
    assert r["status"] == "unreadable"
    assert len(r["problems"]) == 3
    for line in ("1. Estimate (scope): {est: 3-5h, tok: 8-12M}",
                 "> - Estimate (scope): {est: 3-5h, tok: 8-12M}"):
        for heading in ("### Size estimate", "## Tasks"):
            r = pe.read_estimate(_section(line, heading=heading))
            assert (r["status"], r["line"]) == ("unreadable", 4), (line, heading)


def test_reader_source_parses_at_python_3_8():
    ast.parse(LIB.read_text(encoding="utf-8"), feature_version=(3, 8))


def test_est_forms_plan_fixture_is_absent():
    r = pe.read_file(REPO / "tests" / "fixtures" / "wbs" / "est-forms-plan.md")
    assert (r["status"], r["problems"]) == ("absent", [])


# Task 5: the spec's contract home (§13.7)

SPEC = REPO / "docs" / "specs" / "2026-05-19-devagent-plugin-design.md"


def _spec_section():
    text = SPEC.read_text(encoding="utf-8")
    start = text.index("### 13.7 Plan estimates (#738)")
    return text[start:text.index("\n## 14.", start)]


def _revision_1_rows(path):
    block = path.read_text(encoding="utf-8").split("## Revision 1", 1)[1].split("\n## ", 1)[0]
    return {step: f". {step}" in block for step in ("scope", "tighten", "impact")}


def test_spec_tier_table_matches_checklist_templates():
    rows = {}
    for line in _spec_section().split("\n"):
        cells = [c.strip() for c in line.strip().strip("|").split("|")]
        if len(cells) >= 4 and cells[1] in ("yes", "no") and line.startswith("|"):
            for tier in cells[0].split(","):
                assert tier.strip() not in rows, tier
                rows[tier.strip()] = {"scope": cells[1] == "yes",
                                      "tighten": cells[2] == "yes",
                                      "impact": cells[3] == "yes"}
    templates = sorted((REPO / "templates").glob("checklist-*.md"))
    assert len(templates) == 6
    assert set(rows) == {t.stem[len("checklist-"):] for t in templates}
    for t in templates:
        assert rows[t.stem[len("checklist-"):]] == _revision_1_rows(t), t.name


def test_spec_example_lines_are_read():
    section = _spec_section()
    fences = section.split("```")[1::2]
    example = next(f for f in fences if "Estimate (confirmed)" in f and "### Size estimate" in f)
    r = pe.read_estimate(example.split("\n", 1)[1])
    assert (r["status"], r["source"]) == ("present", "confirmed")
    assert pe.impact_line(_fix("confirmed-changed.md")) in section
    assert pe.impact_line(_fix("legacy-prose.md")) in section
    near = pe.impact_line(_fix("near-miss.md"))
    assert near.endswith("plan line 1)")
    assert near[: -len("1)")] in section
