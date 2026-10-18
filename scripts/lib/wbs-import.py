#!/usr/bin/env python3
"""Seed a WBS from tracker history: `wbs init --from-tracker` (#706).

An issue backend's `issue-list <repo>` verb prints JSON Lines, one compact
object per issue (spec section 9.1); empty output is a repo with no issues:

  {"id":"12","title":"t","body":"b","state":"closed","class":"done",
   "created":"2026-01-02","closed":"2026-02-01","milestone":null,
   "labels":["epic"],"type":null,
   "parent":"https://github.com/o/r/issues/3",
   "blocked_by":["https://github.com/o/r/issues/4"],
   "url":"https://github.com/o/r/issues/12"}

  id          GitHub number / GitLab iid (digits), or a Jira key
  title, body strings (an empty body is "")
  state       open | closed
  class       a state-list class (wbs-tracker.py CLASSES)
  created     YYYY-MM-DD
  closed      YYYY-MM-DD when state is closed, else null
  milestone, type, parent   string or null
  labels, blocked_by        string arrays
  parent, blocked_by, url   issue URLs (Jira: <base>/browse/<KEY>)

`parse_issue_list` is the one predicate for that contract: the backend
tests (via `check`) and `wbs init` both use it.

The rest is pure work over those records, for scripts/wbs-init.sh:
- `build`: a node per record; its parent is the native `parent` URL, else
  the first `Parent epic:` line outside a code fence (`parent_line`), else
  none (a root; the attempt is listed in the survey's unresolved_parents).
- `select`: the leaf ids a range imports. all; open-only; since:<date>
  (open, or closed on or after it); since:<issue-id> (open, or numbered
  from it: a bare N in every source, <dir_prefix>N in that one only);
  epic:<issue-id> (that epic's subtree and the path above it). The first
  three then add every ancestor, and every descendant of those, so an
  imported child brings its epic and an imported epic all its children.
- `survey` and `render` (see each).
- `merge` (#707, `wbs init --merge`): the same model and selection, added
  to an existing WBS.md parsed by wbs-parser.py; only whole lines are
  inserted (wbs-parser.py's `inserted_only` checks it before the write),
  and the ids of `<!-- wbs-exclude: ... -->` lines (`exclusions`) are
  skipped.

CLI:
  wbs-import.py check   read issue-list output on stdin; print the record
                        count and exit 0, or the error on stderr and exit 1.
  wbs-import.py run     `wbs init --from-tracker`, configured by environment:
      WBS_IMP_<S>_{FILE,BACKEND,REPO,PREFIX}  S = ORIGIN, FORK
                        (a source with no FILE is absent); a Jira source's
                        key prefix is wbs-tracker.py `jira_keyprefix`
      WBS_IMP_MODE      survey | import | merge
      WBS_IMP_RANGE     "" | all | open-only | since:<v> | epic:<v>
      WBS_IMP_PCT       auto_import_below_pct
      WBS_IMP_PROJECT, WBS_IMP_DEST, WBS_IMP_TEMPLATE (not read by merge),
      DEVDOC_DIR
    Exit 0 written (or survey printed, or a merge with nothing to add); 1
    malformed backend output, DEST already exists (import), DEST unreadable
    or not UTF-8 (merge), an existing line would change (merge, a bug), or
    the write fails (merge);
    2 a range value that names nothing; 10 (CHOOSE_RANGE_RC) when no range
    was given and the closed share is not below the threshold: the survey
    JSON, then the line CHOOSE_RANGE_MARKER, on stdout, and nothing
    written.
  wbs-import.py template   plain `wbs init` / `--force` (#764): WBS_IMP_TEMPLATE
                        with `{{PROJECT}}` replaced by WBS_IMP_PROJECT, written
                        to WBS_IMP_DEST; only WBS_IMP_FORCE=1 overwrites.
    Exit 0 written; 1 DEST exists without force, the template is unreadable
    or not UTF-8, or the write fails.

Every write of DEST goes through wbs-parser.py `write_document` (#764).
"""
from __future__ import annotations

import datetime
import functools
import importlib.util
import json
import os
import re
from collections import Counter
from collections.abc import Iterator
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent


def _load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


trk = _load("wbs_tracker", HERE / "wbs-tracker.py")

DATE_RE = re.compile(r"^[0-9]{4}-[0-9]{2}-[0-9]{2}$")
_STR = (str,)
_OPT = (str, type(None))
# key -> allowed types; the order is the documented field order
FIELDS = {
    "id": _STR, "title": _STR, "body": _STR, "state": _STR, "class": _STR,
    "created": _STR, "closed": _OPT, "milestone": _OPT, "labels": (list,),
    "type": _OPT, "parent": _OPT, "blocked_by": (list,), "url": _STR,
}


def _is_date(v) -> bool:
    if not isinstance(v, str) or not DATE_RE.match(v):
        return False
    try:
        datetime.date.fromisoformat(v)
    except ValueError:
        return False
    return True


