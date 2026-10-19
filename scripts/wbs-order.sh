#!/usr/bin/env bash
# wbs-order: sort each non-root WBS node's children by dependency, then
# priority (#803). `wbs update` runs the same pass by default; this is the
# request to sort, so it ignores `order_on_update` (but still validates it).
#
# The rule, the warnings and the permutation check live in
# scripts/lib/wbs-parser.py (`order_text`, `permuted_only`, `order_file`):
# within each set of siblings, in-set `depends_on` first, then the most
# urgent inherited `priority: P1`-`P4` (P3 when none), then the number of
# siblings waiting on it, then the current position. Top-level nodes never
# move; whole blocks move, every line's bytes kept. A set that a line
# separates, a broken subtree, mixed sibling depths or a dependency cycle is
# left as it is, with one warning.
#
# Output (stderr): `wbs order: reordered N of M sibling sets in <dest>`, or
# `wbs order: already in order`, after any warning lines. --dry-run prints a
# unified diff (labels a/WBS.md and b/WBS.md) on stdout, then
# `would reorder ...` and `dry run; nothing written` on stderr, and writes
# nothing.
#
# Exit: 0 written, nothing to do, or a dry run; 1 a missing, unreadable or
# non-UTF-8 WBS.md, a failed permutation check (nothing written; under
# --dry-run no diff either) or a failed write; 2 a usage error (an unknown
# flag, an extra argument), an unknown project, an unset devdoc_dir, or an
# invalid `[project.<p>.wbs]` order_on_update or completed_last value.
#
# No lock: the WBS lock is #749's, and its caller list gains this writer
# (https://github.com/mtibbits/devagent/issues/749#issuecomment-6207411035).
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

usage() {
  echo "usage: /devagent:wbs order [project] [--dry-run]" >&2
}

dry=0
project_arg=""
for arg in "$@"; do
  case "$arg" in
    --dry-run) dry=1 ;;
    --*) printf 'wbs order: unknown flag %s\n' "'$arg'" >&2; usage; exit 2 ;;
    *)
      if [[ -n "$project_arg" ]]; then
        printf 'wbs order: unexpected argument %s\n' "'$arg'" >&2
        usage
        exit 2
      fi
      project_arg="$arg"
      ;;
  esac
done

active_resolve_project_try "$project_arg"
project="$ACTIVE_RESOLVED_PROJECT"
if ! config_is_project "$project"; then
  printf "wbs order: unknown project '%s'\n" "$project" >&2
  exit 2
fi
active_guard_scope "wbs order"
devdoc_dir="$(expand_tilde "$(config_get_project_field "$project" devdoc_dir 2>/dev/null || true)")"
if [[ -z "$devdoc_dir" ]]; then
  printf 'wbs order: devdoc_dir not configured for %s\n' "$project" >&2
  exit 2
fi

wbs="$devdoc_dir/WBS.md"
[[ -f "$wbs" ]] || die "wbs order: $wbs missing; run /devagent:wbs init first"
order_rc=0
order_cfg="$(wbs_order_config "$project" 'wbs order')" || order_rc=$?
if (( order_rc != 0 )); then
  exit 2
fi
read -r -a order_env <<<"$order_cfg"

parser="$PLUGIN_ROOT/scripts/lib/wbs-parser.py"
[[ -f "$parser" ]] || die "wbs-parser.py not found at $parser"

env "${order_env[@]}" \
WBS_PATH="$wbs" \
PARSER_PATH="$parser" \
WBS_DRY_RUN="$dry" \
python3 <<'PY'
import importlib.util
import os
import sys

spec = importlib.util.spec_from_file_location("wbs_parser", os.environ["PARSER_PATH"])
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)

rc, report, diff = mod.order_file(
    os.environ["WBS_PATH"],
    completed_last=os.environ["WBS_COMPLETED_LAST"] == "1",
    dry_run=os.environ["WBS_DRY_RUN"] == "1",
)
# The diff on stdout as UTF-8 bytes (`wbs order --dry-run > patch` is a
# clean diff); report lines on stderr, ASCII only, as wbs update's `say`.
if diff:
    sys.stdout.buffer.write(diff.encode("utf-8"))
    sys.stdout.flush()
for line in report:
    print(f"wbs order: {line}".encode("ascii", "replace").decode("ascii"), file=sys.stderr)
sys.exit(rc)
PY
