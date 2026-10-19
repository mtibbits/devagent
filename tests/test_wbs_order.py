"""Tests for the WBS order pass (#803): order_text, permuted_only, writers."""
import importlib.util
from pathlib import Path

import pytest

REPO = Path(__file__).resolve().parent.parent
FIX = REPO / "tests" / "fixtures" / "wbs"


def _load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


wbs_parser = _load("wbs_parser", REPO / "scripts" / "lib" / "wbs-parser.py")
wbs_bytes = _load("wbs_bytes", REPO / "tests" / "helpers" / "wbs_bytes.py")

# Every order_text input below, by name: test_permuted_only_accepts_order_text_output
# runs the check over each of them (and each EOL variant).
CASES: dict[str, tuple[str, bool]] = {}


def _doc(*lines):
    return "".join(line + "\n" for line in lines)


def _case(name, *lines, cl=False):
    text = _doc(*lines)
    CASES[name] = (text, cl)
    return text


def _ord(text, cl=False):
    out, warnings = wbs_parser.order_text(text, completed_last=cl)
    return out.splitlines(), warnings


def _counts(text, cl=False):
    _out, _warnings, n, m = wbs_parser._order(text, cl)
    return n, m


PRIORITY_WARN = "line {}: priority '{}' is not P1, P2, P3 or P4; ignored"


# --- Task 2: the rule ---------------------------------------------------------

DEP_BEATS_PRIORITY = _case(
    "dep_beats_priority",
    "- [ ] E",
    "  - [ ] S {issue: S, priority: P1, depends_on: T}",
    "  - [ ] T {issue: T, priority: P4}",
)


def test_dependency_beats_priority():
    lines, warnings = _ord(DEP_BEATS_PRIORITY)
    assert lines == [
        "- [ ] E",
        "  - [ ] T {issue: T, priority: P4}",
        "  - [ ] S {issue: S, priority: P1, depends_on: T}",
    ]
    assert warnings == []


TWO_HOP = _case(
    "two_hop",
    "- [ ] E",
    "  - [ ] D {issue: D, priority: P2}",
    "  - [ ] A {issue: A, priority: P4}",
    "  - [ ] B {issue: B, priority: P4, depends_on: A}",
    "  - [ ] C {issue: C, priority: P1, depends_on: B}",
)


def test_two_hop_inheritance():
    # C (P1) lifts B and, through B, A above the P2 sibling D.
    lines, _ = _ord(TWO_HOP)
    assert lines == [
        "- [ ] E",
        "  - [ ] A {issue: A, priority: P4}",
        "  - [ ] B {issue: B, priority: P4, depends_on: A}",
        "  - [ ] C {issue: C, priority: P1, depends_on: B}",
        "  - [ ] D {issue: D, priority: P2}",
    ]


FANOUT = _case(
    "fanout",
    "- [ ] E",
    "  - [ ] X {issue: X}",
    "  - [ ] Y {issue: Y}",
    "  - [ ] X2 {issue: X2, depends_on: X}",
    "  - [ ] Y2 {issue: Y2, depends_on: Y}",
    "  - [ ] Y3 {issue: Y3, depends_on: Y2}",
)
FANOUT_DIRECT = _case(
    "fanout_direct",
    "- [ ] E",
    "  - [ ] X {issue: X}",
    "  - [ ] Y {issue: Y}",
    "  - [ ] X2 {issue: X2, depends_on: X}",
    "  - [ ] Y2 {issue: Y2, depends_on: Y}",
)


def test_two_hop_fanout():
    # Y has two transitive dependents (Y2, Y3), X one: Y leads.
    lines, _ = _ord(FANOUT)
    assert lines == [
        "- [ ] E",
        "  - [ ] Y {issue: Y}",
        "  - [ ] X {issue: X}",
        "  - [ ] Y2 {issue: Y2, depends_on: Y}",
        "  - [ ] X2 {issue: X2, depends_on: X}",
        "  - [ ] Y3 {issue: Y3, depends_on: Y2}",
    ]
    # One dependent each: the tie keeps X first, so the count is transitive,
    # not direct-only.
    lines, _ = _ord(FANOUT_DIRECT)
    assert lines == FANOUT_DIRECT.splitlines()


