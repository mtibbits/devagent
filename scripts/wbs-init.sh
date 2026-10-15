#!/usr/bin/env bash
# wbs init: create <devdoc>/WBS.md.
#
#   init [project] [--force]
#   init [project] --from-tracker [--all | --since YYYY-MM-DD | --since <issue-id>
#                                  | --open-only | --epic <issue-id>]
#   init [project] [--from-tracker] --merge [--all | --since … | --open-only | --epic …]
#   init [project] [--from-tracker] --survey
#   <issue-id> := N | <dir_prefix>N | <JIRA-KEY>        (--flag=value also accepted)
#
# Without --from-tracker it copies the resolved wbs_template (the §12
# registry), substituting {{PROJECT}}, and refuses to overwrite unless
# --force. With it (#706) it builds the file from the project's tracker
# history: one `issue-list` call per configured source (origin
# issue_source, fork issue_source_fork), then scripts/lib/wbs-import.py
# (Python never spawns a backend script). --survey prints the survey JSON
# and writes nothing, so it also runs beside an existing WBS.md. --merge
# (#707) adds the tracker's issues an existing WBS.md lacks, inserting
# whole lines only; ids in a `<!-- wbs-exclude: ... -->` line are skipped.
#
# Exit: 0 written (or surveyed, or merged, or nothing to merge); 1 die (an
# existing WBS.md without --merge, a missing or unreadable one with it, a
# bad config value, a backend without issue-list or failing, malformed
# backend output, a merge that would change an existing line or whose
# write fails);
# 2 a usage error, raised before any tracker call, or a range value only the
# data can check (an --epic that names no epic, a calendar-invalid date);
# 10 no range flag and a closed share at or above
# [project.<p>.wbs].auto_import_below_pct (default 20): the survey JSON and
# then the line `WBS-INIT: choose-range` on stdout, nothing written.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=lib/paths.sh
source "$SCRIPT_DIR/lib/paths.sh"
# shellcheck source=lib/io.sh
source "$SCRIPT_DIR/lib/io.sh"
# shellcheck source=lib/config.sh
source "$SCRIPT_DIR/lib/config.sh"
# active_guard_scope reads state_get (#572); without state.sh the guard's
# state lookup would 127 inside its $(... || true)
# shellcheck source=lib/state.sh
source "$SCRIPT_DIR/lib/state.sh"
# shellcheck source=lib/active.sh
source "$SCRIPT_DIR/lib/active.sh"
# shellcheck source=lib/template_resolve.sh
source "$SCRIPT_DIR/lib/template_resolve.sh"

usage_die() {
  echo "wbs init: $*" >&2
  echo "usage: wbs init [project] [--force] | [project] --from-tracker [--all | --since <date|issue-id> | --open-only | --epic <issue-id>] | [project] [--from-tracker] --merge [<range>] | [project] [--from-tracker] --survey" >&2
  exit 2
}

DATE_RE='^[0-9]{4}-(0[1-9]|1[0-2])-(0[1-9]|[12][0-9]|3[01])$'
ID_RE='^([0-9]+|[A-Za-z][A-Za-z0-9_-]*[0-9]+)$'

force=0 tracker=0 survey=0 merge=0 ranges=0 range="" project_arg=""
_range() { ranges=$((ranges + 1)); range="$1"; }
# _range_val <since|epic> <value>
_range_val() {
  local name="$1" v="$2"
  [[ -n "$v" ]] || usage_die "--$name needs a value"
  if [[ "$name" == since && "$v" =~ $DATE_RE ]]; then
    _range "since:$v"
  elif [[ "$v" =~ $ID_RE ]]; then
    _range "$name:$v"
  else
    usage_die "--$name: '$v' is not $([[ "$name" == since ]] && echo "a YYYY-MM-DD date or ")an issue id (N, <dir_prefix>N or a Jira key)"
  fi
}

while (($#)); do
  arg="$1"; shift
  case "$arg" in
    --force)        force=1 ;;
    --from-tracker) tracker=1 ;;
    --survey)       survey=1 tracker=1 ;;
    --merge)        merge=1 tracker=1 ;;
    --all)          _range all ;;
    --open-only)    _range open-only ;;
    --since|--epic)
      (($#)) || usage_die "$arg needs a value"
      _range_val "${arg#--}" "$1"; shift ;;
    --since=*|--epic=*)
      name="${arg%%=*}"
      _range_val "${name#--}" "${arg#*=}" ;;
    --*) usage_die "unknown flag '$arg'" ;;
    *)
      if [[ -z "$project_arg" ]]; then
        project_arg="$arg"
      else
        warn "wbs init: ignoring extra arg '$arg'"
      fi
      ;;
  esac
done

(( ranges <= 1 )) || usage_die "give at most one of --all, --since, --open-only, --epic"
if (( force == 1 && (tracker == 1 || ranges > 0) )); then
  usage_die "--force overwrites from the template; it cannot be combined with --from-tracker or --merge (--merge adds the tracker's missing issues to an existing WBS.md)"
fi
(( survey == 0 || merge == 0 )) || usage_die "--survey writes nothing; it cannot be combined with --merge"
(( ranges == 0 || tracker == 1 )) || usage_die "a range flag needs --from-tracker"
(( survey == 0 || ranges == 0 )) || usage_die "--survey takes no range flag"

