#!/usr/bin/env python3
"""WBS markdown parser and renderer for devAgent.

Source-of-truth format (spec §13.1): markdown bullet hierarchy with
inline `{key: value, ...}` metadata blocks. This module converts that
format to a structured tree (dict-of-dicts/lists) suitable for
JSON serialization and consumption by:

- `scripts/wbs-show.sh` (current renderer)
- `scripts/statusreport.sh` (roll-up + remaining-leaves count)
- v2/v3 renderers (Gantt, MS Project XML, OpenProject API)

The metadata schema is fixed in v1 (spec §13.3) so deferred renderers do
not require migration; additive keys such as `status_src` (#703) and
`mr` (#704) may be added, and renderers ignore keys they do not use. Unknown metadata keys
are preserved verbatim under
`meta` and additionally listed in `meta_unknown_keys` so a future
renderer can decide whether to pass them through or warn.

A node is a `- [g] ...` line outside a fenced code block. A fence opens
on a line of 3+ backticks or tildes (any indent; a backtick run whose
info string holds a backtick is an inline span, not a fence) and closes
on a run of the same character, at least as long, with no info string.
An opener with no closer is not a fence: it is reported on stderr and
the lines after it parse as usual (#701).

The root also carries `source_text`, the file's exact text (an additive
field; the metadata schema is unaffected). `render_document` of a tree
that has it reproduces the document line by line: an unchanged line is
written back byte for byte, a glyph change rewrites one character, a
change to the owned keys `status_src` (#703) and `mr` (#704) splices only
those keys into the meta block (set, replaced or removed in place), and
new nodes (no `source_line`) are inserted as whole lines in the file's
line-ending style. It refuses, with `ValueError`, a removed node line
unless `allow_removals`, and a node whose depth, parent or sibling order
changed (#764). `render_markdown` is `render_document`, removals refused
unless `allow_removals`; a tree without `source_text` renders as v1 does
(`render_nodes`: title plus nodes only).

The root also carries `exclusions` and `exclusion_warnings` (additive,
#780): the ids of one-line `<!-- wbs-exclude: ... -->` directives outside
a fence, as `(line, id)` pairs, and the grammar warnings for malformed
lines and bad tokens, unprefixed. The parser never prints them; whether an
id names a configured source is the caller's check.

Every WBS.md write goes through `write_document`: `write_markdown` is
`prepare_write` (render plus an optional `check(old, new)` veto, writing
nothing) followed by `write_document`.

CLI:
    wbs-parser.py parse <path>          # emits JSON tree to stdout
    wbs-parser.py edges <path>          # emits dependency edges, one per line
    wbs-parser.py leaves <path>         # emits one leaf per line (issue or text)
    wbs-parser.py render [--allow-removals] <json-path>
                                        # JSON tree → markdown to stdout
                                        # (a `parse` tree reproduces the file;
                                        # a removed node exits 1 without the flag)

The Python API (used by tests and by sibling scripts via importlib) is
`parse_file`, `parse_text`, `render_document`, `render_markdown`,
`render_nodes`, `prepare_write`, `write_markdown`, `write_document`,
`leaves`, `dependency_edges`.
"""

from __future__ import annotations

import json
import re
import sys
from collections.abc import Callable
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
    {
        "issue", "est", "cost", "owner", "milestone", "start", "due",
        "depends_on", "status_src", "mr",
    }
)

_BULLET_RE = re.compile(
    r"^(?P<indent>\s*)- \[(?P<glyph>[ x\-!~?P])\]\s+(?P<rest>.+)$"
)
# Match only a *trailing* `{...}` block. `[^{}]` (not `.*`) stops a brace in the
# item text from swallowing the real meta block, which corrupted issue linkage.
_META_BLOCK_RE = re.compile(r"\s*\{(?P<body>[^{}]*)\}\s*$")
_TITLE_RE = re.compile(r"^#\s+(?P<title>.+)$")
_FENCE_RE = re.compile(r"^[ \t]*(?P<run>`{3,}|~{3,})(?P<info>.*)$")


def _body(line: str) -> str:
    """A line without its terminator (`splitlines` decides what ends a line)."""
    parts = line.splitlines()
    return parts[0] if parts else ""


