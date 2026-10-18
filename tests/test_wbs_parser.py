"""Tests for scripts/lib/wbs-parser.py."""
import ast
import importlib.util
import json
import re
import subprocess
import sys
from pathlib import Path

import pytest

REPO = Path(__file__).resolve().parent.parent
FIX = REPO / "tests" / "fixtures" / "wbs"
PARSER = str(REPO / "scripts" / "lib" / "wbs-parser.py")


def _load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


wbs_parser = _load("wbs_parser", REPO / "scripts" / "lib" / "wbs-parser.py")
wbs_bytes = _load("wbs_bytes", REPO / "tests" / "helpers" / "wbs_bytes.py")


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
    for kind in wbs_bytes.KINDS:
        dst = tmp_path / f"{kind}.md"
        assert wbs_bytes.variant(str(FIX / "preserve.md"), kind, str(dst)) == 0
        out[kind] = dst
    return out


def _walk(tree):
    stack = list(tree["children"])
    while stack:
        node = stack.pop(0)
        yield node
        stack.extend(node["children"])


def _find(tree, text):
    for node in _walk(tree):
        if node["text"] == text:
            return node
    raise AssertionError(f"no node {text!r}")


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


def test_new_child_of_an_existing_parent_is_placed_by_its_siblings():
    text = (
        "# t\n- [ ] Unassigned\n  - [x] Issue-5 {issue: Issue-5}\n"
        "    note\n- [ ] Other\n"
    )
    new = "  - [ ] Issue-7 {issue: Issue-7}\n"

    tree = wbs_parser.parse_text(text)
    tree["children"][0]["children"].append(_new_node("Issue-7", 2, {"issue": "Issue-7"}))
    assert wbs_parser.render_markdown(tree) == text.replace("    note\n", "    note\n" + new)

    tree = wbs_parser.parse_text(text)
    tree["children"][0]["children"].insert(0, _new_node("Issue-7", 2, {"issue": "Issue-7"}))
    assert wbs_parser.render_markdown(tree) == text.replace(
        "- [ ] Unassigned\n", "- [ ] Unassigned\n" + new
    )

    childless = "# t\n- [ ] Unassigned\n  note\n- [ ] Other\n"
    tree = wbs_parser.parse_text(childless)
    tree["children"][0]["children"].append(_new_node("Issue-7", 2, {"issue": "Issue-7"}))
    assert wbs_parser.render_markdown(tree) == childless.replace("  note\n", "  note\n" + new)


@pytest.mark.parametrize(
    "text",
    ["# t\r\n- [ ] a\n  note\r\n- [ ] b\r", "# t\r- [ ] a\r  note\r- [ ] b\r"],
    ids=["mixed", "cr-only"],
)
def test_each_line_keeps_its_own_terminator(text):
    assert wbs_parser.render_markdown(wbs_parser.parse_text(text)) == text
    tree = wbs_parser.parse_text(text)
    _find(tree, "b")["glyph"] = "x"
    assert wbs_parser.render_markdown(tree) == text.replace("- [ ] b", "- [x] b")


def test_document_render_reflects_title_text_meta_and_removal():
    src = (FIX / "preserve.md").read_bytes().decode("utf-8")

    tree = wbs_parser.parse_text(src)
    _find(tree, "Leaf C")["text"] = "Leaf C2"
    out = wbs_parser.render_markdown(tree)
    assert out == src.replace("  - [x] Leaf C {}\n", "  - [x] Leaf C2\n")

    tree = wbs_parser.parse_text(src)
    tree["children"] = [n for n in tree["children"] if n["text"] != "Epic two"]
    out = wbs_parser.render_document(tree, allow_removals=True)
    expected = src.replace("- [ ] Epic two {est: 2w}\n", "").replace(
        "  - [ ] Leaf D {issue: Issue-3, est: 1w}\n", ""
    )
    assert "    Note under the last leaf.\n" in expected
    assert out == expected

    tree = wbs_parser.parse_text(src)
    tree["title"] = "t2"
    out = wbs_parser.render_markdown(tree)
    assert out == src.replace("#  preserve  WBS\n", "# t2\n")