def _check_record(rec) -> str | None:
    """Return why a decoded record breaks the contract, or None."""
    if not isinstance(rec, dict):
        return "not an object"
    for key, types in FIELDS.items():
        if key not in rec:
            return f"missing key {key}"
        if isinstance(rec[key], bool) or not isinstance(rec[key], types):
            return f"wrong type for {key}"
    for key in ("labels", "blocked_by"):
        if not all(isinstance(v, str) for v in rec[key]):
            return f"wrong type in {key}"
    if not rec["id"]:
        return "empty id"
    # the id lands in a meta block and a devdoc path
    if not _wbs_parser().ID_TOKEN_RE.fullmatch(rec["id"]):
        return "bad id"
    if rec["state"] not in ("open", "closed"):
        return f"bad state {rec['state']}"
    if rec["class"] not in trk.CLASSES:
        return f"bad class {rec['class']}"
    if not _is_date(rec["created"]):
        return "bad date in created"
    if rec["state"] == "closed":
        if not _is_date(rec["closed"]):
            return "bad date in closed"
    elif rec["closed"] is not None:
        return "closed set on an open issue"
    return None


def parse_issue_list(text: str) -> list[dict]:
    """Decode issue-list output; blank lines are skipped, CRLF absorbed.

    Only LF ends a record: jq writes U+2028, U+2029 and NEL raw inside a
    string, and str.splitlines() would break a record on them.

    Raises ValueError("malformed line <n>: <why>[ (issue <id>)]") for a line
    that is not one contract record, or for an id listed twice.
    """
    out: list[dict] = []
    seen: set[str] = set()
    for n, line in enumerate(text.split("\n"), start=1):
        line = line.rstrip("\r")
        if not line.strip():
            continue
        try:
            rec = json.loads(line)
        except ValueError:
            raise ValueError(f"malformed line {n}: not JSON") from None
        why = _check_record(rec)
        if why:
            rid = rec.get("id") if isinstance(rec, dict) else None
            named = f" (issue {rid})" if isinstance(rid, str) and rid else ""
            raise ValueError(f"malformed line {n}: {why}{named}")
        if rec["id"] in seen:
            raise ValueError(f"malformed line {n}: duplicate id {rec['id']}")
        seen.add(rec["id"])
        out.append(rec)
    return out


# --- parent lines and issue references ----------------------------------------
# A body line `Parent epic: <value>` outside a code fence names the parent
# (the crrf convention, commands/crrf.md). Fences are wbs-parser.py's
# (_classify_lines, #701: an opener with no closer is not a fence). The key
# is case-insensitive and may sit in a list item, a quote, or `**`/`__`.
# No regex here backtracks on a long line: lines are rstripped first and the
# value is split on whitespace, not matched with a lazy group.
PARENT_KEY_RE = re.compile(
    r"^[ \t]*(?:[-*>][ \t]*)?(?:\*\*|__)?parent epic(?:\*\*|__)?:(?:\*\*|__)?[ \t]*",
    re.IGNORECASE)
NUM_RE = re.compile(r"#([0-9]+)")
JIRA_KEY_RE = trk.JIRA_KEY_RE
MD_LINK_URL_RE = re.compile(r"\]\((https?://[^()\s]+)\)")
URL_RE = re.compile(r"https?://\S+")
REPO_NUM_RE = re.compile(r"(?P<repo>[^\s/#]+/[^\s#]+)#(?P<n>[0-9]+)")
SLUG_RE = re.compile(r"[A-Za-z0-9][A-Za-z0-9._/-]*")
TRAILING = ".,;:)>"

GITHUB_REF_RE = re.compile(
    r"^https?://[^/\s]+/(?P<repo>[^/\s]+/[^/\s]+)/issues/(?P<n>[0-9]+)/?(?:[?#]\S*)?$")
GITLAB_REF_RE = re.compile(
    r"^https?://[^/\s]+/(?P<repo>\S+?)/-/(?:issues|work_items)/(?P<n>[0-9]+)/?(?:[?#]\S*)?$")
JIRA_REF_RE = re.compile(
    r"^https?://[^/\s]+/browse/(?P<key>[A-Z][A-Z0-9_]*-[0-9]+)/?(?:[?#]\S*)?$")

_parser = None


def _wbs_parser():
    global _parser
    if _parser is None:
        _parser = _load("wbs_parser", HERE / "wbs-parser.py")
    return _parser


def _value_form(val: str, jira: bool) -> tuple[str, str]:
    """The value's reference, by the first rule that fits: a leading `#N`
    (or, on Jira, a leading key), a markdown link's URL, the first URL
    token, a leading `owner/repo#N`; else one slug-like token (slug) or
    anything else (other). Trailing prose and punctuation are ignored."""
    toks = val.split()
    first = toks[0].rstrip(TRAILING)
    m = NUM_RE.fullmatch(first)
    if m:
        return ("num", m.group(1))
    if jira and JIRA_KEY_RE.fullmatch(first):
        return ("key", first)
    m = MD_LINK_URL_RE.search(val)
    if m:
        return ("url", m.group(1))
    for tok in toks:
        tok = tok.lstrip("<(").rstrip(TRAILING)
        if URL_RE.fullmatch(tok):
            return ("url", tok)
    if REPO_NUM_RE.fullmatch(first):
        return ("ref", first)
    if len(toks) == 1 and SLUG_RE.fullmatch(val):
        return ("slug", val)
    return ("other", val)