active_resolve_project_try "$project_arg"
project="$ACTIVE_RESOLVED_PROJECT"
config_is_project "$project" || die "wbs init: unknown project '$project'"
active_guard_scope "wbs init"
devdoc_dir="$(expand_tilde "$(config_get_project_field "$project" devdoc_dir)")"
[[ -n "$devdoc_dir" ]] || die "wbs init: devdoc_dir not configured for $project"

dest="$devdoc_dir/WBS.md"

if (( tracker == 0 )) && [[ -e "$dest" && $force -ne 1 ]]; then
  die "wbs init: $dest exists; pass --force to overwrite"
fi
if (( merge == 1 )); then
  [[ -f "$dest" ]] || die "wbs init --merge: $dest missing; run 'wbs init --from-tracker' first"
elif (( tracker == 1 && survey == 0 )) && [[ -e "$dest" ]]; then
  die "wbs init: $dest exists; pass --merge to add the tracker's missing issues to it"
fi

# Resolve the template through the §12 registry (lib/template_resolve.sh) so a
# [project.<name>.paths].wbs_template override (layer 1) is honored — not just
# devdoc (2) / plugin (3), which the previous hand-rolled loop was limited to.
# #341. The `if …; then` captures the rc so `set -e` cannot swallow the die on a
# genuine no-template case (template_resolve returns 1 when no layer matches).
template=""
if (( survey == 0 && merge == 0 )); then
  if resolved="$(template_resolve "$project" wbs_template)"; then
    template="$(printf '%s\n' "$resolved" | sed -n 's/^path=//p')"
  fi
  [[ -n "$template" ]] || die "no wbs_template.md found for '$project' (checked project paths, devdoc, plugin)"
fi

if (( tracker == 0 )); then
  mkdir -p "$(dirname "$dest")"
  sed -e "s|{{PROJECT}}|${project}|g" "$template" > "$dest"
  info "wbs init: wrote $dest from $template"
  exit 0
fi

# --- --from-tracker (#706) ----------------------------------------------------
pct=20
if v="$(config_get_project_field "$project" wbs.auto_import_below_pct 2>/dev/null)"; then
  v="$(printf '%s' "$v" | tr -d '\r')"
  [[ "$v" =~ ^(0|[1-9][0-9]?|100)$ ]] \
    || die "wbs init: [project.$project.wbs] auto_import_below_pct must be an integer from 0 to 100, got '$v'"
  pct="$v"
fi

backend_dir="${DEVAGENT_ISSUE_BACKEND_DIR:-$PLUGIN_ROOT/scripts/issue}"
imp_tmp="$(mktemp -d)"
trap 'rm -rf "$imp_tmp"' EXIT
imp_env=()

# _imp_fetch <ORIGIN|FORK> <table>: one issue-list call; dies on any failure.
_imp_fetch() {
  local S="$1" table="$2" backend repo prefix keyprefix="" sh file err rc
  backend="$(config_get_project_field "$project" "$table.backend" 2>/dev/null || true)"
  repo="$(config_get_project_field "$project" "$table.repo" 2>/dev/null || true)"
  prefix="$(config_get_project_field "$project" "$table.dir_prefix" 2>/dev/null || true)"
  if [[ -z "$backend$repo$prefix" && "$S" == FORK ]]; then
    return 0
  fi
  # a source silently dropped would corrupt the survey
  [[ -n "$backend" && -n "$repo" && -n "$prefix" ]] \
    || die "wbs init: [project.$project.$table] needs backend, repo and dir_prefix for --from-tracker"
  [[ "$backend" == jira ]] && keyprefix="${DEVAGENT_JIRA_PROJECT_KEY:-$repo}"
  sh="$backend_dir/$backend.sh"
  [[ -f "$sh" && -x "$sh" ]] || die "wbs init: no issue backend script $sh"
  file="$imp_tmp/$S.out" err="$imp_tmp/$S.err"
  if DEVAGENT_PROJECT="$project" "$sh" issue-list "$repo" >"$file" 2>"$err"; then
    rc=0
  else
    rc=$?
  fi
  case "$rc" in
    0) ;;
    2|78) die "wbs init: $backend has no issue-list (exit $rc); wbs init --from-tracker needs it" ;;
    *) die "wbs init: $backend issue-list $repo failed (exit $rc): $(grep -v '^[[:space:]]*$' "$err" | tail -n 1 | tr -d '\r' || true)" ;;
  esac
  imp_env+=("WBS_IMP_${S}_FILE=$file" "WBS_IMP_${S}_BACKEND=$backend"
            "WBS_IMP_${S}_REPO=$repo" "WBS_IMP_${S}_PREFIX=$prefix"
            "WBS_IMP_${S}_KEYPREFIX=$keyprefix")
}

_imp_fetch ORIGIN issue_source
_imp_fetch FORK issue_source_fork

mode=import
(( survey == 0 )) || mode=survey
(( merge == 0 )) || mode=merge
env "${imp_env[@]}" \
  WBS_IMP_MODE="$mode" WBS_IMP_RANGE="$range" WBS_IMP_PCT="$pct" \
  WBS_IMP_PROJECT="$project" WBS_IMP_DEST="$dest" WBS_IMP_TEMPLATE="$template" \
  DEVDOC_DIR="$devdoc_dir" \
  python3 "$SCRIPT_DIR/lib/wbs-import.py" run