# #703 — status_src is spliced into the owned line, never regenerated

META_NODES = ["Epic one", "Leaf A", "Leaf B", "Leaf C", "Epic two", "Leaf D"]


def test_status_src_is_known_key():
    tree = wbs_parser.parse_text("# t\n\n- [ ] A {issue: Issue-1, status_src: tracker}\n")
    assert tree["children"][0]["meta_unknown_keys"] == []


def test_status_src_splice_keeps_bytes(variants, tmp_path):
    for kind, p in variants.items():
        for text in META_NODES:
            tree = wbs_parser.parse_file(p)
            node = _find(tree, text)
            node["meta"]["status_src"] = "checklist"
            exp = tmp_path / "expected.md"
            assert wbs_bytes.patch_leaf(str(p), str(exp), text, node["glyph"], "checklist") == 0
            out = wbs_parser.render_markdown(tree).encode("utf-8")
            assert out == exp.read_bytes(), (kind, text)


def test_status_src_splice_with_glyph_change(variants, tmp_path):
    for kind, p in variants.items():
        tree = wbs_parser.parse_file(p)
        node = _find(tree, "Leaf A")
        node["glyph"] = "x"
        node["state"] = "done"
        node["meta"]["status_src"] = "tracker"
        exp = tmp_path / "expected.md"
        assert wbs_bytes.patch_leaf(str(p), str(exp), "Leaf A", "x", "tracker") == 0
        assert wbs_parser.render_markdown(tree).encode("utf-8") == exp.read_bytes(), kind


def test_status_src_splice_reparses_to_the_new_meta(variants):
    for kind, p in variants.items():
        for text in META_NODES:
            tree = wbs_parser.parse_file(p)
            node = _find(tree, text)
            want = dict(node["meta"], status_src="tracker")
            node["meta"]["status_src"] = "tracker"
            again = wbs_parser.parse_text(wbs_parser.render_markdown(tree))
            assert _find(again, text)["meta"] == want, (kind, text)


def test_status_src_replace_value(tmp_path):
    src = "# t\n\n- [ ] A {issue: Issue-1,est:1w ,status_src:  checklist , owner: @me}\n"
    p = tmp_path / "w.md"
    p.write_bytes(src.encode("utf-8"))
    tree = wbs_parser.parse_file(p)
    tree["children"][0]["meta"]["status_src"] = "tracker"
    out = wbs_parser.render_markdown(tree)
    assert out == src.replace("checklist", "tracker")
    exp = tmp_path / "e.md"
    assert wbs_bytes.patch_leaf(str(p), str(exp), "A {", " ", "tracker") == 0
    assert out.encode("utf-8") == exp.read_bytes()


def test_other_meta_change_still_regenerates():
    src = "# t\n\n- [ ] A {issue: Issue-1,est:1w}\n"
    tree = wbs_parser.parse_text(src)
    tree["children"][0]["meta"]["est"] = "2w"
    tree["children"][0]["meta"]["status_src"] = "tracker"
    out = wbs_parser.render_markdown(tree)
    assert out == "# t\n\n- [ ] A {issue: Issue-1, est: 2w, status_src: tracker}\n"


# #704 — `mr` is a second owned key: set, replaced or removed in place


def test_mr_is_known_key():
    tree = wbs_parser.parse_text("# t\n\n- [~] A {issue: Issue-1, status_src: mr, mr: open}\n")
    assert tree["children"][0]["meta_unknown_keys"] == []


def test_mr_splice_add_with_status_src(variants):
    for kind, p in variants.items():
        src = p.read_bytes()
        tree = wbs_parser.parse_file(p)
        node = _find(tree, "Leaf A")
        node["glyph"], node["state"] = "~", "in_progress"
        node["meta"]["status_src"] = "mr"
        node["meta"]["mr"] = "open"
        want = src.replace(b"- [ ] Leaf A {issue: Issue-1,est:1w}",
                           b"- [~] Leaf A {issue: Issue-1,est:1w, status_src: mr, mr: open}")
        assert want != src, kind
        assert wbs_parser.render_markdown(tree).encode("utf-8") == want, kind


