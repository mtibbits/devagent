"""devagent's own requirements file (#915), docs/requirements.md, stays in shape.

This guards later edits; it is not a second reader. Gantry's reader
(gantry/requirements.py in mtibbits/gantry) is the authoritative check, run
once by hand when the file was written. Its format is
https://github.com/mtibbits/gantry/blob/main/docs/requirements-format.md.

The guard transcribes the reader's candidate rule (an ID-shaped list item that
is not a requirement) and its meta-block rule, with exactly two deliberate,
stricter deltas: it scans fenced lines too, and a requirement must start at
column 0 (the reader reports a nested item only under another item).

Standard library only: no gantry import, so the devagent suite stays
self-contained.
"""

import functools
import re
from collections import Counter
from pathlib import Path

import pytest

DOC = Path(__file__).resolve().parent.parent / "docs" / "requirements.md"
NAMESPACE = "devagent"
FORMAT_URL = "https://github.com/mtibbits/gantry/blob/main/docs/requirements-format.md"
# The source-of-truth claims, one anchor phrase each, matched on the normalised header.
SOT_PHRASES = ("derived once", "changes with the code", "not re-derived",
               "never renumbered or reused")
# Meta-block keys the format defines; a space-less `{refines:SR-2}` must not read as a namespace.
META_KEYS = {"needs", "refines"}
LAYER_CODES = ("BRule", "UC", "SR", "FR", "QA", "EI", "CON")  # Gantry's PROJECT_LAYERS

# Gantry's line grammar (gantry/requirements.py), with its ID_TOKEN_RE inlined.
ITEM_RE = re.compile(r"(?P<indent>[ \t]*)(?P<marker>[-*+]|[0-9]{1,9}[.)])(?:[ \t]+(?P<rest>.*)|)")  # fullmatch
CANDIDATE_RE = re.compile(  # .match on an item's rest
    r"(?P<open>[*_`~]*)"
    r"(?:(?P<namespace>[A-Za-z0-9][A-Za-z0-9_.-]*):)?"
    r"(?P<code>[A-Za-z]+)(?P<dash>-?)(?P<digits>[0-9]+)(?P<suffix>[A-Za-z]*)"
    r"(?P<close>[*_`~ \t]*):")
VALID_ID_RE = re.compile(r"(?:BRule|CON|UC|SR|FR|QA|EI)-[1-9][0-9]{0,8}")  # fullmatch
BLOCK_RE = re.compile(r"\{[ \t]*[A-Za-z_][A-Za-z0-9_]*[ \t]*:[^{}]*\}")  # finditer
KEY_RE = re.compile(r"[A-Za-z_][A-Za-z0-9_]*")
# A business-requirement ID, bare or qualified, anywhere in the text (fences included).
BR_TOKEN_RE = re.compile(r"(?<![A-Za-z0-9])BR-[0-9]")
QUALIFIED_RE = re.compile(
    r"(?P<namespace>[A-Za-z0-9][A-Za-z0-9_.-]*):(?:BRule|CON|UC|SR|FR|QA|EI|BR)-[0-9]")

UC_FLOOR = 9  # one use case per capability area in #915


# --- pure functions over text --------------------------------------------------


@functools.cache
def own_text():
    assert DOC.is_file(), "docs/requirements.md is missing"
    return DOC.read_bytes().decode("utf-8")


def split_lines(text):
    """Lines split at LF with one trailing CR removed, as Gantry's reader does:
    never str.splitlines(), which also breaks at form feed, U+2028 and others."""
    return [line[:-1] if line.endswith("\r") else line
            for line in text.removeprefix("\N{BYTE ORDER MARK}").split("\n")]


def _items(text):
    """(line number, ITEM_RE match, candidate match) for each ID-shaped item."""
    for n, line in enumerate(split_lines(text), start=1):
        m = ITEM_RE.fullmatch(line)
        if m is None or m["rest"] is None:
            continue
        c = CANDIDATE_RE.match(m["rest"])
        if c is not None:
            yield n, m, c


