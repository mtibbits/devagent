"""Tests for the portfolio JSON schema (#725): scripts/lib/portfolio-schema.json
and its stdlib checker scripts/lib/portfolio-check.py."""
import ast
import copy
import hashlib
import importlib.util
import json
import re
import subprocess
import sys
from pathlib import Path

import pytest

REPO = Path(__file__).resolve().parent.parent
LIB = REPO / "scripts" / "lib"
CHECKER = LIB / "portfolio-check.py"
DOC = REPO / "docs" / "portfolio-schema.md"
SPEC = REPO / "docs" / "specs" / "2026-05-19-devagent-plugin-design.md"
HISTORY = REPO / "tests" / "fixtures" / "portfolio" / "schema-history"
EXAMPLE = REPO / "tests" / "fixtures" / "portfolio" / "example-1.0.json"


def _load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    # Registered before exec: a frozen dataclass under `from __future__ import
    # annotations` looks its module up in sys.modules while it is being built.
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


pc = _load("portfolio_check", CHECKER)
wbs_parser = _load("wbs_parser", LIB / "wbs-parser.py")


def _schema():
    return copy.deepcopy(pc.load_schema())


def _write_schema(tmp_path, schema):
    path = tmp_path / "schema.json"
    path.write_text(json.dumps(schema), encoding="utf-8")
    return path



def test_schema_loads_and_is_1_0():
    schema = pc.load_schema()
    assert "schema_version" in schema["properties"]
    assert schema["version"] == "1.0"
    assert pc.parse_version(schema["version"]) == (1, 0)


def test_schema_refuses_unsupported_keyword(tmp_path):
    schema = _schema()
    schema["$defs"]["Project"]["properties"]["project"]["pattern"] = "^a"
    with pytest.raises(pc.SchemaError) as e:
        pc.load_schema(_write_schema(tmp_path, schema))
    assert "pattern" in str(e.value)
    assert "Project/properties/project" in str(e.value)


def test_schema_refuses_nonlocal_and_cyclic_ref(tmp_path):
    schema = _schema()
    schema["properties"]["parse_report"]["items"] = {"$ref": "http://x"}
    with pytest.raises(pc.SchemaError, match="http://x"):
        pc.load_schema(_write_schema(tmp_path, schema))
    schema = _schema()
    schema["$defs"]["Loop"] = {"$ref": "#/$defs/Loop"}
    schema["properties"]["forecast"] = {"$ref": "#/$defs/Loop"}
    with pytest.raises(pc.SchemaError, match="cycl"):
        pc.load_schema(_write_schema(tmp_path, schema))


def test_schema_refuses_version_key_off_root(tmp_path):
    schema = _schema()
    schema["$defs"]["Dep"]["version"] = "1.0"
    with pytest.raises(pc.SchemaError, match="version"):
        pc.load_schema(_write_schema(tmp_path, schema))


NODE = "projects[].nodes[]"
INVENTORY_PINS = [
    # (path, types, required, enum, minimum, maximum)
    ("schema", {"string"}, True, ("devagent-portfolio",), None, None),
    ("schema_version", {"string"}, True, None, None, None),
    ("projects[].status", {"string"}, True,
     ("read", "no_wbs", "no_devdoc_dir", "unreadable"), None, None),
    ("projects[].rollup", {"object", "null"}, True, None, None, None),
    (f"{NODE}.depth", {"integer"}, True, None, 1, None),
    (f"{NODE}.est.class", {"string"}, True,
     ("absent", "placeholder", "time", "non-time", "unparseable"), None, None),
    (f"{NODE}.est.src", {"string", "null"}, True,
     ("confirmed", "derived", None), None, None),
    (f"{NODE}.est.low_hours", {"number", "null"}, True, None, None, None),
    (f"{NODE}.h", {"integer", "null"}, True, None, 0, 4),
    (f"{NODE}.satisfies[]", {"string"}, False, None, None, None),
    (f"{NODE}.depends_on[].scope", {"string"}, True, ("local", "foreign"), None, None),
    ("projects[].issues[].stuck.reason", {"string", "null"}, True, None, None, None),
    ("projects[].issues[].next_step_number", {"integer", "null"}, True, None, None, None),
    ("projects[].rollup.remaining.non_time{}", {"number"}, False, None, None, None),
    ("parse_report[].source_line", {"integer", "null"}, True, None, 1, None),
]


