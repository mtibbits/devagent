"""Tests for scripts/lib/wbs-parser.py."""
import importlib.util
import json
import subprocess
import sys
from pathlib import Path

import pytest

REPO = Path(__file__).resolve().parent.parent
FIX = REPO / "tests" / "fixtures" / "wbs"
BYTES_HELPER = REPO / "tests" / "helpers" / "wbs_bytes.py"
VARIANTS = ("lf", "crlf", "lf-nofinal", "crlf-nofinal")

spec = importlib.util.spec_from_file_location(
    "wbs_parser", REPO / "scripts" / "lib" / "wbs-parser.py"
)
wbs_parser = importlib.util.module_from_spec(spec)
spec.loader.exec_module(wbs_parser)


def test_parse_simple():
    tree = wbs_parser.parse_file(FIX / "simple.md")
    assert tree["title"] == "test WBS"
    assert len(tree["children"]) == 1
    top = tree["children"][0]
    assert top["text"] == "Top"
    assert top["state"] == "pending"
    assert top["meta"]["est"] == "2w"
    assert top["meta"]["milestone"] == "M1"
    assert top["meta"]["owner"] == "@me"
    assert len(top["children"]) == 2
    leaf_a = top["children"][0]
    assert leaf_a["state"] == "done"
    assert leaf_a["meta"]["issue"] == "Issue-1"


def test_parse_nested_depth():
    tree = wbs_parser.parse_file(FIX / "nested.md")
    root = tree["children"][0]
    subgoal_a = root["children"][0]
    subsub = subgoal_a["children"][0]
    assert subsub["text"] == "Subsubgoal A1"
    assert subsub["depth"] == 3
    assert subsub["meta"]["issue"] == "Issue-10"


def test_unknown_keys_preserved():
    tree = wbs_parser.parse_file(FIX / "unknown_keys.md")
    node = tree["children"][0]
    assert node["meta"]["jira"] == "PROJ-42"
    assert node["meta"]["severity"] == "high"
    assert node["meta_unknown_keys"] == ["jira", "severity"]
    leaf = node["children"][0]
    assert leaf["meta"]["custom_field"] == "value with spaces"
    assert "custom_field" in leaf["meta_unknown_keys"]


def test_meta_block_only_trailing_braces():
    """Braces in item text must not be swallowed into the meta block (B12).

    A `{...}` inside the item text before the real trailing `{issue: ...}` block
    used to be matched from the *first* brace, corrupting issue linkage.
    """
    tree = wbs_parser.parse_text(
        "# t\n- [ ] Refactor {foo} helper {issue: Issue-9, est: 1w}\n"
    )
    node = tree["children"][0]
    assert node["text"] == "Refactor {foo} helper"
    assert node["meta"]["issue"] == "Issue-9"
    assert node["meta"]["est"] == "1w"


def test_tab_indent_nests_not_flattened():
    """A tab-indented child must nest under its parent, not flatten (B12).

    A leading tab counted as a single indent char, so depth collapsed and the
    child became a sibling of its parent.
    """
    tree = wbs_parser.parse_text(
        "# t\n- [ ] Parent\n\t- [ ] Child {issue: Issue-5}\n"
    )
    parent = tree["children"][0]
    assert parent["text"] == "Parent"
    assert len(parent["children"]) == 1, "tab-indented child flattened to a sibling"
    child = parent["children"][0]
    assert child["depth"] == 2
    assert child["meta"]["issue"] == "Issue-5"


def test_dependency_edges():
    tree = wbs_parser.parse_file(FIX / "depends.md")
    edges = wbs_parser.dependency_edges(tree)
    assert ("Issue-2", "Issue-1") in edges
    assert ("Issue-3", "Issue-1") in edges
    assert ("Issue-3", "Issue-2") in edges
    assert len(edges) == 3


def test_leaves_enumeration():
    tree = wbs_parser.parse_file(FIX / "nested.md")
    leaves = wbs_parser.leaves(tree)
    issues = sorted(n["meta"]["issue"] for n in leaves)
    assert issues == ["Issue-10", "Issue-11", "Issue-12"]


def test_roundtrip_to_markdown():
    """Parse → render → parse must yield equivalent tree (whitespace allowed)."""
    tree1 = wbs_parser.parse_file(FIX / "simple.md")
    rendered = wbs_parser.render_markdown(tree1)
    assert rendered == (FIX / "simple.md").read_bytes().decode("utf-8")
    import tempfile
    with tempfile.NamedTemporaryFile(
        "w", suffix=".md", delete=False, encoding="utf-8", newline=""
    ) as f:
        f.write(rendered)
        tmp = Path(f.name)
    tree2 = wbs_parser.parse_file(tmp)
    assert json.dumps(_strip_locs(tree1), sort_keys=True) == json.dumps(
        _strip_locs(tree2), sort_keys=True
    )


def _strip_locs(node):
    if isinstance(node, dict):
        return {
            k: _strip_locs(v)
            for k, v in node.items()
            if k not in ("source_line",)
        }
    if isinstance(node, list):
        return [_strip_locs(x) for x in node]
    return node