def _reason(m, c):
    """Why a candidate is not a requirement (the first that applies), or None."""
    if m["indent"]:
        return "nested"
    if m["marker"] not in ("-", "*", "+"):
        return "ordered"
    if c["open"].strip(" \t") or c["close"].strip(" \t"):
        return "marks"
    if c["namespace"] is not None:
        return "namespace"
    if c["close"]:
        return "space before the colon"
    if c["code"] not in LAYER_CODES:
        return "layer code"
    if not c["dash"]:
        return "dash"
    if c["digits"].startswith("0") or len(c["digits"]) > 9:
        return "number"
    if c["suffix"]:
        return "suffix"
    if not VALID_ID_RE.fullmatch(c["code"] + c["dash"] + c["digits"] + c["suffix"]):
        return "not an ID"
    return None


def id_problems(text):
    """One 'line N: <reason>' per ID-shaped item that is not a requirement,
    and per ID defined twice."""
    problems, first = [], {}
    for n, m, c in _items(text):
        why = _reason(m, c)
        if why is not None:
            problems.append(f"line {n}: {why}: {m['rest'][: c.end()]!r}")
            continue
        rid = c["code"] + "-" + c["digits"]
        if rid in first:
            problems.append(f"line {n}: {rid} is also defined on line {first[rid]}")
        else:
            first[rid] = n
    return problems


def requirements(text):
    """{bare ID: (line, joined text after the ID)} for the valid items. The
    joined text is the first line plus each following non-blank line that
    starts with a space or tab, joined with single spaces."""
    lines = split_lines(text)
    found = {}
    for n, m, c in _items(text):
        if _reason(m, c) is not None:
            continue
        rid = c["code"] + "-" + c["digits"]
        if rid in found:
            continue
        parts = [m["rest"][c.end():].strip()]
        k = n  # lines[k] is the line after line n
        while k < len(lines) and lines[k].strip() and lines[k][0] in " \t":
            parts.append(lines[k].strip())
            k += 1
        found[rid] = (n, parts)
    return {rid: (n, " ".join(p for p in parts if p)) for rid, (n, parts) in found.items()}


def _ending_block(text):
    last = None
    for last in BLOCK_RE.finditer(text):
        pass
    return last if last is not None and last.end() == len(text) else None


def _split(body, sep):
    """`body` split at `sep` outside [...] and quotes; None if a [ or quote is unclosed."""
    parts, current, depth, quote = [], [], 0, None
    for ch in body:
        if quote:
            if ch == quote:
                quote = None
        elif ch in "'\"":
            quote = ch
        elif ch == "[":
            depth += 1
        elif ch == "]":
            depth -= 1
            if depth < 0:
                return None
        elif ch == sep and depth == 0:
            parts.append("".join(current))
            current = []
            continue
        current.append(ch)
    if quote or depth:
        return None
    parts.append("".join(current))
    return parts


def _unquote(item):
    item = item.strip()
    if len(item) >= 2 and item[0] == item[-1] and item[0] in "'\"":
        return item[1:-1]
    return item


def _block_needs(block):
    """The needs list in a meta block: a list, or None with no readable needs key."""
    parts = _split(block[1:-1], ",")
    if parts is None:
        return None
    for entry in parts:
        key, colon, value = entry.partition(":")
        if not colon or not KEY_RE.fullmatch(key.strip()):
            return None
        if key.strip() != "needs":
            continue
        value = value.strip()
        if value.startswith("[") and value.endswith("]"):
            items = [_unquote(item) for item in _split(value[1:-1], ",") or []]
            return [item for item in items if item]
        return [_unquote(value)]
    return None


def _first_line_rest(text, line):
    m = ITEM_RE.fullmatch(split_lines(text)[line - 1])
    c = CANDIDATE_RE.match(m["rest"])
    return m["rest"][c.end():].strip()


def use_case_needs(text):
    """{UC ID: needs list, or None when no meta block holds a needs key}. The
    block is the one ending the first line, else the one ending the joined
    text, as Gantry's reader reads it."""
    out = {}
    for rid, (line, joined) in requirements(text).items():
        if not rid.startswith("UC-"):
            continue
        block = _ending_block(_first_line_rest(text, line)) or _ending_block(joined)
        needs = None if block is None else _block_needs(block.group(0))
        if needs is not None:
            needs = [n.removeprefix(NAMESPACE + ":") for n in needs]
        out[rid] = needs
    return out


def needs_problems(text):
    """One 'UC-n: <reason>' per use case whose needs are missing, empty, or
    name an ID this file does not define."""
    defined = requirements(text)
    problems = []
    for uc, needs in use_case_needs(text).items():
        if needs is None:
            problems.append(f"{uc}: no needs block")
        elif not needs:
            problems.append(f"{uc}: needs names no target")
        else:
            problems += [f"{uc}: needs {n}, which is not defined" for n in needs if n not in defined]
    return problems


