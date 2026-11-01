#!/usr/bin/env bash
# scripts/lib/trust.sh — the #711 trust policy at entry points (#713).
#
# Entry points source this after their usual libraries and call
# trust_entry_check once, after project resolution and before any backend
# call, network call or devdoc write. With no policy on the host it runs only
# [ -e ] / [ -L ] tests and returns 0, so a no-policy run is byte-identical to
# one without trust (tests/trust-golden.bats). Out of scope, it returns 0
# after loading the policy. In scope it refuses (exit 9) or asks for a retry
# (exit 10) through refusals.sh; spec §3.8.
#
# shellcheck shell=bash

_TRUST_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$_TRUST_LIB_DIR/trust-locate.sh"
# shellcheck source=/dev/null
source "$_TRUST_LIB_DIR/refusals.sh"
# shellcheck source=/dev/null
declare -F plugin_root >/dev/null || source "$_TRUST_LIB_DIR/paths.sh"
# shellcheck source=/dev/null
declare -F config_get_project_field >/dev/null || source "$_TRUST_LIB_DIR/config.sh"
# shellcheck source=/dev/null
declare -F transition_gate_open >/dev/null || source "$_TRUST_LIB_DIR/transition.sh"

# The fixed system candidates: Git Bash's /etc is the Git install's, WSL's is
# the distro's, and /c/ProgramData is the Windows one (invisible to WSL). Set
# here, never from the environment (an array cannot be exported). Keep
# tests/lib/hermetic-env.bash's copy in step.
TRUST_SYSTEM_DIRS=(/etc/devagent/trust /c/ProgramData/devagent/trust)

# Every script that calls trust_entry_check (or trust_entry_check_devdoc), by
# its path under scripts/ minus .sh — the #713 Task 1 census (the issue's set
# plus wbs-update and statusreport). tests/trust-entry.bats holds this list
# equal to the callers in both directions. #720 adds sign.
TRUST_ENTRY_POINTS=(
  pull next ship cleanup mergetoall mergemr comments capture/file sync
  transition-draft-start park resume switch stuck unstuck revise
  checklist-advance checklist-init checklist-log checklist-mark checklist-stuck
  checklist-unstuck commit branch spike promote-potholes
  migrate-checklist-numbering wbs-update statusreport
)

_TRUST_KINDS=" digest file scope id val "
_TRUST_TRUSTED_SETS=(trusted_approvers trusted_reporters trusted_reviewers)

# trust_locate_host: trust_locate over the fixed candidates.
trust_locate_host() {
  trust_locate --system "${TRUST_SYSTEM_DIRS[@]}" --user "$HOME/.config/devagent/trust"
}

# _trust_py <verb> [args…]: trust_policy.py exactly as every caller runs it.
_trust_py() { python3 -I -X utf8 "$_TRUST_LIB_DIR/trust_policy.py" "$@"; }

# _trust_forbid_roots: the --forbid arguments — where the agent writes, so a
# policy there could be rewritten by the session it governs.
_trust_forbid_roots() {
  local p f v src
  printf '%s\n' --forbid "$(devagent_home)" --forbid "$(plugin_root)"
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    for f in devdoc_dir source_dir worktree_root; do
      v="$(config_get_project_field "$p" "$f" 2>/dev/null || true)"
      if [ "$f" = worktree_root ] && [ -z "$v" ] && [ -n "$src" ]; then v="$src-wt"; fi
      [ "$f" = source_dir ] && src="$v"
      [ -n "$v" ] && printf '%s\n' --forbid "$v"
    done
    src=""
  done < <(config_list_projects 2>/dev/null || true)
}

