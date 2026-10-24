#!/usr/bin/env bash
# scripts/lib/transition.sh — tracker stage transitions (#710). Source-only.
# Requires paths.sh, io.sh and config.sh sourced first.
#
# Two jobs, one home:
#   * the stage→state resolver (stage_map_*), read by the three built-in issue
#     backends, the three callers and doctor, so they cannot disagree on which
#     label or status a stage names;
#   * the gate/fire/classify step (transition_*), shared by the three callers
#     (transition-draft-start.sh, ship.sh, sync.sh).
#
# Precedence of stage_map_target <backend> <project> <stage> (spec §9.1):
#   1. the per-stage env override, DEVAGENT_GITHUB_LABEL_<STAGE> (github),
#      DEVAGENT_GITLAB_LABELS_<STAGE> (gitlab), DEVAGENT_JIRA_STAGE_<STAGE>
#      (jira); <STAGE> is the stage upper-cased with - as _. These are
#      PROCESS-GLOBAL operator/test seams: a stale one redirects every
#      project's write (doctor warns while one is set).
#   2. [project.<p>.github_labels].<stage> or [project.<p>.gitlab_labels].<stage>
#   3. [project.<p>.issue_workflow].<stage>, for every backend
# Steps 2 and 3 run only for a non-empty <project> and an on_* stage. The
# project is the one the CALLER resolved, never an ambient DEVAGENT_PROJECT
# (#663: such exports go stale).

_TRANSITION_STAGES="on_draft_start on_ship on_merge"
# The built-in backends, which map stages here; a custom backend maps for itself.
_TRANSITION_BUILTINS="github gitlab jira"

# stage_map_builtin <backend>: 0 iff <backend> is a built-in backend.
stage_map_builtin() { [[ " $_TRANSITION_BUILTINS " == *" $1 "* ]]; }

# stage_map_env_var <backend> <stage>: the env override's name, or nothing for
# a backend without one (or a stage that cannot form a variable name).
stage_map_env_var() {
  local up="${2^^}" var
  up="${up//-/_}"
  case "$1" in
    github) var="DEVAGENT_GITHUB_LABEL_${up}" ;;
    gitlab) var="DEVAGENT_GITLAB_LABELS_${up}" ;;
    jira)   var="DEVAGENT_JIRA_STAGE_${up}" ;;
    *)      return 0 ;;
  esac
  [[ "$var" =~ ^[A-Z_][A-Z0-9_]*$ ]] && printf '%s' "$var"
  return 0
}

# stage_map_target <backend> <project> <stage>: print the mapped state, or
# nothing when the stage has no mapping. Returns 0, or 1 when the config
# cannot be read (an unparseable file): the caller must not read that as "no
# mapping" (a backend exits 1, failed, so sync retries; register 314). A
# missing config file is no mapping.
stage_map_target() {
  local backend="$1" project="$2" stage="$3" var v rc t
  var="$(stage_map_env_var "$backend" "$stage")"
  if [ -n "$var" ] && [ -n "${!var:-}" ]; then
    printf '%s\n' "${!var}"
    return 0
  fi
  [ -n "$project" ] || return 0
  [[ " $_TRANSITION_STAGES " == *" $stage "* ]] || return 0
  [ -f "$(config_path)" ] || return 0
  local tables=()
  case "$backend" in github|gitlab) tables+=("${backend}_labels") ;; esac
  tables+=(issue_workflow)
  for t in "${tables[@]}"; do
    rc=0
    v="$(config_get_project_field "$project" "$t.$stage" 2>/dev/null)" || rc=$?
    case "$rc" in
      0) v="${v//$'\r'/}"
         if [ -n "$v" ]; then printf '%s\n' "$v"; return 0; fi ;;
      1) ;;
      *) echo "stage_map_target: cannot read $(config_path) (exit $rc); no stage mapping resolved" >&2
         return 1 ;;
    esac
  done
  return 0
}

# _stage_map_key <backend> <name>: the comparison key — GitHub names labels
# case-insensitively, GitLab and JIRA compare exactly.
_stage_map_key() {
  if [ "$1" = github ]; then printf '%s' "${2,,}"; else printf '%s' "$2"; fi
}