def _indent_width(body: str) -> int:
    # Expand tabs before measuring: the format is 2-space indents, so a
    # leading tab is one level (tabsize 2). Counting a raw tab as one char
    # flattened tab-indented children into siblings.
    b = body.expandtabs(2)
    return len(b) - len(b.lstrip())


def _depth(m: re.Match) -> int:
    return _indent_width(m.group("indent")) // 2 + 1


def _classify_lines(
    lines: list[str],
) -> tuple[list[tuple[str, re.Match | None]], list[str], int | None]:
    """Classify each line as title, node, fence, code or other.

    The one home of the title / node / fence predicate: parse and render
    both call it. Returns `(kinds, bodies, unclosed_at)`: `bodies` are the
    lines without terminators, and `unclosed_at` is the 1-based line of the
    first fence opener that has no closer (and so is not a fence), or None.
    """
    bodies = [_body(line) for line in lines]
    n = len(lines)
    kinds: list[tuple[str, re.Match | None]] = [("other", None)] * n
    unclosed_at: int | None = None
    # Pass 1: pair fence openers with closers. An unpaired opener is `other`.
    i = 0
    while i < n:
        m = _FENCE_RE.match(bodies[i])
        if not m or (m.group("run")[0] == "`" and "`" in m.group("info")):
            i += 1
            continue
        run = m.group("run")
        close = None
        for j in range(i + 1, n):
            c = _FENCE_RE.match(bodies[j])
            if (
                c
                and c.group("run")[0] == run[0]
                and len(c.group("run")) >= len(run)
                and not c.group("info").strip()
            ):
                close = j
                break
        if close is None:
            if unclosed_at is None:
                unclosed_at = i + 1
            i += 1
            continue
        kinds[i] = ("fence", None)
        for j in range(i + 1, close):
            kinds[j] = ("code", None)
        kinds[close] = ("fence", None)
        i = close + 1
    # Pass 2: title and nodes, outside fences only.
    have_title = False
    for i, body in enumerate(bodies):
        if kinds[i][0] != "other":
            continue
        if not have_title:
            m = _TITLE_RE.match(body)
            if m and m.group("title").strip():
                kinds[i] = ("title", m)
                have_title = True
                continue
        m = _BULLET_RE.match(body)
        if m:
            kinds[i] = ("node", m)
    return kinds, bodies, unclosed_at


def _parse_parents(kinds: list[tuple[str, re.Match | None]]) -> dict[int, int]:
    """Map each node line index to its parent's node line index (-1: root).

    The one home of the parser's nesting rule: a node's parent is the
    nearest earlier node of smaller depth. Parse and render both call it.
    """
    parents: dict[int, int] = {}
    stack: list[tuple[int, int]] = [(-1, -1)]  # (depth, line index)
    for i, (kind, m) in enumerate(kinds):
        if kind != "node":
            continue
        depth = _depth(m)
        while stack and stack[-1][0] >= depth:
            stack.pop()
        parents[i] = stack[-1][1]
        stack.append((depth, i))
    return parents


# One-line directives (#780), outside a fence: `<!-- wbs-<key>: <value> -->`.
# `wbs-exclude` ids split on commas and whitespace; several lines form a union.
EXCLUDE_KEY = "wbs-exclude:"
ID_TOKEN_RE = re.compile(r"[A-Za-z0-9][A-Za-z0-9_.-]*")
EXCLUDE_WANT = "want '<!-- wbs-exclude: <id>, ... -->' on one line"
# #797 adds "scope"; the second to land adds its key here
DIRECTIVE_KEYS: tuple[str, ...] = ("exclude",)


def _directives(
    kinds: list[tuple[str, re.Match | None]], bodies: list[str]
) -> list[tuple[int, str, str | None]]:
    """The directive lines as `(line, key, value)`, in line order.

    `value` is the raw text after `wbs-<key>:`; None marks a line starting
    `<!--` that names `wbs-<key>` (any case) but does not parse. Fenced
    lines are not read. A prefix and a suffix test: nothing here backtracks
    on a long line.
    """
    out: list[tuple[int, str, str | None]] = []
    for ln, ((kind, _m), body) in enumerate(zip(kinds, bodies), start=1):
        if kind in ("fence", "code"):
            continue
        s = body.strip(" \t")
        if not s.startswith("<!--"):
            continue
        inner = s[4:-3].strip() if len(s) >= 7 and s.endswith("-->") else None
        for key in DIRECTIVE_KEYS:
            tag = f"wbs-{key}:"
            if inner is not None and inner.startswith(tag):
                out.append((ln, key, inner[len(tag):]))
            elif f"wbs-{key}" in s.casefold():
                out.append((ln, key, None))
    return out