def _one(src, edit):
    tree = wbs_parser.parse_text(src)
    edit(tree["children"][0]["meta"])
    return wbs_parser.render_markdown(tree)


def test_mr_splice_replace_and_remove_compact():
    src = "# t\n\n- [~] A {issue: Issue-1,est:1w,mr:open}\n"
    assert _one(src, lambda m: m.update(mr="merged")) == src.replace("mr:open", "mr:merged")
    assert _one(src, lambda m: m.pop("mr")) == "# t\n\n- [~] A {issue: Issue-1,est:1w}\n"


def test_mr_remove_first_and_only_key():
    assert _one("# t\n\n- [ ] A {mr: open, issue: Issue-1}\n", lambda m: m.pop("mr")) == \
        "# t\n\n- [ ] A {issue: Issue-1}\n"
    assert _one("# t\n\n- [ ] A {mr: open}\n", lambda m: m.pop("mr")) == "# t\n\n- [ ] A {}\n"


def test_mr_and_status_src_removed_together():
    src = "# t\n\n- [~] A {issue: Issue-1, est: 1w, status_src: mr, mr: open}  " + CRLF
    out = _one(src, lambda m: (m.pop("mr"), m.pop("status_src")))
    assert out == "# t\n\n- [~] A {issue: Issue-1, est: 1w}  " + CRLF


def test_owned_change_with_other_meta_change_regenerates():
    src = "# t\n\n- [ ] A {issue: Issue-1,est:1w,mr:open}\n"
    out = _one(src, lambda m: (m.pop("mr"), m.update(est="2w")))
    assert out == "# t\n\n- [ ] A {issue: Issue-1, est: 2w}\n"


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
    assert set(tree) == {"title", "children", "source_text", "exclusions",
                         "exclusion_warnings"}
    for node in _walk(tree):
        assert set(node) == NODE_KEYS, node["text"]
    j = tmp_path / "tree.json"
    j.write_bytes(res.stdout)
    res = subprocess.run(
        [sys.executable, parser, "render", str(j)], capture_output=True, check=True
    )
    assert res.stdout == p.read_bytes()


# #764 — the document render refuses removals, moves and reorders

W_MD = (
    "# W\n\nProse.\n\n- [ ] A {issue: Issue-1}\n"
    "  - [ ] A1 {issue: Issue-2}\n- [ ] B {issue: Issue-3}\n"
)
MOVED = "moved; moving or reordering nodes is not supported"


def _w(tmp_path):
    p = tmp_path / "w.md"
    p.write_bytes(W_MD.encode("utf-8"))
    return p


def test_write_markdown_refuses_a_filtered_tree(tmp_path):
    p = _w(tmp_path)
    tree = wbs_parser.parse_file(p)
    tree["children"] = tree["children"][:1]
    with pytest.raises(ValueError, match=re.escape("w.md line 7: node 'B' is not in the tree")):
        wbs_parser.write_markdown(p, tree)
    assert p.read_bytes() == W_MD.encode("utf-8")


def test_render_document_removal_needs_allow_removals():
    tree = wbs_parser.parse_text(W_MD)
    tree["children"] = tree["children"][:1]
    with pytest.raises(ValueError, match=re.escape("line 7: node 'B' is not in the tree")):
        wbs_parser.render_document(tree)
    out = wbs_parser.render_document(tree, allow_removals=True)
    assert out == W_MD.replace("- [ ] B {issue: Issue-3}\n", "")


def _b_under_a(depth):
    tree = wbs_parser.parse_text(W_MD)
    b = tree["children"].pop()
    b["depth"] = depth
    tree["children"][0]["children"].append(b)
    return tree


@pytest.mark.parametrize("depth", [2, 1], ids=["new-depth", "same-depth"])
def test_reparent_is_refused(depth):
    with pytest.raises(ValueError, match=re.escape(f"line 7: node 'B' {MOVED}")):
        wbs_parser.render_markdown(_b_under_a(depth))


def test_depth_change_alone_is_refused():
    tree = wbs_parser.parse_text(W_MD)
    tree["children"][1]["depth"] = 2
    with pytest.raises(ValueError, match=re.escape(f"line 7: node 'B' {MOVED}")):
        wbs_parser.render_markdown(tree)