# stage_map_others <backend> <project> <stage> [target]: the other two stages'
# mapped states, one per line in stage order, deduplicated, never the target
# itself. These are the stale stage labels a transition removes. A caller that
# already resolved <stage>'s target passes it, saving its config reads. Returns
# 1 as stage_map_target does.
stage_map_others() {
  local backend="$1" project="$2" stage="$3" target s t k seen
  if [ "$#" -ge 4 ]; then
    target="$4"
  else
    target="$(stage_map_target "$backend" "$project" "$stage")" || return 1
  fi
  seen=$'\n'"$(_stage_map_key "$backend" "$target")"$'\n'
  for s in $_TRANSITION_STAGES; do
    [ "$s" != "$stage" ] || continue
    t="$(stage_map_target "$backend" "$project" "$s")" || return 1
    [ -n "$t" ] || continue
    k="$(_stage_map_key "$backend" "$t")"
    [[ "$seen" == *$'\n'"$k"$'\n'* ]] && continue
    seen+="$k"$'\n'
    printf '%s\n' "$t"
  done
  return 0
}

# stage_map_carried <backend> <present> <names>: each of <names> (one per line)
# that <present> (the issue's labels, one per line) carries, in <names> order,
# printed as the issue carries it — compared by _stage_map_key.
stage_map_carried() {
  local o p k
  while IFS= read -r o; do
    [ -n "$o" ] || continue
    k="$(_stage_map_key "$1" "$o")"
    while IFS= read -r p; do
      if [ -n "$p" ] && [ "$(_stage_map_key "$1" "$p")" = "$k" ]; then printf '%s\n' "$p"; break; fi
    done <<<"$2"
  done <<<"$3"
}

# stage_state_probe <auth-header> <url> <confirm-url>: a state-exists lookup
# (needs backend-common.sh). 0 <url> answers, 3 auth refused, 1 any other
# failure; a 404 is 4 (absent) only when <confirm-url> answers, so a token
# that cannot see the resource, or a wrong base path, never reads as absent.
stage_state_probe() {
  local rc=0
  bc_curl_auth "$1" GET "$2" -H 'Accept: application/json' >/dev/null 2>&1 || rc=$?
  if [ "$rc" = 4 ]; then
    rc=0
    bc_curl_auth "$1" GET "$3" -H 'Accept: application/json' >/dev/null 2>&1 || rc=$?
    case "$rc" in
      0) return 4 ;;
      3) return 3 ;;
      *) return 1 ;;
    esac
  fi
  case "$rc" in
    0|3) return "$rc" ;;
    *)   return 1 ;;
  esac
}

# stage_map_kind <backend>: what a mapped state is on that tracker.
stage_map_kind() {
  case "$1" in
    github|gitlab) echo label ;;
    jira)          echo status ;;
    *)             echo state ;;
  esac
}

# transition_args <b> <args…>: parse a built-in backend's
#   transition <repo> <num> <semantic-stage> [--project <name>]
# into TA_REPO TA_NUM TA_STAGE TA_PROJECT. Returns 2 with one stderr line for
# anything else: a missing positional, --project with no value or an empty one,
# --project=x, a repeated --project, or any other argument (a first `--flag`
# on a positional script must refuse, not be read as a stage; register 655).
# The TA_* setter-globals are the return channel, read by the calling backend.
# shellcheck disable=SC2034
transition_args() {
  local b="$1"; shift
  TA_REPO="${1:-}" TA_NUM="${2:-}" TA_STAGE="${3:-}" TA_PROJECT=""
  if [ -z "$TA_REPO" ] || [ -z "$TA_NUM" ] || [ -z "$TA_STAGE" ] \
     || [[ "$TA_REPO" == -* || "$TA_NUM" == -* || "$TA_STAGE" == -* ]]; then
    echo "$b: usage: transition <repo> <num> <semantic-stage> [--project <name>]" >&2
    return 2
  fi
  shift 3
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --project)
        if [ -n "$TA_PROJECT" ] || [ -z "${2:-}" ]; then
          echo "$b: transition: --project takes one non-empty value" >&2
          return 2
        fi
        TA_PROJECT="$2"; shift 2 ;;
      *)
        echo "$b: transition: unknown argument '$1'" >&2
        return 2 ;;
    esac
  done
}

# transition_unmapped <backend> <stage> <project>: the one warning a built-in
# backend prints for a stage with no mapping (it then exits 0, no tracker call).
transition_unmapped() {
  if [ -n "$3" ]; then
    echo "$1.sh: no tracker state mapped for '$2' (project $3); transition skipped" >&2
  else
    echo "$1.sh: no tracker state mapped for '$2' (no --project: only $(stage_map_env_var "$1" "$2") is read); transition skipped" >&2
  fi
}

# transition_gate_open <project>: 0 iff permissions.transition_issue is exactly
# true. Every transition — on_draft_start, on_ship and on_merge — is behind it
# (#710 reopened #219/#344's ungated on_ship, decided while on_ship wrote
# nothing). Read directly, fail closed: never permission_gate, which prompts.
transition_gate_open() {
  local v
  v="$(config_get_project_field "$1" permissions.transition_issue 2>/dev/null || true)"
  [ "${v//$'\r'/}" = true ]
}