@pytest.mark.parametrize("path,types,required,enum,minimum,maximum", INVENTORY_PINS,
                         ids=[p[0] for p in INVENTORY_PINS])
def test_inventory_pins_literal_paths(path, types, required, enum, minimum, maximum):
    spec = pc.inventory(pc.load_schema())[path]
    assert spec.types == frozenset(types)
    assert spec.required is required
    assert spec.enum == enum
    assert spec.minimum == minimum
    assert spec.maximum == maximum
    assert spec.reserved is None


def test_inventory_pins_reserved_slots():
    inv = pc.inventory(pc.load_schema())
    slots = {p: s.reserved for p, s in inv.items() if s.reserved}
    assert slots == {
        "forecast": "#742",
        "projects[].lanes": "#748",
        "projects[].forecast": "#742",
        "projects[].issues[].actuals": "#729",
        "projects[].issues[].estimates": "#736",
    }
    lanes = inv["projects[].lanes"]
    assert lanes.types == frozenset({"object", "null"})
    assert lanes.required is False
    assert lanes.additional is True
    assert inv[f"{NODE}.meta"].additional == "schema"
    assert inv[NODE].additional is False


# Hand count of the field tables in docs/portfolio-schema.md: document 6,
# project 9 + `projects[]`, node 16 + `nodes[]` + `meta{}` + `meta{}[]`
# + `meta_unknown_keys[]` + `satisfies[]` + `depends_on[]`, est 7 + `raw[]`,
# dep 5, issue entry 8 + `issues[]` + `nodes[]`, stuck 3, rollup 2
# (`by_state`, `remaining`) + 7 states x (1 + 4 counts) + remaining 7
# + `non_time{}`, report entry 4 + `parse_report[]`.
INVENTORY_SIZE = 6 + 10 + 22 + 8 + 5 + 10 + 3 + 2 + 35 + 8 + 5


def test_inventory_path_count():
    assert len(pc.inventory(pc.load_schema())) == INVENTORY_SIZE


def test_state_and_glyph_enums_match_parser():
    inv = pc.inventory(pc.load_schema())
    assert set(inv[f"{NODE}.state"].enum) == set(wbs_parser.STATE_GLYPHS.values())
    assert set(inv[f"{NODE}.glyph"].enum) == set(wbs_parser.STATE_GLYPHS)


def test_schema_file_is_lf_utf8_without_bom():
    data = pc.SCHEMA_PATH.read_bytes()
    assert not data.startswith(b"\xef\xbb\xbf")
    assert b"\r" not in data
    data.decode("utf-8")



def _counts(leaves=0, estimated=0, derived=0, unestimated=0):
    return {"leaves": leaves, "estimated": estimated,
            "estimated_derived": derived, "unestimated": unestimated}


def _est(raw=None, cls="absent", low=None, high=None, quantity=None, unit=None, src=None):
    return {"raw": raw, "class": cls, "low_hours": low, "high_hours": high,
            "quantity": quantity, "unit": unit, "src": src}


def _node(id_, parent, depth, leaf, line, issue=None, meta=None, est=None, deps=()):
    return {"id": id_, "parent": parent, "depth": depth, "leaf": leaf,
            "text": f"node {id_}", "state": "pending", "glyph": " ",
            "source_line": line, "issue": issue, "meta": meta or {},
            "meta_unknown_keys": [], "est": est or _est(), "satisfies": [],
            "h": None, "depends_on": list(deps), "ready": None}