def _exclusions(
    kinds: list[tuple[str, re.Match | None]], bodies: list[str]
) -> tuple[list[tuple[int, str]], list[str]]:
    """The `wbs-exclude` ids as (line, id) pairs, and the grammar warnings.

    Grammar only: a token outside the id charset, or a malformed line, is a
    warning; whether an id names a configured source is the caller's check.
    """
    ids: list[tuple[int, str]] = []
    warns: list[str] = []
    for ln, key, value in _directives(kinds, bodies):
        if key != "exclude":
            continue
        if value is None:
            warns.append(f"line {ln}: not an exclusion line ({EXCLUDE_WANT}); ignored")
            continue
        for tok in re.split(r"[,\s]+", value):
            if not tok:
                continue
            if ID_TOKEN_RE.fullmatch(tok):
                ids.append((ln, tok))
            else:
                warns.append(f"line {ln}: '{tok}' is not an issue id; ignored")
    return ids, warns


def parse_file(path: Path | str) -> dict:
    # newline="" keeps CR bytes: Path.read_text translates line endings,
    # and its newline= parameter needs Python 3.13.
    with open(path, encoding="utf-8", newline="") as f:
        return parse_text(f.read())


def parse_text(text: str) -> dict:
    root: dict = {"title": "", "children": [], "source_text": text}
    kinds, bodies, unclosed_at = _classify_lines(text.splitlines(keepends=True))
    root["exclusions"], root["exclusion_warnings"] = _exclusions(kinds, bodies)
    parents = _parse_parents(kinds)
    by_line: dict[int, dict] = {-1: root}
    if unclosed_at is not None:
        print(
            f"wbs-parser: unclosed code fence at line {unclosed_at} ignored; "
            "lines after it are parsed as WBS nodes",
            file=sys.stderr,
        )

    for lineno, (kind, m) in enumerate(kinds, start=1):
        if kind == "title":
            root["title"] = m.group("title").strip()
            continue
        if kind != "node":
            continue
        glyph = m.group("glyph")
        rest = m.group("rest").rstrip()
        depth = _depth(m)
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
        by_line[parents[lineno - 1]]["children"].append(node)
        by_line[lineno - 1] = node
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


class _NodeRemoved(ValueError):
    """`render_document`'s removal refusal, the one `allow_removals` relaxes."""


def render_markdown(tree: dict, *, allow_removals: bool = False) -> str:
    """Render a tree: the document when it carries `source_text`, else v1."""
    if tree.get("source_text") is not None:
        return render_document(tree, allow_removals=allow_removals)
    return render_nodes(tree)


def prepare_write(
    path: Path | str,
    tree: dict,
    check: Callable[[str, str], bool] | None = None,
) -> str:
    """The text `write_markdown(path, tree, check)` would write; writes nothing.

    Renders with removals refused, then runs the optional `check(old, new)`
    veto (#764). Either refusal raises `ValueError` prefixed with `path`.
    """
    try:
        new = render_document(tree)
    except ValueError as e:
        cls = _NodeRemoved if isinstance(e, _NodeRemoved) else ValueError
        raise cls(f"{path} {e}") from None
    if check is not None and not check(tree["source_text"], new):
        raise ValueError(f"{path} check refused the write")
    return new


def write_markdown(
    path: Path | str,
    tree: dict,
    check: Callable[[str, str], bool] | None = None,
) -> bool:
    """`prepare_write`, then write through `write_document` only if it changed.

    Returns whether it wrote. `check` runs even when nothing would change.
    """
    new = prepare_write(path, tree, check)
    if new == tree["source_text"]:
        return False
    write_document(path, new)
    return True


