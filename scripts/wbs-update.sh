#!/usr/bin/env bash
# wbs-update: reconcile WBS leaf glyphs against issue checklist truth.
#
# For every leaf in <devdoc>/WBS.md that carries `{issue: Issue-N}` meta,
# read <devdoc>/Issue-N/checklist.md and set the leaf's glyph from the
# checklist's actual completion state:
#   - all step lines `[x]` or `[-]`        -> `[x]` (done)
#   - some progress (any `[x]` or `[~]`)   -> `[~]` (in progress)
#   - otherwise                            -> `[ ]` (pending)
#
# Plus: if the project's active_issue is set and is not yet present in
# the WBS, append it under a synthetic "Unassigned" top-level node so
# newly-pulled issues auto-appear.
#
# Reconciliation derives from the checklist (the authoritative source),
# not from state.last_step. Safe to run any time, idempotent.
#
# Flags:
#   --if-exists   exit 0 silently when <devdoc>/WBS.md does not exist
#                 (used by cleanup.sh and other auto-call sites)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=lib/paths.sh
source "$SCRIPT_DIR/lib/paths.sh"
# shellcheck source=lib/io.sh
source "$SCRIPT_DIR/lib/io.sh"
# shellcheck source=lib/config.sh
source "$SCRIPT_DIR/lib/config.sh"
# shellcheck source=lib/state.sh
source "$SCRIPT_DIR/lib/state.sh"
# shellcheck source=lib/active.sh
source "$SCRIPT_DIR/lib/active.sh"

if_exists=0
project_arg=""
for arg in "$@"; do
  case "$arg" in
    --if-exists) if_exists=1 ;;
    --*) warn "wbs update: ignoring unknown flag '$arg'" ;;
    *)
      if [[ -z "$project_arg" ]]; then
        project_arg="$arg"
      else
        warn "wbs update: ignoring extra arg '$arg'"
      fi
      ;;
  esac
done

project="$(active_resolve_project "$project_arg")"
config_is_project "$project" || die "wbs update: unknown project '$project'"
devdoc_dir="$(expand_tilde "$(config_get_project_field "$project" devdoc_dir)")"
[[ -n "$devdoc_dir" ]] || die "wbs update: devdoc_dir not configured for $project"

wbs="$devdoc_dir/WBS.md"
if [[ ! -f "$wbs" ]]; then
  if (( if_exists == 1 )); then
    exit 0
  fi
  die "wbs update: $wbs missing; run /devagent:wbs init first"
fi

parser="$PLUGIN_ROOT/scripts/lib/wbs-parser.py"
[[ -f "$parser" ]] || die "wbs-parser.py not found at $parser"

active_issue="$(active_resolve_issue "$project" 2>/dev/null || true)"
if [[ "$active_issue" == "null" || "$active_issue" == '""' ]]; then
  active_issue=""
fi

WBS_PATH="$wbs" \
PARSER_PATH="$parser" \
DEVDOC_DIR="$devdoc_dir" \
ACTIVE_ISSUE="$active_issue" \
python3 <<'PY'
import importlib.util
import os
import re
from pathlib import Path

wbs_path     = os.environ["WBS_PATH"]
parser_path  = os.environ["PARSER_PATH"]
devdoc_dir   = Path(os.environ["DEVDOC_DIR"])
active_issue = os.environ.get("ACTIVE_ISSUE", "") or ""

spec = importlib.util.spec_from_file_location("wbs_parser", parser_path)
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)

tree = mod.parse_file(wbs_path)

# Checklist step-line pattern: `- [<glyph>] <num>. <name>`
STEP_RE = re.compile(r"^- \[([ x\-!~?P])\][ \t]+\d+\. ")
DONE_GLYPHS = {"x", "-"}
PROGRESS_GLYPHS = {"x", "~"}


def checklist_state(issue_id: str) -> str:
    """Return new glyph for an issue based on its checklist's step lines.

    Returns ' ' if checklist missing or has no step lines (no signal).
    """
    cl = devdoc_dir / issue_id / "checklist.md"
    if not cl.exists():
        return " "
    glyphs = []
    for line in cl.read_text(encoding="utf-8").splitlines():
        m = STEP_RE.match(line)
        if m:
            glyphs.append(m.group(1))
    if not glyphs:
        return " "
    if all(g in DONE_GLYPHS for g in glyphs):
        return "x"
    if any(g in PROGRESS_GLYPHS for g in glyphs):
        return "~"
    return " "


def visit(node, fn):
    fn(node)
    for child in node.get("children", []):
        visit(child, fn)


updates = 0


def reconcile(node):
    global updates
    if node.get("children"):
        return  # not a leaf; parent glyphs aren't checklist-derived
    iid = node.get("meta", {}).get("issue")
    if not iid:
        return
    new_glyph = checklist_state(iid)
    if node["glyph"] != new_glyph:
        node["glyph"] = new_glyph
        node["state"] = mod.STATE_GLYPHS.get(new_glyph, "pending")
        updates += 1


for top in tree["children"]:
    visit(top, reconcile)


# Auto-add active_issue under "Unassigned" if not already in WBS anywhere.
def find_issue_node(node, issue):
    if node.get("meta", {}).get("issue") == issue:
        return node
    for k in node.get("children", []):
        r = find_issue_node(k, issue)
        if r is not None:
            return r
    return None


if active_issue:
    found = None
    for top in tree["children"]:
        found = find_issue_node(top, active_issue)
        if found is not None:
            break
    if found is None:
        unassigned = next(
            (n for n in tree["children"] if n["text"] == "Unassigned"),
            None,
        )
        if unassigned is None:
            unassigned = {
                "text": "Unassigned",
                "state": "pending",
                "glyph": " ",
                "depth": 1,
                "meta": {},
                "meta_unknown_keys": [],
                "children": [],
                "source_line": 0,
            }
            tree["children"].append(unassigned)
        new_glyph = checklist_state(active_issue)
        unassigned["children"].append({
            "text": active_issue,
            "state": mod.STATE_GLYPHS.get(new_glyph, "pending"),
            "glyph": new_glyph,
            "depth": 2,
            "meta": {"issue": active_issue, "est": "?w"},
            "meta_unknown_keys": [],
            "children": [],
            "source_line": 0,
        })
        updates += 1

Path(wbs_path).write_text(mod.render_markdown(tree), encoding="utf-8")
PY

info "wbs update: reconciled $wbs against issue checklists"
