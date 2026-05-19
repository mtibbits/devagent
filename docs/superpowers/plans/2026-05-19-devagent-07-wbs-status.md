# devAgent Phase 7 — WBS + Status Reports Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship the WBS authoring/render commands (`/devagent:wbs init|update|show`, alias `/devagent:updatewbs`) and the status-report command (`/devagent:statusreport`) for devAgent v1, including a forward-compatible WBS parser library used by both.

**Architecture:** A pure-Python WBS parser (`scripts/lib/wbs-parser.py`) converts `<devdoc>/WBS.md` (markdown bullet hierarchy with inline `{key: value, ...}` metadata) into a structured JSON tree. The tree is the stable interchange format consumed by `wbs show`, by `statusreport.sh` for roll-up, and (in v2/v3) by Gantt/MS Project/OpenProject renderers. The status-report command is a `bash` orchestrator (`scripts/statusreport.sh`) that reads pin state, scans devdoc issue dirs (using checklist log entries from Plan 1's `scripts/lib/checklist.sh`), runs the detection heuristics from spec §14.4, computes velocity (§14.5), renders from `templates/statusreport_template.md`, writes to `<devdoc>/StatusReports/YYYY-MM-DD.md`, and commits per `permissions.commit_devdoc`. `wbs init/update/show` are thin `bash` scripts that read `<devdoc>/WBS.md`, optionally rewrite it (update), and pipe it through the parser for show.

**Tech Stack:** Bash 5 + Python 3 (stdlib only: `argparse`, `re`, `json`, `pathlib`, `datetime`, `tomllib`). Tests: `bats-core` for shell, `pytest` for Python. Markdown templates live in `templates/`.

**Dependencies on other plans:**
- **Plan 1** ships `scripts/lib/config-loader.sh` (reads `~/.claude/devagent/config.toml`, exports `DEVAGENT_CFG_*` variables), `scripts/lib/state.sh` (reads/writes `~/.claude/devagent/state/<project>.toml`), `scripts/lib/checklist.sh` (parses `checklist.md` log entries into `{ts, step_name, message}` records on stdout, one JSON object per line — function `checklist_log_entries <path>`), and `scripts/lib/log.sh` (`devagent_log info|warn|err`).
- **Plan 2** ships the `~/.claude/devagent/state/<project>.statusreport.toml` schema (`last_pin`, `last_pin_by`) and `state_get`/`state_set` helpers (`state_get <file> <key>`, `state_set <file> <key> <value>`).
- **Plan 3** (cleanup) writes the final log entry (`step 20 cleanup`) on each issue so `statusreport.sh` can detect completed issues for velocity.

This plan assumes those exist with the signatures named above and stubs them in `tests/fixtures/` so this plan is independently testable.

---

## File Structure

**Create:**
- `scripts/lib/wbs-parser.py` — WBS markdown → JSON tree (and reverse, for `update`)
- `scripts/wbs.sh` — dispatcher for `init|update|show` subcommands
- `scripts/wbs-init.sh` — scaffold `<devdoc>/WBS.md` from template
- `scripts/wbs-update.sh` — append/update WBS entries from active issues
- `scripts/wbs-show.sh` — render WBS markdown (filtered by depth/milestone)
- `scripts/statusreport.sh` — generate status report
- `scripts/lib/statusreport-detect.py` — heuristic detection (stuck, failed red-team, poorly scoped, idle)
- `scripts/lib/statusreport-velocity.py` — velocity + estimate
- `templates/wbs_template.md` — empty WBS scaffold
- `templates/statusreport_template.md` — Jinja-style placeholder template (no Jinja dep; envsubst-style)
- `commands/wbs.md` — slash command frontmatter for `/devagent:wbs`
- `commands/updatewbs.md` — alias slash command for `/devagent:updatewbs`
- `commands/statusreport.md` — slash command for `/devagent:statusreport`
- `tests/test_wbs_parser.py` — pytest for parser
- `tests/test_statusreport_detect.py` — pytest for detection heuristics
- `tests/test_statusreport_velocity.py` — pytest for velocity calc
- `tests/wbs.bats` — bats for `wbs.sh` subcommands
- `tests/statusreport.bats` — bats for `statusreport.sh`
- `tests/fixtures/wbs/simple.md`, `tests/fixtures/wbs/nested.md`, `tests/fixtures/wbs/unknown_keys.md`, `tests/fixtures/wbs/depends.md` — fixture WBS files
- `tests/fixtures/issues/Issue-100/checklist.md` (stuck), `Issue-101/checklist.md` (failed redmr), `Issue-102/checklist.md` (poorly scoped), `Issue-103/checklist.md` (idle), `Issue-104/checklist.md` (completed) — issue fixtures with `STUCK` files where applicable
- `tests/fixtures/devagent_stubs/` — stub `config-loader.sh`, `state.sh`, `checklist.sh`, `log.sh` so this plan is testable without Plans 1–3

**Modify:** none (greenfield phase)

---

## Task 1: Scaffold templates and command files

**Files:**
- Create: `templates/wbs_template.md`
- Create: `templates/statusreport_template.md`
- Create: `commands/wbs.md`
- Create: `commands/updatewbs.md`
- Create: `commands/statusreport.md`

- [ ] **Step 1: Write `templates/wbs_template.md`**

```markdown
# {{PROJECT}} WBS

> Source-of-truth for work-breakdown structure. Edited by hand and by
> `/devagent:wbs update`. Each bullet is a WBS node; inline
> `{key: value, ...}` block carries metadata.
>
> Recognized keys (v1): issue, est, cost, owner, milestone, start, due, depends_on
> Unrecognized keys are preserved verbatim.

- [ ] Top-level milestone or epic {est: 0w, milestone: M1, owner: @you, cost: 0}
  - [ ] First leaf {issue: Issue-1, est: 1w}
  - [ ] Second leaf {issue: Issue-2, est: 1w, depends_on: Issue-1}
```

- [ ] **Step 2: Write `templates/statusreport_template.md`**

```markdown
# Status Report — {{PROJECT}} — {{PIN_FROM_DATE}} → {{PIN_TO_DATE}}
Pin: {{PIN_FROM}} → {{PIN_TO}} ({{PIN_SPAN}})

## Accomplished
{{ACCOMPLISHED_LIST}}

## Needs attention
### Stuck ({{STUCK_COUNT}})
{{STUCK_LIST}}
### Failed red-team ({{FAILED_REDTEAM_COUNT}})
{{FAILED_REDTEAM_LIST}}
### Idle > 7d ({{IDLE_COUNT}})
{{IDLE_LIST}}
### Poorly scoped ({{POORLY_SCOPED_COUNT}})
{{POORLY_SCOPED_LIST}}

## WBS roll-up
{{WBS_ROLLUP}}

## Velocity & estimate
- Last {{VELOCITY_WINDOW_WEEKS}} weeks: {{VELOCITY_PER_WEEK}} issues/week shipped, median {{MEDIAN_DAYS}} days/issue
- Remaining WBS leaves: {{REMAINING_LEAVES}}
- Estimated completion: {{ESTIMATED_COMPLETION}} ± {{ESTIMATE_BAND_WEEKS}} weeks

> Honest noise: v1 makes no attempt at precision. Treat the band as
> a rough indicator, not a forecast.
```

- [ ] **Step 3: Write `commands/wbs.md`**

```markdown
---
description: WBS authoring and rendering (init | update | show)
allowed-tools: Bash
---

Run `scripts/wbs.sh "$@"` with the user's arguments.

Subcommands:
- `init` — scaffold `<devdoc>/WBS.md` from `templates/wbs_template.md`
- `update` — append/update WBS entries from active and recently shipped issues
- `show [--depth N] [--milestone X]` — render `<devdoc>/WBS.md` filtered

Positional arguments follow the standard devAgent invocation grammar
(§6.1): `[project] [issue-dir] [free-form note]`. Unrecognized tokens
between subcommand and flags are treated as `$NOTE`.
```

- [ ] **Step 4: Write `commands/updatewbs.md`**

```markdown
---
description: Alias for `/devagent:wbs update` (workflow step 17)
allowed-tools: Bash
---

Run `scripts/wbs.sh update "$@"` with the user's arguments.

This is the workflow step-17 entrypoint. Identical behavior to
`/devagent:wbs update`; exists as a separate command so the 21-step
workflow chaining (`--auto`, `--through`) and skill mapping can
reference a single verb.
```

- [ ] **Step 5: Write `commands/statusreport.md`**

```markdown
---
description: Generate per-project status report, advance pin, optionally commit to devdoc
allowed-tools: Bash
---

Run `scripts/statusreport.sh "$@"` with the user's arguments.

Flags:
- `--no-pin` — do not advance the pin (read-only report)
- `--window-weeks N` — velocity window override (default 4)

Positional arguments follow the standard devAgent invocation grammar
(§6.1). The report is written to
`<devdoc>/StatusReports/YYYY-MM-DD.md` and committed to the devdoc
repo iff `permissions.commit_devdoc=true`.
```

- [ ] **Step 6: Commit**

```bash
git add templates/wbs_template.md templates/statusreport_template.md commands/wbs.md commands/updatewbs.md commands/statusreport.md
git commit -s -m "$(cat <<'EOF'
feat(phase7): add wbs and statusreport templates and slash command files

Scaffold the WBS template, status-report template, and slash command
markdown for /devagent:wbs, /devagent:updatewbs, /devagent:statusreport.
Implementation scripts land in subsequent tasks.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: Build the WBS parser data model (test-first)

**Files:**
- Create: `tests/test_wbs_parser.py`
- Create: `tests/fixtures/wbs/simple.md`
- Create: `tests/fixtures/wbs/nested.md`
- Create: `tests/fixtures/wbs/unknown_keys.md`
- Create: `tests/fixtures/wbs/depends.md`

- [ ] **Step 1: Write `tests/fixtures/wbs/simple.md`**

```markdown
# test WBS

- [ ] Top {est: 2w, milestone: M1, owner: @me}
  - [x] Leaf A {issue: Issue-1, est: 1w}
  - [ ] Leaf B {issue: Issue-2, est: 1w}
```

- [ ] **Step 2: Write `tests/fixtures/wbs/nested.md`**

```markdown
# test WBS

- [ ] Root {est: 10w, milestone: M2}
  - [ ] Subgoal A {est: 4w}
    - [ ] Subsubgoal A1 {issue: Issue-10, est: 2w}
    - [ ] Subsubgoal A2 {issue: Issue-11, est: 2w}
  - [~] Subgoal B {est: 6w}
    - [ ] Subsubgoal B1 {issue: Issue-12, est: 3w}
```

- [ ] **Step 3: Write `tests/fixtures/wbs/unknown_keys.md`**

```markdown
# test WBS

- [ ] Future-proof node {est: 1w, jira: PROJ-42, severity: high, owner: @me}
  - [ ] Leaf {issue: Issue-7, est: 1w, custom_field: "value with spaces"}
```

- [ ] **Step 4: Write `tests/fixtures/wbs/depends.md`**

```markdown
# test WBS

- [ ] A {issue: Issue-1, est: 1w}
- [ ] B {issue: Issue-2, est: 1w, depends_on: Issue-1}
- [ ] C {issue: Issue-3, est: 1w, depends_on: [Issue-1, Issue-2]}
```

- [ ] **Step 5: Write `tests/test_wbs_parser.py` (failing test for simple parse)**

```python
"""Tests for scripts/lib/wbs-parser.py."""
import importlib.util
import json
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
FIX = REPO / "tests" / "fixtures" / "wbs"

# Load wbs-parser.py (hyphen in name → importlib)
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
```

- [ ] **Step 6: Run tests to confirm they fail**

```bash
cd /home/user/src/devAgent && pytest tests/test_wbs_parser.py -v
```

Expected: all six tests fail with `ModuleNotFoundError` or `FileNotFoundError` for `scripts/lib/wbs-parser.py`.

- [ ] **Step 7: Commit fixtures + failing tests**

```bash
git add tests/test_wbs_parser.py tests/fixtures/wbs/
git commit -s -m "$(cat <<'EOF'
test(phase7): add wbs parser fixtures and failing test suite

Covers simple parse, nested depth, unknown-keys preservation,
dependency edges, leaf enumeration, and parse→render→parse
roundtrip equivalence. Implementation lands in next task.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: Implement the WBS parser

**Files:**
- Create: `scripts/lib/wbs-parser.py`

- [ ] **Step 1: Write the parser**

```python
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
from typing import Iterable, Optional

# State glyphs recognized in WBS bullets, mapping to canonical names.
STATE_GLYPHS: dict[str, str] = {
    " ": "pending",
    "x": "done",
    "-": "skipped",
    "!": "stuck",
    "~": "in_progress",
    "?": "blocked_external",
    "P": "parked",
}

# v1 recognized metadata keys (spec §13.1). Anything else is preserved
# verbatim and listed in meta_unknown_keys.
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
    """Parse WBS markdown into a tree.

    Returns:
        {"title": str, "children": [node, ...]}
    where node = {
        "text": str,
        "state": str,            # canonical state name
        "glyph": str,            # raw glyph char
        "depth": int,            # 0 = top-level bullet
        "meta": {key: value},    # all metadata, recognized and not
        "meta_unknown_keys": [str, ...],
        "children": [node, ...],
        "source_line": int,      # 1-based; useful for error messages
    }
    """
    title = ""
    root: dict = {"title": "", "children": []}
    # Stack of (depth, node) pairs. depth -1 = root.
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
        # 2-space indent = one depth level (matches markdown convention
        # used in the spec example).
        depth = len(indent) // 2
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
        # Pop deeper or sibling entries off the stack.
        while stack and stack[-1][0] >= depth:
            stack.pop()
        parent = stack[-1][1]
        parent["children"].append(node)
        stack.append((depth, node))
    return root


def _split_text_and_meta(rest: str) -> tuple[str, dict]:
    """Split a bullet body into text and inline `{...}` metadata."""
    m = _META_BLOCK_RE.search(rest)
    if not m:
        return rest.strip(), {}
    text_part = rest[: m.start()].rstrip()
    meta = _parse_meta(m.group("body"))
    return text_part, meta


def _parse_meta(body: str) -> dict:
    """Parse `key: value, key2: value2, key3: [a, b]` into a dict.

    Values may be:
    - bare tokens (`Issue-1`, `1w`, `M2`)
    - quoted strings (`"hello world"` or `'foo'`)
    - lists (`[Issue-1, Issue-2]`)

    Whitespace around delimiters is permitted.
    """
    out: dict[str, object] = {}
    i = 0
    n = len(body)
    while i < n:
        # skip whitespace and commas
        while i < n and body[i] in " ,\t":
            i += 1
        if i >= n:
            break
        # key
        key_start = i
        while i < n and body[i] not in ":":
            i += 1
        key = body[key_start:i].strip()
        if i >= n or not key:
            break
        i += 1  # consume ':'
        # value
        while i < n and body[i] in " \t":
            i += 1
        if i < n and body[i] == "[":
            # list
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
                i += 1  # consume closing quote
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
    """Return all leaf nodes (no children) in document order."""
    out: list[dict] = []

    def walk(node: dict) -> None:
        kids = node.get("children", [])
        if not kids:
            # The root has no `text` key; skip it.
            if "text" in node:
                out.append(node)
            return
        for k in kids:
            walk(k)

    walk(tree)
    return out


def dependency_edges(tree: dict) -> list[tuple[str, str]]:
    """Return (dependent_issue, depends_on_issue) edges across all nodes."""
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
    """Inverse of parse_text. Preserves all metadata including unknown keys."""
    lines: list[str] = []
    title = tree.get("title", "")
    if title:
        lines.append(f"# {title}")
        lines.append("")

    glyph_for_state = {v: k for k, v in STATE_GLYPHS.items()}

    def write(node: dict) -> None:
        indent = "  " * node["depth"]
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
        elif isinstance(v, str) and ("," in v or ":" in v or " " in v and not v.startswith("@")):
            parts.append(f'{k}: "{v}"')
        else:
            parts.append(f"{k}: {v}")
    return "{" + ", ".join(parts) + "}"


def _cli(argv: list[str]) -> int:
    if len(argv) < 2:
        print("usage: wbs-parser.py {parse|edges|leaves|render} <path>", file=sys.stderr)
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
```

- [ ] **Step 2: Run parser tests, confirm they pass**

```bash
cd /home/user/src/devAgent && pytest tests/test_wbs_parser.py -v
```

Expected: all six tests pass.

- [ ] **Step 3: Commit parser**

```bash
git add scripts/lib/wbs-parser.py
git commit -s -m "$(cat <<'EOF'
feat(phase7): implement wbs markdown parser and renderer

Pure-stdlib parser produces a JSON tree from WBS markdown and renders
it back. Preserves unknown metadata keys verbatim for forward
compatibility with v2/v3 renderers (Gantt, MS Project XML, OpenProject)
without schema migration. Exposes parse_file, parse_text,
render_markdown, leaves, dependency_edges via importlib and a CLI for
shell consumers.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 4: Stub upstream-plan helpers so this plan is testable standalone

**Files:**
- Create: `tests/fixtures/devagent_stubs/config-loader.sh`
- Create: `tests/fixtures/devagent_stubs/state.sh`
- Create: `tests/fixtures/devagent_stubs/checklist.sh`
- Create: `tests/fixtures/devagent_stubs/log.sh`

- [ ] **Step 1: Write `tests/fixtures/devagent_stubs/log.sh`**

```bash
#!/usr/bin/env bash
# Stub for scripts/lib/log.sh (Plan 1). Real impl prepends timestamps
# and routes to stderr; the stub does the minimum needed for tests.
devagent_log() {
  local level="$1"; shift
  printf '[%s] %s\n' "$level" "$*" >&2
}
export -f devagent_log
```

- [ ] **Step 2: Write `tests/fixtures/devagent_stubs/config-loader.sh`**

```bash
#!/usr/bin/env bash
# Stub for scripts/lib/config-loader.sh (Plan 1). Real impl reads
# ~/.claude/devagent/config.toml; stub reads env vars set by the test.
# Required exports for this plan's scripts:
#   DEVAGENT_PROJECT          (e.g. "volk")
#   DEVAGENT_DEVDOC_DIR       (path to devdoc repo)
#   DEVAGENT_PERM_COMMIT_DEVDOC ("true" or "false")
#   DEVAGENT_STATE_DIR        (path to state dir; tests use a tmp dir)

devagent_load_config() {
  : "${DEVAGENT_PROJECT:?DEVAGENT_PROJECT must be set in tests}"
  : "${DEVAGENT_DEVDOC_DIR:?DEVAGENT_DEVDOC_DIR must be set}"
  : "${DEVAGENT_PERM_COMMIT_DEVDOC:=false}"
  : "${DEVAGENT_STATE_DIR:=$HOME/.claude/devagent/state}"
  export DEVAGENT_PROJECT DEVAGENT_DEVDOC_DIR DEVAGENT_PERM_COMMIT_DEVDOC DEVAGENT_STATE_DIR
}
export -f devagent_load_config
```

- [ ] **Step 3: Write `tests/fixtures/devagent_stubs/state.sh`**

```bash
#!/usr/bin/env bash
# Stub for scripts/lib/state.sh (Plan 2). Minimal flat TOML reader/writer
# supporting only `key = "value"` lines (no sections, no arrays).

state_get() {
  local file="$1" key="$2"
  [[ -f "$file" ]] || { printf ''; return 0; }
  awk -v k="$key" '
    $1 == k && $2 == "=" {
      sub(/^[^=]*=[[:space:]]*/, "")
      gsub(/^"|"$/, "")
      print
      exit
    }' "$file"
}

state_set() {
  local file="$1" key="$2" value="$3"
  mkdir -p "$(dirname "$file")"
  touch "$file"
  if grep -q "^${key} *= *" "$file"; then
    # in-place rewrite
    local tmp; tmp="$(mktemp)"
    awk -v k="$key" -v v="$value" '
      $1 == k && $2 == "=" { printf "%s = \"%s\"\n", k, v; next }
      { print }' "$file" > "$tmp"
    mv "$tmp" "$file"
  else
    printf '%s = "%s"\n' "$key" "$value" >> "$file"
  fi
}
export -f state_get state_set
```

- [ ] **Step 4: Write `tests/fixtures/devagent_stubs/checklist.sh`**

```bash
#!/usr/bin/env bash
# Stub for scripts/lib/checklist.sh (Plan 1). Real impl parses the full
# checklist.md format; stub only implements `checklist_log_entries`,
# which parses the `## Log` section and emits one JSON object per line:
#   {"ts": "...", "step": "...", "message": "..."}

checklist_log_entries() {
  local path="$1"
  [[ -f "$path" ]] || return 0
  awk '
    BEGIN { in_log = 0 }
    /^## Log[[:space:]]*$/ { in_log = 1; next }
    /^## / { in_log = 0 }
    in_log && /^- [0-9]{4}-[0-9]{2}-[0-9]{2}/ {
      # Format: "- YYYY-MM-DD HH:MM  step: message"
      line = $0
      sub(/^- /, "", line)
      # Split timestamp (first 16 chars: "YYYY-MM-DD HH:MM")
      ts = substr(line, 1, 16)
      rest = substr(line, 17)
      sub(/^[[:space:]]+/, "", rest)
      # Split step (up to first ":")
      colon = index(rest, ":")
      if (colon == 0) next
      step = substr(rest, 1, colon - 1)
      msg = substr(rest, colon + 1)
      sub(/^[[:space:]]+/, "", msg)
      # JSON-escape backslashes and quotes in msg
      gsub(/\\/, "\\\\", msg)
      gsub(/"/, "\\\"", msg)
      printf "{\"ts\": \"%s\", \"step\": \"%s\", \"message\": \"%s\"}\n", ts, step, msg
    }
  ' "$path"
}
export -f checklist_log_entries
```

- [ ] **Step 5: Commit stubs**

```bash
git add tests/fixtures/devagent_stubs/
git commit -s -m "$(cat <<'EOF'
test(phase7): add stubs for Plan 1/2 helpers so phase 7 is testable standalone

config-loader.sh, state.sh, checklist.sh, log.sh stubs implement the
minimum surface area used by wbs.sh and statusreport.sh, so this plan's
bats tests do not require Plans 1 and 2 to be merged first.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 5: Implement `wbs init` (test-first)

**Files:**
- Create: `tests/wbs.bats`
- Create: `scripts/wbs.sh`
- Create: `scripts/wbs-init.sh`

- [ ] **Step 1: Write `tests/wbs.bats` (failing test for init)**

```bash
#!/usr/bin/env bats

REPO="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"

setup() {
  TMPDEV="$(mktemp -d)"
  TMPSTATE="$(mktemp -d)"
  export DEVAGENT_PROJECT="testproj"
  export DEVAGENT_DEVDOC_DIR="$TMPDEV"
  export DEVAGENT_STATE_DIR="$TMPSTATE"
  export DEVAGENT_PERM_COMMIT_DEVDOC="false"
  export DEVAGENT_STUB_LIB="$REPO/tests/fixtures/devagent_stubs"
}

teardown() {
  rm -rf "$TMPDEV" "$TMPSTATE"
}

@test "wbs init scaffolds WBS.md from template" {
  run bash "$REPO/scripts/wbs.sh" init
  [ "$status" -eq 0 ]
  [ -f "$TMPDEV/WBS.md" ]
  grep -q "# testproj WBS" "$TMPDEV/WBS.md"
  grep -q "Recognized keys" "$TMPDEV/WBS.md"
}

@test "wbs init is idempotent (refuses to overwrite without --force)" {
  bash "$REPO/scripts/wbs.sh" init
  echo "hand-edited content" >> "$TMPDEV/WBS.md"
  run bash "$REPO/scripts/wbs.sh" init
  [ "$status" -ne 0 ]
  grep -q "hand-edited content" "$TMPDEV/WBS.md"
}

@test "wbs init --force overwrites existing file" {
  bash "$REPO/scripts/wbs.sh" init
  echo "hand-edited" >> "$TMPDEV/WBS.md"
  run bash "$REPO/scripts/wbs.sh" init --force
  [ "$status" -eq 0 ]
  ! grep -q "hand-edited" "$TMPDEV/WBS.md"
}
```

- [ ] **Step 2: Run, confirm failure**

```bash
cd /home/user/src/devAgent && bats tests/wbs.bats
```

Expected: all three tests fail (`wbs.sh` not found).

- [ ] **Step 3: Write `scripts/wbs.sh` (dispatcher)**

```bash
#!/usr/bin/env bash
# /devagent:wbs dispatcher. Routes subcommand to wbs-<sub>.sh.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="${DEVAGENT_STUB_LIB:-$SCRIPT_DIR/lib}"

# shellcheck source=/dev/null
source "$LIB_DIR/log.sh"
# shellcheck source=/dev/null
source "$LIB_DIR/config-loader.sh"
devagent_load_config

usage() {
  cat >&2 <<'EOF'
usage: /devagent:wbs <init|update|show> [args]

  init [--force]                        scaffold <devdoc>/WBS.md
  update                                append/update entries from active issues
  show [--depth N] [--milestone X]      render WBS markdown (filtered)
EOF
  exit 2
}

[[ $# -ge 1 ]] || usage
sub="$1"; shift

case "$sub" in
  init)   exec bash "$SCRIPT_DIR/wbs-init.sh"   "$@" ;;
  update) exec bash "$SCRIPT_DIR/wbs-update.sh" "$@" ;;
  show)   exec bash "$SCRIPT_DIR/wbs-show.sh"   "$@" ;;
  *)      usage ;;
esac
```

- [ ] **Step 4: Write `scripts/wbs-init.sh`**

```bash
#!/usr/bin/env bash
# Scaffold <devdoc>/WBS.md from templates/wbs_template.md, substituting
# {{PROJECT}}. Refuses to overwrite unless --force.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
LIB_DIR="${DEVAGENT_STUB_LIB:-$SCRIPT_DIR/lib}"

# shellcheck source=/dev/null
source "$LIB_DIR/log.sh"
# shellcheck source=/dev/null
source "$LIB_DIR/config-loader.sh"
devagent_load_config

force=0
for arg in "$@"; do
  case "$arg" in
    --force) force=1 ;;
    *) devagent_log warn "wbs init: ignoring unknown arg '$arg'" ;;
  esac
done

dest="$DEVAGENT_DEVDOC_DIR/WBS.md"

if [[ -e "$dest" && $force -ne 1 ]]; then
  devagent_log err "wbs init: $dest exists; pass --force to overwrite"
  exit 1
fi

# Resolve template per spec §12 artifact-resolution order:
# 1. <devdoc>/templates/wbs_template.md
# 2. plugin templates/wbs_template.md
for candidate in \
  "$DEVAGENT_DEVDOC_DIR/templates/wbs_template.md" \
  "$PLUGIN_ROOT/templates/wbs_template.md"; do
  if [[ -f "$candidate" ]]; then
    template="$candidate"
    break
  fi
done
: "${template:?no wbs_template.md found in devdoc or plugin}"

mkdir -p "$(dirname "$dest")"
sed -e "s|{{PROJECT}}|${DEVAGENT_PROJECT}|g" "$template" > "$dest"
devagent_log info "wbs init: wrote $dest from $template"
```

- [ ] **Step 5: Make scripts executable and re-run tests**

```bash
chmod +x /home/user/src/devAgent/scripts/wbs.sh /home/user/src/devAgent/scripts/wbs-init.sh
cd /home/user/src/devAgent && bats tests/wbs.bats
```

Expected: three init tests pass.

- [ ] **Step 6: Commit**

```bash
git add scripts/wbs.sh scripts/wbs-init.sh tests/wbs.bats
git commit -s -m "$(cat <<'EOF'
feat(phase7): implement /devagent:wbs init

Dispatcher routes init|update|show to subcommand scripts. wbs-init.sh
scaffolds <devdoc>/WBS.md from the artifact-resolved template (devdoc
override → plugin default), refusing to overwrite without --force.
Three bats tests cover scaffold, idempotence, and --force.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 6: Implement `wbs show`

**Files:**
- Modify: `tests/wbs.bats`
- Create: `scripts/wbs-show.sh`

- [ ] **Step 1: Append show tests to `tests/wbs.bats`**

Append the following to the bottom of `tests/wbs.bats`:

```bash

@test "wbs show prints WBS.md contents" {
  cp "$REPO/tests/fixtures/wbs/simple.md" "$TMPDEV/WBS.md"
  run bash "$REPO/scripts/wbs.sh" show
  [ "$status" -eq 0 ]
  [[ "$output" == *"Top"* ]]
  [[ "$output" == *"Leaf A"* ]]
  [[ "$output" == *"Leaf B"* ]]
}

@test "wbs show --depth 1 hides children below depth 1" {
  cp "$REPO/tests/fixtures/wbs/nested.md" "$TMPDEV/WBS.md"
  run bash "$REPO/scripts/wbs.sh" show --depth 1
  [ "$status" -eq 0 ]
  [[ "$output" == *"Root"* ]]
  [[ "$output" == *"Subgoal A"* ]]
  [[ "$output" != *"Subsubgoal A1"* ]]
}

@test "wbs show --milestone M2 filters to that milestone subtree" {
  cp "$REPO/tests/fixtures/wbs/nested.md" "$TMPDEV/WBS.md"
  run bash "$REPO/scripts/wbs.sh" show --milestone M2
  [ "$status" -eq 0 ]
  [[ "$output" == *"Root"* ]]
}

@test "wbs show errors when WBS.md missing" {
  run bash "$REPO/scripts/wbs.sh" show
  [ "$status" -ne 0 ]
  [[ "$output" == *"not found"* ]] || [[ "$stderr" == *"not found"* ]] || true
}
```

- [ ] **Step 2: Run, confirm failure**

```bash
cd /home/user/src/devAgent && bats tests/wbs.bats
```

Expected: four new tests fail (`wbs-show.sh` not found).

- [ ] **Step 3: Write `scripts/wbs-show.sh`**

```bash
#!/usr/bin/env bash
# Render <devdoc>/WBS.md. Optional --depth N truncates below depth N
# (0-indexed; --depth 1 shows root + first level). Optional
# --milestone X filters to subtrees containing a node with
# meta.milestone == X.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="${DEVAGENT_STUB_LIB:-$SCRIPT_DIR/lib}"

# shellcheck source=/dev/null
source "$LIB_DIR/log.sh"
# shellcheck source=/dev/null
source "$LIB_DIR/config-loader.sh"
devagent_load_config

depth=""
milestone=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --depth)     depth="$2"; shift 2 ;;
    --milestone) milestone="$2"; shift 2 ;;
    *) devagent_log warn "wbs show: ignoring '$1'"; shift ;;
  esac