# #701 — line-local WBS writes
#
# Every variant of preserve.md is built by tests/helpers/wbs_bytes.py, the one
# implementation of the LF/CRLF/no-final-newline conversion (shared with bats).

CRLF = bytes([13, 10]).decode("ascii")


@pytest.fixture
def variants(tmp_path):
    out = {}
    for kind in VARIANTS:
        dst = tmp_path / f"{kind}.md"
        subprocess.run(
            [sys.executable, str(BYTES_HELPER), "variant",
             str(FIX / "preserve.md"), kind, str(dst)],
            check=True,
        )
        out[kind] = dst
    return out


def _find(tree, text):
    stack = list(tree["children"])
    while stack:
        node = stack.pop(0)
        if node["text"] == text:
            return node
        stack.extend(node["children"])
    raise AssertionError(f"no node {text!r}")


def _walk(tree):
    stack = list(tree["children"])
    while stack:
        node = stack.pop(0)
        yield node
        stack.extend(node["children"])


def _tuples(nodes):
    return [(n["text"], n["meta"], n["state"], n["glyph"], n["depth"]) for n in nodes]


def test_render_reproduces_every_variant_byte_for_byte(variants):
    for kind, p in variants.items():
        tree = wbs_parser.parse_file(p)
        assert wbs_parser.render_markdown(tree).encode("utf-8") == p.read_bytes(), kind
        before = p.read_bytes()
        assert wbs_parser.write_markdown(p, tree) is False, kind
        assert p.read_bytes() == before, kind


def test_glyph_change_rewrites_one_character(variants):
    for kind, p in variants.items():
        src = p.read_bytes().decode("utf-8")
        tree = wbs_parser.parse_file(p)
        leaf = _find(tree, "Leaf A")
        leaf["glyph"] = "~"
        leaf["state"] = "in_progress"
        out = wbs_parser.render_markdown(tree)
        assert len(out) == len(src), kind
        diffs = [i for i, (a, b) in enumerate(zip(src, out)) if a != b]
        assert len(diffs) == 1, kind
        i = diffs[0]
        line_start = src.rfind("\n", 0, i) + 1
        line_end = src.find("\n", i)
        assert "Leaf A" in src[line_start:line_end], kind
        assert src[i] == " ", kind
        assert out[i] == "~", kind


def test_fenced_lines_are_never_nodes():
    tree = wbs_parser.parse_file(FIX / "preserve.md")
    assert "Fenced example" not in [n["text"] for n in wbs_parser.leaves(tree)]
    assert wbs_parser.dependency_edges(tree) == [("Issue-2", "Issue-1")]
    lines = (FIX / "preserve.md").read_bytes().decode("utf-8").splitlines()
    fences = [i + 1 for i, line in enumerate(lines) if line.startswith("```")]
    assert len(fences) == 2
    for node in _walk(tree):
        assert not fences[0] <= node["source_line"] <= fences[1], node["text"]
    t = wbs_parser.parse_text("```\n# not title\n- [ ] x {issue: Issue-5}\n```\n# real\n")
    assert t["title"] == "real"
    assert t["children"] == []


def test_prose_does_not_change_the_tree():
    full = wbs_parser.parse_file(FIX / "preserve.md")
    bare = wbs_parser.parse_file(FIX / "preserve-stripped.md")
    assert _tuples(wbs_parser.leaves(full)) == _tuples(wbs_parser.leaves(bare))
    assert wbs_parser.dependency_edges(full) == wbs_parser.dependency_edges(bare)
    assert [n["text"] for n in full["children"]] == ["Epic one", "Epic two"]
    assert _find(full, "Leaf A")["children"] == []


def test_backtick_info_with_backtick_is_not_a_fence():
    tree = wbs_parser.parse_text("# t\n```x``` inline span\n- [ ] after {issue: Issue-5}\n")
    assert "after" in [n["text"] for n in wbs_parser.leaves(tree)]


def test_unclosed_fence_is_ignored_with_warning(capsys):
    text = "# t\n- [ ] a\n```\n- [ ] b\n"
    tree = wbs_parser.parse_text(text)
    assert [n["text"] for n in wbs_parser.leaves(tree)] == ["a", "b"]
    assert "unclosed code fence at line 3 ignored" in capsys.readouterr().err
    assert wbs_parser.render_markdown(tree) == text


PROBE = "- [ ] probe {issue: Issue-5}"


@pytest.mark.parametrize(
    "body, is_leaf",
    [
        (f"~~~\n{PROBE}\n~~~\n", False),
        (f"````\n```\n{PROBE}\n````\n", False),
        (f"```\n~~~\n{PROBE}\n```\n", False),
        (f"   ```\n{PROBE}\n```\n", False),
        (f"```\n```x\n{PROBE}\n```\n", False),
        (f"```\ncode\n```\n{PROBE}\n", True),
    ],
    ids=["tilde", "shorter-run", "other-char", "indented-opener",
         "closer-with-info", "control-after-fence"],
)
def test_fence_syntax_controls(body, is_leaf):
    tree = wbs_parser.parse_text("# t\n- [ ] anchor\n" + body)
    texts = [n["text"] for n in wbs_parser.leaves(tree)]
    assert "anchor" in texts
    assert ("probe" in texts) is is_leaf