# trust_load: validate $TRUST_DIR/policy.toml. SETTER-GLOBAL — call it bare.
# Sets TRUST_DIGEST TRUST_FILE TRUST_SCOPES[] TRUST_ID[<set>|<b>:<id>]
# TRUST_VAL[<key>] (JSON). Any defect refuses (exit 9): a non-zero exit of the
# loader (1 traceback, 2 usage, 3 defect), a CR anywhere in its output, a
# kind outside the five or an empty field — so a CRLF host can never fall
# open to "out of scope".
# shellcheck disable=SC2034,SC2153  # setter-globals; TRUST_DIR is trust_locate's
trust_load() {
  local out rc=0 err line kind name value file="$TRUST_DIR/policy.toml" forbid=()
  mapfile -t forbid < <(_trust_forbid_roots)
  err="$(mktemp)"
  out="$(_trust_py load "$TRUST_DIR" "${forbid[@]}" 2>"$err")" || rc=$?
  if [ "$rc" -ne 0 ]; then
    local reason
    reason="$(head -n 1 "$err" | tr -d '\r')"
    rm -f "$err"
    refuse policy-defect "$file" "${reason:-trust_policy.py exited $rc}"
  fi
  rm -f "$err"
  [[ "$out" != *$'\r'* ]] || refuse policy-defect "$file" "a carriage return in the loader's output"
  unset TRUST_ID TRUST_VAL
  declare -gA TRUST_ID=() TRUST_VAL=()
  TRUST_SCOPES=() TRUST_DIGEST="" TRUST_FILE=""
  while IFS= read -r line; do
    IFS=$'\t' read -r kind name value <<<"$line"
    if [[ "$_TRUST_KINDS" != *" $kind "* ]] || [ -z "$name" ] || [ -z "$value" ]; then
      refuse policy-defect "$file" "a malformed loader line '$line'"
    fi
    case "$kind" in
      digest) TRUST_DIGEST="$value" ;;
      file)   TRUST_FILE="$value" ;;
      scope)  TRUST_SCOPES+=("$value") ;;
      id)     TRUST_ID["$name|$value"]=1 ;;
      val)    TRUST_VAL["$name"]="$value" ;;
    esac
  done <<<"$out"
  if [ -z "$TRUST_DIGEST" ] || [ "${#TRUST_SCOPES[@]}" -eq 0 ]; then
    refuse policy-defect "$file" "the loader printed no digest or no scope"
  fi
}

# _trust_tracker_host <backend>: the policy's tracker host/URL for <backend>.
_trust_tracker_host() {
  local path
  case "$1" in
    github) path=.github.host ;;
    gitlab) path=.gitlab.api_url ;;
    jira)   path=.jira.base_url ;;
    *) return 0 ;;
  esac
  [ -n "${TRUST_VAL[trackers]:-}" ] || return 0
  printf '%s' "${TRUST_VAL[trackers]}" | jq -r "$path // empty" 2>/dev/null | tr -d '\r'
}

# trust_repo_key <backend> <repo>, trust_issue_key <backend> <repo> <num>:
# the canonical keys, the host taken from the policy's trackers.
trust_repo_key() {
  local h
  h="$(_trust_tracker_host "$1")"
  _trust_py key "$1" "$2" ${h:+--host "$h"}
}
trust_issue_key() {
  local h
  h="$(_trust_tracker_host "$1")"
  _trust_py key "$1" "$2" "$3" ${h:+--host "$h"}
}

# trust_project_scope <project> [origin|fork]: 0 iff an issue_source or
# issue_source_fork repo key equals a scope. SETTER-GLOBAL: TRUST_SCOPE_KEYS[]
# and, parallel to it, TRUST_SCOPE_BACKENDS[] / TRUST_SCOPE_REPOS[] — the
# in-scope sources to check, narrowed to <source> when it is in scope.
trust_project_scope() {
  local project="$1" only="${2:-}" section which backend repo key s
  TRUST_SCOPE_KEYS=() TRUST_SCOPE_BACKENDS=() TRUST_SCOPE_REPOS=()
  local keys=() backends=() repos=() whichs=()
  for which in origin fork; do
    section=issue_source
    [ "$which" = fork ] && section=issue_source_fork
    backend="$(config_get_project_field "$project" "$section.backend" 2>/dev/null || true)"
    repo="$(config_get_project_field "$project" "$section.repo" 2>/dev/null || true)"
    backend="${backend//$'\r'/}" repo="${repo//$'\r'/}"
    if [ -z "$backend" ] || [ -z "$repo" ]; then continue; fi
    key="$(trust_repo_key "$backend" "$repo" 2>/dev/null)" || continue
    for s in "${TRUST_SCOPES[@]}"; do
      if [ "$s" = "$key" ]; then
        keys+=("$key") backends+=("$backend") repos+=("$repo") whichs+=("$which")
      fi
    done
  done
  [ "${#keys[@]}" -gt 0 ] || return 1
  local i
  for i in "${!keys[@]}"; do
    # pull names its source; when that source is out of scope every in-scope
    # source is checked instead (fail closed).
    if [ -n "$only" ] && [[ " ${whichs[*]} " == *" $only "* ]] && [ "${whichs[$i]}" != "$only" ]; then
      continue
    fi
    TRUST_SCOPE_KEYS+=("${keys[$i]}") TRUST_SCOPE_BACKENDS+=("${backends[$i]}") TRUST_SCOPE_REPOS+=("${repos[$i]}")
  done
  return 0
}