done

src="$DEVAGENT_DEVDOC_DIR/WBS.md"
if [[ ! -f "$src" ]]; then
  devagent_log err "wbs show: $src not found; run /devagent:wbs init first"
  exit 1
fi

python3 - "$src" "$depth" "$milestone" <<'PY'
import importlib.util
import sys
from pathlib import Path

src, depth_s, milestone = sys.argv[1], sys.argv[2], sys.argv[3]
depth = int(depth_s) if depth_s else None

repo = Path(__file__).resolve()  # heredoc tmpfile is not a project file;
# fall back to walking from the source path to find scripts/lib.
candidate = Path(src).resolve()
while candidate != candidate.parent:
    p = candidate / "scripts" / "lib" / "wbs-parser.py"
    if p.exists():
        parser_path = p
        break
    candidate = candidate.parent
else:
    # Search known plugin install location.
    for guess in (
        Path.home() / "src" / "devAgent" / "scripts" / "lib" / "wbs-parser.py",
        Path("/home/user/src/devAgent/scripts/lib/wbs-parser.py"),
    ):
        if guess.exists():
            parser_path = guess
            break
    else:
        sys.exit("could not locate wbs-parser.py")

spec = importlib.util.spec_from_file_location("wbs_parser", parser_path)
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)

tree = mod.parse_file(src)