EQUAL_KEYS = _case(
    "equal_keys",
    "- [ ] E",
    "  - [ ] a {priority: P2}",
    "  - [ ] b {priority: P2}",
    "  - [ ] c {priority: P2}",
)


def test_equal_keys_keep_order():
    lines, warnings = _ord(EQUAL_KEYS)
    assert lines == EQUAL_KEYS.splitlines()
    assert warnings == []
    assert _counts(EQUAL_KEYS) == (0, 1)


NESTED_DEP = _case(
    "nested_dep",
    "- [ ] E",
    "  - [ ] S {issue: S, depends_on: t1}",
    "  - [ ] T",
    "    - [ ] t1 {issue: t1}",
)


def test_dependency_on_nested_node():
    lines, _ = _ord(NESTED_DEP)
    assert lines == [
        "- [ ] E",
        "  - [ ] T",
        "    - [ ] t1 {issue: t1}",
        "  - [ ] S {issue: S, depends_on: t1}",
    ]


NO_ISSUE_DEPENDENT = _case(
    "no_issue_dependent",
    "- [ ] E",
    "  - [ ] dependent {depends_on: T}",
    "  - [ ] T {issue: T}",
)


def test_dependent_without_issue():
    lines, _ = _ord(NO_ISSUE_DEPENDENT)
    assert lines == [
        "- [ ] E",
        "  - [ ] T {issue: T}",
        "  - [ ] dependent {depends_on: T}",
    ]


OTHER_EPIC = _case(
    "other_epic",
    "- [ ] E1",
    "  - [ ] B {issue: B, priority: P3}",
    "  - [ ] A {issue: A, priority: P4}",
    "- [ ] E2",
    "  - [ ] Z {issue: Z, priority: P1, depends_on: A}",
)


def test_other_epic_dependent_ignored():
    # A cross-epic count would lift A to P1 and first.
    lines, _ = _ord(OTHER_EPIC)
    assert lines == OTHER_EPIC.splitlines()


FINISHED_DEPENDENT = _case(
    "finished_dependent",
    "- [ ] E",
    "  - [ ] A {issue: A, priority: P4}",
    "  - [ ] B {issue: B, priority: P3}",
    "  - [x] C {issue: C, priority: P1, depends_on: A}",
)
FINISHED_FANOUT = _case(
    "finished_fanout",
    "- [ ] E",
    "  - [ ] Y {issue: Y}",
    "  - [ ] X {issue: X}",
    "  - [x] X2 {issue: X2, depends_on: X}",
)


def test_finished_dependent_passes_nothing():
    # Counting the finished C would lift A to P1: A, B.
    lines, _ = _ord(FINISHED_DEPENDENT)
    assert lines == [
        "- [ ] E",
        "  - [ ] B {issue: B, priority: P3}",
        "  - [ ] A {issue: A, priority: P4}",
        "  - [x] C {issue: C, priority: P1, depends_on: A}",
    ]
    # Counting the finished X2 as fan-out would put X first.
    lines, _ = _ord(FINISHED_FANOUT)
    assert lines == FINISHED_FANOUT.splitlines()


FINISHED_INSIDE = _case(
    "finished_inside",
    "- [ ] E",
    "  - [ ] R {depends_on: s1}",
    "  - [ ] Q",
    "    - [x] q1 {priority: P1, depends_on: s2}",
    "  - [ ] S",
    "    - [x] s1 {issue: s1}",
    "    - [ ] s2 {issue: s2}",
)


def test_finished_node_inside_open_sibling_counts_nothing():
    # A dependency on the done s1 constrains nothing (else R follows S), the
    # done q1's dependency constrains nothing (else Q follows S), and its P1
    # lifts nothing (else Q first).
    lines, _ = _ord(FINISHED_INSIDE)
    assert lines == FINISHED_INSIDE.splitlines()


