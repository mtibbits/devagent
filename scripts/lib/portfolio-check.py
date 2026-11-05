#!/usr/bin/env python3
"""portfolio-check.py — #725. Validate a portfolio JSON document against
scripts/lib/portfolio-schema.json, using only the Python standard library.

The schema is written in a declared subset of JSON Schema 2020-12 (the
keywords in SCHEMA_KEYWORDS); the loader refuses any other keyword, so a
schema edit cannot silently rely on a rule this checker does not enforce.
docs/portfolio-schema.md is the prose contract.

    portfolio-check.py <document.json>

Exit 0 valid (a newer minor also notes that unknown fields were ignored),
1 invalid, 2 could not run (usage, unreadable file, not strict JSON, schema
load error), 3 unsupported major version.

What this checker does not decide (owned by #726): exit 0 is structural
only. Node id uniqueness, source order and parent links; leaf versus parent
links and `ready` on parents; agreement of issue/est/satisfies/h/depends_on
with `meta`; an estimate class against its hour/quantity/unit fields; one
IssueEntry per distinct issue; `meta_unknown_keys` against `meta`; unique
project names and status against nodes/issues/rollup/wbs_title/status_reason;
the rollup against a recomputation; checklist against next_step; report
entries naming a real project.
"""
from __future__ import annotations

import json
import math
import re
import sys
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

PORTFOLIO_ID = "devagent-portfolio"
USAGE = "usage: portfolio-check.py <document.json>"
MSG_UNSUPPORTED = 'unsupported portfolio schema_version "{document}": this reader supports major {major} (schema {reader})'
MSG_NEWER_MINOR = 'document is schema {document}, newer than this reader\'s {reader}; fields this reader does not know are ignored'
MSG_NO_VERSION = 'portfolio document has no schema_version'
MSG_BAD_VERSION = 'schema_version {value!r} is not MAJOR.MINOR'
MSG_NOT_OBJECT = 'portfolio document is not a JSON object'
MSG_NOT_PORTFOLIO = 'not a devagent portfolio document (schema is {value!r})'

COMPAT_BACKWARDS = 'version went backwards: {old} -> {new}'
COMPAT_REMOVED = 'removed or renamed without a major bump: {path}'
COMPAT_CHANGED = '{attr} changed without a major bump: {path}'
COMPAT_REQUIRED = 'new field is required: {path}'
COMPAT_NO_BUMP = 'schema changed without a version bump: {path}'
COMPAT_OPEN = 'field added under a free-form object needs a major bump: {path}'


class SchemaError(Exception):
    """The schema file is unreadable or leaves the declared dialect."""


class DocumentError(Exception):
    """The document could not be read as strict JSON."""


class UnsupportedVersion(Exception):
    """The document's MAJOR differs from the reader's."""

    def __init__(self, document, reader):
        self.document = document
        self.reader = reader
        super().__init__(MSG_UNSUPPORTED.format(
            document=document, major=parse_version(reader)[0], reader=reader))


@dataclass(frozen=True)
class FieldSpec:
    types: frozenset
    required: bool
    enum: tuple | None
    minimum: float | None
    maximum: float | None
    additional: bool | str | None
    reserved: str | None


ROOT_SPEC = FieldSpec(frozenset({"object"}), True, None, None, None, False, None)


def _types(node):
    types = node.get("type")
    return [types] if isinstance(types, str) else types


def _members(node):
    """The allowed values (`const` is a one-member enum), or None."""
    return [node["const"]] if "const" in node else node.get("enum")


def _target(ref):
    return ref.rpartition("/")[2]


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
    done = set()
    for name in defs:
        _cycle_check(name, defs, (), done)
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
    types = _types(node)
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
    # An implicit `true` would let unknown keys pass at the document's own
    # minor, so every object says what it does with them.
    if "object" in types and "additionalProperties" not in node:
        raise SchemaError(f"{where}: an object schema must declare additionalProperties")
    extra = node.get("additionalProperties", True)
    if not isinstance(extra, bool):
        _lint(extra, f"{where}/additionalProperties", defs, root=False)