def parent_line(body: str, jira: bool = False) -> tuple[str, str, str] | None:
    """The first `Parent epic:` line outside a fence, as (kind, value, raw).

    kind: num (`#N`, same source), key (a bare Jira key; Jira sources only),
    url (an issue URL anywhere in the value, a markdown link's included),
    ref (`owner/repo#N`), slug (one slug-like token: unresolvable) or other.
    raw is the line, stripped. None when no line has a value.
    """
    # Bodies come from anyone who can file an issue, and wbs-parser's fence
    # pairing is quadratic in unclosed openers: classify only a body that
    # can hold the key.
    if "parent epic" not in body.casefold():
        return None
    lines = body.splitlines(keepends=True)
    kinds, _bodies, _unclosed = _wbs_parser()._classify_lines(lines)
    for (kind, _m), line in zip(kinds, lines):
        if kind in ("fence", "code"):
            continue
        s = line.rstrip()
        m = PARENT_KEY_RE.match(s)
        if not m:
            continue
        val = s[m.end():]
        if val.endswith(("**", "__")):
            val = val[:-2].rstrip()
        if not val:
            continue
        kind, value = _value_form(val, jira)
        return (kind, value, s.strip())
    return None


def parse_ref(url: str) -> tuple[str | None, str] | None:
    """An issue URL as (repo, id): GitHub and GitLab give the repo path and
    the number, Jira gives (None, key). The host is not compared (GHES,
    self-hosted GitLab). None for any other URL."""
    m = GITHUB_REF_RE.match(url) or GITLAB_REF_RE.match(url)
    if m:
        return (m.group("repo"), m.group("n"))
    m = JIRA_REF_RE.match(url)
    if m:
        return (None, m.group("key"))
    return None


# --- the model ------------------------------------------------------------------
class RangeError(Exception):
    """A range value only the data can check (exit 2)."""


def _tail_num(s: str) -> int:
    tail = re.search(r"([0-9]+)$", s)
    return int(tail.group(1)) if tail else 0


class Node:
    def __init__(self, si: int, source: dict, rec: dict):
        self.si, self.source, self.rec = si, source, rec
        rid = rec["id"]
        self.num = _tail_num(rid)
        self.leaf = trk.leaf_for(source, rid)
        self.parent: Node | None = None
        self.children: list[Node] = []
        self.blockers: list[Node] = []
        self.epic = is_epic(rec)

    @property
    def order(self):
        return (self.si, self.num, self.rec["id"])

    @property
    def group(self) -> bool:
        return self.epic or bool(self.children)

    @property
    def is_open(self) -> bool:
        return self.rec["state"] == "open"


class Model:
    def __init__(self, sources: list[dict]):
        self.sources = sources
        self.nodes: list[Node] = []
        self.by_id: dict[tuple[int, str], Node] = {}
        self.unresolved: list[dict] = []
        self.dropped_deps = 0

    def roots(self) -> list[Node]:
        return [n for n in self.nodes if n.parent is None]

    @functools.cached_property
    def leaves(self) -> set[str]:
        """Every node's leaf (read after build; nodes are fixed by then)."""
        return {n.leaf for n in self.nodes}


def is_epic(rec: dict) -> bool:
    """`type` Epic, else an `epic` label, else a title starting `Epic:`."""
    if (rec.get("type") or "").casefold() == "epic":
        return True
    if any(label.casefold() == "epic" for label in rec.get("labels", [])):
        return True
    return re.match(r"\s*Epic:", rec.get("title") or "") is not None


def _resolve_url(model: Model, url: str) -> tuple[Node | None, str]:
    ref = parse_ref(url)
    if ref is None:
        return (None, "unrecognised-form")
    return _resolve_ref(model, ref)


def _resolve_ref(model: Model, ref: tuple[str | None, str]) -> tuple[Node | None, str]:
    repo, rid = ref
    if repo is None:
        sis = [i for i, s in enumerate(model.sources) if s["backend"] == "jira"]
    else:
        sis = [i for i, s in enumerate(model.sources)
               if s["backend"] != "jira" and s["repo"].casefold() == repo.casefold()]
    for si in sis:
        if (si, rid) in model.by_id:
            return (model.by_id[(si, rid)], "")
    return (None, "not-found" if sis else "foreign")


def _resolve_line(model: Model, node: Node, kind: str, value: str) -> tuple[Node | None, str]:
    if kind in ("num", "key"):
        hit = _node_for(model, node.si, value)
        return (hit, "" if hit else "not-found")
    if kind == "url":
        return _resolve_url(model, value)
    if kind == "ref":
        m = REPO_NUM_RE.fullmatch(value)
        return _resolve_ref(model, (m.group("repo"), m.group("n")))
    return (None, "slug-only" if kind == "slug" else "unrecognised-form")


def _parent_attempts(model: Model, node: Node) -> Iterator[tuple[str, Node | None, str]]:
    """Each parent source in precedence order, as (line, parent, why). Lazy, so a
    native parent that resolves leaves the body unparsed."""
    native = node.rec.get("parent")
    if native:
        yield (f"parent: {native}", *_resolve_url(model, native))
    pl = parent_line(node.rec["body"], jira=node.source["backend"] == "jira")
    if pl:
        kind, value, raw = pl
        yield (raw, *_resolve_line(model, node, kind, value))