def _minimal_doc(version="1.0"):
    """A valid one-project, two-node document (a parent and one leaf)."""
    by_state = {s: _counts() for s in wbs_parser.STATE_GLYPHS.values()}
    by_state["pending"] = _counts(leaves=1, estimated=1)
    dep = {"raw": "Issue-2", "scope": "local", "project": "alpha",
           "issue": "Issue-2", "resolved": None}
    leaf = _node("n2", "n1", 2, True, 2, issue="Issue-1",
                 meta={"issue": "Issue-1", "est": "2h", "depends_on": "Issue-2"},
                 est=_est(raw="2h", cls="time", low=2, high=2), deps=[dep])
    return {
        "schema": "devagent-portfolio",
        "schema_version": version,
        "generated_at": "2026-11-04T00:00:00Z",
        "projects": [{
            "project": "alpha", "status": "read", "status_reason": None,
            "wbs_title": "alpha WBS",
            "nodes": [_node("n1", None, 1, False, 1), leaf],
            "issues": [{"issue": "Issue-1", "nodes": ["n2"], "stuck": None,
                        "checklist": "absent", "next_step": None,
                        "next_step_number": None}],
            "rollup": {"by_state": by_state, "remaining": {
                **_counts(leaves=1, estimated=1), "low_hours": 2,
                "high_hours": 2, "non_time": {}}},
        }],
        "parse_report": [],
    }


def _run_cli(*args, isolated=False):
    flags = ["-I", "-S"] if isolated else []
    return subprocess.run([sys.executable, *flags, str(CHECKER), *map(str, args)],
                          capture_output=True, text=True)


def _main(capsys, *args):
    """main() in-process: (exit code, stdout, stderr)."""
    code = pc.main([str(a) for a in args])
    out, err = capsys.readouterr()
    return code, out, err


def _dump(tmp_path, doc, name="doc.json"):
    path = tmp_path / name
    path.write_text(json.dumps(doc), encoding="utf-8")
    return path


def test_minimal_doc_valid():
    assert pc.check(_minimal_doc()) == []


@pytest.mark.parametrize("version", ["2.0", "0.9"])
def test_unknown_major_refused(version):
    with pytest.raises(pc.UnsupportedVersion) as e:
        pc.check(_minimal_doc(version))
    assert str(e.value) == pc.MSG_UNSUPPORTED.format(
        document=version, major=1, reader="1.0")
    assert (e.value.document, e.value.reader) == (version, "1.0")


def test_cli_unknown_major_exit_3(tmp_path, capsys):
    code, out, err = _main(capsys, _dump(tmp_path, _minimal_doc("2.0")))
    assert (code, out) == (3, "")
    assert "2.0" in err and "1.0" in err


MISSING = object()


@pytest.mark.parametrize("value", [MISSING, 1.0, "1", "1.0.0", "01.0", ""],
                         ids=["missing", "1.0-number", "1", "1.0.0", "01.0", "empty"])
def test_bad_version_forms(value):
    doc = _minimal_doc()
    if value is MISSING:
        del doc["schema_version"]
        expected = pc.MSG_NO_VERSION
    else:
        doc["schema_version"] = value
        expected = pc.MSG_BAD_VERSION.format(value=value)
    assert pc.check(doc) == [expected]


@pytest.mark.parametrize("doc", [None, [], "x"], ids=["null", "list", "string"])
def test_not_object(doc, tmp_path, capsys):
    assert pc.check(doc) == [pc.MSG_NOT_OBJECT]
    assert _main(capsys, _dump(tmp_path, doc)) == (
        1, "", f"portfolio-check: {pc.MSG_NOT_OBJECT}\n")


def test_not_portfolio_id():
    doc = _minimal_doc()
    doc["schema"] = "something-else"
    assert pc.check(doc) == [pc.MSG_NOT_PORTFOLIO.format(value="something-else")]