def write_document(path: Path | str, text: str, *, exclusive: bool = False) -> None:
    """Write `text` to `path` as UTF-8 bytes: the one writer of WBS.md bytes.

    `exclusive` refuses an existing file (`FileExistsError`). Bytes, not
    text mode: text mode would turn `\\n` into `\\r\\n` on Windows.
    """
    data = text.encode("utf-8")
    if exclusive:
        with open(path, "xb") as f:
            f.write(data)
    else:
        Path(path).write_bytes(data)


_GLYPH_FOR_STATE = {v: k for k, v in STATE_GLYPHS.items()}


def _glyph(node: dict) -> str:
    return node.get("glyph") or _GLYPH_FOR_STATE.get(node["state"], " ")


def _node_tail(node: dict, glyph: str) -> str:
    """`- [g] text{ meta}`: a node line after its indent."""
    meta_str = _render_meta(node.get("meta", {}))
    suffix = f" {meta_str}" if meta_str else ""
    return f"- [{glyph}] {node['text']}{suffix}"


def render_nodes(tree: dict) -> str:
    """v1 renderer: the title and the node lines, canonical, nothing else."""
    lines: list[str] = []
    title = tree.get("title", "")
    if title:
        lines.append(f"# {title}")
        lines.append("")

    def write(node: dict) -> None:
        indent = "  " * (node["depth"] - 1)
        lines.append(f"{indent}{_node_tail(node, _glyph(node))}")
        for k in node.get("children", []):
            write(k)

    for top in tree.get("children", []):
        write(top)
    return "\n".join(lines) + "\n"