def _refs(node):
    """Every $defs name a schema node reaches without passing through a $ref."""
    if "$ref" in node:
        yield _target(node["$ref"])
        return
    for sub in node.get("properties", {}).values():
        yield from _refs(sub)
    for key in ("items", "additionalProperties"):
        if isinstance(node.get(key), dict):
            yield from _refs(node[key])


def _cycle_check(name, defs, trail, done):
    if name in trail:
        raise SchemaError(f"$ref cycle: {' -> '.join(trail + (name,))}")
    if name in done:
        return
    for ref in _refs(defs[name]):
        _cycle_check(ref, defs, trail + (name,), done)
    done.add(name)


def _resolve(node, defs):
    while "$ref" in node:
        node = defs[_target(node["$ref"])]
    return node


def _spec(node, required):
    types = frozenset(_types(node))
    members = _members(node)
    enum = None if members is None else tuple(members)
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
        for key, mark in (("items", "[]"), ("additionalProperties", "{}")):
            if isinstance(node.get(key), dict):
                out[prefix + mark] = _spec(_resolve(node[key], defs), False)
                walk(node[key], prefix + mark)

    walk(schema, "")
    return out


def _parent(path):
    """The inventory path that holds `path`'s last segment ('' at the root)."""
    if path.endswith(("[]", "{}")):
        return path[:-2]
    return path.rpartition(".")[0]


def compat_violations(old, new) -> list:
    """Why `new` is not a compatible successor of `old` under the version
    rules; [] when it is. Descriptions and titles are ignored."""
    old_v, new_v = parse_version(old["version"]), parse_version(new["version"])
    if new_v[0] > old_v[0]:
        return []
    if new_v < old_v:
        return [COMPAT_BACKWARDS.format(old=old["version"], new=new["version"])]
    bumped = new_v != old_v
    before, after = inventory(old), inventory(new)
    out = []
    for path, was in before.items():
        now = after.get(path)
        if now is None:
            out.append(COMPAT_REMOVED.format(path=path))
            continue
        slot = was.reserved is not None
        attrs = [("types", was.types != now.types),
                 ("required", was.required != now.required),
                 ("enum", was.enum != now.enum),
                 ("bounds", (was.minimum, was.maximum) != (now.minimum, now.maximum)),
                 ("additional", was.additional != now.additional and not slot),
                 ("reserved", was.reserved != now.reserved and now.reserved is not None)]
        out.extend(COMPAT_CHANGED.format(attr=a, path=path) for a, hit in attrs if hit)
        defined = slot and (now.reserved is None or was.additional != now.additional)
        if defined and not bumped:
            out.append(COMPAT_NO_BUMP.format(path=path))
    for path, now in after.items():
        if path in before:
            continue
        parent = _parent(path)
        # The root is never in the inventory, and always exists.
        holder = before.get(parent) if parent else ROOT_SPEC
        if holder is not None and holder.reserved is None:
            if now.required:
                out.append(COMPAT_REQUIRED.format(path=path))
            # An older reader checks every key of a free-form object against
            # its schema, so declaring one there is not additive. Under
            # `additionalProperties: true` the older reader accepts the key.
            if holder.additional == "schema":
                out.append(COMPAT_OPEN.format(path=path))
        if not bumped:
            out.append(COMPAT_NO_BUMP.format(path=path))
    return out


def _refuse_constant(name):
    raise ValueError(f"{name} is not JSON")


def _finite_float(text):
    value = float(text)
    if not math.isfinite(value):
        raise ValueError(f"{text} is not a finite number")
    return value


def _refuse_duplicates(pairs):
    out = {}
    for key, value in pairs:
        if key in out:
            raise ValueError(f"duplicate key {key!r}")
        out[key] = value
    return out


def read_document(path):
    """Strict JSON: UTF-8 only (no BOM), no NaN/Infinity (nor a number that
    overflows to it), no duplicate keys, no nesting deeper than the stack."""
    try:
        text = Path(path).read_bytes().decode("utf-8")
        return json.loads(text, parse_constant=_refuse_constant,
                          parse_float=_finite_float,
                          object_pairs_hook=_refuse_duplicates)
    except (OSError, ValueError, RecursionError) as e:
        raise DocumentError(f"cannot read {path}: {e}") from e