READ_REFUSALS = {
    "nan": b'{"a": NaN}',
    "infinity": b'{"a": Infinity}',
    "dup-key": b'{"a": 1, "a": 2}',
    "5000-digit-int": b'{"a": ' + b"9" * 5000 + b"}",
    "latin1-bytes": '{"a": "café"}'.encode("latin-1"),
    "bom": b'\xef\xbb\xbf{"a": 1}',
    "truncated": b'{"a": ',
    "deep-nesting": b'{"a": ' + b"[" * 100000 + b"]" * 100000 + b"}",
    "huge-exponent": b'{"a": 1e400}',
}


@pytest.mark.parametrize("name", list(READ_REFUSALS))
def test_read_refusals(name, tmp_path, capsys):
    path = tmp_path / "doc.json"
    path.write_bytes(READ_REFUSALS[name])
    code, out, err = _main(capsys, path)
    assert (code, out) == (2, "")
    assert err.startswith(f"portfolio-check: cannot read {path}: ")


def test_read_document_positive_control(tmp_path):
    path = tmp_path / "doc.json"
    path.write_bytes('{"a": "café", "b": -1.5e3}'.encode("utf-8"))
    assert pc.read_document(path) == {"a": "café", "b": -1500.0}


def test_cli_usage_exit_2(tmp_path, capsys):
    good = _dump(tmp_path, _minimal_doc())
    assert _main(capsys) == (2, "", pc.USAGE + "\n")
    for args in ([good, good], [tmp_path / "missing.json"]):
        code, out, _ = _main(capsys, *args)
        assert (code, out) == (2, ""), args


def test_cli_valid_exit_0_silent(tmp_path):
    r = _run_cli(_dump(tmp_path, _minimal_doc()))
    assert (r.returncode, r.stdout, r.stderr) == (0, "", "")


def _plant_unknown_fields(doc):
    p = doc["projects"][0]
    leaf = p["nodes"][1]
    doc["x_top"] = 1
    p["x_project"] = 1
    leaf["x_node"] = 1
    leaf["est"]["x_est"] = 1
    leaf["depends_on"][0]["x_dep"] = 1
    p["issues"][0]["x_issue"] = 1
    p["rollup"]["x_rollup"] = 1
    return doc


PLANTED_PATHS = [
    "$.x_top", "$.projects[0].x_project", "$.projects[0].nodes[1].x_node",
    "$.projects[0].nodes[1].est.x_est",
    "$.projects[0].nodes[1].depends_on[0].x_dep",
    "$.projects[0].issues[0].x_issue", "$.projects[0].rollup.x_rollup",
]


def test_newer_minor_ignores_unknown_fields(tmp_path, capsys):
    doc = _plant_unknown_fields(_minimal_doc("1.7"))
    assert pc.check(doc) == []
    assert _main(capsys, _dump(tmp_path, doc)) == (
        0, "", "portfolio-check: " + pc.MSG_NEWER_MINOR.format(
            document="1.7", reader="1.0") + "\n")


def test_same_minor_unknown_fields_are_errors():
    errors = pc.check(_plant_unknown_fields(_minimal_doc()))
    assert sorted(errors) == sorted(f"{p}: unknown field" for p in PLANTED_PATHS)


def test_older_minor_document_reads():
    schema = _schema()
    schema["version"] = "1.1"
    schema["$defs"]["Node"]["properties"]["note"] = {"type": "string"}
    assert pc.check(_minimal_doc("1.0"), schema) == []


def _leaf(doc):
    return doc["projects"][0]["nodes"][1]


LEAF_PATH = "$.projects[0].nodes[1]"


def test_type_edges():
    cases = [
        ("source_line", True, f"{LEAF_PATH}.source_line: expected integer, got boolean"),
        ("depth", 1.0, f"{LEAF_PATH}.depth: expected integer, got number"),
        ("h", "3", f"{LEAF_PATH}.h: expected integer|null, got string"),
    ]
    for field, value, expected in cases:
        doc = _minimal_doc()
        _leaf(doc)[field] = value
        assert pc.check(doc) == [expected], field
    doc = _minimal_doc()
    _leaf(doc)["est"]["low_hours"] = 1
    _leaf(doc)["est"]["high_hours"] = 1.5
    assert pc.check(doc) == []


