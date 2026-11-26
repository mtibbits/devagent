#!/usr/bin/env python3
"""The plan's structured estimate, read back (#738; spec §13.7).

The scope step writes `- Estimate (scope): {est: …, tok: …}` under the plan's
`### Size estimate` heading, and the tighten step writes
`- Estimate (confirmed): {…}` directly below it. This module finds those
lines; it owns no grammar of its own. The block is a WBS metadata block, read
by `wbs-parser.py`'s `_parse_meta_walk`, and each value is classified by its
`classify_estimate` (#737). Fenced lines are skipped by one linear pass over
`wbs-parser.py`'s `_FENCE_RE` (an opener with no closer runs to the end of the
file); the parser's own `_classify_lines` pairs fences in quadratic time on
unclosed openers, so it is not used here.

Reading rules: a heading whose text starts with `Size estimate` opens the
section and any other heading closes it. Inside it, a line that fullmatches
ESTIMATE_LINE_RE is an estimate line, and any other line that matches
ESTIMATE_NEAR_MISS_RE, or holds a `{` block with an `est` or `tok` key
(BRACED_ESTIMATE_RE: a drifted label), is a near-miss; the last of these decides (`present`,
or `unreadable` for a near-miss). With none, an estimate-shaped line anywhere
else outside a fence makes the result `unreadable`; with none at all it is
`absent`. `est` and `tok` come from the deciding line only. A confirmed line's
`changed` compares the classes and bounds of both values with the nearest
earlier scope line.

API: `read_estimate(text)`, `read_file(path)`, `impact_line(result)`.
CLI: `plan-estimate.sh [--json | --impact-line] <imPlan.md>`, exit 0 present,
1 absent, 3 unreadable (one stdout line each), 2 usage or unreadable file,
4 internal error. Stdlib only; reads nothing but the one path it is given.
"""
from __future__ import annotations

import argparse
import importlib.util
import json
import os
import re
import sys
from pathlib import Path

# Test use only: load the parser from another path (a planted import failure).
PARSER_ENV = "PLAN_ESTIMATE_WBS_PARSER"