# trust_grants <set> <backend> <actor> <atype> [--signed]: THE predicate — does
# <actor> (an immutable id, `whoami` for this session's account, or `?` when
# unknown) count as a member of <set>? <atype> (User, Bot, App, Customer…)
# grants nothing by itself: a bot or app grants only when listed.
#   - `?` and an unlisted actor: false.
#   - single_identity = false: false for whoami and for any worker.
#   - single_identity = true: a worker that is also in <set> (whoami included)
#     grants only --signed or with an empty required_hardening; a worker not
#     in <set> stays false.
trust_grants() {
  local set="$1" b="$2" actor="$3" signed=0 id worker=0
  [ "${5:-}" = --signed ] && signed=1
  [ "$actor" != "?" ] || return 1
  if [ "$actor" = whoami ]; then
    id="${TRUST_WHOAMI:-}"
    worker=1
    [ -n "$id" ] || return 1
    [ "${id%%:*}" = "$b" ] || return 1
  else
    id="$b:$actor"
  fi
  [ -n "${TRUST_ID["$set|$id"]:-}" ] || return 1
  [ -n "${TRUST_ID["worker_identities|$id"]:-}" ] && worker=1
  [ "$worker" = 1 ] || return 0
  [ "${TRUST_VAL[single_identity]:-false}" = true ] || return 1
  [ "$signed" = 1 ] && return 0
  [ "${TRUST_VAL[required_hardening]:-[]}" = "[]" ]
}

# _trust_list <json-list-of-strings>: one member per line (members are
# validated names from a fixed set, so no quoting survives).
_trust_list() {
  local s="${1#[}"
  s="${s%]}"
  s="${s//\"/}"
  [ -n "$s" ] || return 0
  tr ',' '\n' <<<"$s"
}

# _trust_system_policy_met: 1 — `system_policy` reads "unverified: not met"
# until #902 verifies the location's write access.
_trust_system_policy_met() { return 1; }

# _trust_signatures_met: 1 — no signature is verified until #720 (sign, the
# keyring principal check).
_trust_signatures_met() { return 1; }

# trust_hardening: SETTER-GLOBAL TRUST_HARD_MET[] / TRUST_HARD_MISSING[] and
# TRUST_HARD_WHY[<name>], in the order separate_identity, signatures,
# system_policy. separate_identity is met iff single_identity = false and the
# identity check passed (TRUST_WHOAMI set).
trust_hardening() {
  TRUST_HARD_MET=() TRUST_HARD_MISSING=()
  declare -gA TRUST_HARD_WHY=(
    [separate_identity]="single_identity = true, or no identity check passed"
    [signatures]="no signature is verified until #720"
    [system_policy]="unverified: not met until #902 verifies the system location"
  )
  if [ "${TRUST_VAL[single_identity]:-false}" != true ] && [ -n "${TRUST_WHOAMI:-}" ]; then
    TRUST_HARD_MET+=(separate_identity)
  else
    TRUST_HARD_MISSING+=(separate_identity)
  fi
  if _trust_signatures_met; then TRUST_HARD_MET+=(signatures); else TRUST_HARD_MISSING+=(signatures); fi
  if _trust_system_policy_met; then TRUST_HARD_MET+=(system_policy); else TRUST_HARD_MISSING+=(system_policy); fi
}

# trust_project_for_devdoc <dir>: the one config project whose devdoc_dir is
# <dir>, both sides resolved with realpath; empty for none or several, which
# trust_entry_check reads as scope-unresolved. Never reads an ambient
# DEVAGENT_PROJECT.
trust_project_for_devdoc() {
  local want p d hit="" n=0
  [ -n "${1:-}" ] || return 0
  want="$(realpath -m -- "$1" 2>/dev/null)" || return 0
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    d="$(config_get_project_field "$p" devdoc_dir 2>/dev/null || true)"
    [ -n "$d" ] || continue
    if [ "$(realpath -m -- "$d" 2>/dev/null)" = "$want" ]; then
      hit="$p" n=$((n + 1))
    fi
  done < <(config_list_projects 2>/dev/null || true)
  if [ "$n" -eq 1 ]; then printf '%s\n' "$hit"; fi
  return 0
}