def test_enum_bounds_required():
    doc = _minimal_doc()
    _leaf(doc)["est"]["class"] = "quantity"
    assert pc.check(doc) == [
        f"{LEAF_PATH}.est.class: 'quantity' is not one of "
        '"absent", "placeholder", "time", "non-time", "unparseable"']
    doc = _minimal_doc()
    _leaf(doc)["h"] = 5
    assert pc.check(doc) == [f"{LEAF_PATH}.h: 5 is outside 0..4"]
    doc = _minimal_doc()
    del doc["projects"][0]["status"]
    assert pc.check(doc) == ["$.projects[0]: missing required field status"]


def test_reserved_slot_must_be_null():
    doc = _minimal_doc()
    doc["projects"][0]["lanes"] = {}
    assert pc.check(doc) == [
        "$.projects[0].lanes: reserved slot must be null in schema 1.0"]
    doc = _minimal_doc("1.3")
    doc["projects"][0]["lanes"] = {}
    assert pc.check(doc) == []
    doc = _minimal_doc()
    doc["projects"][0]["lanes"] = None
    assert pc.check(doc) == []


def test_meta_values_shape():
    for bad, expected in ((3, "meta.k: expected string|array, got integer"),
                          ([1], "meta.k[0]: expected string, got integer")):
        doc = _minimal_doc()
        _leaf(doc)["meta"]["k"] = bad
        assert pc.check(doc) == [f"{LEAF_PATH}.{expected}"]
    for good in ([], "x"):
        doc = _minimal_doc()
        _leaf(doc)["meta"]["k"] = good
        assert pc.check(doc) == []



def _example():
    return pc.read_document(EXAMPLE)


def _project(doc, name):
    return next(p for p in doc["projects"] if p["project"] == name)


def test_example_valid(capsys):
    assert pc.check(_example()) == []
    assert _main(capsys, EXAMPLE) == (0, "", "")


def test_example_covers_ac_shapes():
    doc = _example()
    read = [p for p in doc["projects"] if p["status"] == "read"]
    issue_sets = [{i["issue"] for i in p["issues"]} for p in read]
    assert len(read) >= 2 and set.intersection(*issue_sets[:2])
    alpha = _project(doc, "alpha")
    nodes = [n for p in read for n in p["nodes"]]
    leaves = [n for n in nodes if n["leaf"]]
    assert any(len(i["nodes"]) >= 2 for i in alpha["issues"])
    assert any(n["issue"] is None for n in leaves)
    assert {n["est"]["class"] for n in leaves} == {
        "absent", "placeholder", "time", "non-time", "unparseable"}
    assert any(p["status"] == "no_wbs" for p in doc["projects"])
    assert doc["parse_report"] == []
    deps = [d for n in nodes for d in n["depends_on"]]
    assert any(d["scope"] == "foreign" for d in deps)
    assert any(d["scope"] == "local" and ":" in d["raw"] for d in deps)
    issues = [i for p in read for i in p["issues"]]
    assert any(i["stuck"] is not None for i in issues)
    assert any(i["next_step"] is not None for i in issues)
    assert any(isinstance(n["meta"].get("satisfies"), str) and n["satisfies"]
               for n in nodes)
    assert any(isinstance(n["h"], int) for n in nodes)
    assert any(n["h"] is None and "h" in n["meta"] for n in nodes)
    assert any(n["est"]["class"] == "time" and n["est"]["src"] == "derived"
               for n in leaves)
    assert any(not n["leaf"] and n["est"]["raw"] is not None for n in nodes)