def _json_type(value):
    if value is None:
        return "null"
    if isinstance(value, bool):
        return "boolean"
    if isinstance(value, int):
        return "integer"
    if isinstance(value, float):
        return "number"
    if isinstance(value, str):
        return "string"
    if isinstance(value, list):
        return "array"
    return "object"


def _bound(b):
    return "" if b is None else b


def _validate(value, node, path, ctx):
    node = _resolve(node, ctx["defs"])
    errors = ctx["errors"]
    types = _types(node)
    jtype = _json_type(value)
    if jtype not in types and not (jtype == "integer" and "number" in types):
        errors.append(f"{path}: expected {'|'.join(types)}, got {jtype}")
        return
    if "x-reserved" in node and value is not None:
        if not ctx["newer"]:
            errors.append(f"{path}: reserved slot must be null in schema {ctx['reader']}")
        return
    members = _members(node)
    if members is not None and not any(
            m == value and type(m) is type(value) for m in members):
        listed = ", ".join(json.dumps(m) for m in members)
        errors.append(f"{path}: {value!r} is not one of {listed}")
        return
    if jtype in ("integer", "number"):
        lo, hi = node.get("minimum"), node.get("maximum")
        if (lo is not None and value < lo) or (hi is not None and value > hi):
            errors.append(f"{path}: {value} is outside {_bound(lo)}..{_bound(hi)}")
            return
    if jtype == "array" and "items" in node:
        for i, item in enumerate(value):
            _validate(item, node["items"], f"{path}[{i}]", ctx)
    if jtype == "object":
        props = node.get("properties", {})
        for name in node.get("required", []):
            if name not in value:
                errors.append(f"{path}: missing required field {name}")
        extra = node.get("additionalProperties", True)
        for name, item in value.items():
            if name in props:
                _validate(item, props[name], f"{path}.{name}", ctx)
            elif isinstance(extra, dict):
                _validate(item, extra, f"{path}.{name}", ctx)
            elif extra is False and not ctx["newer"]:
                errors.append(f"{path}.{name}: unknown field")


def check(doc, schema=None) -> list:
    """Structural errors in `doc`, [] when valid. Raises UnsupportedVersion
    when the document's MAJOR differs from the schema's, and SchemaError when
    `schema` is None and the default schema cannot be loaded."""
    schema = load_schema() if schema is None else schema
    if not isinstance(doc, dict):
        return [MSG_NOT_OBJECT]
    if doc.get("schema") != PORTFOLIO_ID:
        return [MSG_NOT_PORTFOLIO.format(value=doc.get("schema"))]
    if "schema_version" not in doc:
        return [MSG_NO_VERSION]
    try:
        version = parse_version(doc["schema_version"])
    except ValueError as e:
        return [str(e)]
    reader = schema["version"]
    reader_v = parse_version(reader)
    if version[0] != reader_v[0]:
        raise UnsupportedVersion(doc["schema_version"], reader)
    ctx = {"defs": schema.get("$defs", {}), "errors": [], "reader": reader,
           "newer": version[1] > reader_v[1]}
    _validate(doc, schema, "$", ctx)
    return ctx["errors"]


def _say(line):
    sys.stderr.write(f"portfolio-check: {line}\n")


def main(argv) -> int:
    if len(argv) != 1:
        sys.stderr.write(USAGE + "\n")
        return 2
    try:
        doc = read_document(argv[0])
        schema = load_schema()
    except (DocumentError, SchemaError) as e:
        _say(e)
        return 2
    try:
        errors = check(doc, schema)
    except UnsupportedVersion as e:
        _say(e)
        return 3
    for line in errors:
        _say(line)
    if errors:
        return 1
    reader = schema["version"]
    if parse_version(doc["schema_version"]) > parse_version(reader):
        _say(MSG_NEWER_MINOR.format(document=doc["schema_version"], reader=reader))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