def filter_milestone(node, ms):
    """Return True if node or any descendant has meta.milestone == ms."""
    if node.get("meta", {}).get("milestone") == ms:
        return True
    return any(filter_milestone(k, ms) for k in node.get("children", []))

if milestone:
    tree["children"] = [n for n in tree["children"] if filter_milestone(n, milestone)]

def prune_depth(node, max_depth):
    if max_depth is None:
        return
    if node.get("depth", -1) >= max_depth:
        node["children"] = []
    else:
        for k in node.get("children", []):
            prune_depth(k, max_depth)

if depth is not None:
    for k in tree["children"]:
        prune_depth(k, depth)

sys.stdout.write(mod.render_markdown(tree))
PY
```

- [ ] **Step 4: Make executable and re-run**

```bash
chmod +x /home/user/src/devAgent/scripts/wbs-show.sh
cd /home/user/src/devAgent && bats tests/wbs.bats
```

Expected: all wbs.bats tests pass.

- [ ] **Step 5: Commit**

```bash
git add scripts/wbs-show.sh tests/wbs.bats
git commit -s -m "$(cat <<'EOF'
feat(phase7): implement /devagent:wbs show with depth and milestone filters

Renders <devdoc>/WBS.md by parsing it through wbs-parser.py and
re-emitting markdown, optionally pruning below --depth N or filtering
to subtrees whose nodes carry meta.milestone == X.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 7: Implement `wbs update`

