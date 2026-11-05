"""Tests for the portfolio JSON schema (#725): scripts/lib/portfolio-schema.json
and its stdlib checker scripts/lib/portfolio-check.py."""
import copy
import importlib.util
import json
import sys
from pathlib import Path

import pytest

REPO = Path(__file__).resolve().parent.parent
LIB = REPO / "scripts" / "lib"
CHECKER = LIB / "portfolio-check.py"


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