def br_tokens(text):
    return BR_TOKEN_RE.findall(text)


def foreign_namespaces(text):
    return {m["namespace"] for m in QUALIFIED_RE.finditer(text)} - {NAMESPACE} - META_KEYS


def header(text):
    return re.split(r"(?m)^## ", text, maxsplit=1)[0]


def normalised(text):
    return " ".join(text.split()).casefold()


# --- the file ------------------------------------------------------------------


def test_file_exists():
    assert DOC.is_file(), "docs/requirements.md is missing"


def test_header_links_format_doc():
    assert f"]({FORMAT_URL})" in header(own_text())


def test_header_states_source_of_truth():
    text = normalised(header(own_text()))
    assert [p for p in SOT_PHRASES if p not in text] == []


def test_id_like_items_are_requirements():
    problems = id_problems(own_text())
    assert problems == [], "\n".join(problems)


def test_no_business_requirement_ids():
    assert br_tokens(own_text()) == []


def test_qualified_ids_are_devagent_only():
    assert foreign_namespaces(own_text()) == set()


def test_layer_floors():
    counts = Counter(rid.split("-")[0] for rid in requirements(own_text()))
    assert sum(counts.values()) > 0, "no requirements read"
    assert counts["UC"] >= UC_FLOOR, f"UC: {counts['UC']}"
    for code in ("SR", "FR", "QA", "EI", "CON"):
        assert counts[code] >= 1, f"{code}: {counts[code]}"


def test_every_use_case_needs_defined_ids():
    text = own_text()
    ucs = [rid for rid in requirements(text) if rid.startswith("UC-")]
    assert len(use_case_needs(text)) == len(ucs)
    assert len(ucs) >= UC_FLOOR, f"UC: {len(ucs)}"
    problems = needs_problems(text)
    assert problems == [], "\n".join(problems)


def test_no_html_comments():
    # The reader reads an ID item inside a comment as live, so the rendered
    # page and the read set would disagree.
    assert "<!--" not in own_text()


# --- planted controls: each leg can fail -----------------------------------------


@pytest.mark.parametrize("planted", [
    "- FR12: x", "- Fr-12: x", "- FR-012: x", "- NFR-4: x", "- FR-3a: x",
    "- FR-3 : x", "- **FR-3:** x", "- devagent:FR-3: x", "1. FR-3: x",
    "  - FR-3: x", "- BR-1: x", "- FR-1234567890: x", "- FR-3: a\n- FR-3: b",
])
def test_planted_bad_item_is_flagged(planted):
    assert len(id_problems(planted)) == 1, id_problems(planted)


@pytest.mark.parametrize("planted", [
    "- FR-3: x", "- BRule-1: x", "- CON-12: x", "- FR_1: x", "- **operator:** x",
    "- Step 1: x", "- FR-1: a\x0c- FR-1: b",
])
def test_planted_good_item_is_clean(planted):
    assert id_problems(planted) == []


def test_planted_scanners():
    planted = ("See life:BR-3 and harbor:FR-1.\n```text\n- BR-2: x\n```\n"
               "Not found: devagent:FR-1, BRule-1, https://example.org/FR-1. "
               "{refines:SR-2} {needs:[FR-1]}\n")
    assert br_tokens(planted) == ["BR-3", "BR-2"]
    assert foreign_namespaces(planted) == {"life", "harbor"}
    assert header("# T\nhead\n## S\nbody\n## U\n") == "# T\nhead\n"
    assert "derived once" in normalised("It was derived\n  once from notes.")


PLANTED_USE_CASES = """\
- FR-1: a behaviour.
- UC-1: no block at all.
- UC-2: an empty list. {needs: []}
- UC-3: an undefined target. {needs: [FR-9]}
- UC-4: the block ends a continuation line,
  which carries it. {needs: [FR-1]}
- UC-5: the block ends the first line. {needs: [FR-1]}
  and a continuation line follows.
- UC-6: a scalar. {needs: FR-1}
- UC-7: spaced. { needs : [FR-1] }
- UC-8: combined. {needs: [devagent:FR-1], refines: FR-1}
"""


def test_planted_use_case_needs():
    problems = needs_problems(PLANTED_USE_CASES)
    assert sorted(p.split(":")[0] for p in problems) == ["UC-1", "UC-2", "UC-3"], problems
