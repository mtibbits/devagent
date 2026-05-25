#!/usr/bin/env bash
# Render <devdoc>/WBS.md. Optional --depth N keeps nodes through N
# levels below root (depth 1-based in parser, so --depth 1 means
# "root + first level"). Optional --milestone X filters to subtrees
# containing a node with meta.milestone == X.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=lib/paths.sh
source "$SCRIPT_DIR/lib/paths.sh"
# shellcheck source=lib/io.sh
source "$SCRIPT_DIR/lib/io.sh"
# shellcheck source=lib/config.sh
source "$SCRIPT_DIR/lib/config.sh"
# shellcheck source=lib/active.sh
source "$SCRIPT_DIR/lib/active.sh"

depth=""
milestone=""
project_arg=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --depth)     depth="$2"; shift 2 ;;
    --milestone) milestone="$2"; shift 2 ;;
    --*) warn "wbs show: ignoring unknown flag '$1'"; shift ;;
    *)
      if [[ -z "$project_arg" ]]; then
        project_arg="$1"
      else
        warn "wbs show: ignoring extra arg '$1'"
      fi
      shift
      ;;
  esac
done

project="$(active_resolve_project "$project_arg")"
config_is_project "$project" || die "wbs show: unknown project '$project'"
devdoc_dir="$(expand_tilde "$(config_get_project_field "$project" devdoc_dir)")"
[[ -n "$devdoc_dir" ]] || die "wbs show: devdoc_dir not configured for $project"

src="$devdoc_dir/WBS.md"
if [[ ! -f "$src" ]]; then
  die "wbs show: $src not found; run /devagent:wbs init first"
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
