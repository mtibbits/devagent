#!/usr/bin/env python3
"""WBS markdown parser and renderer for devAgent.

Source-of-truth format (spec §13.1): markdown bullet hierarchy with
inline `{key: value, ...}` metadata blocks. This module converts that
format to a structured tree (dict-of-dicts/lists) suitable for
JSON serialization and consumption by:

- `scripts/wbs-show.sh` (current renderer)
- `scripts/statusreport.sh` (roll-up + remaining-leaves count)
- v2/v3 renderers (Gantt, MS Project XML, OpenProject API)

The schema is fixed in v1 (spec §13.3) so deferred renderers do not
require migration. Unknown metadata keys are preserved verbatim under
`meta` and additionally listed in `meta_unknown_keys` so a future
renderer can decide whether to pass them through or warn.

CLI:
    wbs-parser.py parse <path>          # emits JSON tree to stdout
    wbs-parser.py edges <path>          # emits dependency edges, one per line
    wbs-parser.py leaves <path>         # emits one leaf per line (issue or text)
    wbs-parser.py render <json-path>    # JSON tree → markdown to stdout

The Python API (used by tests and by sibling scripts via importlib) is
`parse_file`, `parse_text`, `render_markdown`, `leaves`,
`dependency_edges`.
"""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path

STATE_GLYPHS: dict[str, str] = {
    " ": "pending",
    "x": "done",
    "-": "skipped",
    "!": "stuck",
    "~": "in_progress",
    "?": "blocked_external",
    "P": "parked",
}

KNOWN_META_KEYS: frozenset[str] = frozenset(
    {"issue", "est", "cost", "owner", "milestone", "start", "due", "depends_on"}
)

_BULLET_RE = re.compile(
    r"^(?P<indent>\s*)- \[(?P<glyph>[ x\-!~?P])\]\s+(?P<rest>.+)$"
)
_META_BLOCK_RE = re.compile(r"\s*\{(?P<body>.*)\}\s*$")
_TITLE_RE = re.compile(r"^#\s+(?P<title>.+)$")


def parse_file(path: Path | str) -> dict:
    return parse_text(Path(path).read_text(encoding="utf-8"))


def parse_text(text: str) -> dict:
    title = ""
    root: dict = {"title": "", "children": []}
    stack: list[tuple[int, dict]] = [(-1, root)]

    for lineno, raw in enumerate(text.splitlines(), start=1):
        if not title:
            m = _TITLE_RE.match(raw)
            if m:
                title = m.group("title").strip()
                root["title"] = title
                continue
        m = _BULLET_RE.match(raw)
        if not m:
            continue
        indent = m.group("indent")
        glyph = m.group("glyph")
        rest = m.group("rest").rstrip()
        depth = len(indent) // 2 + 1
        text_part, meta = _split_text_and_meta(rest)
        unknown = [k for k in meta if k not in KNOWN_META_KEYS]
        node = {
            "text": text_part,
            "state": STATE_GLYPHS.get(glyph, "pending"),
            "glyph": glyph,
            "depth": depth,
            "meta": meta,
            "meta_unknown_keys": unknown,
            "children": [],
            "source_line": lineno,
        }
        while stack and stack[-1][0] >= depth:
            stack.pop()
        parent = stack[-1][1]
        parent["children"].append(node)
        stack.append((depth, node))
    return root


def _split_text_and_meta(rest: str) -> tuple[str, dict]:
    m = _META_BLOCK_RE.search(rest)
    if not m:
        return rest.strip(), {}
    text_part = rest[: m.start()].rstrip()
    meta = _parse_meta(m.group("body"))
    return text_part, meta