def build(sources: list[dict]) -> Model:
    """Nodes, parents and blockers from each source's records.

    sources: [{source, backend, repo, prefix, keyprefix, records}], origin
    first. A parent comes from the native `parent` URL first, then the
    `Parent epic:` line; the first that resolves wins. An issue with no
    resolving parent is a root, and its attempts go to `unresolved`. An edge
    that would close a cycle (a self-parent included) is dropped, in node
    order, and reported as `cycle`.
    """
    model = Model(sources)
    for si, source in enumerate(sources):
        for rec in source["records"]:
            node = Node(si, source, rec)
            model.nodes.append(node)
            model.by_id[(si, rec["id"])] = node
    model.nodes.sort(key=lambda n: n.order)

    wanted: list[tuple[Node, Node, str]] = []
    for node in model.nodes:
        attempts = []
        for line, got, why in _parent_attempts(model, node):
            if got:
                wanted.append((node, got, line))
                break
            attempts.append((line, why))
        else:
            model.unresolved += [{"issue": node.leaf, "line": ln, "reason": why}
                                 for ln, why in attempts]

    for child, parent, line in wanted:
        up = parent
        while up is not None and up is not child:
            up = up.parent
        if up is child:
            model.unresolved.append({"issue": child.leaf, "line": line, "reason": "cycle"})
            continue
        child.parent = parent
        parent.children.append(child)
    for node in model.nodes:
        node.children.sort(key=lambda n: n.order)

    for node in model.nodes:
        for url in node.rec["blocked_by"]:
            hit, _why = _resolve_url(model, url)
            if hit is None:
                model.dropped_deps += 1
            elif hit is not node and hit not in node.blockers:
                node.blockers.append(hit)
    return model


# --- selection --------------------------------------------------------------------
def _ancestors(node: Node) -> list[Node]:
    out = []
    while node.parent is not None:
        node = node.parent
        out.append(node)
    return out


def _subtree(node: Node) -> list[Node]:
    out = [node]
    for n in out:
        out.extend(n.children)
    return out


def _close(base: list[Node]) -> set[str]:
    """base, its ancestors, then every descendant of those: an imported child
    brings its epic, and an imported epic brings all its children."""
    seen: set[Node] = set()
    stack = [m for n in base for m in (n, *_ancestors(n))]
    while stack:
        n = stack.pop()
        if n not in seen:
            seen.add(n)
            stack.extend(n.children)
    return {n.leaf for n in seen}


def _source_index(model: Model, source) -> int:
    """The index of a model source, by identity (parse_leaf returns it)."""
    return next(i for i, s in enumerate(model.sources) if s is source)


def _id_token(model: Model, token: str) -> tuple[set[int], str]:
    """An <issue-id> as (source indexes, id-or-number): a bare N names every
    source; a leaf id names the one source the shared codec reads it in
    (wbs-tracker.py `parse_leaf`, #792); a Jira key the Jira sources."""
    if re.fullmatch(r"[0-9]+", token):
        return (set(range(len(model.sources))), token)
    hit = trk.parse_leaf(model.sources, token)
    if hit is not None:
        return ({_source_index(model, hit[0])}, hit[1])
    if JIRA_KEY_RE.fullmatch(token):
        jira = {i for i, s in enumerate(model.sources) if s["backend"] == "jira"}
        if not jira:
            raise RangeError(f"{token} is a Jira key, but no configured source is Jira")
        return (jira, token)
    raise RangeError(f"{token} names no configured source")


def _node_for(model: Model, si: int, value: str) -> Node | None:
    if re.fullmatch(r"[0-9]+", value) and model.sources[si]["backend"] == "jira":
        value = f"{model.sources[si].get('keyprefix') or ''}-{value}"
    return model.by_id.get((si, value))


def _hits(model: Model, sis: set[int], value: str) -> list[Node]:
    """The nodes an _id_token result names, in source order."""
    return [h for h in (_node_for(model, si, value) for si in sorted(sis)) if h]


def _epics_hint(model: Model) -> str:
    groups = [n.leaf for n in model.nodes if n.group]
    return "epics: " + (", ".join(groups) if groups else "(none)")


def _select_epic(model: Model, node: Node) -> set[str]:
    return {n.leaf for n in _subtree(node)} | {n.leaf for n in _ancestors(node)}


def select(model: Model, rng: str) -> set[str]:
    """The leaf ids a range imports (see the module docstring).

    rng: all | open-only | since:YYYY-MM-DD | since:<issue-id> | epic:<issue-id>.
    Raises RangeError for a value that names nothing (with the epics listed
    for epic:), a calendar-invalid date, or an ambiguous bare epic number.
    """
    nodes = model.nodes
    if rng == "all":
        return {n.leaf for n in nodes}
    if rng == "open-only":
        return _close([n for n in nodes if n.is_open])
    kind, _, value = rng.partition(":")
    if kind == "since" and DATE_RE.match(value):
        if not _is_date(value):
            raise RangeError(f"--since {value} is not a calendar date")
        return _close([n for n in nodes if n.is_open or (n.rec["closed"] or "") >= value])
    if kind == "since":
        sis, v = _id_token(model, value)
        if not re.search(r"[0-9]+$", v):
            raise RangeError(f"--since {value} has no trailing number to compare")
        floor = _tail_num(v)
        return _close([n for n in nodes if n.is_open or (n.si in sis and n.num >= floor)])
    if kind == "epic":
        hits = _hits(model, *_id_token(model, value))
        if len(hits) > 1:
            raise RangeError(f"--epic {value} is ambiguous; name one of "
                             + ", ".join(h.leaf for h in hits))
        if not hits or not hits[0].group:
            raise RangeError(f"--epic {value} names no epic; {_epics_hint(model)}")
        return _select_epic(model, hits[0])
    raise RangeError(f"unknown range {rng}")


# --- rendering ----------------------------------------------------------------------
def _collapse(s: str) -> str:
    return " ".join(s.split())


