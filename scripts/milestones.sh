#!/usr/bin/env bash
# scripts/milestones.sh — #734. Print each issue's dated milestones: one row
# per event (opened, MR opened/merged, checklist steps, parks, revisions,
# closed) from the tracker's `issue-list`, the code host's `issue-mrs` and the
# local checklist logs, plus per-issue spans (spec section 13.5).
#
# Usage: milestones.sh [project] [--issue <issue-id> | --all] [--json]
#
#   (no flag)   default scope: every <devdoc>/*/checklist.md issue plus every
#               open tracker issue
#   --all       every tracker issue plus every checklist issue
#   --issue ID  one issue: an id of a configured source, or a devdoc dir
#   --json      JSON Lines (a header line, then one line per row; no spans)
#
# Read-only: it writes no WBS.md, devdoc, state or tracker. It is a trust
# entry point (it dispatches backends) and resolver-scope EXEMPT: the first
# output line names the project, so a wrong scope is self-identifying.
#
# Calls: one `issue-list` per configured issue source, then one `issue-mrs`
# per source with ids in scope (GitHub batches 50 ids per GraphQL call;
# GitLab makes one call per id). A failed source is reported, never fatal:
# one `milestones: WARNING:` line on stderr and a `missing:` line in the
# report. scripts/lib/milestones.py does everything but the calls; it reads
# the inputs from the MS_* manifest documented in its header.
#
# Exit: 0 report printed; 1 unknown project, devdoc_dir unset or missing, or
# a library failure; 2 usage error, or --issue names no configured source and
# no <devdoc>/<id>/checklist.md; 6-11 trust refusals (lib/refusals.sh).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=lib/paths.sh
source "$SCRIPT_DIR/lib/paths.sh"
# shellcheck source=lib/io.sh
source "$SCRIPT_DIR/lib/io.sh"
# shellcheck source=lib/config.sh
source "$SCRIPT_DIR/lib/config.sh"
# shellcheck source=lib/issue-source.sh
source "$SCRIPT_DIR/lib/issue-source.sh"
# shellcheck source=lib/state.sh
source "$SCRIPT_DIR/lib/state.sh"
# shellcheck source=lib/active.sh
source "$SCRIPT_DIR/lib/active.sh"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/lib/trust.sh"

USAGE="usage: milestones.sh [project] [--issue <issue-id> | --all] [--json]"

usage_error() {
  echo "milestones: $1" >&2
  echo "$USAGE" >&2
  exit 2
}

project_arg="" issue="" have_issue=0 all=0 json=0 positionals=0
while (( $# > 0 )); do
  case "$1" in
    -h|--help)
      echo "$USAGE"
      exit 0
      ;;
    --issue)
      [[ -n "${2:-}" ]] || usage_error "--issue needs an issue id"
      issue="$2" have_issue=1
      shift 2
      ;;
    --issue=*)
      issue="${1#--issue=}" have_issue=1
      [[ -n "$issue" ]] || usage_error "--issue needs an issue id"
      shift
      ;;
    --all)
      all=1
      shift
      ;;
    --json)
      json=1
      shift
      ;;
    --*)
      usage_error "unknown flag '$1'"
      ;;
    *)
      (( positionals == 0 )) || usage_error "unexpected argument '$1'"
      project_arg="$1" positionals=1
      shift
      ;;
  esac
done
if (( have_issue )); then
  # the `wbs exclude` token rule (commands/wbs.md), before any path is built
  [[ "$issue" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]] \
    || usage_error "--issue '$issue' is not one issue-id token"
  (( all == 0 )) || usage_error "--issue and --all cannot be combined"
fi

active_resolve_project_try "$project_arg" || true
project="$ACTIVE_RESOLVED_PROJECT"
config_is_project "$project" || die "milestones: unknown project '${project:-$project_arg}'"
devdoc_dir="$(expand_tilde "$(config_get_project_field "$project" devdoc_dir)")"
[[ -n "$devdoc_dir" ]] || die "milestones: devdoc_dir not configured for $project"
[[ -d "$devdoc_dir" ]] || die "milestones: devdoc_dir $devdoc_dir does not exist"
trust_entry_check "milestones" "$project"

# The manifest belongs to this script: nothing inherited reaches the library.
unset "${!MS_@}"
lib="$PLUGIN_ROOT/scripts/lib/milestones.py"
issue_dir="${DEVAGENT_ISSUE_BACKEND_DIR:-$PLUGIN_ROOT/scripts/issue}"
code_dir="${DEVAGENT_CODE_BACKEND_DIR:-$PLUGIN_ROOT/scripts/code}"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