def _parse_meta(body: str) -> dict:
    out: dict[str, object] = {}
    i = 0
    n = len(body)
    while i < n:
        while i < n and body[i] in " ,\t":
            i += 1
        if i >= n:
            break
        key_start = i
        while i < n and body[i] not in ":":
            i += 1
        key = body[key_start:i].strip()
        if i >= n or not key:
            break
        i += 1  # consume ':'
        while i < n and body[i] in " \t":
            i += 1
        if i < n and body[i] == "[":
            end = body.find("]", i)
            if end == -1:
                out[key] = body[i + 1 :].strip()
                break
            items = [
                _strip_quotes(x.strip())
                for x in body[i + 1 : end].split(",")
                if x.strip()
            ]
            out[key] = items
            i = end + 1
        elif i < n and body[i] in "\"'":
            quote = body[i]
            i += 1
            val_start = i
            while i < n and body[i] != quote:
                i += 1
            out[key] = body[val_start:i]
            if i < n:
                i += 1
        else:
            val_start = i
            while i < n and body[i] != ",":
                i += 1
            out[key] = body[val_start:i].strip()
    return out


def _strip_quotes(s: str) -> str:
    if len(s) >= 2 and s[0] == s[-1] and s[0] in "\"'":
        return s[1:-1]
    return s


def leaves(tree: dict) -> list[dict]:
    out: list[dict] = []

    def walk(node: dict) -> None:
        kids = node.get("children", [])
        if not kids:
            if "text" in node:
                out.append(node)
            return
        for k in kids:
            walk(k)

    walk(tree)
    return out


def dependency_edges(tree: dict) -> list[tuple[str, str]]:
    edges: list[tuple[str, str]] = []

    def walk(node: dict) -> None:
        if "meta" in node:
            issue = node["meta"].get("issue")
            dep = node["meta"].get("depends_on")
            if issue and dep:
                deps = dep if isinstance(dep, list) else [dep]
                for d in deps:
                    edges.append((issue, d))
        for k in node.get("children", []):
            walk(k)

    walk(tree)
    return edges


def render_markdown(tree: dict) -> str:
    lines: list[str] = []
    title = tree.get("title", "")
    if title:
        lines.append(f"# {title}")
        lines.append("")

    glyph_for_state = {v: k for k, v in STATE_GLYPHS.items()}

    def write(node: dict) -> None:
        indent = "  " * (node["depth"] - 1)
        glyph = node.get("glyph") or glyph_for_state.get(node["state"], " ")
        meta_str = _render_meta(node.get("meta", {}))
        suffix = f" {meta_str}" if meta_str else ""
        lines.append(f"{indent}- [{glyph}] {node['text']}{suffix}")
        for k in node.get("children", []):
            write(k)

    for top in tree.get("children", []):
        write(top)
    return "\n".join(lines) + "\n"


def _render_meta(meta: dict) -> str:
    if not meta:
        return ""
    parts: list[str] = []
    for k, v in meta.items():
        if isinstance(v, list):
            parts.append(f"{k}: [{', '.join(str(x) for x in v)}]")
        elif isinstance(v, str) and (
            "," in v or ":" in v or (" " in v and not v.startswith("@"))
        ):
            parts.append(f'{k}: "{v}"')
        else:
            parts.append(f"{k}: {v}")
    return "{" + ", ".join(parts) + "}"


def _cli(argv: list[str]) -> int:
    if len(argv) < 2:
        print(
            "usage: wbs-parser.py {parse|edges|leaves|render} <path>",
            file=sys.stderr,
        )
        return 2
    cmd = argv[1]
    path = Path(argv[2]) if len(argv) > 2 else None
    if cmd == "parse":
        print(json.dumps(parse_file(path), indent=2))
    elif cmd == "edges":
        for a, b in dependency_edges(parse_file(path)):
            print(f"{a}\t{b}")
    elif cmd == "leaves":
        for leaf in leaves(parse_file(path)):
            issue = leaf.get("meta", {}).get("issue", "")
            print(f"{issue}\t{leaf['text']}")
    elif cmd == "render":
        tree = json.loads(path.read_text(encoding="utf-8"))
        sys.stdout.write(render_markdown(tree))
    else:
        print(f"unknown subcommand: {cmd}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(_cli(sys.argv))