def _load_parser():
    path = os.environ.get(PARSER_ENV) or str(Path(__file__).resolve().parent / "wbs-parser.py")
    spec = importlib.util.spec_from_file_location("_plan_estimate_wbs_parser", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


try:
    wbs_parser = _load_parser()
    _LOAD_ERROR: BaseException | None = None
except BaseException as exc:  # reported as exit 4 by main(); a library import raises
    if __name__ != "__main__":
        raise
    wbs_parser = None
    _LOAD_ERROR = exc

SCHEMA = 1
SECTION_TITLE = "Size estimate"
STATUSES = ("present", "absent", "unreadable")
EXIT_CODES = {"present": 0, "absent": 1, "unreadable": 3}
IMPACT_LABEL = "- Estimate vs actual (interim):"
INTERIM_NOTE = ("interim: actuals stop at the impact step and count only the "
                "transcripts cost-report read")

# A heading's marker; its text is the rest of the line less trailing ` \t#`.
HEADING_PREFIX_RE = re.compile(r" {0,3}#{1,6}[ \t]+")
ESTIMATE_LINE_RE = re.compile(
    r"[ \t]*[-*+][ \t]+\*{0,2}Estimate \((?P<kind>scope|confirmed)\)\*{0,2}:\*{0,2}"
    r"[ \t]*`?\{(?P<body>[^{}`]*)\}`?[ \t]*")
# Anything labelled like an estimate line: a bullet, a numbered item, a
# blockquote or bare text, any case. `.match`, so anchored at the line start.
ESTIMATE_NEAR_MISS_RE = re.compile(
    r"[ \t]*(?:>[ \t]*)*(?:(?:[-*+]|[0-9]{1,9}[.)])[ \t]+)?[*_`]{0,3}"
    r"Estimate[ \t]*\([ \t]*(?:scope|confirmed)\b", re.I)
# Inside a size section only: a `{…}` block with an est or tok key under any
# other label is an estimate written in the wrong form, never silently absent.
BRACED_ESTIMATE_RE = re.compile(r"\{[^{}]*\b(?:est|tok)[ \t]*:")

NEAR_MISS_MESSAGE = ("estimate-shaped line is not in the form "
                     "`- Estimate (scope|confirmed): {est: <time>, tok: <tokens>}`")
OUTSIDE_MESSAGE = "estimate-shaped line outside a `### Size estimate` section"
REASONS = {
    "est": {"absent": "no est value", "placeholder": "est is a placeholder",
            "non-time": "est is not in h, d or w"},
    "tok": {"absent": "no tok value", "placeholder": "tok is a placeholder"},
}
MEASURED = {"est": "time", "tok": "tokens"}


def _lines(text: str) -> list[str]:
    return [x[:-1] if x.endswith("\r") else x for x in text.split("\n")]


def _fenced(lines: list[str]) -> list[bool]:
    """True for each fence or code line: one pass, an unclosed fence runs to EOF."""
    out = [False] * len(lines)
    run = None
    for i, line in enumerate(lines):
        m = wbs_parser._FENCE_RE.match(line)
        if run is None:
            if m and not (m.group("run")[0] == "`" and "`" in m.group("info")):
                run = m.group("run")
                out[i] = True
            continue
        out[i] = True
        if (m and m.group("run")[0] == run[0] and len(m.group("run")) >= len(run)
                and not m.group("info").strip()):
            run = None
    return out


def _classify(meta: dict, key: str):
    value = meta.get(key)
    if isinstance(value, str):
        value = value.strip()
    return wbs_parser.classify_estimate(key, value)


def _empty(status: str, problems: list) -> dict:
    return {"schema": SCHEMA, "status": status, "source": None, "changed": None,
            "line": None, "text": None, "est": None, "tok": None, "meta": None,
            "scope": None, "problems": problems}


def read_estimate(text: str) -> dict:
    """The issue's estimate from a plan's text (C1 reading rules)."""
    lines = _lines(text)
    fenced = _fenced(lines)
    in_section = False
    entries: list[dict] = []  # in-section estimate lines and near-misses, in order
    outside: list[int] = []
    problems: list[dict] = []
    for idx, line in enumerate(lines):
        if fenced[idx]:
            continue
        lineno = idx + 1
        h = HEADING_PREFIX_RE.match(line)
        if h:
            in_section = line[h.end():].rstrip(" \t#").startswith(SECTION_TITLE)
            continue
        if in_section:
            m = ESTIMATE_LINE_RE.fullmatch(line)
            if m:
                meta, walk = wbs_parser._parse_meta_walk(m.group("body"))
                messages = [msg for _code, msg in walk]
                problems.extend({"line": lineno, "message": msg} for msg in messages)
                entries.append({"line": lineno, "text": line, "kind": m.group("kind"),
                                "meta": meta})
                continue
            if ESTIMATE_NEAR_MISS_RE.match(line) or BRACED_ESTIMATE_RE.search(line):
                problems.append({"line": lineno, "message": NEAR_MISS_MESSAGE})
                entries.append({"line": lineno, "text": line, "kind": None})
            continue
        if ESTIMATE_NEAR_MISS_RE.match(line):
            problems.append({"line": lineno, "message": OUTSIDE_MESSAGE})
            outside.append(lineno)
    if not entries:
        if not outside:
            return _empty("absent", problems)
        out = _empty("unreadable", problems)
        out["line"] = outside[-1]
        out["text"] = lines[outside[-1] - 1]
        return out
    win = entries[-1]
    if win["kind"] is None:
        out = _empty("unreadable", problems)
        out.update(line=win["line"], text=win["text"])
        return out
    out = _empty("present", problems)
    est, tok = _classify(win["meta"], "est"), _classify(win["meta"], "tok")
    out.update(source=win["kind"], line=win["line"], text=win["text"], est=est,
               tok=tok, meta=win["meta"])
    if win["kind"] == "confirmed":
        earlier = [e for e in entries[:-1] if e["kind"] == "scope"]
        if earlier:
            sc = earlier[-1]
            s_est, s_tok = _classify(sc["meta"], "est"), _classify(sc["meta"], "tok")
            out["scope"] = {"line": sc["line"], "est": s_est, "tok": s_tok}
            out["changed"] = any(
                (a.get("class"), a.get("low"), a.get("high"))
                != (b.get("class"), b.get("low"), b.get("high"))
                for a, b in ((est, s_est), (tok, s_tok)))
    return out


def read_file(path) -> dict:
    """`read_estimate` of a file read as UTF-8 (errors replaced, newlines kept).
    Raises OSError when the file cannot be read."""
    with open(path, encoding="utf-8", errors="replace", newline="") as fh:
        return read_estimate(fh.read())


def _value(key: str, c: dict, block_problem_at: int | None) -> str:
    if c.get("class") == MEASURED[key]:
        return c["raw"]
    if block_problem_at is not None:
        # A fixed reason: the walk's own message can hold `;` and quotes.
        return f"not measured ({key} block problem at plan line {block_problem_at})"
    return f"not measured ({REASONS[key].get(c.get('class'), f'{key} is unparseable')})"


def impact_line(result: dict) -> str:
    """The impact step's comparison line, with `<agent wall>` and `<cost>` slots."""
    status = result["status"]
    if status == "absent":
        return f"{IMPACT_LABEL} no structured estimate"
    if status == "unreadable":
        return f"{IMPACT_LABEL} not measured (estimate line unreadable at plan line {result['line']})"
    # Only the block walk can report a problem on the deciding line itself.
    at = result["line"] if any(p["line"] == result["line"] for p in result["problems"]) else None
    if result["source"] == "scope":
        mark = "estimate not confirmed"
    elif result["changed"] is None:
        mark = "estimate confirmed, no scope line"
    elif result["changed"]:
        mark = "estimate confirmed, changed from scope"
    else:
        mark = "estimate confirmed, unchanged"
    return (f"{IMPACT_LABEL} agent time est {_value('est', result['est'], at)} "
            f"vs actual <agent wall>; tokens est {_value('tok', result['tok'], at)} "
            f"vs actual <cost> [{mark}; {INTERIM_NOTE}]")


def _parse_args(argv):
    ap = argparse.ArgumentParser(
        prog="plan-estimate",
        description="Read the structured estimate from a plan (imPlan.md).")
    mode = ap.add_mutually_exclusive_group()
    mode.add_argument("--json", action="store_true", help="print the result as JSON (default)")
    mode.add_argument("--impact-line", action="store_true",
                      help="print the impact step's comparison line")
    ap.add_argument("path", help="the plan file")
    return ap.parse_args(argv)


def main(argv=None) -> int:
    try:
        if _LOAD_ERROR is not None:
            raise _LOAD_ERROR
        args = _parse_args(argv)
        try:
            result = read_file(args.path)
        except OSError as e:
            sys.stderr.write(f"plan-estimate: cannot read {args.path}: {e.strerror or e}\n")
            return 2
        out = impact_line(result) if args.impact_line else json.dumps(
            result, ensure_ascii=False)
        sys.stdout.reconfigure(encoding="utf-8", newline="\n")
        sys.stdout.write(out + "\n")
        sys.stdout.flush()
        return EXIT_CODES[result["status"]]
    except SystemExit:
        raise
    except BaseException as e:  # never let a crash read as `absent` (exit 1)
        sys.stderr.write(f"plan-estimate: internal error: {type(e).__name__}: {e}\n")
        return 4


if __name__ == "__main__":
    sys.exit(main())