def safe_title(s: str) -> str:
    """A title as one node line's text: whitespace runs (CR, LF, TAB) become
    one space; braces become parentheses (a trailing `{...}` would read as
    metadata); leading `- [<c>]` checkboxes (space after optional), then a
    leading `- [`, go."""
    s = _collapse(s or "").replace("{", "(").replace("}", ")")
    while True:
        m = re.match(r"- \[.?\]", s)
        if not m:
            break
        s = s[m.end():].lstrip()
    if s.startswith("- ["):
        s = s[3:].lstrip()
    return s or "(no title)"


def safe_meta(s: str) -> str:
    """safe_title, and a value the meta grammar reads back: `"` -> `'`,
    `[`/`]` -> `(`/`)`."""
    return (safe_title(s).replace('"', "'").replace("[", "(").replace("]", ")"))


def template_preamble(text: str, project: str) -> str:
    """The resolved template's lines before its first node line, with
    {{PROJECT}} substituted; a template with no node line is all preamble."""
    text = text.replace("{{PROJECT}}", project)
    lines = text.splitlines(keepends=True)
    kinds, _b, _u = _wbs_parser()._classify_lines(lines)
    for i, (kind, _m) in enumerate(kinds):
        if kind == "node":
            return "".join(lines[:i])
    return text


def _glyph(node: Node, devdoc_dir) -> tuple[str, str | None]:
    got = trk.resolve(" ", node.rec["class"], trk.checklist_state(devdoc_dir, node.leaf),
                      None, mr_hold=False)
    return got if got else (" ", None)


def _issue_node(node: Node, selected: set[str], depth: int, devdoc_dir,
                deps_in: dict[str, str]) -> dict:
    """A new node for `node` and its selected children. `depends_on` names
    the blockers deps_in ({leaf: spelling to write}) holds."""
    glyph, status_src = _glyph(node, devdoc_dir)
    meta: dict = {"issue": node.leaf}
    deps = [deps_in[b.leaf] for b in node.blockers if b.leaf in deps_in]
    if deps:
        meta["depends_on"] = deps[0] if len(deps) == 1 else deps
    if status_src:
        meta["status_src"] = status_src
    return {"text": safe_title(node.rec["title"]), "glyph": glyph, "depth": depth,
            "meta": meta,
            "children": [_issue_node(c, selected, depth + 1, devdoc_dir, deps_in)
                         for c in node.children if c.leaf in selected]}


def _top_level(groups: list[dict], by_ms: dict[str, list[dict]], loose: list[dict]) -> list[dict]:
    """New top-level nodes in render's order: the groups, one container per
    milestone (casefolded title order), then `Unparented` when non-empty."""
    tops = list(groups)
    for title in sorted(by_ms, key=lambda t: (t.casefold(), t)):
        tops.append({"text": safe_title(title), "glyph": " ", "depth": 1,
                     "meta": {"milestone": safe_meta(title)}, "children": by_ms[title]})
    if loose:
        tops.append({"text": "Unparented", "glyph": " ", "depth": 1, "meta": {},
                     "children": loose})
    return tops


def render(model: Model, selected: set[str], preamble: str, devdoc_dir, note: str) -> str:
    """The new WBS.md: preamble, one `<!-- note -->` line, a blank line, then
    the nodes: group nodes (epics, or roots with children) in node order,
    then one container per milestone (casefolded title order), then
    `Unparented`. Containers appear only when non-empty and carry no issue.
    Glyphs come from wbs-tracker.py `resolve` (tracker class, then the
    issue's checklist), as `wbs update` derives them."""
    roots = [n for n in model.roots() if n.leaf in selected]
    groups = [n for n in roots if n.group]
    rest = [n for n in roots if not n.group]
    spell = {leaf: leaf for leaf in selected}

    def new(n: Node, depth: int) -> dict:
        return _issue_node(n, selected, depth, devdoc_dir, spell)

    group_nodes = [new(n, 1) for n in groups]
    by_ms: dict[str, list[dict]] = {}
    for n in rest:
        if n.rec["milestone"]:
            by_ms.setdefault(n.rec["milestone"], []).append(new(n, 2))
    tops = _top_level(group_nodes, by_ms, [new(n, 2) for n in rest if not n.rec["milestone"]])
    if preamble and not preamble.endswith("\n"):
        preamble += "\n"
    doc = f"{preamble}<!-- {note} -->\n"
    if tops:
        doc += "\n" + _wbs_parser().render_nodes({"title": "", "children": tops})
    return doc


# --- merge into an existing WBS (#707) ------------------------------------------

def resolve_id(model: Model, iid: str) -> list[Node]:
    """The tracker issue a WBS `issue` id (or an exclusion id) names, by the
    shared codec (wbs-tracker.py `parse_leaf`), as `wbs update` reads it:
    a configured dir_prefix is required (a bare N or Jira key names
    nothing), and the rest must fit the source's backend, else the next
    shorter dir_prefix is tried. [] when it names no fetched record."""
    hit = trk.parse_leaf(model.sources, iid)
    if hit is None:
        return []
    node = model.by_id.get((_source_index(model, hit[0]), hit[1]))
    return [node] if node else []


def named_leaves(model: Model, iid: str) -> set[str]:
    """The leaves of the records a WBS id names: the codec's answer united
    with an exact leaf match. A writer's leaf may read as another record
    (leaf_for is not injective), so presence and exclusion take both."""
    leaves = {n.leaf for n in resolve_id(model, iid)}
    if iid in model.leaves:
        leaves.add(iid)
    return leaves