# transition_route <project> <issue_arg>: the issue's tracker, by origin —
# Issue-Fork-NNN to issue_source_fork, Issue-NNN to issue_source — in the
# setter-globals TR_BACKEND TR_REPO TR_NUM. An absent source leaves backend and
# repo empty, which transition_fire reads as no-tracker.
# shellcheck disable=SC2034
transition_route() {
  local which=issue_source
  if [[ "$2" == Issue-Fork-* ]]; then
    which=issue_source_fork; TR_NUM="${2#Issue-Fork-}"
  else
    TR_NUM="${2#Issue-}"
  fi
  TR_BACKEND="$(config_get_project_field "$1" "$which.backend" 2>/dev/null || true)"
  TR_REPO="$(config_get_project_field    "$1" "$which.repo"    2>/dev/null || true)"
}

# transition_backend_sh <backend>: the backend script's path.
transition_backend_sh() {
  printf '%s' "${DEVAGENT_ISSUE_BACKEND_DIR:-$(plugin_root)/scripts/issue}/$1.sh"
}

# transition_fire <caller> <project> <issue_arg> <stage> <backend> <repo> <num> [suffix]
# Gate, route and fire one transition. Call it BARE, never in $(…): it returns
# its result in three setter-globals and must not lose them to a subshell.
#   TRANSITION_OUTCOME  gated | no-tracker | no-backend | failed | unmapped | landed
#   TRANSITION_RC       the backend's exit code (0 unless it ran and failed)
#   TRANSITION_TARGET   the generic mapped state ("" for none, or a custom
#                       backend that maps for itself)
# It never dies and always returns 0: a tracker hiccup must not block the step
# (spec §11), and the callers run under set -e inside --auto chains. Each
# outcome but landed and unmapped prints one stderr line (an unmapped stage's
# warning is the backend's own). <suffix> is appended to the lines of the
# outcomes that leave nothing done (failed, no-backend): sync passes its
# retry note there.
# The TRANSITION_* setter-globals are the return channel, read by the caller.
# shellcheck disable=SC2034
transition_fire() {
  local caller="$1" project="$2" issue_arg="$3" stage="$4" backend="$5" repo="$6" num="$7" suffix="${8:-}"
  TRANSITION_OUTCOME="" TRANSITION_RC=0 TRANSITION_TARGET=""
  if ! transition_gate_open "$project"; then
    TRANSITION_OUTCOME=gated
    echo "$caller: $stage transition for $project/$issue_arg skipped — permissions.transition_issue not enabled (remote tracker state left unchanged)" >&2
    return 0
  fi
  if [ -z "$backend" ] || [ -z "$repo" ]; then
    TRANSITION_OUTCOME=no-tracker
    echo "$caller: no issue tracker configured for $issue_arg; skipping $stage transition" >&2
    return 0
  fi
  local sh; sh="$(transition_backend_sh "$backend")"
  if [ ! -x "$sh" ]; then
    TRANSITION_OUTCOME=no-backend
    echo "$caller: issue backend $sh not executable; skipping $stage transition$suffix" >&2
    return 0
  fi
  TRANSITION_TARGET="$(stage_map_target "$backend" "$project" "$stage" 2>/dev/null || true)"
  "$sh" transition "$repo" "$num" "$stage" --project "$project" || TRANSITION_RC=$?
  if [ "$TRANSITION_RC" -ne 0 ]; then
    TRANSITION_OUTCOME=failed
    echo "warning: $stage transition failed for $project/$issue_arg (exit $TRANSITION_RC) — continuing per spec §11$suffix" >&2
  elif [ -z "$TRANSITION_TARGET" ] && stage_map_builtin "$backend"; then
    TRANSITION_OUTCOME=unmapped
  else
    TRANSITION_OUTCOME=landed
  fi
  return 0
}

# transition_plan_note <project> <stage> <backend> <repo>: what a transition
# would do, for a plan line (ship's, D7) — decided in transition_fire's order.
transition_plan_note() {
  local project="$1" stage="$2" backend="$3" repo="$4" t
  if ! transition_gate_open "$project"; then
    echo "skipped (permissions.transition_issue not enabled)"
  elif [ -z "$backend" ] || [ -z "$repo" ]; then
    echo "skipped (no issue tracker configured)"
  else
    t="$(stage_map_target "$backend" "$project" "$stage" 2>/dev/null || true)"
    if [ -n "$t" ]; then
      echo "\"$t\" on $repo"
    elif stage_map_builtin "$backend"; then
      echo "skipped (no tracker state mapped)"
    else
      echo "on $repo"
    fi
  fi
}