@pytest.mark.parametrize("glyph", ["~", "!", "?", "P"])
def test_open_states(glyph):
    text = _doc(
        "- [ ] E",
        f"  - [{glyph}] S {{issue: S, depends_on: T}}",
        "  - [ ] T {issue: T}",
    )
    lines, _ = _ord(text)
    assert lines == [
        "- [ ] E",
        "  - [ ] T {issue: T}",
        f"  - [{glyph}] S {{issue: S, depends_on: T}}",
    ]
    plain = _doc("- [ ] E", f"  - [{glyph}] a", "  - [ ] b")
    lines, _ = _ord(plain)
    assert lines == plain.splitlines()


OPEN_STATE = _case(
    "open_state",
    "- [ ] E",
    "  - [~] S {issue: S, depends_on: T}",
    "  - [ ] T {issue: T}",
)


MISSING_PRIORITY = _case(
    "missing_priority",
    "- [ ] E",
    "  - [ ] A",
    "  - [ ] B {priority: P2}",
    "  - [ ] C {priority: P4}",
)


def test_missing_priority_is_p3():
    lines, _ = _ord(MISSING_PRIORITY)
    assert lines == [
        "- [ ] E",
        "  - [ ] B {priority: P2}",
        "  - [ ] A",
        "  - [ ] C {priority: P4}",
    ]


MALFORMED_LOW = _case(
    "malformed_after_p3",
    "- [ ] E",
    "  - [ ] A {issue: A, priority: P3}",
    "  - [ ] B {issue: B, priority: high}",
)
MALFORMED_HIGH = _case(
    "malformed_before_p3",
    "- [ ] E",
    "  - [ ] B {issue: B, priority: high}",
    "  - [ ] A {issue: A, priority: P3}",
)


def test_malformed_priority_warns_once():
    # Read as P1 or P2, B would rise above A.
    lines, warnings = _ord(MALFORMED_LOW)
    assert lines == MALFORMED_LOW.splitlines()
    assert warnings == [PRIORITY_WARN.format(3, "high")]
    # Read as P4, A would rise above B.
    lines, warnings = _ord(MALFORMED_HIGH)
    assert lines == MALFORMED_HIGH.splitlines()
    assert warnings == [PRIORITY_WARN.format(2, "high")]
    # Every run warns again, once.
    _lines, warnings = _ord(MALFORMED_HIGH)
    assert warnings == [PRIORITY_WARN.format(2, "high")]


def test_malformed_list_priority_renders_as_a_list():
    text = _doc("- [ ] E", "  - [ ] a {priority: [P1, P2]}", "  - [ ] b")
    _lines, warnings = _ord(text)
    assert warnings == [PRIORITY_WARN.format(2, "[P1, P2]")]


FINISHED_SLOTS = _case(
    "finished_slots",
    "- [ ] E",
    "  - [x] F1",
    "  - [ ] A {priority: P4}",
    "  - [-] F2",
    "  - [ ] B {priority: P1}",
)
CASES["finished_slots_cl"] = (FINISHED_SLOTS, True)


def test_finished_siblings_keep_slots():
    lines, _ = _ord(FINISHED_SLOTS)
    assert lines == [
        "- [ ] E",
        "  - [x] F1",
        "  - [ ] B {priority: P1}",
        "  - [-] F2",
        "  - [ ] A {priority: P4}",
    ]


def test_completed_last():
    lines, _ = _ord(FINISHED_SLOTS, cl=True)
    assert lines == [
        "- [ ] E",
        "  - [ ] B {priority: P1}",
        "  - [ ] A {priority: P4}",
        "  - [x] F1",
        "  - [-] F2",
    ]


TOP_LEVEL = _case(
    "top_level",
    "- [ ] X {issue: X, depends_on: Y}",
    "- [ ] Y {issue: Y, priority: P1}",
)
TOP_LEVEL_KIDS = _case(
    "top_level_kids",
    "- [ ] X {issue: X, depends_on: Y}",
    "  - [ ] b {issue: b, depends_on: a}",
    "  - [ ] a {issue: a}",
    "- [ ] Y {issue: Y, priority: P1}",
)


def test_top_level_never_moves():
    lines, _ = _ord(TOP_LEVEL)
    assert lines == TOP_LEVEL.splitlines()
    assert _counts(TOP_LEVEL) == (0, 0)
    lines, _ = _ord(TOP_LEVEL_KIDS)
    assert lines == [
        "- [ ] X {issue: X, depends_on: Y}",
        "  - [ ] a {issue: a}",
        "  - [ ] b {issue: b, depends_on: a}",
        "- [ ] Y {issue: Y, priority: P1}",
    ]
    assert _counts(TOP_LEVEL_KIDS) == (1, 1)