**Files:**
- Modify: `tests/wbs.bats`
- Create: `scripts/wbs-update.sh`

- [ ] **Step 1: Append update tests to `tests/wbs.bats`**

```bash

@test "wbs update appends a new entry for an active issue not yet in WBS" {
  cat > "$TMPDEV/WBS.md" <<EOF
# testproj WBS

- [ ] Existing milestone {est: 2w, milestone: M1}
  - [x] Old leaf {issue: Issue-1, est: 1w}
EOF
  # Active-issue state file: project state points at Issue-2.
  cat > "$TMPSTATE/testproj.toml" <<EOF
active_issue = "Issue-2"
issue_dir = "$TMPDEV/Issue-2"
last_step = 3
last_step_name = "improve"
EOF
  mkdir -p "$TMPDEV/Issue-2"
  cat > "$TMPDEV/Issue-2/checklist.md" <<EOF
# Issue-2 — Workflow checklist
Template: standard

## Revision 1
- [x] 0. pull
- [~] 3. improve

## Log
- 2026-05-19 10:00  pull: fetched
EOF
  run bash "$REPO/scripts/wbs.sh" update
  [ "$status" -eq 0 ]
  grep -q "Issue-2" "$TMPDEV/WBS.md"
}

@test "wbs update is idempotent (running twice produces same file)" {
  cp "$REPO/tests/fixtures/wbs/simple.md" "$TMPDEV/WBS.md"
  cat > "$TMPSTATE/testproj.toml" <<EOF
active_issue = "Issue-1"
issue_dir = "$TMPDEV/Issue-1"
last_step = 0
last_step_name = "pull"
EOF
  mkdir -p "$TMPDEV/Issue-1"
  echo "# Issue-1 — Workflow checklist" > "$TMPDEV/Issue-1/checklist.md"
  bash "$REPO/scripts/wbs.sh" update
  cp "$TMPDEV/WBS.md" "$TMPDEV/WBS.md.first"
  bash "$REPO/scripts/wbs.sh" update
  diff "$TMPDEV/WBS.md" "$TMPDEV/WBS.md.first"
}

@test "wbs update updates state glyph when active issue progresses" {
  cat > "$TMPDEV/WBS.md" <<EOF
# testproj WBS

- [ ] Plan {est: 1w}
  - [ ] Working leaf {issue: Issue-9, est: 1w}
EOF
  cat > "$TMPSTATE/testproj.toml" <<EOF
active_issue = "Issue-9"
issue_dir = "$TMPDEV/Issue-9"
last_step = 7
last_step_name = "implement"
EOF
  mkdir -p "$TMPDEV/Issue-9"
  echo "# Issue-9 — Workflow checklist" > "$TMPDEV/Issue-9/checklist.md"
  run bash "$REPO/scripts/wbs.sh" update
  [ "$status" -eq 0 ]
  # Step 7 is well below 20 → should be marked in_progress [~]
  grep -q "\[~\] Working leaf" "$TMPDEV/WBS.md"
}
```

- [ ] **Step 2: Run, confirm failure**

```bash
cd /home/user/src/devAgent && bats tests/wbs.bats
```

Expected: three new tests fail.

- [ ] **Step 3: Write `scripts/wbs-update.sh`**

```bash
#!/usr/bin/env bash
# Append or update WBS leaves based on the active issue recorded in
# ~/.claude/devagent/state/<project>.toml. Idempotent: running twice
# on the same state produces an identical file.
#
# v1 update rules (deliberately minimal; spec §13 leaves room for
# growth):
#   - If active_issue is already a leaf anywhere in WBS, refresh its
#     state glyph based on last_step:
#       0           → pending     [ ]
#       1..19       → in_progress [~]
#       20          → done        [x]
#   - If active_issue is not in WBS, append a new leaf under a
#     synthetic "Unassigned" top-level node (creating it if absent),
#     with meta `{issue: <id>, est: ?w}`.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="${DEVAGENT_STUB_LIB:-$SCRIPT_DIR/lib}"

# shellcheck source=/dev/null
source "$LIB_DIR/log.sh"
# shellcheck source=/dev/null
source "$LIB_DIR/config-loader.sh"
# shellcheck source=/dev/null
source "$LIB_DIR/state.sh"
devagent_load_config

state_file="$DEVAGENT_STATE_DIR/${DEVAGENT_PROJECT}.toml"
active_issue="$(state_get "$state_file" active_issue)"
last_step="$(state_get "$state_file" last_step)"

if [[ -z "$active_issue" ]]; then
  devagent_log info "wbs update: no active issue; nothing to do"
  exit 0
fi

wbs="$DEVAGENT_DEVDOC_DIR/WBS.md"
if [[ ! -f "$wbs" ]]; then
  devagent_log err "wbs update: $wbs missing; run /devagent:wbs init first"
  exit 1
fi

# Find the parser. Plan 7 keeps it at scripts/lib/wbs-parser.py.
parser="$SCRIPT_DIR/lib/wbs-parser.py"
[[ -f "$parser" ]] || { devagent_log err "wbs-parser.py not found"; exit 1; }

python3 - "$wbs" "$parser" "$active_issue" "$last_step" <<'PY'
import importlib.util
import sys
from pathlib import Path

wbs_path, parser_path, active_issue, last_step_s = sys.argv[1:5]
last_step = int(last_step_s) if last_step_s else 0

spec = importlib.util.spec_from_file_location("wbs_parser", parser_path)
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)

if last_step >= 20:
    new_glyph = "x"
elif last_step >= 1:
    new_glyph = "~"
else:
    new_glyph = " "

tree = mod.parse_file(wbs_path)

def find_issue_node(node, issue):
    if node.get("meta", {}).get("issue") == issue:
        return node
    for k in node.get("children", []):
        r = find_issue_node(k, issue)
        if r is not None:
            return r
    return None

target = None
for top in tree["children"]:
    target = find_issue_node(top, active_issue)
    if target is not None:
        break

if target is not None:
    if target["glyph"] != new_glyph:
        target["glyph"] = new_glyph
        target["state"] = mod.STATE_GLYPHS[new_glyph]
else:
    # Append under "Unassigned" synthetic top-level node.
    unassigned = next(
        (n for n in tree["children"] if n["text"] == "Unassigned"),
        None,
    )
    if unassigned is None:
        unassigned = {
            "text": "Unassigned",
            "state": "pending",
            "glyph": " ",
            "depth": 0,
            "meta": {},
            "meta_unknown_keys": [],
            "children": [],
            "source_line": 0,
        }
        tree["children"].append(unassigned)
    unassigned["children"].append({
        "text": active_issue,
        "state": mod.STATE_GLYPHS[new_glyph],
        "glyph": new_glyph,
        "depth": 1,
        "meta": {"issue": active_issue, "est": "?w"},
        "meta_unknown_keys": [],
        "children": [],
        "source_line": 0,
    })

Path(wbs_path).write_text(mod.render_markdown(tree), encoding="utf-8")
PY

devagent_log info "wbs update: refreshed $wbs for $active_issue (step $last_step)"
```

- [ ] **Step 4: Make executable and re-run**

```bash
chmod +x /home/user/src/devAgent/scripts/wbs-update.sh
cd /home/user/src/devAgent && bats tests/wbs.bats
```

Expected: all wbs.bats tests pass.

- [ ] **Step 5: Commit**

```bash
git add scripts/wbs-update.sh tests/wbs.bats
git commit -s -m "$(cat <<'EOF'
feat(phase7): implement /devagent:wbs update (workflow step 17 backend)

Reads active_issue and last_step from state, finds the matching leaf
in WBS.md, and refreshes its glyph (pending/in_progress/done) based on
last_step. If the issue is not yet in WBS, appends it under a synthetic
"Unassigned" top-level node. Idempotent: same inputs → same file.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 8: Wire `/devagent:updatewbs` alias and verify

**Files:** none new — only verification.

- [ ] **Step 1: Add an alias bats test to `tests/wbs.bats`**

```bash