scope=default
(( all )) && scope=all
(( have_issue )) && scope=issue
scope_args=("$scope")
(( have_issue )) && scope_args+=("$issue")

# _cli <issue|code> <backend>: the CLI that backend's read path needs on
# PATH, or "" (jira's code side never calls out).
_cli() {
  case "$1:$2" in
    *:github) echo gh ;;
    *:gitlab|issue:jira) echo curl ;;
    *) echo "" ;;
  esac
}

# _probe <script> <cli>: probe_detail = why the backend cannot be read, or "".
_probe() {
  probe_detail=""
  if [[ ! -f "$1" || ! -x "$1" ]]; then
    probe_detail="no script"
  elif [[ -n "$2" ]] && ! command -v "$2" >/dev/null 2>&1; then
    probe_detail="$2 not on PATH"
  fi
}

# _last_line <file>: the file's last non-blank line, CR stripped.
_last_line() {
  grep -v '^[[:space:]]*$' "$1" | tail -n 1 | tr -d '\r' || true
}

for S in ORIGIN FORK; do
  src_table="$(issue_source_section "${S,,}")"
  for k in backend repo dir_prefix; do
    v="$(config_get_project_field "$project" "$src_table.$k" 2>/dev/null || true)"
    [[ "$k" == dir_prefix ]] && k=prefix
    export "MS_TRK_${S}_${k^^}=$v"
  done
done

if (( have_issue )); then
  rc=0
  python3 "$lib" resolve "$devdoc_dir" "$issue" || rc=$?
  (( rc != 2 )) || exit 2
  (( rc == 0 )) || die "milestones: library failed (exit $rc)"
fi

# One issue-list per configured source.
for S in ORIGIN FORK; do
  b="MS_TRK_${S}_BACKEND" r="MS_TRK_${S}_REPO" p="MS_TRK_${S}_PREFIX"
  backend="${!b}" repo="${!r}"
  [[ -n "$backend" && -n "$repo" && -n "${!p}" ]] || continue
  sh="$issue_dir/$backend.sh"
  status=ok file="" detail=""
  _probe "$sh" "$(_cli issue "$backend")"
  if [[ -n "$probe_detail" ]]; then
    status=nolookup detail="$probe_detail"
  else
    file="$tmp/il-$S.out" rc=0
    DEVAGENT_PROJECT="$project" "$sh" issue-list "$repo" >"$file" 2>"$tmp/il-$S.err" || rc=$?
    case "$rc" in
      0) ;;
      2|78) status=nolookup detail="exit $rc" ;;
      *) status=failed detail="exit $rc: $(_last_line "$tmp/il-$S.err")" ;;
    esac
  fi
  export "MS_TRK_${S}_STATUS=$status" "MS_TRK_${S}_FILE=$file" "MS_TRK_${S}_DETAIL=$detail"
done

# One issue-mrs per source with ids in scope.
code_backend="$(config_get_project_field "$project" code_source.backend 2>/dev/null || true)"
export MS_MR_BACKEND="$code_backend"
if [[ -n "$code_backend" ]]; then
  mr_script="$code_dir/$code_backend.sh"
  _probe "$mr_script" "$(_cli code "$code_backend")"
  if [[ -n "$probe_detail" ]]; then
    export MS_MR_STATUS=nolookup MS_MR_DETAIL="$probe_detail"
  else
    export MS_MR_STATUS=ready
    keys="$(python3 "$lib" keys "$devdoc_dir" "${scope_args[@]}")" \
      || die "milestones: library failed (keys)"
    for S in ORIGIN FORK; do
      mr_repo="" mr_ids=()
      while IFS=$'\t' read -r s r k; do
        k="${k%$'\r'}"
        [[ "$s" == "$S" && -n "$k" ]] || continue
        mr_repo="$r" mr_ids+=("$k")
      done <<<"$keys"
      (( ${#mr_ids[@]} > 0 )) || continue
      rc=0 detail=""
      DEVAGENT_PROJECT="$project" "$mr_script" issue-mrs "$mr_repo" "${mr_ids[@]}" \
        >"$tmp/mr-$S.out" 2>"$tmp/mr-$S.err" || rc=$?
      (( rc == 0 )) || detail="$(_last_line "$tmp/mr-$S.err")"
      export "MS_MR_${S}_RC=$rc" "MS_MR_${S}_FILE=$tmp/mr-$S.out" "MS_MR_${S}_DETAIL=$detail"
    done
  fi
fi

emit_args=("$devdoc_dir" "$project" "${scope_args[@]}")
(( json )) && emit_args+=(--json)
python3 "$lib" emit "${emit_args[@]}" || die "milestones: library failed (emit)"