def test_reorder_is_refused():
    tree = wbs_parser.parse_text(W_MD)
    tree["children"].reverse()
    with pytest.raises(ValueError, match=re.escape(f"line 5: node 'A' {MOVED}")):
        wbs_parser.render_markdown(tree)


def test_nested_reorder_is_refused():
    tree = wbs_parser.parse_file(FIX / "preserve.md")
    tree["children"][0]["children"].reverse()
    with pytest.raises(ValueError, match=re.escape(f"line 15: node 'Leaf A' {MOVED}")):
        wbs_parser.render_markdown(tree)


def test_move_under_a_new_node_is_refused():
    """`claim()` never descends into a new node, so B's line is unowned; the
    refusal must not read that as a removal that `allow_removals` permits."""
    tree = wbs_parser.parse_text(W_MD)
    b = tree["children"].pop()
    b["depth"] = 2
    tree["children"].append(_new_node("N", 1, children=[b]))
    with pytest.raises(ValueError, match=re.escape(f"line 7: node 'B' {MOVED}")):
        wbs_parser.render_markdown(tree)
    with pytest.raises(ValueError, match=re.escape(f"line 7: node 'B' {MOVED}")):
        wbs_parser.render_document(tree, allow_removals=True)


def test_new_node_among_owned_siblings_is_not_a_reorder():
    tree = wbs_parser.parse_text(W_MD)
    tree["children"].insert(1, _new_node("N", 1))
    want = W_MD.replace("  - [ ] A1 {issue: Issue-2}\n", "  - [ ] A1 {issue: Issue-2}\n- [ ] N\n")
    assert wbs_parser.render_markdown(tree) == want
    assert wbs_parser.render_document(tree) == want


def test_owned_edits_still_render_after_the_checks():
    line = "- [ ] B {issue: Issue-3}"
    cases = [
        (lambda b: b.update(glyph="x", state="done"), "- [x] B {issue: Issue-3}"),
        (lambda b: b.update(text="B2"), "- [ ] B2 {issue: Issue-3}"),
        (lambda b: b["meta"].update(status_src="tracker"),
         "- [ ] B {issue: Issue-3, status_src: tracker}"),
    ]
    for edit, want in cases:
        tree = wbs_parser.parse_text(W_MD)
        edit(tree["children"][1])
        assert wbs_parser.render_markdown(tree) == W_MD.replace(line, want), want
        assert wbs_parser.render_document(tree) == W_MD.replace(line, want), want


def test_render_document_requires_source_text():
    tree = wbs_parser.parse_text(W_MD)
    tree.pop("source_text")
    with pytest.raises(ValueError, match=re.escape("render_document: the tree has no source_text")):
        wbs_parser.render_document(tree)


INSERTION_TEXTS = [
    "# t\n- [ ] Epic two\n  - [ ] Leaf D {issue: Issue-3}\n"
    "Note not indented\n  - [ ] Leaf E {issue: Issue-4}\n",
    "# t\n- [ ] Epic two\n\n## Sub\n\n  - [ ] Leaf D {issue: Issue-3}\n",
]


@pytest.mark.parametrize(
    "text, want",
    [
        ((FIX / "preserve.md").read_bytes().decode("utf-8"),
         {12: -1, 14: 12, 16: 12, 17: 12, 29: -1, 30: 29}),
        ((FIX / "nested.md").read_bytes().decode("utf-8"),
         {2: -1, 3: 2, 4: 3, 5: 3, 6: 2, 7: 6}),
        ((FIX / "simple.md").read_bytes().decode("utf-8"), {2: -1, 3: 2, 4: 2}),
        (INSERTION_TEXTS[0], {1: -1, 2: 1, 4: 1}),
        (INSERTION_TEXTS[1], {1: -1, 5: 1}),
    ],
    ids=["preserve", "nested", "simple", "col0-note", "heading-between"],
)
def test_parse_parents_known_maps(text, want):
    """Hand-written {node line index: parent line index, -1 for the root}."""
    kinds, _bodies, _ = wbs_parser._classify_lines(text.splitlines(keepends=True))
    assert wbs_parser._parse_parents(kinds) == want