WARNING_MOVES = _case(
    "warning_moves",
    "- [ ] E",
    "  - [ ] S {depends_on: T}",
    "  - [ ] T {issue: T, priority: high}",
)


def test_warning_line_follows_moved_block():
    lines, warnings = _ord(WARNING_MOVES)
    assert lines[1] == "  - [ ] T {issue: T, priority: high}"
    assert warnings == [PRIORITY_WARN.format(2, "high")]


SORTABLE_TAIL = (
    "- [ ] F",
    "  - [ ] y {depends_on: x}",
    "  - [ ] x {issue: x}",
)
SORTED_TAIL = [
    "- [ ] F",
    "  - [ ] x {issue: x}",
    "  - [ ] y {depends_on: x}",
]

CYCLE = _case(
    "cycle",
    "- [ ] E",
    "  - [ ] Sigma {issue: S}",
    "    - [ ] a {depends_on: T}",
    "    - [ ] c {issue: Sc}",
    "  - [ ] Tau {issue: T}",
    "    - [ ] b {depends_on: Sc}",
    *SORTABLE_TAIL,
)
CYCLE_TEXT_NAME = _case(
    "cycle_text_name",
    "- [ ] E",
    "  - [ ] Sigma {issue: S}",
    "    - [ ] a {depends_on: tb}",
    "    - [ ] c {issue: Sc}",
    "  - [ ] Tau group",
    "    - [ ] b {issue: tb, depends_on: Sc}",
    *SORTABLE_TAIL,
)


def test_cycle_left_alone():
    lines, warnings = _ord(CYCLE)
    assert lines == CYCLE.splitlines()[:6] + SORTED_TAIL
    assert warnings == ["line 1: children of 'E' left in order: dependency cycle among S, T"]
    lines, warnings = _ord(CYCLE_TEXT_NAME)
    assert lines == CYCLE_TEXT_NAME.splitlines()[:6] + SORTED_TAIL
    assert warnings == [
        "line 1: children of 'E' left in order: dependency cycle among S, Tau group"
    ]


# --- Task 3: sets left alone, and blocks ----------------------------------------

BLANK_SEP = _case(
    "blank_separator",
    "- [ ] E",
    "  - [ ] b {depends_on: a}",
    "",
    "  - [ ] a {issue: a}",
    *SORTABLE_TAIL,
)
EXCLUDE_SEP = _case(
    "exclude_separator",
    "- [ ] E",
    "  - [ ] b {depends_on: a}",
    "  <!-- wbs-exclude: Issue-9 -->",
    "  - [ ] a {issue: a}",
    *SORTABLE_TAIL,
)
BROKEN = _case(
    "broken_subtree",
    "- [ ] E",
    "  - [ ] S {depends_on: T}",
    "    - [ ] s1",
    "prose at column 0",
    "      - [ ] s2",
    "  - [ ] T {issue: T}",
    *SORTABLE_TAIL,
)


def test_blank_line_between_siblings_leaves_set():
    lines, warnings = _ord(BLANK_SEP)
    assert lines == BLANK_SEP.splitlines()[:4] + SORTED_TAIL
    assert warnings == ["line 1: children of 'E' left in order: line 3 separates two of them"]


def test_exclude_line_between_siblings_leaves_set():
    lines, warnings = _ord(EXCLUDE_SEP)
    assert lines == EXCLUDE_SEP.splitlines()[:4] + SORTED_TAIL
    assert warnings == ["line 1: children of 'E' left in order: line 3 separates two of them"]


def test_broken_subtree_leaves_set():
    # s2 still parses under s1 (depth alone), past the column-0 line that
    # ends S's block: moving S's block would leave s2 behind.
    lines, warnings = _ord(BROKEN)
    assert lines == BROKEN.splitlines()[:6] + SORTED_TAIL
    assert warnings == [
        "line 1: children of 'E' left in order: line 4 splits the subtree of line 2"
    ]