@test "updatewbs.md command file exists and references wbs.sh update" {
  [ -f "$REPO/commands/updatewbs.md" ]
  grep -q "scripts/wbs.sh update" "$REPO/commands/updatewbs.md"
}
```

- [ ] **Step 2: Run, confirm pass**

```bash
cd /home/user/src/devAgent && bats tests/wbs.bats
```

Expected: all tests pass (the command file was created in Task 1).

- [ ] **Step 3: Commit**

```bash
git add tests/wbs.bats
git commit -s -m "$(cat <<'EOF'
test(phase7): verify /devagent:updatewbs alias routes to wbs.sh update

Confirms commands/updatewbs.md (workflow step 17 entrypoint) invokes
the same scripts/wbs.sh update backend as /devagent:wbs update.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 9: Build status-report detection heuristics (test-first)

**Files:**
- Create: `tests/test_statusreport_detect.py`
- Create: `tests/fixtures/issues/Issue-100/checklist.md`
- Create: `tests/fixtures/issues/Issue-100/STUCK`
- Create: `tests/fixtures/issues/Issue-101/checklist.md`
- Create: `tests/fixtures/issues/Issue-102/checklist.md`
- Create: `tests/fixtures/issues/Issue-103/checklist.md`
- Create: `tests/fixtures/issues/Issue-104/checklist.md`

- [ ] **Step 1: Write `tests/fixtures/issues/Issue-100/checklist.md`** (stuck)

```markdown
# Issue-100 — Workflow checklist
Template: standard

## Revision 1
- [!] 14. redmr

## Log
- 2026-05-15 09:00  pull: fetched
- 2026-05-19 14:00  redmr: 12 blocking findings
```

- [ ] **Step 2: Write `tests/fixtures/issues/Issue-100/STUCK`**

```
Step:        14 redmr
Reason:      need triage strategy
Last good:   step 13 review (2026-05-19 13:42)
Suggested:   group by severity
Created:     2026-05-19 14:08
```

- [ ] **Step 3: Write `tests/fixtures/issues/Issue-101/checklist.md`** (failed redteam, no recovery)

```markdown
# Issue-101 — Workflow checklist
Template: standard

## Revision 1
- [~] 14. redmr

## Log
- 2026-05-18 10:00  pull: fetched
- 2026-05-19 11:00  redmr: 5 blocking findings on draft mr
```

- [ ] **Step 4: Write `tests/fixtures/issues/Issue-102/checklist.md`** (poorly scoped)

```markdown
# Issue-102 — Workflow checklist
Template: standard

## Revision 1
- [~] 2. scope

## Log
- 2026-05-19 10:00  pull: fetched
- 2026-05-19 10:30  scope: 4 recommendations: clarify return path, add overflow test, define units, document threading model
```

- [ ] **Step 5: Write `tests/fixtures/issues/Issue-103/checklist.md`** (idle)

```markdown
# Issue-103 — Workflow checklist
Template: standard

## Revision 1
- [~] 7. implement

## Log
- 2026-05-01 09:00  pull: fetched
- 2026-05-01 10:00  implement: started
```

- [ ] **Step 6: Write `tests/fixtures/issues/Issue-104/checklist.md`** (completed)

```markdown
# Issue-104 — Workflow checklist
Template: standard

## Revision 1
- [x] 20. cleanup

## Log
- 2026-05-10 09:00  pull: fetched
- 2026-05-12 11:00  ship: opened MR
- 2026-05-15 14:00  cleanup: branch deleted, devdoc committed
```

- [ ] **Step 7: Write `tests/test_statusreport_detect.py`**

```python
"""Tests for scripts/lib/statusreport-detect.py."""
import importlib.util
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
ISSUES = REPO / "tests" / "fixtures" / "issues"

spec = importlib.util.spec_from_file_location(
    "sr_detect", REPO / "scripts" / "lib" / "statusreport-detect.py"
)
sr = importlib.util.module_from_spec(spec)
spec.loader.exec_module(sr)


def test_stuck_detected_by_stuck_file():
    assert sr.is_stuck(ISSUES / "Issue-100")
    assert not sr.is_stuck(ISSUES / "Issue-101")
    assert not sr.is_stuck(ISSUES / "Issue-104")


def test_failed_redteam_when_recent_blocking_no_recovery():
    assert sr.failed_redteam(ISSUES / "Issue-101")
    # Issue-100 also has blocking redmr, but is also stuck; failed_redteam
    # only checks the redmr signal itself.
    assert sr.failed_redteam(ISSUES / "Issue-100")
    assert not sr.failed_redteam(ISSUES / "Issue-104")


def test_failed_redteam_recovers_after_passing_entry(tmp_path):
    cl = tmp_path / "checklist.md"
    cl.write_text(
        "# x\n"
        "## Log\n"
        "- 2026-05-19 10:00  redmr: 3 blocking findings\n"
        "- 2026-05-19 14:00  redmr: 0 blocking findings, ship-ready\n",
        encoding="utf-8",
    )
    assert not sr.failed_redteam(tmp_path)


def test_poorly_scoped_by_recommendation_count():
    assert sr.poorly_scoped(ISSUES / "Issue-102")
    assert not sr.poorly_scoped(ISSUES / "Issue-104")


def test_poorly_scoped_by_ambiguity_keyword(tmp_path):
    cl = tmp_path / "checklist.md"
    cl.write_text(
        "## Log\n"
        "- 2026-05-19 10:00  scope: ambiguity in step 3 of implementation\n",
        encoding="utf-8",
    )
    assert sr.poorly_scoped(tmp_path)


def test_idle_when_no_log_entry_in_7d_and_step_below_20(monkeypatch):
    # Pin reference: 2026-05-19; Issue-103's last log = 2026-05-01.
    from datetime import datetime, timezone
    monkeypatch.setattr(
        sr, "_now", lambda: datetime(2026, 5, 19, 12, 0, tzinfo=timezone.utc)
    )
    assert sr.is_idle(ISSUES / "Issue-103", last_step=7)
    # Issue-104 is at step 20 → not idle even if old.
    assert not sr.is_idle(ISSUES / "Issue-104", last_step=20)


def test_completed_detection():
    assert sr.is_completed(ISSUES / "Issue-104")
    assert not sr.is_completed(ISSUES / "Issue-103")


def test_completion_timestamp_returns_log_ts_of_step_20():
    ts = sr.completion_timestamp(ISSUES / "Issue-104")
    assert ts.year == 2026 and ts.month == 5 and ts.day == 15
```

- [ ] **Step 8: Run, confirm failure**

```bash
cd /home/user/src/devAgent && pytest tests/test_statusreport_detect.py -v
```

Expected: all eight tests fail (`statusreport-detect.py` not found).

- [ ] **Step 9: Write `scripts/lib/statusreport-detect.py`**