# #764 — one write path: prepare_write, write_markdown(check=), write_document


def test_write_document_writes_bytes_verbatim(variants):
    p = variants["crlf-nofinal"]
    text = p.read_bytes().decode("utf-8")
    p.write_bytes(b"old")
    wbs_parser.write_document(p, text)
    assert p.read_bytes() == text.encode("utf-8")
    assert not p.read_bytes().endswith(b"\n")


def test_write_document_exclusive(tmp_path):
    p = tmp_path / "new.md"
    wbs_parser.write_document(p, "x\n", exclusive=True)
    assert p.read_bytes() == b"x\n"
    with pytest.raises(FileExistsError):
        wbs_parser.write_document(p, "y\n", exclusive=True)
    assert p.read_bytes() == b"x\n"


def test_prepare_write_returns_the_text_and_writes_nothing(tmp_path):
    p = _w(tmp_path)
    tree = wbs_parser.parse_file(p)
    tree["children"][1]["glyph"] = "x"
    want = W_MD.replace("- [ ] B {", "- [x] B {")
    assert wbs_parser.prepare_write(p, tree) == want
    assert p.read_bytes() == W_MD.encode("utf-8")
    tree["children"] = tree["children"][:1]
    with pytest.raises(wbs_parser._NodeRemoved,
                       match=re.escape(f"{p} line 7: node 'B' is not in the tree")):
        wbs_parser.prepare_write(p, tree)
    assert p.read_bytes() == W_MD.encode("utf-8")


def test_write_markdown_check_veto(tmp_path):
    p = _w(tmp_path)
    tree = wbs_parser.parse_file(p)
    tree["children"][1]["glyph"] = "x"
    want = W_MD.replace("- [ ] B {", "- [x] B {")
    seen = []

    def veto(old, new):
        seen.append((old, new))
        return False

    with pytest.raises(ValueError, match=re.escape(f"{p} check refused the write")):
        wbs_parser.write_markdown(p, tree, check=veto)
    assert seen == [(W_MD, want)]
    assert p.read_bytes() == W_MD.encode("utf-8")
    assert wbs_parser.write_markdown(p, tree, check=lambda old, new: True) is True
    assert p.read_bytes() == want.encode("utf-8")


@pytest.fixture
def doc_writes(monkeypatch):
    calls = []
    monkeypatch.setattr(
        wbs_parser, "write_document",
        lambda path, text, *, exclusive=False: calls.append((path, text, exclusive)),
    )
    return calls


def test_write_markdown_routes_through_write_document(tmp_path, doc_writes):
    p = _w(tmp_path)
    tree = wbs_parser.parse_file(p)
    assert wbs_parser.write_markdown(p, tree) is False
    assert doc_writes == []
    tree["children"][1]["glyph"] = "x"
    assert wbs_parser.write_markdown(p, tree) is True
    assert doc_writes == [(p, W_MD.replace("- [ ] B {", "- [x] B {"), False)]


def test_check_runs_on_a_noop_render(tmp_path, doc_writes):
    p = _w(tmp_path)
    tree = wbs_parser.parse_file(p)
    with pytest.raises(ValueError, match=re.escape(f"{p} check refused the write")):
        wbs_parser.write_markdown(p, tree, check=lambda old, new: False)
    assert doc_writes == []


# #764 — the `render` CLI refuses removals unless given --allow-removals

LEAF_B = "  - [~] Leaf B {issue: Issue-2, est: 1w, depends_on: Issue-1}\n"
RENDER_USAGE = "usage: wbs-parser.py {parse|edges|leaves|render [--allow-removals]} <path>"


def _cli_tree(tmp_path, variants, edit):
    p = variants["lf"]
    tree = wbs_parser.parse_file(p)
    edit(tree)
    j = tmp_path / "tree.json"
    j.write_bytes(json.dumps(tree).encode("utf-8"))
    return p, str(j)


def _render_cli(*args):
    """(rc, stdout bytes, stderr text); stderr's line ends are the host's."""
    res = subprocess.run([sys.executable, PARSER, "render", *args], capture_output=True)
    return res.returncode, res.stdout, res.stderr.decode("utf-8").replace("\r\n", "\n")