def test_example_rollup_literals():
    # Hand-worked from the example: only `time` counts as estimated, `pr`
    # is unestimated, and the parent's 10.5pr is never summed.
    rollup = _project(_example(), "alpha")["rollup"]
    assert rollup["remaining"] == {
        "leaves": 6, "estimated": 1, "estimated_derived": 1, "unestimated": 4,
        "low_hours": 6, "high_hours": 6, "non_time": {"pr": 48}}
    assert rollup["by_state"]["done"] == {
        "leaves": 1, "estimated": 1, "estimated_derived": 0, "unestimated": 0}


def test_example_validates_with_jsonschema_if_installed():
    jsonschema = pytest.importorskip("jsonschema")
    if not hasattr(jsonschema, "Draft202012Validator"):
        pytest.skip(f"jsonschema {jsonschema.__version__} predates 2020-12")
    validator = jsonschema.Draft202012Validator(pc.load_schema())
    validator.validate(_example())


# Digest of every committed history snapshot. A past snapshot never changes;
# a version bump adds a file and a line here.
HISTORY_SHA256 = {
    "1.0": "782fe9fab59ab9b01f41518a683e9eb0f0c97aa8ecba288d6789b3c20d11c9a0",
}


def _snapshots():
    files = sorted(HISTORY.glob("*.json"), key=lambda f: pc.parse_version(f.stem))
    return [(f.stem, f) for f in files]


def test_history_current_version_snapshot():
    live = pc.load_schema()
    snapshot = HISTORY / f"{live['version']}.json"
    remedy = ("the schema changed without a version bump: bump `version` in "
              "scripts/lib/portfolio-schema.json and add its snapshot to "
              "tests/fixtures/portfolio/schema-history/")
    assert snapshot.is_file(), remedy
    assert pc.inventory(pc.load_schema(snapshot)) == pc.inventory(live), remedy


def test_history_digests_pinned():
    present = {v: f for v, f in _snapshots()}
    assert set(present) == set(HISTORY_SHA256)
    for version, path in present.items():
        assert hashlib.sha256(path.read_bytes()).hexdigest() == HISTORY_SHA256[version], version


def test_history_consecutive_compatible():
    chain = [pc.load_schema(f) for _, f in _snapshots()] + [pc.load_schema()]
    pairs = 0
    for old, new in zip(chain, chain[1:]):
        if pc.parse_version(old["version"])[0] == pc.parse_version(new["version"])[0]:
            assert pc.compat_violations(old, new) == [], (old["version"], new["version"])
            pairs += 1
    assert pairs >= 1


def _segments(path):
    out = []
    for part in path.split("."):
        name = part.rstrip("[]{}")
        if name:
            out.append(name)
        out.extend(part[len(name):][i:i + 2] for i in range(0, len(part) - len(name), 2))
    return out


def _spec_at(schema, path):
    """(container, name): the object schema holding `path`'s last segment,
    following $ref into $defs."""
    defs = schema["$defs"]
    *walk, last = _segments(path)
    node = schema
    for seg in walk:
        node = pc._resolve(node, defs)
        if seg == "[]":
            node = node["items"]
        elif seg == "{}":
            node = node["additionalProperties"]
        else:
            node = node["properties"][seg]
    return pc._resolve(node, defs), last


def _rename(path, new_name):
    def edit(schema):
        node, name = _spec_at(schema, path)
        node["properties"][new_name] = node["properties"].pop(name)
        if name in node.get("required", []):
            node["required"] = [new_name if r == name else r for r in node["required"]]
    return edit


def _remove(path):
    def edit(schema):
        node, name = _spec_at(schema, path)
        del node["properties"][name]
        node["required"] = [r for r in node.get("required", []) if r != name]
    return edit


def _set(path, **changes):
    def edit(schema):
        node, name = _spec_at(schema, path)
        field = node["properties"][name]
        for key, value in changes.items():
            if value is None:
                field.pop(key, None)
            else:
                field[key] = value
    return edit