```python
#!/usr/bin/env python3
"""Detection heuristics for /devagent:statusreport (spec §14.4).

Each predicate takes an issue directory (Path or str) and returns bool
or an ancillary datum. The predicates are pure (no filesystem writes,
no network) so they are trivially unit-testable against fixture
directories.
"""

from __future__ import annotations

import re
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Optional

# Pattern from the canonical log line:
#   "- YYYY-MM-DD HH:MM  step: message"
_LOG_RE = re.compile(
    r"^-\s+(?P<ts>\d{4}-\d{2}-\d{2} \d{2}:\d{2})\s+(?P<step>[a-zA-Z0-9_]+):\s+(?P<msg>.*)$"
)
# "N blocking" / "N blocking findings" — match the count token before "blocking".
_BLOCKING_RE = re.compile(r"(?P<count>\d+)\s+blocking", re.IGNORECASE)
# "N recommendations" — for poorly-scoped detection (spec §14.4).
_RECS_RE = re.compile(r"(?P<count>\d+)\s+recommendations?", re.IGNORECASE)


def _now() -> datetime:
    # Overridable in tests via monkeypatch.
    return datetime.now(timezone.utc)


def _parse_log_entries(checklist_path: Path) -> list[dict]:
    """Return all entries in the `## Log` section as
    [{"ts": datetime, "step": str, "message": str}].
    """
    if not checklist_path.exists():
        return []
    entries: list[dict] = []
    in_log = False
    for line in checklist_path.read_text(encoding="utf-8").splitlines():
        if line.strip().startswith("## Log"):
            in_log = True
            continue
        if in_log and line.startswith("## "):
            in_log = False
            continue
        if not in_log:
            continue
        m = _LOG_RE.match(line)
        if not m:
            continue
        ts = datetime.strptime(m.group("ts"), "%Y-%m-%d %H:%M").replace(
            tzinfo=timezone.utc
        )
        entries.append(
            {"ts": ts, "step": m.group("step"), "message": m.group("msg")}
        )
    return entries


def is_stuck(issue_dir: Path | str) -> bool:
    return (Path(issue_dir) / "STUCK").exists()


def failed_redteam(issue_dir: Path | str) -> bool:
    """True if the most recent `redmr` log entry has blocking>0 and no
    subsequent passing entry. Spec §14.4."""
    entries = _parse_log_entries(Path(issue_dir) / "checklist.md")
    redmr = [e for e in entries if e["step"] == "redmr"]
    if not redmr:
        return False
    last = redmr[-1]
    m = _BLOCKING_RE.search(last["message"])
    if not m:
        return False
    return int(m.group("count")) > 0


def poorly_scoped(issue_dir: Path | str) -> bool:
    """True if a `scope` log entry recorded ≥3 recommendations or
    contains the word 'ambiguity'. Spec §14.4."""
    entries = _parse_log_entries(Path(issue_dir) / "checklist.md")
    for e in entries:
        if e["step"] != "scope":
            continue
        if "ambiguity" in e["message"].lower():
            return True
        m = _RECS_RE.search(e["message"])
        if m and int(m.group("count")) >= 3:
            return True
    return False


def is_idle(issue_dir: Path | str, last_step: int, threshold_days: int = 7) -> bool:
    """True if last log entry is older than threshold_days and step < 20."""
    if last_step >= 20:
        return False
    entries = _parse_log_entries(Path(issue_dir) / "checklist.md")
    if not entries:
        return False
    most_recent = max(e["ts"] for e in entries)
    return (_now() - most_recent) > timedelta(days=threshold_days)


def is_completed(issue_dir: Path | str) -> bool:
    """True if a step-20 (`cleanup`) log entry exists."""
    entries = _parse_log_entries(Path(issue_dir) / "checklist.md")
    return any(e["step"] == "cleanup" for e in entries)


def completion_timestamp(issue_dir: Path | str) -> Optional[datetime]:
    entries = _parse_log_entries(Path(issue_dir) / "checklist.md")
    for e in entries:
        if e["step"] == "cleanup":
            return e["ts"]
    return None
```

- [ ] **Step 10: Run, confirm pass**

```bash
cd /home/user/src/devAgent && pytest tests/test_statusreport_detect.py -v
```

Expected: all eight tests pass.

- [ ] **Step 11: Commit**

```bash
git add tests/test_statusreport_detect.py tests/fixtures/issues/ scripts/lib/statusreport-detect.py
git commit -s -m "$(cat <<'EOF'
feat(phase7): implement statusreport detection heuristics

Pure-function predicates for the four signals defined in spec §14.4:
stuck (STUCK file), failed_redteam (most-recent redmr entry has
blocking > 0 with no recovery), poorly_scoped (scope entry has ≥3
recommendations or 'ambiguity' keyword), is_idle (no log activity in
threshold_days and step < 20). Plus is_completed and
completion_timestamp for velocity computation.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 10: Build velocity + estimate (test-first)

**Files:**
- Create: `tests/test_statusreport_velocity.py`
- Create: `scripts/lib/statusreport-velocity.py`

- [ ] **Step 1: Write `tests/test_statusreport_velocity.py`**

```python
"""Tests for scripts/lib/statusreport-velocity.py."""
import importlib.util
from datetime import datetime, timedelta, timezone
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent

spec = importlib.util.spec_from_file_location(
    "sr_velocity", REPO / "scripts" / "lib" / "statusreport-velocity.py"
)
sv = importlib.util.module_from_spec(spec)
spec.loader.exec_module(sv)


def _ts(y, m, d):
    return datetime(y, m, d, 12, 0, tzinfo=timezone.utc)


def test_velocity_zero_when_no_completions():
    now = _ts(2026, 5, 19)
    v = sv.velocity_per_week([], window_weeks=4, now=now)
    assert v == 0.0


def test_velocity_simple_case():
    now = _ts(2026, 5, 19)
    # 8 completions in 4 weeks → 2.0/week.
    completions = [_ts(2026, 4, 21 + i) for i in range(8)]
    v = sv.velocity_per_week(completions, window_weeks=4, now=now)
    assert abs(v - 2.0) < 1e-6


def test_velocity_excludes_completions_before_window():
    now = _ts(2026, 5, 19)
    # 2 in window, 5 long before
    completions = [_ts(2026, 1, 1), _ts(2026, 1, 5), _ts(2026, 1, 9),
                   _ts(2026, 1, 13), _ts(2026, 1, 17),
                   _ts(2026, 5, 10), _ts(2026, 5, 15)]
    v = sv.velocity_per_week(completions, window_weeks=4, now=now)
    assert abs(v - 0.5) < 1e-6  # 2 completions / 4 weeks


def test_median_days_per_issue():
    # durations 3, 5, 7 days → median 5
    starts = [_ts(2026, 5, 1), _ts(2026, 5, 1), _ts(2026, 5, 1)]
    ends   = [_ts(2026, 5, 4), _ts(2026, 5, 6), _ts(2026, 5, 8)]
    pairs = list(zip(starts, ends))
    assert sv.median_days_per_issue(pairs) == 5.0


def test_estimate_completion_date():
    now = _ts(2026, 5, 19)
    # velocity 2/week, 10 leaves → 5 weeks → 2026-06-23
    est = sv.estimate_completion(remaining_leaves=10, velocity=2.0, now=now)
    assert est.date().isoformat() == "2026-06-23"


def test_estimate_band_widens_with_variance():
    now = _ts(2026, 5, 19)
    # High variance per-week counts → larger band.
    band_low = sv.estimate_band_weeks(per_week_counts=[2, 2, 2, 2])
    band_high = sv.estimate_band_weeks(per_week_counts=[0, 0, 4, 4])
    assert band_high > band_low


def test_estimate_when_zero_velocity_returns_none():
    now = _ts(2026, 5, 19)
    est = sv.estimate_completion(remaining_leaves=10, velocity=0.0, now=now)
    assert est is None
```

- [ ] **Step 2: Run, confirm failure**

```bash
cd /home/user/src/devAgent && pytest tests/test_statusreport_velocity.py -v
```

Expected: all seven tests fail.

- [ ] **Step 3: Write `scripts/lib/statusreport-velocity.py`**

```python
#!/usr/bin/env python3
"""Velocity and completion-estimate helpers for /devagent:statusreport.

Spec §14.5:
- Velocity = issues completed (step 20) per calendar week, over a
  configurable window (default 4 weeks).
- Estimate = (remaining WBS leaves) / velocity, rendered with `± X weeks`
  band based on observed variance.
- "Honest noise": no false precision; the band reflects real variance,
  not statistical confidence intervals.