def _drop_leaf_b(tree):
    epic = tree["children"][0]
    epic["children"] = [n for n in epic["children"] if n["text"] != "Leaf B"]


def test_render_cli_refuses_a_removed_node(tmp_path, variants):
    _p, j = _cli_tree(tmp_path, variants, _drop_leaf_b)
    rc, out, err = _render_cli(j)
    assert rc == 1
    assert out == b""
    assert err == (
        "wbs-parser.py render: line 17: node 'Leaf B' is not in the tree; "
        "pass --allow-removals to drop removed nodes\n"
    )


def test_render_cli_allow_removals_drops_the_line(tmp_path, variants):
    p, j = _cli_tree(tmp_path, variants, _drop_leaf_b)
    rc, out, err = _render_cli("--allow-removals", j)
    assert (rc, err) == (0, "")
    assert out == p.read_bytes().replace(LEAF_B.encode("utf-8"), b"")


def test_render_cli_allow_removals_after_the_path(tmp_path, variants):
    p, j = _cli_tree(tmp_path, variants, _drop_leaf_b)
    rc, out, err = _render_cli(j, "--allow-removals")
    assert (rc, err) == (0, "")
    assert out == p.read_bytes().replace(LEAF_B.encode("utf-8"), b"")


def test_render_cli_unknown_flag_is_a_usage_error(tmp_path, variants):
    _p, j = _cli_tree(tmp_path, variants, _drop_leaf_b)
    rc, out, err = _render_cli("--allow-removal", j)
    assert rc == 2
    assert out == b""
    assert err.splitlines() == [
        "wbs-parser.py render: unknown flag '--allow-removal'",
        RENDER_USAGE,
    ]


def test_render_cli_move_refusal_has_no_hint(tmp_path, variants):
    _p, j = _cli_tree(tmp_path, variants, lambda t: t["children"][0]["children"].reverse())
    rc, out, err = _render_cli("--allow-removals", j)
    assert rc == 1
    assert out == b""
    assert err == (
        "wbs-parser.py render: line 15: node 'Leaf A' moved; "
        "moving or reordering nodes is not supported\n"
    )


# #780 — the parser reads one-line `<!-- wbs-<key>: <value> -->` directives
# Twin of test_wbs_import.py::test_exclusions_parse_one_line_union's text.
EXCL_TEXT = ("<!-- wbs-exclude: Issue-1, Issue-2 -->\n"          # 1
             "  <!-- wbs-exclude: Issue-5 Issue-6,Issue-7 -->\n"  # 2 indented, mixed separators
             "```\n<!-- wbs-exclude: Issue-9 -->\n```\n"          # 3-5 fenced: not read
             "<!-- wbs-exclude: #4, Issue-8 -->\n"                # 6 a bad token
             "<!-- wbs-exclude: Issue-3\n-->\n"                   # 7-8 two lines
             "<!-- wbs-exclude Issue-5 -->\n"                     # 9 no colon
             "<!-- WBS-Exclude: Issue-5 -->\n"                    # 10 wrong case
             "Prose names the wbs-exclude: Issue-11 convention.\n"  # 11 silent
             "<!-- wbs-exclude: 12 -->\n"                         # 12 a bare id
             "<!-- wbs-exclude: Issue-5. Issue-x Issue-99 -->\n")  # 13 bad shapes; 99 well formed
EXCL_IDS = [(1, "Issue-1"), (1, "Issue-2"), (2, "Issue-5"), (2, "Issue-6"), (2, "Issue-7"),
            (6, "Issue-8"), (12, "12"), (13, "Issue-5."), (13, "Issue-x"), (13, "Issue-99")]


def _excl_warnings():
    near = f"not an exclusion line ({wbs_parser.EXCLUDE_WANT}); ignored"
    return ["line 6: '#4' is not an issue id; ignored",
            f"line 7: {near}", f"line 9: {near}", f"line 10: {near}"]