MIXED_DEPTH = _case(
    "mixed_depth",
    "- [ ] E",
    "      - [ ] b {depends_on: a}",
    "  - [ ] a {issue: a}",
    *SORTABLE_TAIL,
)


def test_mixed_sibling_depths_leave_set():
    # Moving a ahead of b would make b a's child.
    lines, warnings = _ord(MIXED_DEPTH)
    assert lines == MIXED_DEPTH.splitlines()[:3] + SORTED_TAIL
    assert warnings == [
        "line 1: children of 'E' left in order: line 3 is not at the depth of line 2"
    ]


TRAILING_BLANK = _case(
    "trailing_blank",
    "- [ ] E",
    "  - [ ] b {depends_on: a}",
    "  - [ ] a {issue: a}",
    "",
    "- [ ] F",
)


def test_trailing_blank_after_run_is_not_a_separator():
    lines, warnings = _ord(TRAILING_BLANK)
    assert lines == ["- [ ] E", "  - [ ] a {issue: a}", "  - [ ] b {depends_on: a}", "", "- [ ] F"]
    assert warnings == []


BLOCK = _case(
    "block_note_fence",
    "- [ ] E",
    "  - [ ] S {depends_on: T}",
    "  - [ ] T {issue: T}",
    "    a note on T",
    "    ```",
    "    - [ ] fenced, not a node",
    "    ```",
)
T_BLOCK = [
    "  - [ ] T {issue: T}",
    "    a note on T",
    "    ```",
    "    - [ ] fenced, not a node",
    "    ```",
]


def test_block_moves_with_note_and_fence():
    out, _ = wbs_parser.order_text(BLOCK)
    assert out.splitlines() == ["- [ ] E"] + T_BLOCK + ["  - [ ] S {depends_on: T}"]
    tree = wbs_parser.parse_text(out)
    epic = tree["children"][0]
    assert [c["text"] for c in epic["children"]] == ["T", "S"]
    assert epic["children"][0]["children"] == []


def _variant(tmp_path, text, kind):
    src, dst = tmp_path / "src.md", tmp_path / f"{kind}.md"
    src.write_bytes(text.encode("utf-8"))
    assert wbs_bytes.variant(str(src), kind, str(dst)) == 0
    return dst.read_bytes().decode("utf-8")


@pytest.mark.parametrize("kind", wbs_bytes.KINDS)
def test_eol_variants(tmp_path, kind):
    base = _variant(tmp_path, BLOCK, kind)
    out, _ = wbs_parser.order_text(base)
    assert out != base
    assert sorted(out.splitlines()) == sorted(base.splitlines())
    assert out.endswith(("\n", "\r")) == base.endswith(("\n", "\r"))
    eol = "\r\n" if kind.startswith("crlf") else "\n"
    assert out.count(eol) == base.count(eol)
    if kind.endswith("nofinal"):
        # The moved former last line (T's closing fence) gains the EOL.
        assert f"    ```{eol}  - [ ] S" in out
        assert out.endswith("  - [ ] S {depends_on: T}")


NESTED_SETS = _case(
    "nested_sets",
    "- [ ] E",
    "  - [ ] S {depends_on: T}",
    "  - [ ] T {issue: T}",
    "    - [ ] t2 {depends_on: t1}",
    "    - [ ] t1 {issue: t1}",
)


def test_nested_sets_sort_independently():
    lines, _ = _ord(NESTED_SETS)
    assert lines == [
        "- [ ] E",
        "  - [ ] T {issue: T}",
        "    - [ ] t1 {issue: t1}",
        "    - [ ] t2 {depends_on: t1}",
        "  - [ ] S {depends_on: T}",
    ]
    assert _counts(NESTED_SETS) == (2, 2)


INNER_UNDER_LEFT_ALONE = _case(
    "inner_under_left_alone",
    "- [ ] E",
    "  - [ ] S {depends_on: T}",
    "    - [ ] s2 {depends_on: s1}",
    "    - [ ] s1 {issue: s1}",
    "",
    "  - [ ] T {issue: T}",
)