"""

from __future__ import annotations

import math
import statistics
from datetime import datetime, timedelta, timezone
from typing import Iterable, Optional


def velocity_per_week(
    completion_timestamps: Iterable[datetime],
    window_weeks: int = 4,
    now: Optional[datetime] = None,
) -> float:
    """Average completions per calendar week within the trailing window."""
    if now is None:
        now = datetime.now(timezone.utc)
    cutoff = now - timedelta(weeks=window_weeks)
    in_window = [t for t in completion_timestamps if t >= cutoff]
    return len(in_window) / window_weeks


def per_week_counts(
    completion_timestamps: Iterable[datetime],
    window_weeks: int = 4,
    now: Optional[datetime] = None,
) -> list[int]:
    """Bucket completions into one-week bins ending at `now`.

    Returns counts in chronological order (oldest week first).
    """
    if now is None:
        now = datetime.now(timezone.utc)
    buckets = [0] * window_weeks
    for t in completion_timestamps:
        delta = now - t
        weeks_back = int(delta.total_seconds() // (7 * 86400))
        if 0 <= weeks_back < window_weeks:
            buckets[window_weeks - 1 - weeks_back] += 1
    return buckets


def median_days_per_issue(start_end_pairs: list[tuple[datetime, datetime]]) -> float:
    if not start_end_pairs:
        return 0.0
    durations = [(e - s).total_seconds() / 86400.0 for s, e in start_end_pairs]
    return float(statistics.median(durations))


def estimate_completion(
    remaining_leaves: int,
    velocity: float,
    now: Optional[datetime] = None,
) -> Optional[datetime]:
    """Project completion date assuming constant `velocity` issues/week."""
    if velocity <= 0.0:
        return None
    if now is None:
        now = datetime.now(timezone.utc)
    weeks_needed = remaining_leaves / velocity
    return now + timedelta(weeks=weeks_needed)


def estimate_band_weeks(per_week_counts: list[int]) -> float:
    """Width of the ± band, based on stdev of per-week counts.

    v1 heuristic: one standard deviation of weekly completions, rounded
    to the nearest 0.5 week, floor 0.5. Honest noise, not statistical
    rigor.
    """
    if len(per_week_counts) < 2:
        return 0.5
    sd = statistics.pstdev(per_week_counts)
    band = max(0.5, round(sd * 2) / 2)
    return band
```

- [ ] **Step 4: Run, confirm pass**

```bash
cd /home/user/src/devAgent && pytest tests/test_statusreport_velocity.py -v
```

Expected: all seven tests pass.

- [ ] **Step 5: Commit**

```bash
git add tests/test_statusreport_velocity.py scripts/lib/statusreport-velocity.py
git commit -s -m "$(cat <<'EOF'
feat(phase7): implement statusreport velocity + completion estimate

velocity_per_week, per_week_counts, median_days_per_issue,
estimate_completion, estimate_band_weeks. Implements the §14.5
"honest noise" model: ± band reflects observed variance in weekly
completion counts, not statistical confidence — explicitly imprecise
by design.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 11: Build `statusreport.sh` orchestrator (test-first)

**Files:**
- Create: `tests/statusreport.bats`
- Create: `scripts/statusreport.sh`

- [ ] **Step 1: Write `tests/statusreport.bats`**

```bash
#!/usr/bin/env bats

REPO="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"

setup() {
  TMPDEV="$(mktemp -d)"
  TMPSTATE="$(mktemp -d)"
  export DEVAGENT_PROJECT="testproj"
  export DEVAGENT_DEVDOC_DIR="$TMPDEV"
  export DEVAGENT_STATE_DIR="$TMPSTATE"
  export DEVAGENT_PERM_COMMIT_DEVDOC="false"
  export DEVAGENT_STUB_LIB="$REPO/tests/fixtures/devagent_stubs"

  mkdir -p "$TMPDEV/Issue-100" "$TMPDEV/Issue-101" "$TMPDEV/Issue-103" "$TMPDEV/Issue-104"
  cp "$REPO/tests/fixtures/issues/Issue-100/checklist.md" "$TMPDEV/Issue-100/"
  cp "$REPO/tests/fixtures/issues/Issue-100/STUCK"        "$TMPDEV/Issue-100/"
  cp "$REPO/tests/fixtures/issues/Issue-101/checklist.md" "$TMPDEV/Issue-101/"
  cp "$REPO/tests/fixtures/issues/Issue-103/checklist.md" "$TMPDEV/Issue-103/"
  cp "$REPO/tests/fixtures/issues/Issue-104/checklist.md" "$TMPDEV/Issue-104/"

  cat > "$TMPDEV/WBS.md" <<EOF
# testproj WBS

- [ ] Milestone {est: 5w, milestone: M1}
  - [x] Done leaf {issue: Issue-104, est: 1w}
  - [~] Stuck leaf {issue: Issue-100, est: 1w}
  - [ ] Idle leaf {issue: Issue-103, est: 1w}
  - [ ] Future leaf {est: 1w}
EOF
}

teardown() {
  rm -rf "$TMPDEV" "$TMPSTATE"
}

@test "statusreport writes a dated report to <devdoc>/StatusReports/" {
  run bash "$REPO/scripts/statusreport.sh"
  [ "$status" -eq 0 ]
  found="$(find "$TMPDEV/StatusReports" -name '*.md' | head -n1)"
  [ -n "$found" ]
}

@test "statusreport detects stuck, failed-redteam, and idle issues" {
  bash "$REPO/scripts/statusreport.sh"
  report="$(find "$TMPDEV/StatusReports" -name '*.md' | head -n1)"
  grep -q "Issue-100" "$report"
  grep -q "Issue-101" "$report"
  grep -q "Issue-103" "$report"
}

@test "statusreport advances pin by default" {
  bash "$REPO/scripts/statusreport.sh"
  pin_file="$TMPSTATE/testproj.statusreport.toml"
  [ -f "$pin_file" ]
  grep -q '^last_pin' "$pin_file"
}

@test "statusreport --no-pin leaves pin unchanged" {
  pin_file="$TMPSTATE/testproj.statusreport.toml"
  echo 'last_pin = "2026-05-01T00:00:00+00:00"' > "$pin_file"
  bash "$REPO/scripts/statusreport.sh" --no-pin
  grep -q '2026-05-01T00:00:00' "$pin_file"
}

@test "statusreport reports velocity and estimate sections" {
  bash "$REPO/scripts/statusreport.sh"
  report="$(find "$TMPDEV/StatusReports" -name '*.md' | head -n1)"
  grep -q "Velocity & estimate" "$report"
  grep -q "Remaining WBS leaves" "$report"
}

@test "statusreport prints summary to stdout" {
  run bash "$REPO/scripts/statusreport.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Status Report"* ]] || [[ "$output" == *"testproj"* ]]
}
```

- [ ] **Step 2: Run, confirm failure**

```bash
cd /home/user/src/devAgent && bats tests/statusreport.bats
```

Expected: all six tests fail (`statusreport.sh` not found).

- [ ] **Step 3: Write `scripts/statusreport.sh`**

```bash
#!/usr/bin/env bash
# /devagent:statusreport — generate per-project status report.
#
# Behavior (spec §14):
#   1. Read pin from ~/.claude/devagent/state/<project>.statusreport.toml
#   2. Unless --no-pin, advance pin to now
#   3. Investigate every issue dir under <devdoc>/Issue*/
#      (and Captures/, if any), apply detection heuristics (§14.4)
#   4. Compute velocity + estimate (§14.5)
#   5. Render templates/statusreport_template.md into
#      <devdoc>/StatusReports/YYYY-MM-DD.md
#   6. Commit to devdoc iff permissions.commit_devdoc=true
#   7. Print summary to stdout
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
LIB_DIR="${DEVAGENT_STUB_LIB:-$SCRIPT_DIR/lib}"

# shellcheck source=/dev/null
source "$LIB_DIR/log.sh"
# shellcheck source=/dev/null
source "$LIB_DIR/config-loader.sh"
# shellcheck source=/dev/null
source "$LIB_DIR/state.sh"
devagent_load_config

no_pin=0
window_weeks=4
while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-pin)       no_pin=1; shift ;;
    --window-weeks) window_weeks="$2"; shift 2 ;;
    *)              devagent_log warn "statusreport: ignoring '$1'"; shift ;;
  esac
done

# Resolve template (spec §12 order).
template=""
for cand in \
  "$DEVAGENT_DEVDOC_DIR/templates/statusreport_template.md" \
  "$PLUGIN_ROOT/templates/statusreport_template.md"; do
  [[ -f "$cand" ]] && { template="$cand"; break; }
done
[[ -n "$template" ]] || { devagent_log err "no statusreport_template.md found"; exit 1; }

pin_file="$DEVAGENT_STATE_DIR/${DEVAGENT_PROJECT}.statusreport.toml"
prev_pin="$(state_get "$pin_file" last_pin || true)"
now_iso="$(date -u +'%Y-%m-%dT%H:%M:%S+00:00')"
report_date="$(date -u +'%Y-%m-%d')"
report_dir="$DEVAGENT_DEVDOC_DIR/StatusReports"
report_path="$report_dir/${report_date}.md"
mkdir -p "$report_dir"

# Delegate the heavy lifting to one Python pass so heuristics and
# rendering share a single tree-walk.
parser="$PLUGIN_ROOT/scripts/lib/wbs-parser.py"
detect="$PLUGIN_ROOT/scripts/lib/statusreport-detect.py"
velocity_lib="$PLUGIN_ROOT/scripts/lib/statusreport-velocity.py"

python3 - <<PY > "$report_path"
import importlib.util
import re
from datetime import datetime, timezone
from pathlib import Path

def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    mod  = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod

wbs_parser = load("wbs_parser", "$parser")
detect     = load("sr_detect",  "$detect")
velocity   = load("sr_vel",     "$velocity_lib")

devdoc       = Path("$DEVAGENT_DEVDOC_DIR")
project      = "$DEVAGENT_PROJECT"
template     = Path("$template").read_text(encoding="utf-8")
prev_pin     = "$prev_pin"
now_iso      = "$now_iso"
window_weeks = int("$window_weeks")

# Discover issue directories. Match anything matching Issue(-Fork)?-N.
issue_re = re.compile(r"^Issue(-Fork)?-\d+\$")
issue_dirs = sorted(
    d for d in devdoc.iterdir()
    if d.is_dir() and issue_re.match(d.name)
)

# Per-issue snapshot.
stuck, failed_rt, idle_list, poorly, completed = [], [], [], [], []
completion_ts = []
for d in issue_dirs:
    # Determine last_step from checklist log (approximation: max step
    # observed in entries). When Plan 1's checklist.sh lands, replace
    # with checklist_active_step.
    entries = detect._parse_log_entries(d / "checklist.md")
    if not entries:
        continue
    # Heuristic last_step: parse leading digits from any step label?
    # Plan 1's checklist library knows the canonical 21 names; for v1
    # we approximate via "cleanup" presence and per-step ordering.
    last_step = 20 if any(e["step"] == "cleanup" for e in entries) else 7

    if detect.is_stuck(d):
        stuck.append(d.name)
    if detect.failed_redteam(d):
        failed_rt.append(d.name)
    if detect.poorly_scoped(d):
        poorly.append(d.name)
    if detect.is_idle(d, last_step=last_step):
        idle_list.append(d.name)
    if detect.is_completed(d):
        completed.append(d.name)
        ts = detect.completion_timestamp(d)
        if ts:
            completion_ts.append(ts)

# WBS roll-up: list top-level nodes, count remaining leaves.
wbs_path = devdoc / "WBS.md"
remaining_leaves = 0
wbs_rollup = "(no WBS.md found — run /devagent:wbs init)"
if wbs_path.exists():
    tree = wbs_parser.parse_file(wbs_path)
    leaves = wbs_parser.leaves(tree)
    remaining_leaves = sum(1 for l in leaves if l["state"] not in ("done", "skipped"))
    wbs_rollup = "\n".join(
        f"- {n['text']} ({n.get('meta', {}).get('milestone', 'no milestone')})"
        for n in tree["children"]
    )

now_dt = datetime.fromisoformat(now_iso)
v = velocity.velocity_per_week(completion_ts, window_weeks=window_weeks, now=now_dt)
pwc = velocity.per_week_counts(completion_ts, window_weeks=window_weeks, now=now_dt)
est = velocity.estimate_completion(remaining_leaves, v, now=now_dt)
band = velocity.estimate_band_weeks(pwc)

# Honest-noise rendering.
if est is None:
    est_str = "n/a (no completions in window)"
    band_str = "—"
else:
    est_str = est.date().isoformat()
    band_str = f"{band:.1f}"

def render_list(items, prefix="- "):
    return "\n".join(f"{prefix}{x}" for x in items) if items else "_(none)_"

def pin_span(prev, now):
    if not prev:
        return "first report (no prior pin)"
    try:
        p = datetime.fromisoformat(prev)
        n = datetime.fromisoformat(now)
        d = n - p
        days, rem = divmod(int(d.total_seconds()), 86400)
        hours = rem // 3600
        return f"{days}d {hours}h"
    except Exception:
        return "(unparseable pin)"

filled = (template
    .replace("{{PROJECT}}",                project)
    .replace("{{PIN_FROM}}",               prev_pin or "(none)")
    .replace("{{PIN_TO}}",                 now_iso)
    .replace("{{PIN_FROM_DATE}}",          (prev_pin or "")[:10] or "—")
    .replace("{{PIN_TO_DATE}}",            now_iso[:10])
    .replace("{{PIN_SPAN}}",               pin_span(prev_pin, now_iso))
    .replace("{{ACCOMPLISHED_LIST}}",      render_list(completed))
    .replace("{{STUCK_COUNT}}",            str(len(stuck)))
    .replace("{{STUCK_LIST}}",             render_list(stuck))
    .replace("{{FAILED_REDTEAM_COUNT}}",   str(len(failed_rt)))
    .replace("{{FAILED_REDTEAM_LIST}}",    render_list(failed_rt))
    .replace("{{IDLE_COUNT}}",             str(len(idle_list)))
    .replace("{{IDLE_LIST}}",              render_list(idle_list))
    .replace("{{POORLY_SCOPED_COUNT}}",    str(len(poorly)))
    .replace("{{POORLY_SCOPED_LIST}}",     render_list(poorly))
    .replace("{{WBS_ROLLUP}}",             wbs_rollup)
    .replace("{{VELOCITY_WINDOW_WEEKS}}",  str(window_weeks))
    .replace("{{VELOCITY_PER_WEEK}}",      f"{v:.1f}")
    .replace("{{MEDIAN_DAYS}}",            "n/a")
    .replace("{{REMAINING_LEAVES}}",       str(remaining_leaves))
    .replace("{{ESTIMATED_COMPLETION}}",   est_str)
    .replace("{{ESTIMATE_BAND_WEEKS}}",    band_str)
)
print(filled, end="")
PY

# Advance pin unless --no-pin.
if [[ $no_pin -eq 0 ]]; then
  state_set "$pin_file" last_pin "$now_iso"
  state_set "$pin_file" last_pin_by "${USER:-unknown}"
fi

# Commit to devdoc if permitted.
if [[ "$DEVAGENT_PERM_COMMIT_DEVDOC" == "true" ]]; then
  if command -v git >/dev/null && git -C "$DEVAGENT_DEVDOC_DIR" rev-parse >/dev/null 2>&1; then
    git -C "$DEVAGENT_DEVDOC_DIR" add "StatusReports/${report_date}.md" || true
    git -C "$DEVAGENT_DEVDOC_DIR" commit -s -m "statusreport(${DEVAGENT_PROJECT}): ${report_date}" || true
  else
    devagent_log warn "statusreport: commit requested but devdoc is not a git repo"
  fi
fi

# Stdout summary (terse, for terminal).
echo "Status Report — $DEVAGENT_PROJECT — $report_date"
echo "  Written to: $report_path"
echo "  Pin: ${prev_pin:-(none)} → ${now_iso}"
```

- [ ] **Step 4: Make executable and re-run**

```bash
chmod +x /home/user/src/devAgent/scripts/statusreport.sh
cd /home/user/src/devAgent && bats tests/statusreport.bats
```

Expected: all six tests pass.

- [ ] **Step 5: Commit**

```bash
git add scripts/statusreport.sh tests/statusreport.bats
git commit -s -m "$(cat <<'EOF'
feat(phase7): implement /devagent:statusreport

Reads the per-project pin, scans <devdoc>/Issue*/ for stuck/failed-
redteam/idle/poorly-scoped/completed signals, computes velocity and
estimate from completion timestamps, renders
statusreport_template.md to <devdoc>/StatusReports/YYYY-MM-DD.md,
advances the pin (unless --no-pin), commits to devdoc if permitted,
and prints a one-screen summary to stdout. Six bats tests cover the
output path, pin advance, --no-pin, velocity section, and stdout
summary.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 12: Verify commit_devdoc gate is honored

**Files:**
- Modify: `tests/statusreport.bats`

- [ ] **Step 1: Append gate test**

```bash

@test "statusreport commits to devdoc git repo iff commit_devdoc=true" {
  ( cd "$TMPDEV" && git init -q && git config user.email "t@x" && git config user.name "t" )
  export DEVAGENT_PERM_COMMIT_DEVDOC="true"
  bash "$REPO/scripts/statusreport.sh"
  run git -C "$TMPDEV" log --oneline -n1
  [ "$status" -eq 0 ]
  [[ "$output" == *"statusreport(testproj)"* ]]
}

@test "statusreport does not commit when commit_devdoc=false" {
  ( cd "$TMPDEV" && git init -q && git config user.email "t@x" && git config user.name "t" )
  export DEVAGENT_PERM_COMMIT_DEVDOC="false"
  bash "$REPO/scripts/statusreport.sh"
  run git -C "$TMPDEV" log --oneline -n1
  # No commits yet → git log exits non-zero
  [ "$status" -ne 0 ]
}
```

- [ ] **Step 2: Run, confirm pass**

```bash
cd /home/user/src/devAgent && bats tests/statusreport.bats
```

Expected: all eight tests pass.

- [ ] **Step 3: Commit**

```bash
git add tests/statusreport.bats
git commit -s -m "$(cat <<'EOF'
test(phase7): verify commit_devdoc gate is honored by statusreport

Adds two bats tests: one confirming the report is committed when
permissions.commit_devdoc=true, one confirming no commit occurs when
the gate is false. Mirrors the permission-gate semantics from spec §8.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 13: Cross-reference doctor wiring (documentation only)

**Files:**
- Create: `docs/superpowers/plans/2026-05-19-devagent-07-handoff.md`

This task documents the integration surface phase 7 expects so other plan owners can wire it up without grepping. It is plain markdown — no code.

- [ ] **Step 1: Write the handoff note**

```markdown
# Phase 7 Handoff — interfaces consumed and exposed

## Consumed (must exist before phase 7 ships)

### From Plan 1 (foundation)
- `scripts/lib/log.sh`         → `devagent_log <level> <msg>`
- `scripts/lib/config-loader.sh` → `devagent_load_config` sets:
  - `DEVAGENT_PROJECT`
  - `DEVAGENT_DEVDOC_DIR`
  - `DEVAGENT_STATE_DIR`
  - `DEVAGENT_PERM_COMMIT_DEVDOC`  ("true"/"false")
- `scripts/lib/checklist.sh`   → `checklist_log_entries <path>` emits one JSON object per line: `{"ts": "...", "step": "...", "message": "..."}`. Phase 7 currently reimplements this in Python (`statusreport-detect._parse_log_entries`) for test isolation; before Plan 1 merges, switch the Python helper to shell out to `checklist_log_entries`.

### From Plan 2 (state)
- `scripts/lib/state.sh`       → `state_get <file> <key>` / `state_set <file> <key> <value>`
- State schema for `~/.claude/devagent/state/<project>.statusreport.toml`:
  - `last_pin = "ISO-8601 timestamp"`
  - `last_pin_by = "username"`

### From Plan 3 (cleanup)
- Issue checklist log entries with `step = "cleanup"` mark completion (used for velocity).

## Exposed (downstream plans may consume)

### To workflow (Plan 4)
- `/devagent:updatewbs` slash command (= `/devagent:wbs update`).
  Workflow step 17 invokes this.

### To capture family (Plan 5)
- `/devagent:wbs update` is reentrant; capture flows should call it
  after creating new issues so the WBS gains an "Unassigned" entry
  per new issue.

### To doctor (Plan 1 or 9)
- `<devdoc>/WBS.md` should be checked for parse-cleanness.
  `scripts/lib/wbs-parser.py parse <path>` returns non-zero on
  malformed input (today: only on missing file; future tasks can
  tighten validation).

### To v2/v3 (out of scope)
- `wbs-parser.py` produces a stable JSON tree designed to feed:
  - mermaid/PlantUML Gantt renderer
  - MS Project XML (mspdi) exporter
  - OpenProject REST API poster
  No schema migration is anticipated. Unknown metadata keys are
  preserved on `meta` and surfaced on `meta_unknown_keys` so a
  renderer can pass-through or warn.
```

- [ ] **Step 2: Commit**

```bash
git add docs/superpowers/plans/2026-05-19-devagent-07-handoff.md
git commit -s -m "$(cat <<'EOF'
docs(phase7): document interfaces consumed and exposed by phase 7

Lists the symbols phase 7 expects from Plans 1/2/3 and the surfaces
it exposes to workflow (Plan 4), capture (Plan 5), doctor (Plan 1/9),
and out-of-scope v2/v3 renderers. Eases integration for plan owners
who do not need to read all of phase 7 in detail.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 14: Full-suite verification

- [ ] **Step 1: Run pytest**

```bash
cd /home/user/src/devAgent && pytest tests/ -v
```

Expected: 6 (parser) + 8 (detect) + 7 (velocity) = 21 tests pass.

- [ ] **Step 2: Run bats**

```bash
cd /home/user/src/devAgent && bats tests/wbs.bats tests/statusreport.bats
```

Expected: 11 (wbs) + 8 (statusreport) = 19 tests pass.

- [ ] **Step 3: Smoke-test the CLI**

```bash
cd /tmp && rm -rf dev-smoke && mkdir -p dev-smoke && cd dev-smoke
mkdir -p devdoc statedir
export DEVAGENT_PROJECT=smoke
export DEVAGENT_DEVDOC_DIR="$(pwd)/devdoc"
export DEVAGENT_STATE_DIR="$(pwd)/statedir"
export DEVAGENT_PERM_COMMIT_DEVDOC=false
export DEVAGENT_STUB_LIB=/home/user/src/devAgent/tests/fixtures/devagent_stubs

bash /home/user/src/devAgent/scripts/wbs.sh init
bash /home/user/src/devAgent/scripts/wbs.sh show
bash /home/user/src/devAgent/scripts/statusreport.sh
```

Expected: `wbs init` creates `devdoc/WBS.md`. `wbs show` prints it. `statusreport` writes `devdoc/StatusReports/<today>.md` and prints a 3-line summary.

- [ ] **Step 4: No final commit needed** — verification only.

---

## Self-Review checklist

Run through this before declaring the plan complete.

**Spec coverage:**
- §13.1 source format → Tasks 2, 3 (parser handles all v1 keys; unknown keys preserved)
- §13.2 commands → Tasks 5, 6, 7 (`init`, `update`, `show` all shipped)
- §13.3 future renderers — explicitly out of scope; parser data model accommodates (Task 3 docstring)
- §14.1 pin — Task 11 reads, advances, honors --no-pin
- §14.2 data sources — Task 11 (issue dirs, STUCK files, WBS); git-log of source/devdoc and `mr-state` deferred to Plan 8/9 wiring (noted in handoff)
- §14.3 output — Task 11 (`<devdoc>/StatusReports/YYYY-MM-DD.md`)
- §14.4 detection heuristics — Task 9 covers all four
- §14.5 velocity & estimate — Task 10 implements; report says "honest noise" via the template
- §6.3 step 17 — Task 1 ships `commands/updatewbs.md`; Task 8 verifies alias

**Placeholder scan:** no TBDs, no "implement appropriate error handling", no "similar to Task N". Every code step shows complete code.

**Type consistency:**
- Parser tree shape (`{"text", "state", "glyph", "depth", "meta", "meta_unknown_keys", "children", "source_line"}`) is consistent between parser, render_markdown, leaves, dependency_edges, and statusreport.sh consumer.
- `STATE_GLYPHS` mapping is referenced consistently as `mod.STATE_GLYPHS`.
- `_parse_log_entries` returns `[{"ts": datetime, "step": str, "message": str}]` consistently.

---

## Open questions (flagged for review, not blocking)

1. **`last_step` determination in statusreport.sh.** The current implementation uses a coarse heuristic (`20 if cleanup else 7`). This works for is_idle's `step < 20` predicate but is otherwise lossy. When Plan 1 ships `checklist.sh` with a `checklist_active_step <path>` helper, replace the heuristic. Tracked in the handoff doc.
2. **WBS update conflict policy when an issue moves milestones manually.** v1 only touches the glyph of an existing leaf; it does not relocate leaves. If the operator hand-moves a leaf and then runs `wbs update`, the leaf's glyph updates in place. Adequate for v1; may need a `--reconcile` flag later.
3. **Median days/issue rendering.** Velocity helper exposes `median_days_per_issue`, but `statusreport.sh` currently emits `n/a` because computing per-issue durations requires log-entry pairs (`pull` ts → `cleanup` ts) that the current heuristic doesn't extract. Wire up once Plan 1's checklist helper lands.
4. **Backend mr-state polling.** Spec §14.2 calls for `code/<backend>.sh mr-state` per shipped issue; deferred to Plan 8 (backends). Phase 7 does not block on it — completed-status detection works from the local checklist log alone.
5. **Pin default when state file missing.** `state_get` returns empty string for a missing key; the report renders `(none)` and the pin-span as "first report (no prior pin)". No follow-up action required, but flagged for UX review.