def leaf_collisions(model: Model, mode: str) -> list[str]:
    """One warning per leaf two or more records share, in node order;
    `mode` prefixes it (`wbs init` or `wbs init --merge`)."""
    groups: dict[str, list[Node]] = {}
    for n in model.nodes:
        groups.setdefault(n.leaf, []).append(n)
    out = []
    for leaf, nodes in groups.items():
        if len(nodes) < 2:
            continue
        names = [f"{n.source['source']} {n.rec['id']}" for n in nodes]
        who = ", ".join(names[:-1]) + " and " + names[-1]
        hit = trk.parse_leaf(model.sources, leaf)
        answer = f"{hit[0]['source']} {hit[1]}" if hit else "no issue"
        out.append(f"{mode}: leaf {leaf} names {who}; it resolves to {answer}")
    return out


def exclusions(tree: dict, model: Model) -> tuple[list[tuple[int, str]], list[str]]:
    """The exclusion lines' ids as (line, id) pairs, and the warnings, unprefixed.

    The parsed tree's `exclusions` and `exclusion_warnings` (wbs-parser.py
    applies the grammar), plus the source check: an id that is neither read
    as an id by the shared codec (no dir_prefix, or a bad shape after every
    one) nor some record's exact leaf is warned about and skipped. Warnings
    come in line order, the parser's first within a line.
    """
    parser = _wbs_parser()
    ids: list[tuple[int, str]] = []
    warns = [(parser.warning_line(w), w) for w in tree["exclusion_warnings"]]
    for ln, tok in tree["exclusions"]:
        # Deliberately by SHAPE, not by "names a record": a well-formed
        # Issue-99 that no fetched record has passes silently. The
        # presence and exclusion sets (named_leaves) are by record.
        if trk.parse_leaf(model.sources, tok) is None and tok not in model.leaves:
            warns.append((ln, parser.NOT_AN_ID.format(ln, tok)))
            continue
        ids.append((ln, tok))
    return ids, [w for _ln, w in sorted(warns, key=lambda p: p[0])]


def _walk(nodes: list[dict]):
    """Parsed nodes in document order (the parser appends in line order)."""
    for n in nodes:
        yield n
        yield from _walk(n["children"])


def _count_issues(node: dict) -> int:
    own = 1 if "issue" in node["meta"] else 0
    return own + sum(_count_issues(c) for c in node["children"])


def merge(model: Model, selected: set[str], tree: dict, devdoc_dir,
          excluded_ids: list[str]) -> dict:
    """Add to a parsed WBS (`tree`, mutated) each selected tracker issue it
    lacks and no exclusion id names. No existing node is moved or changed.

    Present: a parsed node's `issue` meta names the issue, by the shared
    codec (resolve_id) or by an exact leaf match, both counting
    (named_leaves); the first such node is its anchor. Placement,
    the first rule that fits:
      1. a parent being added: inside that new parent;
      2. a present parent: the last child of its anchor;
      3. a group (epic, or an issue with children): a new top-level node;
      4. a milestone: under the first node (any depth, document order) with
         no `issue` meta whose `milestone` meta is the title or its
         safe_meta form, else a new top-level container per title;
      5. else under the first top-level `Unparented` with no `issue` meta,
         else such an `Unassigned`, else a new top-level `Unparented`.
    New top-level nodes follow the existing ones in render's order: groups,
    milestone containers (casefolded title order), `Unparented`.

    Returns {added: [leaf...] in node order, under_existing: U, new_tops: T,
    present: P, excluded: K, warnings: [...]}; a warning names a milestone
    with several candidate nodes. U and T count issues (a new container is not
    one), P the selected issues present, K those absent and excluded.
    """
    existing = list(_walk(tree["children"]))
    present: dict[str, dict] = {}
    for pn in existing:
        iid = pn["meta"].get("issue")
        if not isinstance(iid, str):
            continue
        for leaf in named_leaves(model, iid):
            present.setdefault(leaf, pn)
    excluded = {leaf for i in excluded_ids for leaf in named_leaves(model, i)}

    add = [n for n in model.nodes
           if n.leaf in selected and n.leaf not in present and n.leaf not in excluded]
    add_leaves = {n.leaf for n in add}
    deps_in = {leaf: pn["meta"]["issue"] for leaf, pn in present.items()}
    deps_in.update((leaf, leaf) for leaf in add_leaves)

    def new(n: Node, depth: int) -> dict:
        return _issue_node(n, add_leaves, depth, devdoc_dir, deps_in)

    def put_under(home: dict, n: Node) -> None:
        """n as home's last child, at its last child's parse-time depth
        (else one deeper), so it lines up with its siblings."""
        kids = home["children"]
        kids.append(new(n, kids[-1]["depth"] if kids else home["depth"] + 1))

    containers = [pn for pn in existing if "issue" not in pn["meta"]]
    tops = [pn for pn in tree["children"] if "issue" not in pn["meta"]]
    bucket = (next((pn for pn in tops if pn["text"] == "Unparented"), None)
              or next((pn for pn in tops if pn["text"] == "Unassigned"), None))
    groups: list[dict] = []
    new_ms: dict[str, list[dict]] = {}
    loose: list[dict] = []
    warnings: list[str] = []
    homes_for: dict[str, list[dict]] = {}
    for n in add:
        if n.parent is not None and n.parent.leaf in add_leaves:
            continue                                        # rule 1
        if n.parent is not None and n.parent.leaf in present:
            put_under(present[n.parent.leaf], n)            # rule 2
        elif n.group:
            groups.append(new(n, 1))                        # rule 3
        elif n.rec["milestone"]:
            title = n.rec["milestone"]                      # rule 4
            if title not in homes_for:
                want = (title, safe_meta(title))
                homes_for[title] = [pn for pn in containers
                                    if pn["meta"].get("milestone") in want]
                if len(homes_for[title]) > 1:
                    lines = ", ".join(str(pn["source_line"]) for pn in homes_for[title])
                    warnings.append(f"milestone '{title}' has {len(homes_for[title])} "
                                    f"candidate nodes (lines {lines}); its issues go under "
                                    "the first")
            if homes_for[title]:
                put_under(homes_for[title][0], n)
            else:
                new_ms.setdefault(title, []).append(new(n, 2))
        elif bucket is not None:
            put_under(bucket, n)                            # rule 5
        else:
            loose.append(new(n, 2))

    added_tops = _top_level(groups, new_ms, loose)
    tree["children"].extend(added_tops)
    new_tops = sum(_count_issues(t) for t in added_tops)
    return {"added": [n.leaf for n in add], "under_existing": len(add) - new_tops,
            "new_tops": new_tops,
            "present": sum(1 for leaf in present if leaf in selected),
            "excluded": sum(1 for leaf in excluded
                            if leaf in selected and leaf not in present),
            "warnings": warnings}