def test_inner_set_sorted_under_left_alone_outer():
    lines, warnings = _ord(INNER_UNDER_LEFT_ALONE)
    assert lines == [
        "- [ ] E",
        "  - [ ] S {depends_on: T}",
        "    - [ ] s1 {issue: s1}",
        "    - [ ] s2 {depends_on: s1}",
        "",
        "  - [ ] T {issue: T}",
    ]
    assert warnings == ["line 1: children of 'E' left in order: line 5 separates two of them"]


# --- Task 4: permuted_only -------------------------------------------------------

ACCEPT = [(name, kind) for name in sorted(CASES) for kind in ("lf", "crlf", "lf-nofinal")]


def test_permuted_only_subject_set_is_not_empty():
    assert len(CASES) >= 20
    assert len(ACCEPT) == 3 * len(CASES)


@pytest.mark.parametrize(("name", "kind"), ACCEPT)
def test_permuted_only_accepts_order_text_output(tmp_path, name, kind):
    text, cl = CASES[name]
    base = _variant(tmp_path, text, kind)
    out, _ = wbs_parser.order_text(base, completed_last=cl)
    assert wbs_parser.permuted_only(base, out) == (True, "")


def _swap(text, a, b):
    """`text` with lines a and b (0-based) exchanged, terminators kept with
    their bodies."""
    lines = text.splitlines(keepends=True)
    lines[a], lines[b] = lines[b], lines[a]
    return "".join(lines)


TWO_EPICS = _doc("- [ ] E", "  - [ ] a", "  - [ ] b", "- [ ] F", "  - [ ] c")


def test_permuted_only_rejects():
    ordered, _ = wbs_parser.order_text(BLOCK)
    assert ordered != BLOCK

    dropped = "".join(ordered.splitlines(keepends=True)[:-1])
    assert wbs_parser.permuted_only(BLOCK, dropped) == (
        False, "the ordered text has 6 lines, the base 7")

    changed = ordered.replace("a note on T", "a note on X")
    assert wbs_parser.permuted_only(BLOCK, changed) == (
        False, "line 3: '    a note on X' is not a line of the base")

    crlf = BLOCK.replace("\n", "\r\n")
    ordered_crlf, _ = wbs_parser.order_text(crlf)
    one_lf = ordered_crlf.replace("    a note on T\r\n", "    a note on T\n")
    assert wbs_parser.permuted_only(crlf, one_lf) == (False, "line 3: line ending changed")

    final_nl = BLOCK.rstrip("\n")
    assert wbs_parser.permuted_only(final_nl, BLOCK) == (False, "line 7: line ending changed")

    reparented = _doc("- [ ] E", "  - [ ] a", "- [ ] F", "  - [ ] c", "  - [ ] b")
    assert wbs_parser.permuted_only(TWO_EPICS, reparented) == (
        False, "line 5: node 'b' changed parent or depth")

    epics_swapped = _doc("- [ ] F", "  - [ ] c", "- [ ] E", "  - [ ] a", "  - [ ] b")
    assert wbs_parser.permuted_only(TWO_EPICS, epics_swapped) == (
        False, "line 1: block structure changed")

    separated = _doc("- [ ] E", "  - [ ] a", "", "  - [ ] b")
    assert wbs_parser.permuted_only(separated, _swap(separated, 2, 3)) == (
        False, "line 3: block structure changed")

    notes = _doc("- [ ] E", "  - [ ] a", "    note A", "  - [ ] b", "    note B")
    assert wbs_parser.permuted_only(notes, _swap(notes, 2, 4)) == (
        False, "line 3: block structure changed")


UNCLOSED = _doc(
    "- [ ] E",
    "  - [ ] S {depends_on: T}",
    "    ```",
    "  - [ ] T {issue: T}",
    "    ```python",
)


def test_permuted_only_unclosed_fence():
    # In the base neither fence-like line pairs. Moved ahead, T's opener
    # pairs with S's bare fence and swallows S's node line.
    out, _ = wbs_parser.order_text(UNCLOSED)
    assert out.splitlines()[1] == "  - [ ] T {issue: T}"
    ok, reason = wbs_parser.permuted_only(UNCLOSED, out)
    assert ok is False
    assert reason == "line 4: node 'S' changed parent or depth"
