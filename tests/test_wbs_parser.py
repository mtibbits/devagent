"""Tests for scripts/lib/wbs-parser.py."""
import importlib.util
import json
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
FIX = REPO / "tests" / "fixtures" / "wbs"

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
    import tempfile
    with tempfile.NamedTemporaryFile("w", suffix=".md", delete=False) as f:
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
