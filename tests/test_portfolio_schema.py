"""Tests for the portfolio JSON schema (#725): scripts/lib/portfolio-schema.json
and its stdlib checker scripts/lib/portfolio-check.py."""
import copy
import importlib.util
import json
import subprocess
import sys
from pathlib import Path

import pytest

REPO = Path(__file__).resolve().parent.parent
LIB = REPO / "scripts" / "lib"
CHECKER = LIB / "portfolio-check.py"
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


# ---------------------------------------------------------------- Task 1


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


# ---------------------------------------------------------------- Task 2


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
    assert version in str(e.value) and "1.0" in str(e.value)
    assert str(e.value) == pc.MSG_UNSUPPORTED.format(
        document=version, major=1, reader="1.0")
    assert (e.value.document, e.value.reader) == (version, "1.0")


def test_cli_unknown_major_exit_3(tmp_path):
    r = _run_cli(_dump(tmp_path, _minimal_doc("2.0")))
    assert r.returncode == 3
    assert "2.0" in r.stderr and "1.0" in r.stderr
    assert r.stdout == ""


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
def test_not_object(doc, tmp_path):
    assert pc.check(doc) == [pc.MSG_NOT_OBJECT]
    r = _run_cli(_dump(tmp_path, doc))
    assert r.returncode == 1
    assert "Traceback" not in r.stderr
    assert r.stderr == f"portfolio-check: {pc.MSG_NOT_OBJECT}\n"


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
}


@pytest.mark.parametrize("name", list(READ_REFUSALS))
def test_read_refusals(name, tmp_path):
    path = tmp_path / "doc.json"
    path.write_bytes(READ_REFUSALS[name])
    with pytest.raises(pc.DocumentError):
        pc.read_document(path)
    r = _run_cli(path)
    assert r.returncode == 2
    assert "Traceback" not in r.stderr
    assert r.stdout == ""


def test_read_document_positive_control(tmp_path):
    path = tmp_path / "doc.json"
    path.write_bytes('{"a": "café", "b": -1.5e3}'.encode("utf-8"))
    assert pc.read_document(path) == {"a": "café", "b": -1500.0}


def test_cli_usage_exit_2(tmp_path):
    good = _dump(tmp_path, _minimal_doc())
    for args in ([], [good, good], [tmp_path / "missing.json"]):
        r = _run_cli(*args)
        assert r.returncode == 2, args
        assert r.stdout == ""
    assert pc.USAGE in _run_cli().stderr


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


def test_newer_minor_ignores_unknown_fields(tmp_path):
    doc = _plant_unknown_fields(_minimal_doc("1.7"))
    assert pc.check(doc) == []
    r = _run_cli(_dump(tmp_path, doc))
    assert r.returncode == 0
    assert r.stdout == ""
    assert r.stderr == "portfolio-check: " + pc.MSG_NEWER_MINOR.format(
        document="1.7", reader="1.0") + "\n"


def test_same_minor_unknown_fields_are_errors():
    errors = pc.check(_plant_unknown_fields(_minimal_doc()))
    assert sorted(errors) == sorted(f"{p}: unknown field" for p in PLANTED_PATHS)
    assert len(errors) == 7


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


# ---------------------------------------------------------------- Task 4


def _example():
    return pc.read_document(EXAMPLE)


def _project(doc, name):
    return next(p for p in doc["projects"] if p["project"] == name)


def test_example_valid():
    assert pc.check(_example()) == []
    r = _run_cli(EXAMPLE)
    assert (r.returncode, r.stdout, r.stderr) == (0, "", "")


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
