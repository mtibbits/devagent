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
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
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

parser="$PLUGIN_ROOT/scripts/lib/wbs-parser.py"
[[ -f "$parser" ]] || { devagent_log err "wbs-parser.py not found at $parser"; exit 1; }

WBS_PATH="$wbs" \
PARSER_PATH="$parser" \
ACTIVE_ISSUE="$active_issue" \
LAST_STEP_S="$last_step" \
python3 <<'PY'
import importlib.util
import os
from pathlib import Path

wbs_path = os.environ["WBS_PATH"]
parser_path = os.environ["PARSER_PATH"]
active_issue = os.environ["ACTIVE_ISSUE"]
last_step_s = os.environ["LAST_STEP_S"]
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
    # Skip if this issue is already under Unassigned (idempotence).
    already = any(
        c.get("meta", {}).get("issue") == active_issue
        for c in unassigned["children"]
    )
    if not already:
        unassigned["children"].append({
            "text": active_issue,
            "state": mod.STATE_GLYPHS[new_glyph],
            "glyph": new_glyph,
            "depth": 2,
            "meta": {"issue": active_issue, "est": "?w"},
            "meta_unknown_keys": [],
            "children": [],
            "source_line": 0,
        })

Path(wbs_path).write_text(mod.render_markdown(tree), encoding="utf-8")
PY

devagent_log info "wbs update: refreshed $wbs for $active_issue (step $last_step)"