# --- survey -----------------------------------------------------------------------
def survey(model: Model, pct: int, project: str = "") -> dict:
    """The survey JSON (spec section 13.2). The closed share counts closed
    and not-planned issues over every source combined; `auto_import` is
    share < pct, strictly, and true for an empty project."""
    recs = [n.rec for n in model.nodes]
    total = len(recs)
    not_planned = sum(1 for r in recs if r["class"] == "not_planned")
    closed_all = sum(1 for r in recs if r["state"] == "closed")
    created = sorted(r["created"] for r in recs)
    closed_on = sorted(r["closed"] for r in recs if r["state"] == "closed")
    by_month = dict(Counter(d[:7] for d in closed_on))
    ms = Counter(r["milestone"] for r in recs if r["milestone"])
    groups = [n for n in model.nodes if n.group]
    return {
        "project": project,
        "sources": [{"source": s["source"], "backend": s["backend"], "repo": s["repo"],
                     "prefix": s["prefix"], "issues": len(s["records"])}
                    for s in model.sources],
        "total": total,
        "open": total - closed_all,
        "closed": closed_all - not_planned,
        "not_planned": not_planned,
        "closed_share_pct": closed_all * 100 // total if total else 0,
        "auto_import_below_pct": pct,
        "auto_import": total == 0 or closed_all * 100 < pct * total,
        "epics": [{"issue": n.leaf, "title": n.rec["title"], "state": n.rec["state"],
                   "children": len(n.children),
                   "open_children": sum(1 for c in n.children if c.is_open)}
                  for n in groups],
        "milestones": [{"title": t, "issues": ms[t]}
                       for t in sorted(ms, key=lambda t: (t.casefold(), t))],
        "no_parent": sum(1 for n in model.roots() if not n.group),
        "unresolved_parents": model.unresolved,
        "dropped_dependencies": model.dropped_deps,
        "created": {"first": created[0] if created else None,
                    "last": created[-1] if created else None},
        "closed_on": {"first": closed_on[0] if closed_on else None,
                      "last": closed_on[-1] if closed_on else None,
                      "by_month": by_month},
        "options": {"all": total,
                    "open_only": len(select(model, "open-only")),
                    "epic": {n.leaf: len(_select_epic(model, n)) for n in groups}},
    }


def _stdout(text: str) -> None:
    # UTF-8 bytes, LF: safe on a cp1252 console
    sys.stdout.flush()
    sys.stdout.buffer.write(text.encode("utf-8"))
    sys.stdout.buffer.flush()


CHOOSE_RANGE_MARKER = "WBS-INIT: choose-range"
CHOOSE_RANGE_RC = 10


def _say(msg: str) -> None:
    # ASCII only: a cp1252 stderr must not crash the run
    print(msg.encode("ascii", "replace").decode("ascii"), file=sys.stderr)