def render_document(tree: dict, *, allow_removals: bool = False) -> str:
    """Re-emit `source_text` line by line, changing only what the tree changed.

    A node owns the line its `source_line` names when that line is a node
    line no earlier node claimed; a node that owns none is new. Owned lines
    are kept verbatim, glyph-patched, or regenerated (text/meta change).
    Every other line is kept verbatim. A new node goes after its preceding
    sibling's owned subtree; with no preceding sibling, just before the
    parent's first existing child, or after the block of a parent that has
    none. Its own children follow it.

    Before any output is built, the node lines are checked in line order and
    the first violation raises `ValueError` (#764):

    - an unowned node line is a removal, `line <n>: node '<text>' is not in
      the tree`, unless `allow_removals`, which drops the line;
    - an owned node whose depth, parent or order among its owned siblings
      differs from its line's at parse time, or an unowned line that a node
      under a new node still names, is a move: `line <n>: node '<text>'
      moved; moving or reordering nodes is not supported`. `allow_removals`
      never relaxes it.

    `<text>` is the source line's own text. New nodes are not a reorder.
    """
    src = tree.get("source_text")
    if src is None:
        raise ValueError("render_document: the tree has no source_text")
    lines = src.splitlines(keepends=True)
    n = len(lines)
    kinds, bodies, _ = _classify_lines(lines)
    terms = [line[len(b):] for line, b in zip(lines, bodies)]
    eol = next((t for t in terms if t in ("\r\n", "\n", "\r")), "\n")

    owner: dict[int, int] = {}  # id(node) -> line index
    by_line: dict[int, dict] = {}  # line index -> node
    # Per owned line, against the parse: its tree parent's line (-1: root)
    # and its previous owned sibling's line (-1: none).
    tree_parent: dict[int, int] = {}
    prev_sibling: dict[int, int] = {}
    carried: set[int] = set()  # lines that nodes inside new subtrees still name

    def carry(node: dict) -> None:
        line = node.get("source_line")
        if isinstance(line, int):
            carried.add(line - 1)
        for k in node.get("children", []):
            carry(k)

    def claim(parent: dict, parent_line: int) -> None:
        prev = -1
        for node in parent.get("children", []):
            i = node.get("source_line", 0) - 1
            if 0 <= i < n and kinds[i][0] == "node" and i not in by_line:
                by_line[i] = node
                owner[id(node)] = i
                tree_parent[i], prev_sibling[i] = parent_line, prev
                prev = i
                claim(node, i)
            else:
                # A new node's whole subtree is new: its children claim nothing.
                carry(node)

    claim(tree, -1)

    parse_parent = _parse_parents(kinds)

    def text_at(i: int) -> str:
        return _split_text_and_meta(kinds[i][1].group("rest").rstrip())[0]

    def moved(i: int) -> ValueError:
        return ValueError(
            f"line {i + 1}: node '{text_at(i)}' moved; moving or reordering nodes is not supported"
        )

    for i, (kind, m) in enumerate(kinds):
        if kind != "node":
            continue
        node = by_line.get(i)
        if node is None:
            # claim() never descends into a new node, so a node moved under
            # one leaves its line unowned: a move, not a removal.
            if i in carried:
                raise moved(i)
            if not allow_removals:
                raise _NodeRemoved(f"line {i + 1}: node '{text_at(i)}' is not in the tree")
        elif (
            node["depth"] != _depth(m)
            or tree_parent[i] != parse_parent[i]
            or prev_sibling[i] > i
        ):
            raise moved(i)

    def block_end(i: int) -> int:
        """Last line of node line i's block (see spec §13.1 / #701)."""
        m = kinds[i][1]
        depth, indent = _depth(m), _indent_width(bodies[i])
        last, in_fence = i, False
        for j in range(i + 1, n):
            kind = kinds[j][0]
            if kind == "code":
                last = j
            elif kind == "fence":
                if not in_fence and _indent_width(bodies[j]) <= indent:
                    break
                in_fence = not in_fence
                last = j
            elif kind == "node":
                if _depth(kinds[j][1]) <= depth:
                    break
                last = j
            elif bodies[j].strip():
                if _indent_width(bodies[j]) <= indent:
                    break
                last = j
        return last

    def subtree_end(node: dict, i: int) -> int:
        """Last line of node line i's block or of any owned descendant's.

        The parser nests by depth alone, so a column-0 line can split a
        node's source block from its later children; anchoring at the block
        end alone would re-parent those children under an inserted node.
        """
        end = block_end(i)
        for k in node.get("children", []):
            j = owner.get(id(k))
            if j is not None:
                end = max(end, subtree_end(k, j))
        return end

    first_node = next((i for i, (k, _m) in enumerate(kinds) if k == "node"), None)
    inserts: dict[int, list[dict]] = {}  # insert after line index (-1: top)

    def place(parent: dict, parent_line: int | None) -> None:
        anchor: int | None = None
        for child in parent.get("children", []):
            i = owner.get(id(child))
            if i is not None:
                anchor = subtree_end(child, i)
                place(child, i)
                continue
            if anchor is None:
                if parent_line is None:
                    anchor = first_node - 1 if first_node is not None else n - 1
                else:
                    kids = [owner[id(k)] for k in parent["children"] if id(k) in owner]
                    anchor = min(kids) - 1 if kids else block_end(parent_line)
            inserts.setdefault(anchor, []).append(child)

    place(tree, None)

    out: list[list[str]] = []  # [body, terminator] per emitted line

    def emit_new(node: dict) -> None:
        indent = "  " * (node["depth"] - 1)
        out.append([indent + _node_tail(node, _glyph(node)), eol])
        for k in node.get("children", []):
            emit_new(k)

    title_line = next((i for i, (k, _m) in enumerate(kinds) if k == "title"), None)
    title = tree.get("title", "")
    if title_line is None and title:
        out.append([f"# {title}", eol])
    for node in inserts.get(-1, []):
        emit_new(node)
    for i in range(n):
        kind, m = kinds[i]
        if kind == "title":
            if title == m.group("title").strip():
                out.append([bodies[i], terms[i]])
            elif title:
                out.append([f"# {title}", terms[i]])
        elif kind == "node":
            node = by_line.get(i)
            if node is not None:
                out.append([_node_body(node, m, bodies[i]), terms[i]])
        else:
            out.append([bodies[i], terms[i]])
        for node in inserts.get(i, []):
            emit_new(node)

    # Only the source's last line can lack a terminator. Anything emitted
    # after it needs one; the output's last line keeps the source's
    # final-newline state.
    for pair in out[:-1]:
        if not pair[1]:
            pair[1] = eol
    if out and n and not terms[-1]:
        out[-1][1] = ""
    return "".join(body + term for body, term in out)


# Meta keys `wbs update` writes; a change to them alone is spliced in place.
OWNED_META_KEYS = ("status_src", "mr")