def test_parse_text_exclusions_are_grammar_only():
    tree = wbs_parser.parse_text(EXCL_TEXT)
    assert tree["exclusions"] == EXCL_IDS
    assert tree["exclusion_warnings"] == _excl_warnings()
    # the fenced line 4 and the prose line 11 give nothing
    assert not [ln for ln, _i in tree["exclusions"] if ln in (4, 11)]
    assert not [w for w in tree["exclusion_warnings"]
                if w.startswith(("line 4:", "line 11:"))]


def test_parse_text_collects_but_never_prints_exclusion_warnings(capsys):
    wbs_parser.parse_text(EXCL_TEXT)
    assert capsys.readouterr().err == ""


def test_parse_text_without_directives_has_empty_exclusion_keys():
    for tree in (wbs_parser.parse_text(""), wbs_parser.parse_file(FIX / "simple.md")):
        assert tree["exclusions"] == []
        assert tree["exclusion_warnings"] == []


def test_directive_reader_reads_only_known_keys():
    assert wbs_parser.DIRECTIVE_KEYS == ("exclude",)
    tree = wbs_parser.parse_text("<!-- wbs-scope: 1-9 -->\n<!-- wbs-foo: x -->\n")
    assert tree["exclusions"] == []
    assert tree["exclusion_warnings"] == []
    kinds, bodies, _ = wbs_parser._classify_lines(["<!-- wbs-exclude: A -->"])
    # The value is RAW: the leading space is the contract #797's key extends;
    # callers strip.
    assert wbs_parser._directives(kinds, bodies) == [(1, "exclude", " A")]


def test_exclusion_grammar_constants_live_in_the_parser():
    assert wbs_parser.EXCLUDE_KEY == "wbs-exclude:"


def test_parse_cli_json_carries_exclusions(tmp_path):
    p = tmp_path / "W.md"
    p.write_bytes(EXCL_TEXT.encode("utf-8"))
    res = subprocess.run([sys.executable, PARSER, "parse", str(p)], capture_output=True,
                         check=True)
    tree = json.loads(res.stdout.decode("utf-8"))
    assert tree["exclusions"] == [[ln, i] for ln, i in EXCL_IDS]
    assert tree["exclusion_warnings"] == _excl_warnings()
    assert all(isinstance(w, str) for w in tree["exclusion_warnings"])


# #780 — inserted_only lives next to render_document
def test_inserted_only_postcondition_fires():
    io = wbs_parser.inserted_only
    old = "a\nb\nc\n"
    assert io(old, old)
    assert io(old, "x\na\nb\ny\nc\nz\n")
    assert not io(old, "a\nB\nc\n")              # a mutated line
    assert not io(old, "a\nc\n")                 # a deleted line
    assert not io(old, "a\nx\nc\nb\n")           # an old line moved
    assert not io(old, "a\r\nb\nc\n")            # a changed terminator
    assert io("a\nb", "a\nb\nx")                 # an unterminated last line gains the EOL
    assert io("a\r\nb", "a\r\nb\r\nx")
    assert not io("a\nb", "a\nb\r\nx")           # ... the file's EOL only
    assert not io("a\nb", "a\nb\n")              # ... and only when a line follows it
    assert not io("a\nb", "a\nbz\nx")


def test_line_ends_is_the_one_eol_rule():
    le = wbs_parser._line_ends
    assert le(["a\r\n", "b"], ["a", "b"]) == (["\r\n", ""], "\r\n")
    assert "a\rb".splitlines(keepends=True) == ["a\r", "b"]
    assert le(["a\r", "b"], ["a", "b"]) == (["\r", ""], "\r")
    assert le([], []) == ([], "\n")


def _defs_named(source, name):
    return sum(1 for n in ast.walk(ast.parse(source))
               if isinstance(n, ast.FunctionDef) and n.name == name)


def test_inserted_only_has_one_home():
    # planted control: the walker sees a definition (the literal is split so
    # the AC's git grep for the definition finds only the real one)
    assert _defs_named("def " + "inserted_only(a, b):\n    pass\n", "inserted_only") == 1
    hits = {p.name: _defs_named(p.read_text(encoding="utf-8"), "inserted_only")
            for p in sorted((REPO / "scripts" / "lib").glob("*.py"))}
    assert {k: v for k, v in hits.items() if v} == {"wbs-parser.py": 1}