def run(env) -> int:
    sources = []
    for S, name in (("ORIGIN", "origin"), ("FORK", "fork")):
        f = env.get(f"WBS_IMP_{S}_FILE", "")
        if not f:
            continue
        src = {"source": name, "backend": env.get(f"WBS_IMP_{S}_BACKEND", ""),
               "repo": env.get(f"WBS_IMP_{S}_REPO", ""),
               "prefix": env.get(f"WBS_IMP_{S}_PREFIX", "")}
        src["keyprefix"] = (trk.jira_keyprefix(env, src["repo"])
                            if src["backend"] == "jira" else "")
        try:
            src["records"] = parse_issue_list(Path(f).read_bytes().decode("utf-8", "replace"))
        except ValueError as e:
            _say(f"wbs init: {src['backend']} {src['repo']} issue-list output is malformed: {e}")
            return 1
        sources.append(src)
    project = env.get("WBS_IMP_PROJECT", "")
    pct = int(env.get("WBS_IMP_PCT", "20"))
    model = build(sources)
    sv = survey(model, pct, project=project)
    sv_text = json.dumps(sv, indent=2, ensure_ascii=False) + "\n"
    if env.get("WBS_IMP_MODE") == "survey":
        _stdout(sv_text)
        return 0
    rng = env.get("WBS_IMP_RANGE", "")
    auto = False
    if not rng:
        if not sv["auto_import"]:
            _stdout(sv_text + CHOOSE_RANGE_MARKER + "\n")
            return CHOOSE_RANGE_RC
        rng, auto = "all", True
    try:
        selected = select(model, rng)
    except RangeError as e:
        _say(f"wbs init: {e}")
        return 2
    merging = env.get("WBS_IMP_MODE") == "merge"
    for w in leaf_collisions(model, "wbs init --merge" if merging else "wbs init"):
        _say(w)
    if merging:
        return _run_merge(model, selected, Path(env["WBS_IMP_DEST"]), env.get("DEVDOC_DIR", ""))
    template = Path(env["WBS_IMP_TEMPLATE"]).read_bytes().decode("utf-8")
    preamble = template_preamble(template.replace("\r\n", "\n"), project)
    froms = ", ".join(f"{s['backend']} {s['repo']}" for s in sources)
    note = (f"wbs init --from-tracker {datetime.date.today().isoformat()} {rng}: "
            f"{len(selected)} issues from {froms}")
    doc = render(model, selected, preamble, env.get("DEVDOC_DIR", ""), note)
    dest = Path(env["WBS_IMP_DEST"])
    dest.parent.mkdir(parents=True, exist_ok=True)
    try:
        _wbs_parser().write_document(dest, doc, exclusive=True)
    except FileExistsError:
        _say(f"wbs init: {dest} exists")
        return 1
    picked = [n for n in model.nodes if n.leaf in selected]
    epics = sum(1 for n in picked if n.group)
    loose = sum(1 for n in picked if n.parent is None and not n.group)
    line = f"wbs init: wrote {dest}: {len(selected)} issues ({epics} epics, {loose} unparented)"
    if auto:
        line += f"; closed share {sv['closed_share_pct']}% < {pct}%"
    _say(line)
    return 0


def _run_merge(model: Model, selected: set[str], dest: Path, devdoc_dir) -> int:
    """`wbs init --merge`: insert the missing issues into dest, writing only
    when something was added and no existing line would change."""
    parser = _wbs_parser()
    try:
        tree = parser.parse_file(dest)
    except (OSError, UnicodeDecodeError) as e:
        _say(f"wbs init --merge: cannot read {dest}: {e}")
        return 1
    ids, warns = exclusions(tree, model)
    for w in warns:
        _say(f"wbs init --merge: {dest}: {w}")
    stats = merge(model, selected, tree, devdoc_dir, [i for _ln, i in ids])
    for w in stats["warnings"]:
        _say(f"wbs init --merge: {dest}: {w}")
    tail = f"{stats['present']} already present, {stats['excluded']} excluded"
    if not stats["added"]:
        _say(f"wbs init --merge: nothing to add to {dest}; {tail}")
        return 0
    try:
        parser.write_markdown(dest, tree, check=parser.inserted_only)
    except ValueError:
        # A render refusal (a removed or moved node, which merge never makes)
        # is the same bug class as the veto, so it gets the same message.
        _say(f"wbs init --merge: refusing to write {dest}: an existing line would change "
             "(a bug; please report); nothing written")
        return 1
    except OSError as e:
        _say(f"wbs init --merge: cannot write {dest}: {e}")
        return 1
    _say(f"wbs init --merge: added {len(stats['added'])} issues to {dest} "
         f"({stats['under_existing']} under existing nodes, {stats['new_tops']} in new "
         f"top-level nodes); {tail}")
    return 0


def write_template(env) -> int:
    """`wbs init` / `--force`: the template with `{{PROJECT}}` substituted,
    written through write_document (#764). Only WBS_IMP_FORCE=1 overwrites;
    any other value refuses an existing dest."""
    template, dest = env["WBS_IMP_TEMPLATE"], env["WBS_IMP_DEST"]
    try:
        # strict UTF-8: parse_file reads UTF-8, so no other wbs command could
        # read the WBS.md a non-UTF-8 template would give
        text = Path(template).read_bytes().decode("utf-8")
    except (OSError, UnicodeDecodeError) as e:
        _say(f"wbs init: cannot read {template}: {e}")
        return 1
    # literal, as sed's s||| was not for &, \ or |; other bytes (CR) kept
    text = text.replace("{{PROJECT}}", env.get("WBS_IMP_PROJECT", ""))
    try:
        _wbs_parser().write_document(dest, text, exclusive=env.get("WBS_IMP_FORCE") != "1")
    except FileExistsError:
        _say(f"wbs init: {dest} exists; pass --force to overwrite")
        return 1
    except OSError as e:
        _say(f"wbs init: cannot write {dest}: {e}")
        return 1
    return 0


def main(argv: list[str]) -> int:
    if argv[1:] == ["run"]:
        return run(os.environ)
    if argv[1:] == ["template"]:
        return write_template(os.environ)
    if argv[1:] == ["check"]:
        text = sys.stdin.buffer.read().decode("utf-8", "replace")
        try:
            recs = parse_issue_list(text)
        except ValueError as e:
            print(e, file=sys.stderr)
            return 1
        _stdout(f"{len(recs)}\n")
        return 0
    print("usage: wbs-import.py check | run | template", file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