def _add(path, required=False):
    def edit(schema):
        node, name = _spec_at(schema, path)
        node["properties"][name] = {"type": "string"}
        if required:
            node["required"].append(name)
    return edit


def _drop_required(path):
    def edit(schema):
        node, name = _spec_at(schema, path)
        node["required"].remove(name)
    return edit


def _define_actuals(schema):
    node, name = _spec_at(schema, "projects[].issues[].actuals")
    slot = node["properties"][name]
    del slot["x-reserved"]
    slot["additionalProperties"] = False
    slot["properties"] = {"agent_hours": {"type": "number"}}


def _declare_meta_issue(schema):
    # A field under an open (additionalProperties-schema) object: a 1.0 reader
    # checks every meta value against meta{}, so a 1.1 document breaks it.
    node, name = _spec_at(schema, "projects[].nodes[].meta")
    node["properties"][name]["properties"] = {"issue": {"type": "integer"}}


def _open_dep(schema):
    schema["$defs"]["Dep"]["additionalProperties"] = True


EST_CLASS = "projects[].nodes[].est.class"
GUARD_ROWS = [
    # (row id, target path, edit, version, expected violations)
    ("M1", "projects[].nodes[].text", _rename("projects[].nodes[].text", "title"), "1.0", [
        pc.COMPAT_REMOVED.format(path="projects[].nodes[].text"),
        pc.COMPAT_REQUIRED.format(path="projects[].nodes[].title"),
        pc.COMPAT_NO_BUMP.format(path="projects[].nodes[].title")]),
    ("M1-major", "projects[].nodes[].text",
     _rename("projects[].nodes[].text", "title"), "2.0", []),
    ("M2", "projects[].issues[].next_step",
     _remove("projects[].issues[].next_step"), "1.0", [
         pc.COMPAT_REMOVED.format(path="projects[].issues[].next_step")]),
    ("M2-major", "projects[].issues[].next_step",
     _remove("projects[].issues[].next_step"), "2.0", []),
    ("M3", "projects[].nodes[].source_line",
     _set("projects[].nodes[].source_line", type="string", minimum=None), "1.0", [
         pc.COMPAT_CHANGED.format(attr="types", path="projects[].nodes[].source_line"),
         pc.COMPAT_CHANGED.format(attr="bounds", path="projects[].nodes[].source_line")]),
    ("M3-major", "projects[].nodes[].source_line",
     _set("projects[].nodes[].source_line", type="string", minimum=None), "2.0", []),
    ("M4", "projects[].nodes[].text",
     _set("projects[].nodes[].text", type=["string", "null"]), "1.1", [
         pc.COMPAT_CHANGED.format(attr="types", path="projects[].nodes[].text")]),
    ("M5", "projects[].status", _drop_required("projects[].status"), "1.1", [
        pc.COMPAT_CHANGED.format(attr="required", path="projects[].status")]),
    ("M6", EST_CLASS, _set(EST_CLASS, enum=["absent", "placeholder", "time", "non-time",
                                            "unparseable", "guess"]), "1.1", [
        pc.COMPAT_CHANGED.format(attr="enum", path=EST_CLASS)]),
    ("M7", "projects[].nodes[].h", _set("projects[].nodes[].h", maximum=5), "1.1", [
        pc.COMPAT_CHANGED.format(attr="bounds", path="projects[].nodes[].h")]),
    ("M8", "projects[].nodes[]", _add("projects[].nodes[].note"), "1.1", []),
    ("M9", "projects[].nodes[]", _add("projects[].nodes[].note"), "1.0", [
        pc.COMPAT_NO_BUMP.format(path="projects[].nodes[].note")]),
    ("M10", "projects[].nodes[]", _add("projects[].nodes[].note", required=True), "1.1", [
        pc.COMPAT_REQUIRED.format(path="projects[].nodes[].note")]),
    ("M11", "schema_version", _rename("schema_version", "schema_rev"), "1.1", [
        pc.COMPAT_REMOVED.format(path="schema_version"),
        pc.COMPAT_REQUIRED.format(path="schema_rev")]),
    ("M12", "projects[].issues[].actuals", _define_actuals, "1.1", []),
    ("M13", "schema_version", lambda schema: None, "0.9", [
        pc.COMPAT_BACKWARDS.format(old="1.0", new="0.9")]),
    ("M14", "projects[].nodes[].meta", _declare_meta_issue, "1.1", [
        pc.COMPAT_OPEN.format(path="projects[].nodes[].meta.issue")]),
    ("M15", "projects[].nodes[].depends_on[]", _open_dep, "1.1", [
        pc.COMPAT_CHANGED.format(attr="additional", path="projects[].nodes[].depends_on[]")]),
    ("M16", "projects[].nodes[].ready",
     _set("projects[].nodes[].ready", **{"x-reserved": "#999"}), "1.1", [
         pc.COMPAT_CHANGED.format(attr="reserved", path="projects[].nodes[].ready")]),
    ("M17", "projects[].issues[].actuals", _define_actuals, "1.0", [
        pc.COMPAT_NO_BUMP.format(path="projects[].issues[].actuals"),
        pc.COMPAT_NO_BUMP.format(path="projects[].issues[].actuals.agent_hours")]),
]