def _new_node(text, depth, meta=None, glyph=" ", children=None):
    return {
        "text": text,
        "state": wbs_parser.STATE_GLYPHS[glyph],
        "glyph": glyph,
        "depth": depth,
        "meta": meta or {},
        "meta_unknown_keys": [],
        "children": children or [],
        "source_line": 0,
    }


def test_inserted_nodes_follow_block_and_eol_rules(variants):
    p = variants["crlf-nofinal"]
    src = p.read_bytes().decode("utf-8")
    tree = wbs_parser.parse_file(p)
    child = _new_node("Issue-7", 2, {"issue": "Issue-7", "est": "?w"})
    tree["children"].append(_new_node("Unassigned", 1, children=[child]))
    anchor = "    Note under the last leaf." + CRLF
    inserted = (
        "- [ ] Unassigned" + CRLF
        + "  - [ ] Issue-7 {issue: Issue-7, est: ?w}" + CRLF
    )
    out = wbs_parser.render_markdown(tree)
    assert out == src.replace(anchor, anchor + inserted)
    assert not out.endswith("\n")

    tree2 = wbs_parser.parse_text("# t\n- [ ] a")
    tree2["children"].append(_new_node("b", 1))
    assert wbs_parser.render_markdown(tree2) == "# t\n- [ ] a\n- [ ] b"


def _shape(tree):
    return [(n["text"], _shape(n)) for n in tree["children"]]


@pytest.mark.parametrize(
    "text",
    [
        "# t\n- [ ] Epic two\n  - [ ] Leaf D {issue: Issue-3}\n"
        "Note not indented\n  - [ ] Leaf E {issue: Issue-4}\n",
        "# t\n- [ ] Epic two\n\n## Sub\n\n  - [ ] Leaf D {issue: Issue-3}\n",
    ],
    ids=["col0-note-between-children", "heading-between-parent-and-child"],
)
def test_insertion_never_reparents_existing_nodes(text):
    """A new node lands after its preceding sibling's whole parsed subtree,
    even when a column-0 line splits that subtree in the source."""
    tree = wbs_parser.parse_text(text)
    child = _new_node("Issue-7", 2, {"issue": "Issue-7", "est": "?w"})
    tree["children"].append(_new_node("Unassigned", 1, children=[child]))
    want = _shape(tree)
    out = wbs_parser.render_markdown(tree)
    assert _shape(wbs_parser.parse_text(out)) == want


def test_document_render_reflects_title_text_meta_and_removal():
    src = (FIX / "preserve.md").read_bytes().decode("utf-8")

    tree = wbs_parser.parse_text(src)
    _find(tree, "Leaf C")["text"] = "Leaf C2"
    out = wbs_parser.render_markdown(tree)
    assert out == src.replace("  - [x] Leaf C {}\n", "  - [x] Leaf C2\n")

    tree = wbs_parser.parse_text(src)
    tree["children"] = [n for n in tree["children"] if n["text"] != "Epic two"]
    out = wbs_parser.render_markdown(tree)
    expected = src.replace("- [ ] Epic two {est: 2w}\n", "").replace(
        "  - [ ] Leaf D {issue: Issue-3, est: 1w}\n", ""
    )
    assert "    Note under the last leaf.\n" in expected
    assert out == expected

    tree = wbs_parser.parse_text(src)
    tree["title"] = "t2"
    out = wbs_parser.render_markdown(tree)
    assert out == src.replace("#  preserve  WBS\n", "# t2\n")


def test_tree_without_source_text_renders_v1():
    tree = wbs_parser.parse_file(FIX / "simple.md")
    tree.pop("source_text", None)
    assert wbs_parser.render_markdown(tree) == (
        "# test WBS\n"
        "\n"
        "- [ ] Top {est: 2w, milestone: M1, owner: @me}\n"
        "  - [x] Leaf A {issue: Issue-1, est: 1w}\n"
        "  - [ ] Leaf B {issue: Issue-2, est: 1w}\n"
    )


NODE_KEYS = {
    "text", "state", "glyph", "depth", "meta", "meta_unknown_keys",
    "children", "source_line",
}


def test_parse_cli_json_is_additive_and_render_cli_roundtrips(variants, tmp_path):
    p = variants["crlf"]
    parser = str(REPO / "scripts" / "lib" / "wbs-parser.py")
    res = subprocess.run(
        [sys.executable, parser, "parse", str(p)], capture_output=True, check=True
    )
    tree = json.loads(res.stdout.decode("utf-8"))
    assert set(tree) == {"title", "children", "source_text"}
    for node in _walk(tree):
        assert set(node) == NODE_KEYS, node["text"]
    j = tmp_path / "tree.json"
    j.write_bytes(res.stdout)
    res = subprocess.run(
        [sys.executable, parser, "render", str(j)], capture_output=True, check=True
    )
    assert res.stdout == p.read_bytes()
