#!/usr/bin/env python3
"""portfolio-check.py — #725. Validate a portfolio JSON document against
scripts/lib/portfolio-schema.json, using only the Python standard library.

The schema is written in a declared subset of JSON Schema 2020-12 (the
keywords in SCHEMA_KEYWORDS); the loader refuses any other keyword, so a
schema edit cannot silently rely on a rule this checker does not enforce.
docs/portfolio-schema.md is the prose contract.
"""
from __future__ import annotations

import json
import re
from dataclasses import dataclass
from pathlib import Path

SCHEMA_PATH = Path(__file__).resolve().parent / "portfolio-schema.json"

SCHEMA_KEYWORDS = frozenset({
    "$schema", "$id", "$defs", "$ref", "title", "description", "type",
    "properties", "required", "additionalProperties", "items", "enum", "const",
    "minimum", "maximum", "x-reserved", "version",
})
ROOT_ONLY = frozenset({"$schema", "$id", "$defs", "version"})
REF_SIBLINGS = frozenset({"description", "title"})
JSON_TYPES = frozenset({"null", "boolean", "integer", "number", "string", "array", "object"})
REF_RE = re.compile(r"#/\$defs/([A-Za-z0-9_]+)")
VERSION_RE = re.compile(r"(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)")

MSG_BAD_VERSION = 'schema_version {value!r} is not MAJOR.MINOR'


class SchemaError(Exception):
    """The schema file is unreadable or leaves the declared dialect."""


@dataclass(frozen=True)
class FieldSpec:
    types: frozenset
    required: bool
    enum: tuple | None
    minimum: float | None
    maximum: float | None
    additional: bool | str | None
    reserved: str | None


def parse_version(s) -> tuple[int, int]:
    """`MAJOR.MINOR` as an int pair; anything else raises ValueError."""
    m = VERSION_RE.fullmatch(s) if isinstance(s, str) else None
    if not m:
        raise ValueError(MSG_BAD_VERSION.format(value=s))
    return int(m.group(1)), int(m.group(2))


def load_schema(path=None) -> dict:
    """Read the schema and refuse anything outside the declared dialect."""
    path = SCHEMA_PATH if path is None else Path(path)
    try:
        schema = json.loads(Path(path).read_bytes().decode("utf-8"))
    except (OSError, ValueError) as e:
        raise SchemaError(f"cannot read schema {path}: {e}") from e
    if not isinstance(schema, dict):
        raise SchemaError("schema root is not an object")
    defs = schema.get("$defs", {})
    if not isinstance(defs, dict):
        raise SchemaError("#/$defs is not an object")
    try:
        parse_version(schema.get("version"))
    except ValueError as e:
        raise SchemaError(f"schema root version: {e}") from e
    _lint(schema, "#", defs, root=True)
    for name, sub in defs.items():
        _lint(sub, f"#/$defs/{name}", defs, root=False)
    for name in defs:
        _cycle_check(name, defs, ())
    return schema


def _lint(node, where, defs, root):
    if not isinstance(node, dict):
        raise SchemaError(f"{where}: a schema must be an object")
    for key in node:
        if key not in SCHEMA_KEYWORDS:
            raise SchemaError(f"{where}: unsupported keyword {key!r}")
        if key in ROOT_ONLY and not root:
            raise SchemaError(f"{where}: {key!r} is allowed only at the schema root")
    if "$ref" in node:
        ref = node["$ref"]
        m = REF_RE.fullmatch(ref) if isinstance(ref, str) else None
        if not m or m.group(1) not in defs:
            raise SchemaError(f"{where}: $ref {ref!r} is not a local #/$defs/<name>")
        extra = set(node) - REF_SIBLINGS - {"$ref"}
        if extra:
            raise SchemaError(f"{where}: $ref may stand only beside description/title, not {sorted(extra)}")
        return
    types = node.get("type")
    types = [types] if isinstance(types, str) else types
    if not isinstance(types, list) or not types or not set(types) <= JSON_TYPES:
        raise SchemaError(f"{where}: type {node.get('type')!r} is not a JSON type or list of them")
    for key in ("minimum", "maximum"):
        if key in node and (isinstance(node[key], bool) or not isinstance(node[key], (int, float))):
            raise SchemaError(f"{where}: {key} is not a number")
    if "enum" in node and not isinstance(node["enum"], list):
        raise SchemaError(f"{where}: enum is not a list")
    if "x-reserved" in node and not isinstance(node["x-reserved"], str):
        raise SchemaError(f"{where}: x-reserved is not a string")
    props = node.get("properties", {})
    if not isinstance(props, dict):
        raise SchemaError(f"{where}: properties is not an object")
    required = node.get("required", [])
    if not isinstance(required, list) or not set(required) <= set(props):
        raise SchemaError(f"{where}: required names a field not in properties")
    for name, sub in props.items():
        _lint(sub, f"{where}/properties/{name}", defs, root=False)
    if "items" in node:
        _lint(node["items"], f"{where}/items", defs, root=False)
    extra = node.get("additionalProperties", True)
    if not isinstance(extra, bool):
        _lint(extra, f"{where}/additionalProperties", defs, root=False)


def _refs(node):
    """Every $defs name a schema node reaches without passing through a $ref."""
    if "$ref" in node:
        yield REF_RE.fullmatch(node["$ref"]).group(1)
        return
    for sub in node.get("properties", {}).values():
        yield from _refs(sub)
    for key in ("items", "additionalProperties"):
        if isinstance(node.get(key), dict):
            yield from _refs(node[key])


def _cycle_check(name, defs, trail):
    if name in trail:
        raise SchemaError(f"$ref cycle: {' -> '.join(trail + (name,))}")
    for ref in _refs(defs[name]):
        _cycle_check(ref, defs, trail + (name,))


def _resolve(node, defs):
    while "$ref" in node:
        node = defs[REF_RE.fullmatch(node["$ref"]).group(1)]
    return node


def _spec(node, required):
    types = node["type"]
    types = frozenset([types] if isinstance(types, str) else types)
    if "const" in node:
        enum = (node["const"],)
    else:
        enum = tuple(node["enum"]) if "enum" in node else None
    if "object" in types:
        extra = node.get("additionalProperties", True)
        additional = extra if isinstance(extra, bool) else "schema"
    else:
        additional = None
    return FieldSpec(types, required, enum, node.get("minimum"), node.get("maximum"),
                     additional, node.get("x-reserved"))


def inventory(schema) -> dict:
    """Flatten the schema to {path: FieldSpec}. Paths are dotted, `[]` marks
    array items and `{}` an additionalProperties schema; $ref is expanded."""
    defs = schema.get("$defs", {})
    out = {}

    def walk(node, prefix):
        node = _resolve(node, defs)
        required = set(node.get("required", []))
        for name, sub in node.get("properties", {}).items():
            path = f"{prefix}.{name}" if prefix else name
            out[path] = _spec(_resolve(sub, defs), name in required)
            walk(sub, path)
        if isinstance(node.get("items"), dict):
            out[prefix + "[]"] = _spec(_resolve(node["items"], defs), False)
            walk(node["items"], prefix + "[]")
        if isinstance(node.get("additionalProperties"), dict):
            out[prefix + "{}"] = _spec(_resolve(node["additionalProperties"], defs), False)
            walk(node["additionalProperties"], prefix + "{}")

    walk(schema, "")
    return out