@pytest.mark.parametrize("row", GUARD_ROWS, ids=[r[0] for r in GUARD_ROWS])
def test_guard_mutation(row):
    _, _, edit, version, expected = row
    baseline = pc.load_schema(HISTORY / "1.0.json")
    mutated = _schema()
    edit(mutated)
    mutated["version"] = version
    assert sorted(pc.compat_violations(baseline, mutated)) == sorted(expected)


def test_guard_rows_target_real_paths():
    inv = pc.inventory(pc.load_schema())
    for row_id, target, *_ in GUARD_ROWS:
        assert target in inv, row_id



def test_checker_imports_stdlib_only():
    stdlib = getattr(sys, "stdlib_module_names", None)
    if stdlib is None:
        pytest.skip("needs Python 3.10+ (sys.stdlib_module_names)")
    tree = ast.parse(CHECKER.read_text(encoding="utf-8"))
    modules = set()
    for node in ast.walk(tree):
        if isinstance(node, ast.Import):
            modules.update(alias.name.split(".")[0] for alias in node.names)
        elif isinstance(node, ast.ImportFrom):
            modules.add(node.module.split(".")[0])
    assert modules, "no imports found: the walk saw nothing"
    assert modules <= set(stdlib) | {"__future__"}, modules - set(stdlib)


def test_checker_runs_isolated():
    r = _run_cli(EXAMPLE, isolated=True)
    assert (r.returncode, r.stdout, r.stderr) == (0, "", "")



def _doc_text():
    return DOC.read_text(encoding="utf-8")


def test_doc_lists_every_schema_field():
    text = _doc_text()
    inv = pc.inventory(pc.load_schema())
    found = [p for p in inv if f"`{p}`" in text]
    assert sorted(set(inv) - set(found)) == []
    assert len(inv) == INVENTORY_SIZE


def test_doc_states_version_rules_verbatim():
    description = pc.load_schema()["description"]
    rules = re.findall(r"\((\d)\) (.*?)(?= \(\d\) |$)", description)
    assert [n for n, _ in rules] == ["1", "2", "3", "4", "5", "6"]
    text = _doc_text()
    for number, rule in rules:
        assert f"{number}. {rule}" in text, number


def test_doc_states_usage_and_exit_codes():
    text = _doc_text()
    assert pc.USAGE in text
    for code in "0123":
        assert re.search(rf"^\| `{code}` \|", text, re.M), code


def test_spec_13_points_at_schema_doc():
    spec = SPEC.read_text(encoding="utf-8")
    section = spec[spec.index("\n## 13."):spec.index("\n## 14.")]
    assert "docs/portfolio-schema.md" in section