_OWNED_RES = {
    k: re.compile(rf"(?P<lead>^|,)(?P<pad>\s*){k}\s*:\s*(?P<val>[^,}}]*?)\s*(?=,|$)")
    for k in OWNED_META_KEYS
}


def _node_body(node: dict, m: re.Match, body: str) -> str:
    """An owned node line: verbatim, glyph-patched, spliced, or regenerated."""
    text, meta = _split_text_and_meta(m.group("rest").rstrip())
    glyph = _glyph(node)
    new_meta = node.get("meta", {})
    if node["text"] != text or new_meta != meta:
        spliced = _splice_owned(new_meta, m, body, node["text"])
        if spliced is None:
            return m.group("indent") + _node_tail(node, glyph)
        body = spliced
    if glyph == m.group("glyph"):
        return body
    g = m.start("glyph")
    return body[:g] + glyph + body[g + 1 :]


def _splice_owned(
    new_meta: dict, m: re.Match, body: str, text: str
) -> str | None:
    """`body` with only the owned meta keys changed, or None (#703, #704).

    An existing value is replaced in place. A removed key goes from its
    preceding comma through the end of its value; a first key goes through
    the comma and spaces after it. A missing key is appended just before
    the block's `}` as `, key: value` (no comma in an empty block), in
    `new_meta` order. The result is re-parsed and must give the line's
    `text` and `new_meta`, so it applies only when the text is unchanged
    and the metas differ in owned keys alone; else None and the caller
    regenerates the line.
    """
    if any(not isinstance(new_meta[k], str) or not new_meta[k]
           for k in OWNED_META_KEYS if k in new_meta):
        return None
    rest = m.group("rest").rstrip()
    block = _META_BLOCK_RE.search(rest)
    if block is None:
        return None
    off = m.start("rest") + block.start("body")
    inner = block.group("body")
    for key in OWNED_META_KEYS:
        old = _OWNED_RES[key].search(inner)
        if old is None:
            continue
        if key in new_meta:
            inner = inner[: old.start("val")] + new_meta[key] + inner[old.end("val") :]
        elif old.group("lead"):
            inner = inner[: old.start()] + inner[old.end("val") :]
        else:
            tail = re.match(r"\s*,\s*", inner[old.end("val") :])
            end = old.end("val") + (tail.end() if tail else 0)
            inner = inner[: old.start() + len(old.group("pad"))] + inner[end:]
    for key in new_meta:
        if key in OWNED_META_KEYS and _OWNED_RES[key].search(inner) is None:
            sep = ", " if inner.strip() else ""
            inner = inner + f"{sep}{key}: {new_meta[key]}"
    out = body[:off] + inner + body[off + len(block.group("body")) :]
    check = _BULLET_RE.match(out)
    if check is None:
        return None
    if _split_text_and_meta(check.group("rest").rstrip()) != (text, new_meta):
        return None
    return out


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


_USAGE = "usage: wbs-parser.py {parse|edges|leaves|render [--allow-removals]} <path>"


def _cli(argv: list[str]) -> int:
    if len(argv) < 2:
        print(_USAGE, file=sys.stderr)
        return 2
    cmd = argv[1]
    allow_removals = False
    if cmd == "render":
        args = []
        for tok in argv[2:]:
            if tok == "--allow-removals":
                allow_removals = True
            elif tok.startswith("--"):
                print(f"wbs-parser.py render: unknown flag '{tok}'", file=sys.stderr)
                print(_USAGE, file=sys.stderr)
                return 2
            else:
                args.append(tok)
        argv = argv[:2] + args
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
        try:
            out = render_markdown(tree, allow_removals=allow_removals)
        except ValueError as e:
            # The flag relaxes removals only, so only they name it.
            hint = ""
            if isinstance(e, _NodeRemoved):
                hint = "; pass --allow-removals to drop removed nodes"
            print(f"wbs-parser.py render: {e}{hint}", file=sys.stderr)
            return 1
        # Bytes: text-mode stdout turns `\n` into `\r\n` on Windows.
        sys.stdout.buffer.write(out.encode("utf-8"))
    else:
        print(f"unknown subcommand: {cmd}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(_cli(sys.argv))