# trust_entry_check_devdoc <caller> <devdoc-dir>: trust_entry_check for an
# entry point that is handed a devdoc dir (capture/file) or an issue dir (the
# checklist-* family passes its parent), not a project. The project lookup
# runs only when a policy exists, so a no-policy run stays [ -e ] / [ -L ].
trust_entry_check_devdoc() {
  local project=""
  trust_locate_host || true   # a defect refuses inside trust_entry_check
  if [ "$TRUST_HOST" = 1 ]; then project="$(trust_project_for_devdoc "${2:-}")"; fi
  trust_entry_check "$1" "$project"
}

# trust_entry_check <caller> <project> [origin|fork]
#
# Call bare, once per entry point. Returns 0 (no policy, out of scope, or
# every check passed); otherwise exits 9 (refuse) or 10 (try_later). Sets
# TRUST_IN_SCOPE (0|1) and, in scope, TRUST_WHOAMI (<backend>:<id>). In
# scope, in order:
#   1. permissions.transition_issue = true (the quarantine and claim writes);
#   2. no bare github OWNER/REPO while GH_HOST is set;
#   3. per in-scope source, whoami: 2|78 unsupported (9), 75 could not run
#      (10), other non-zero failed (9); the account must not be in a trusted
#      set (unless single_identity) and must be in worker_identities. The
#      keyring-principal clause is vacuous until #720 adds the principal;
#   4. every required_hardening member is met.
# A shadowed user policy is never printed here — doctor and pull's run record
# report it.
# shellcheck disable=SC2034  # TRUST_IN_SCOPE is read by permission.sh (#713 task 7)
trust_entry_check() {
  local caller="$1" project="${2:-}" source="${3:-}"
  TRUST_IN_SCOPE=0 TRUST_WHOAMI=""
  trust_locate_host || refuse policy-defect "$TRUST_DIR" "$TRUST_DEFECT"
  [ "$TRUST_HOST" = 1 ] || return 0
  [ -n "$project" ] || refuse scope-unresolved "$caller"
  trust_load
  trust_project_scope "$project" "$source" || return 0
  TRUST_IN_SCOPE=1

  transition_gate_open "$project" || refuse transition-off "$project"

  local i backend repo key
  for i in "${!TRUST_SCOPE_KEYS[@]}"; do
    backend="${TRUST_SCOPE_BACKENDS[$i]}" repo="${TRUST_SCOPE_REPOS[$i]}"
    if [ "$backend" = github ] && [ -n "${GH_HOST:-}" ] && [[ "$repo" =~ ^[^/:@]+/[^/:@]+$ ]]; then
      refuse gh-host-bare "$repo"
    fi
  done

  local target host out rc id set
  for i in "${!TRUST_SCOPE_KEYS[@]}"; do
    backend="${TRUST_SCOPE_BACKENDS[$i]}" repo="${TRUST_SCOPE_REPOS[$i]}" key="${TRUST_SCOPE_KEYS[$i]}"
    target="$repo"
    [ "$backend" = github ] && target="${key#github:}"
    host="${key#*:}" host="${host%%/*}"
    rc=0
    out="$("$(transition_backend_sh "$backend")" whoami "$target")" || rc=$?
    case "$rc" in
      0) ;;
      2|78) refuse whoami-unsupported "$backend" "$rc" ;;
      75) try_later whoami-unavailable "$host" "$rc" ;;
      *) refuse whoami-failed "$target" "$rc" ;;
    esac
    id="${out//$'\r'/}"
    [[ "$id" =~ ^[^[:space:]]+$ ]] || refuse whoami-failed "$target" "$rc"
    id="$backend:$id"
    if [ "${TRUST_VAL[single_identity]:-false}" != true ]; then
      for set in "${_TRUST_TRUSTED_SETS[@]}"; do
        [ -z "${TRUST_ID["$set|$id"]:-}" ] || refuse trusted-worker "$id" "$set"
      done
    fi
    [ -n "${TRUST_ID["worker_identities|$id"]:-}" ] || refuse not-worker "$id"
    TRUST_WHOAMI="$id"
  done

  trust_hardening
  local m
  while IFS= read -r m; do
    [ -n "$m" ] || continue
    if [[ " ${TRUST_HARD_MISSING[*]} " == *" $m "* ]]; then
      refuse hardening-unmet "$m" "${TRUST_HARD_WHY[$m]}"
    fi
  done < <(_trust_list "${TRUST_VAL[required_hardening]:-[]}")
  return 0
}
