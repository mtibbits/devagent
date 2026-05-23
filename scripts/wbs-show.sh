#!/usr/bin/env bash
# Render <devdoc>/WBS.md. Optional --depth N keeps nodes through N
# levels below root (depth 1-based in parser, so --depth 1 means
# "root + first level"). Optional --milestone X filters to subtrees
# containing a node with meta.milestone == X.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
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

PARSER_PATH="$PLUGIN_ROOT/scripts/lib/wbs-parser.py" \
SRC_PATH="$src" \
DEPTH_S="$depth" \
MILESTONE="$milestone" \
python3 <<'PY'
import importlib.util
import os
import sys

src = os.environ["SRC_PATH"]
depth_s = os.environ["DEPTH_S"]
milestone = os.environ["MILESTONE"]
parser_path = os.environ["PARSER_PATH"]
depth = int(depth_s) if depth_s else None

spec = importlib.util.spec_from_file_location("wbs_parser", parser_path)
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)

tree = mod.parse_file(src)


def has_milestone(node, ms):
    if node.get("meta", {}).get("milestone") == ms:
        return True
    return any(has_milestone(k, ms) for k in node.get("children", []))


if milestone:
    tree["children"] = [n for n in tree["children"] if has_milestone(n, milestone)]


def prune_depth(node, max_depth):
    # Parser is 1-based: root nodes have depth 1. --depth N keeps N
    # levels below root, so clear children when this node is already
    # at depth > max_depth (its kids would be at max_depth + 2).
    if max_depth is None:
        return
    if node.get("depth", 0) > max_depth:
        node["children"] = []
    else:
        for k in node.get("children", []):
            prune_depth(k, max_depth)


if depth is not None:
    for k in tree["children"]:
        prune_depth(k, depth)

sys.stdout.write(mod.render_markdown(tree))
PY
