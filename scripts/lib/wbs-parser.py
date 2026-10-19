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
id names a configured source is the caller's check. It also carries
`scopes` (additive, #797): the one-line `<!-- wbs-scope: <range> -->`
directives outside a fence, as `(line, value)` pairs, the value stripped
and None for a near-miss line that does not parse; whether the value names
a range is the caller's check.

Every WBS.md write goes through `write_document`: `write_markdown` is
`prepare_write` (render plus an optional `check(old, new)` veto, writing
nothing) followed by `write_document`. `write_update` (`wbs update`) and
`order_file` (`wbs order`) are the order pass's two writers (#803): each
runs `_order` and accepts its text only when `permuted_only` does.

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
`inserted_only`, `leaves`, `dependency_edges`, and for the order pass
(#803) `order_text`, `permuted_only`, `write_update`, `order_file` and
`unified_diff`; wbs-import.py also reads the
exclusion grammar's `ID_TOKEN_RE`, `NOT_AN_ID` and `warning_line`, and the
scope directive's `SCOPE_KEY` and `SCOPE_TAG`.
"""

from __future__ import annotations

import difflib
import heapq
import json
import re
import sys
from collections import Counter
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
        "depends_on", "status_src", "mr", "priority",
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
ID_TOKEN_RE = re.compile(r"[A-Za-z0-9][A-Za-z0-9_.-]*")
ID_SPLIT_RE = re.compile(r"[,\s]+")
EXCLUDE_WANT = "want '<!-- wbs-exclude: <id>, ... -->' on one line"
# An exclusion warning is `line N: <text>`; wbs-import.py adds its own
# source-check warnings in the same shape and orders by `warning_line`.
NOT_AN_ID = "line {}: '{}' is not an issue id; ignored"
EXCLUDE = "exclude"
SCOPE = "scope"
DIRECTIVE_KEYS: tuple[str, ...] = (EXCLUDE, SCOPE)
EXCLUDE_KEY = f"wbs-{EXCLUDE}:"
SCOPE_TAG = f"wbs-{SCOPE}"
SCOPE_KEY = f"{SCOPE_TAG}:"


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
        folded = s.casefold()
        for key in DIRECTIVE_KEYS:
            tag = f"wbs-{key}:"
            if inner is not None and inner.startswith(tag):
                out.append((ln, key, inner[len(tag):]))
            elif tag[:-1] in folded:
                out.append((ln, key, None))
    return out


def warning_line(warning: str) -> int:
    """The N of an `exclusion_warnings` entry, `line N: ...`."""
    return int(warning[len("line "):warning.index(":")])


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
        if key != EXCLUDE:
            continue
        if value is None:
            warns.append(f"line {ln}: not an exclusion line ({EXCLUDE_WANT}); ignored")
            continue
        for tok in ID_SPLIT_RE.split(value):
            if not tok:
                continue
            if ID_TOKEN_RE.fullmatch(tok):
                ids.append((ln, tok))
            else:
                warns.append(NOT_AN_ID.format(ln, tok))
    return ids, warns


def _scopes(
    kinds: list[tuple[str, re.Match | None]], bodies: list[str]
) -> list[tuple[int, str | None]]:
    """The `wbs-scope` lines as (line, value), in line order.

    Grammar only: the value is stripped (an empty one stays ""), and None
    marks a near-miss, a comment whose text starts `wbs-scope` (any case)
    but does not parse. A comment that only mentions the key elsewhere is
    no entry. Whether the value names a range is wbs-import.py's check.
    """
    out: list[tuple[int, str | None]] = []
    for ln, key, value in _directives(kinds, bodies):
        if key != SCOPE:
            continue
        if value is not None:
            out.append((ln, value.strip()))
        elif bodies[ln - 1].strip(" \t")[4:].lstrip().casefold().startswith(SCOPE_TAG):
            out.append((ln, None))
    return out


def parse_file(path: Path | str) -> dict:
    # newline="" keeps CR bytes: Path.read_text translates line endings,
    # and its newline= parameter needs Python 3.13.
    with open(path, encoding="utf-8", newline="") as f:
        return parse_text(f.read())


def parse_text(text: str) -> dict:
    root: dict = {"title": "", "children": [], "source_text": text}
    kinds, bodies, unclosed_at = _classify_lines(text.splitlines(keepends=True))
    root["exclusions"], root["exclusion_warnings"] = _exclusions(kinds, bodies)
    root["scopes"] = _scopes(kinds, bodies)
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


def _dep_ids(meta: dict) -> list[str]:
    """A node's `depends_on` entries as a list (a scalar is one entry)."""
    dep = meta.get("depends_on")
    if not dep:
        return []
    return dep if isinstance(dep, list) else [dep]


def dependency_edges(tree: dict) -> list[tuple[str, str]]:
    edges: list[tuple[str, str]] = []

    def walk(node: dict) -> None:
        if "meta" in node:
            issue = node["meta"].get("issue")
            if issue:
                for d in _dep_ids(node["meta"]):
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


def write_update(
    path: Path | str, tree: dict, *, order: bool, completed_last: bool = False
) -> list[str]:
    """`wbs update`'s one write (#803): render, then order, then write.

    The base U is `prepare_write(path, tree)` (its refusals raise). With
    `order`, U is ordered and the result kept only when `permuted_only`
    accepts it; else U is written and the report is the skip line alone,
    since the order warnings describe a text it does not write. Writes
    through `write_document` only when the text differs from the file's.
    Returns the report lines, unprefixed.
    """
    final = prepare_write(path, tree)
    report: list[str] = []
    if order:
        ordered, warnings, _n, _m = _order(final, completed_last)
        ok, reason = permuted_only(final, ordered)
        if ok:
            final, report = ordered, warnings
        else:
            report = [f"ordering skipped: {reason}"]
    if final != tree["source_text"]:
        write_document(path, final)
    return report


def order_file(
    path: Path | str, *, completed_last: bool = False, dry_run: bool = False
) -> tuple[int, list[str], str]:
    """`wbs order`'s run (#803): `(rc, report lines unprefixed, diff)`.

    rc 1 for an unreadable or non-UTF-8 file, a failed `permuted_only`
    check (nothing written) or a failed write. `dry_run` writes nothing and
    returns the `unified_diff`.
    """
    dest = str(path)
    try:
        text = Path(path).read_bytes().decode("utf-8")
    except (OSError, UnicodeDecodeError) as e:
        return 1, [f"cannot read {dest}: {e}"], ""
    ordered, report, n, m = _order(text, completed_last)
    ok, reason = permuted_only(text, ordered)
    if not ok:
        return 1, [f"ordering skipped: {reason}; nothing written"], ""
    if dry_run:
        if ordered == text:
            report.append("already in order")
        else:
            report.append(f"would reorder {n} of {m} sibling sets in {dest}")
        report.append("dry run; nothing written")
        return 0, report, unified_diff(text, ordered)
    if ordered == text:
        return 0, report + ["already in order"], ""
    try:
        write_document(path, ordered)
    except OSError as e:
        return 1, report + [f"cannot write {dest}: {e}"], ""
    return 0, report + [f"reordered {n} of {m} sibling sets in {dest}"], ""


def unified_diff(old: str, new: str) -> str:
    """A unified diff of WBS.md, labelled `a/WBS.md` and `b/WBS.md`; empty
    when equal. A side's unterminated last line is followed by a
    `\\ No newline at end of file` line."""
    if old == new:
        return ""
    out: list[str] = []
    for line in difflib.unified_diff(
        old.splitlines(keepends=True), new.splitlines(keepends=True), "a/WBS.md", "b/WBS.md"
    ):
        out.append(line)
        if not line.endswith(("\n", "\r")):
            out.append("\n\\ No newline at end of file\n")
    return "".join(out)


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
    terms, eol = _line_ends(lines, bodies)

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

    def subtree_end(node: dict, i: int) -> int:
        """Last line of node line i's block or of any owned descendant's.

        The parser nests by depth alone, so a column-0 line can split a
        node's source block from its later children; anchoring at the block
        end alone would re-parent those children under an inserted node.
        """
        end = _block_end(kinds, bodies, i)
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
                    anchor = min(kids) - 1 if kids else _block_end(kinds, bodies, parent_line)
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

    return _join(out, eol, bool(n) and not terms[-1])


def _block_end(
    kinds: list[tuple[str, re.Match | None]], bodies: list[str], i: int
) -> int:
    """Last line of node line i's block (see spec §13.1 / #701).

    The one block rule: `render_document` places inserts by it and
    `order_text` moves whole blocks by it.
    """
    m = kinds[i][1]
    depth, indent = _depth(m), _indent_width(bodies[i])
    last, in_fence = i, False
    for j in range(i + 1, len(kinds)):
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


def _join(out: list, eol: str, open_end: bool) -> str:
    """Join `[body, terminator]` pairs by #701's rule.

    Only the source's last line can lack a terminator. Anything emitted
    after it needs one (`eol`); the output's last line keeps the source's
    final-newline state (`open_end`: the source's last line had none).
    """
    last = len(out) - 1
    parts: list[str] = []
    for k, (body, term) in enumerate(out):
        if k < last and not term:
            term = eol
        elif k == last and open_end:
            term = ""
        parts.append(body + term)
    return "".join(parts)


def _line_ends(lines: list[str], bodies: list[str]) -> tuple[list[str], str]:
    """Each line's terminator, and the file's EOL: the first of `\\r\\n`,
    `\\n` or `\\r` among them, else `\\n` (#701). `render_document` and
    `inserted_only` share it."""
    terms = [line[len(b):] for line, b in zip(lines, bodies)]
    return terms, next((t for t in terms if t in ("\r\n", "\n", "\r")), "\n")


def inserted_only(old: str, new: str) -> bool:
    """Whether `new` is `old` with whole lines inserted: old's lines appear
    in order in new, each with its terminator. The one exception, #701's
    rule: an unterminated old last line may gain the file's EOL when a line
    follows it."""
    olds, news = old.splitlines(keepends=True), new.splitlines(keepends=True)
    terms, eol = _line_ends(olds, [_body(ln) for ln in olds])
    j = 0
    for i, line in enumerate(olds):
        last_open = i == len(olds) - 1 and not terms[i]
        while j < len(news):
            got = news[j]
            j += 1
            if got == line and not (last_open and j < len(news)):
                break
            if last_open and got == line + eol and j < len(news):
                break
        else:
            return False
    return True


# The order pass (#803): each non-root node's children, by dependency, then
# inherited priority, then fan-out. Text in, text out, after any render.
PRIORITY_RE = re.compile(r"P[1-4]")
DEFAULT_PRIORITY = 3
FINISHED_GLYPHS = frozenset("x-")


def order_text(text: str, *, completed_last: bool = False) -> tuple[str, list[str]]:
    """`text` with each non-root node's children in order, and the warnings.

    The rule (spec §13.1): a node is finished when its own glyph is `[x]` or
    `[-]`. Within one set of siblings, open sibling S follows open sibling T
    when an open node under S (S included) has a `depends_on` entry naming
    the `issue` of an open node under T; ids match by exact string. Among the
    siblings whose dependencies are placed, the next is the one with the
    most urgent effective priority (the most urgent `priority: P1`-`P4` of
    the open nodes under it or under any sibling depending on it,
    transitively; P3 when none), then the most transitive dependents, then
    its current position. Finished siblings keep their slots, or with
    `completed_last` follow the open ones in their old order. Top-level
    nodes never move.

    A set is left as it is, with one warning naming its parent's line, when
    a line separates two of its sibling blocks, a sibling's subtree is not
    one block (`_block_end`), the siblings differ in depth, or the siblings
    form a dependency cycle. Each malformed `priority` warns once and counts
    as missing. Warning line numbers are those of the returned text.
    """
    new, warnings, _n, _m = _order(text, completed_last)
    return new, warnings


def _order(text: str, completed_last: bool) -> tuple[str, list[str], int, int]:
    """`order_text`, plus N (sets reordered) and M (sets of two or more
    siblings under a non-root parent, the ones left alone included)."""
    lines = text.splitlines(keepends=True)
    kinds, bodies, _ = _classify_lines(lines)
    terms, eol = _line_ends(lines, bodies)
    parents = _parse_parents(kinds)
    kids: dict[int, list[int]] = {}
    for i, p in parents.items():
        kids.setdefault(p, []).append(i)
    ends = {i: _block_end(kinds, bodies, i) for i in parents}
    is_open: dict[int, bool] = {}
    texts: dict[int, str] = {}
    metas: dict[int, dict] = {}
    prio: dict[int, int | None] = {}
    # (U line index, message given the U-index -> output-line-number map)
    warns: list[tuple[int, Callable[[Callable[[int], int]], str]]] = []
    for i in parents:
        m = kinds[i][1]
        is_open[i] = m.group("glyph") not in FINISHED_GLYPHS
        texts[i], metas[i] = _split_text_and_meta(m.group("rest").rstrip())
        v = metas[i].get("priority")
        prio[i] = None
        if isinstance(v, str) and PRIORITY_RE.fullmatch(v):
            prio[i] = int(v[1])
        elif "priority" in metas[i]:
            shown = f"[{', '.join(v)}]" if isinstance(v, list) else v
            warns.append((i, lambda L, i=i, shown=shown:
                          f"line {L(i)}: priority '{shown}' is not P1, P2, P3 or P4; ignored"))

    def subtree(i: int) -> list[int]:
        out = [i]
        for c in kids.get(i, []):
            out.extend(subtree(c))
        return out

    def name(c: int) -> str:
        issue = metas[c].get("issue")
        return issue if isinstance(issue, str) and issue else texts[c]

    runs: dict[int, tuple[list[tuple[int, int]], int]] = {}
    n_sets = m_sets = 0
    for p, cs in kids.items():
        if p == -1 or len(cs) < 2:
            continue
        m_sets += 1
        why = _left_alone(cs, kinds, ends, subtree)
        new = None
        if why is None:
            new, cycle = _rank(cs, is_open, metas, prio, subtree, completed_last)
            if new is None:
                names = ", ".join(name(c) for c in cycle)
                why = lambda L, names=names: f"dependency cycle among {names}"
        if why is not None:
            warns.append((p, lambda L, p=p, why=why:
                          f"line {L(p)}: children of '{texts[p]}' left in order: {why(L)}"))
        elif new != cs:
            n_sets += 1
            runs[cs[0]] = ([(c, ends[c]) for c in new], ends[cs[-1]])
    out, index_map = _assemble(list(zip(bodies, terms)), runs)

    def line_no(u: int) -> int:
        return index_map[u] + 1

    warns.sort(key=lambda w: line_no(w[0]))
    new_text = _join(out, eol, bool(lines) and not terms[-1])
    return new_text, [fmt(line_no) for _u, fmt in warns], n_sets, m_sets


def _left_alone(cs, kinds, ends, subtree):
    """Why the sibling set `cs` (line indexes) cannot move, or None.

    The reason is a function of the line-number map, since the lines it
    names may move with an enclosing block.
    """
    for c in cs:
        if any(ends[d] > ends[c] for d in subtree(c)[1:]):
            split = ends[c] + 1
            return lambda L, c=c: f"line {L(split)} splits the subtree of line {L(c)}"
    for a, b in zip(cs, cs[1:]):
        if ends[a] + 1 != b:
            gap = ends[a] + 1
            return lambda L: f"line {L(gap)} separates two of them"
    depth = _depth(kinds[cs[0]][1])
    for c in cs[1:]:
        if _depth(kinds[c][1]) != depth:
            return lambda L, c=c: f"line {L(c)} is not at the depth of line {L(cs[0])}"
    return None


def _rank(cs, is_open, metas, prio, subtree, completed_last):
    """The new order of the sibling set `cs`, or `(None, cycle)` where
    `cycle` is the siblings in any dependency cycle, in current order."""
    opens = [c for c in cs if is_open[c]]
    pos = {c: k for k, c in enumerate(opens)}
    holders: dict[str, set[int]] = {}
    own: dict[int, int] = {}
    for c in opens:
        vals = []
        for d in subtree(c):
            if not is_open[d]:
                continue
            issue = metas[d].get("issue")
            if isinstance(issue, str) and issue:
                holders.setdefault(issue, set()).add(c)
            if prio[d] is not None:
                vals.append(prio[d])
        own[c] = min(vals, default=DEFAULT_PRIORITY)
    needs: dict[int, set[int]] = {c: set() for c in opens}  # c follows these
    for c in opens:
        for d in subtree(c):
            if is_open[d]:
                for dep in _dep_ids(metas[d]):
                    needs[c] |= holders.get(dep, set()) - {c}
    dependents: dict[int, set[int]] = {c: set() for c in opens}
    for c in opens:
        for t in needs[c]:
            dependents[t].add(c)
    reach: dict[int, set[int]] = {}
    for c in opens:
        seen: set[int] = set()
        stack = [c]
        while stack:
            for y in dependents[stack.pop()]:
                if y not in seen:
                    seen.add(y)
                    stack.append(y)
        reach[c] = seen
    cycle = [c for c in opens if c in reach[c]]
    if cycle:
        return None, cycle
    key = {c: (min([own[c]] + [own[d] for d in reach[c]]), -len(reach[c]), pos[c])
           for c in opens}
    waiting = {c: len(needs[c]) for c in opens}
    ready = [(key[c], c) for c in opens if not needs[c]]
    heapq.heapify(ready)
    ranked: list[int] = []
    while ready:
        _k, c = heapq.heappop(ready)
        ranked.append(c)
        for d in dependents[c]:
            waiting[d] -= 1
            if not waiting[d]:
                heapq.heappush(ready, (key[d], d))
    if completed_last:
        return ranked + [c for c in cs if not is_open[c]], None
    it = iter(ranked)
    return [next(it) if is_open[c] else c for c in cs], None


def _assemble(
    pairs: list[tuple[str, str]], runs: dict[int, tuple[list[tuple[int, int]], int]]
) -> tuple[list[tuple[str, str]], list[int]]:
    """The block mover: `pairs` (body, terminator per line) with each sorted
    run re-emitted. `runs` maps a run's first line to its blocks `(start,
    end)` in the new order and the run's last line. Blocks are walked line
    by line, so a sorted run inside a moved block is applied too. Returns
    the lines and `index_map`, where `index_map[u]` is line u's new index.
    """
    out: list[tuple[str, str]] = []
    index_map = [0] * len(pairs)

    def emit(lo: int, hi: int) -> None:
        i = lo
        while i <= hi:
            run = runs.get(i)
            if run is None:
                index_map[i] = len(out)
                out.append(pairs[i])
                i += 1
                continue
            blocks, end = run
            for start, stop in blocks:
                emit_block(start, stop)
            i = end + 1

    def emit_block(start: int, stop: int) -> None:
        # A block's own line is not its run's start again: emit it, then
        # walk the rest of the block for inner runs.
        index_map[start] = len(out)
        out.append(pairs[start])
        emit(start + 1, stop)

    emit(0, len(pairs) - 1)
    return out, index_map


def permuted_only(old: str, new: str) -> tuple[bool, str]:
    """Whether `new` is `old` with only runs of sibling blocks permuted, and
    the first violation (`""` when ok). The check `order_text`'s callers
    run before writing; it compares against `old`, not the file on disk.

    It holds when the line counts and the multisets of bodies match; the
    multisets of (body, terminator) match once each side's unterminated
    last line gains `old`'s EOL, and the final-newline state is unchanged;
    every node keeps its body, depth and parent chain; and a canonical walk
    matches, in which each block holds its lines in order and each run of
    consecutive sibling blocks under a non-root parent is a multiset.

    It cannot see which runs `order_text` chose to move: a mover that
    reorders a run the rule leaves alone passes; the rule's own tests own
    that case.
    """
    olds, news = old.splitlines(keepends=True), new.splitlines(keepends=True)
    if len(olds) != len(news):
        return False, f"the ordered text has {len(news)} lines, the base {len(olds)}"
    if not olds:
        return True, ""
    okinds, obodies, _ = _classify_lines(olds)
    nkinds, nbodies, _ = _classify_lines(news)
    oterms, eol = _line_ends(olds, obodies)
    nterms, _ = _line_ends(news, nbodies)

    pool = Counter(obodies)
    for k, body in enumerate(nbodies):
        if not pool[body]:
            return False, f"line {k + 1}: '{body}' is not a line of the base"
        pool[body] -= 1

    def closed(terms: list[str]) -> list[str]:
        return terms[:-1] + [terms[-1] or eol]

    ocl, ncl = closed(oterms), closed(nterms)
    pool = Counter(zip(obodies, ocl))
    for k, pair in enumerate(zip(nbodies, ncl)):
        if not pool[pair]:
            return False, f"line {k + 1}: line ending changed"
        pool[pair] -= 1
    if bool(oterms[-1]) != bool(nterms[-1]):
        return False, f"line {len(news)}: line ending changed"

    okeys, nkeys = _node_keys(okinds, obodies), _node_keys(nkinds, nbodies)
    pool = Counter(okeys.values())
    for i, key in nkeys.items():
        if not pool[key]:
            return False, f"line {i + 1}: node '{_node_text(nbodies[i])}' changed parent or depth"
        pool[key] -= 1
    for i, key in okeys.items():
        if pool[key]:
            k = nbodies.index(obodies[i])
            return False, f"line {k + 1}: node '{_node_text(obodies[i])}' changed parent or depth"

    if _canon(okinds, obodies, ocl) != _canon(nkinds, nbodies, ncl):
        k = next(k for k, (a, b) in enumerate(zip(olds, news)) if a != b)
        return False, f"line {k + 1}: block structure changed"
    return True, ""


def _node_text(body: str) -> str:
    return _split_text_and_meta(_BULLET_RE.match(body).group("rest").rstrip())[0]


def _node_keys(kinds, bodies) -> dict[int, tuple]:
    """Each node line's key: (body, depth, parent's key), root None."""
    keys: dict[int, tuple] = {}
    for i, p in _parse_parents(kinds).items():
        keys[i] = (bodies[i], _depth(kinds[i][1]), keys[p] if p >= 0 else None)
    return keys


def _canon(kinds, bodies, terms) -> tuple:
    """The text as nested blocks, each run of consecutive sibling blocks
    under a non-root parent sorted, so a permuted run compares equal."""
    parents = _parse_parents(kinds)
    ends = {i: _block_end(kinds, bodies, i) for i in parents}

    def walk(lo: int, hi: int) -> tuple:
        items: list[tuple] = []
        j = lo
        while j <= hi:
            if kinds[j][0] != "node":
                items.append(("L", bodies[j], terms[j]))
                j += 1
                continue
            run = [j]
            e = min(ends[j], hi)
            while e + 1 <= hi and kinds[e + 1][0] == "node" and parents[e + 1] == parents[j]:
                run.append(e + 1)
                e = min(ends[e + 1], hi)
            blocks = [(bodies[s], terms[s], walk(s + 1, min(ends[s], hi))) for s in run]
            if parents[j] == -1:
                items.extend(("B",) + b for b in blocks)
            else:
                items.append(("R", tuple(sorted(blocks))))
            j = e + 1
        return tuple(items)

    return walk(0, len(kinds) - 1)


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
            or v.startswith(('"', "'"))
        ):
            # _parse_meta reads a quote-led value as quoted, so write it quoted
            # (#789). No escapes: a value with both quote kinds can't round-trip.
            q = "'" if '"' in v else '"'
            parts.append(f"{k}: {q}{v}{q}")
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
