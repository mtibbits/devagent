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
# plus wbs-update, statusreport and wbs-init; doctor, whose call is
# trust_doctor_block).
# tests/trust-entry.bats holds this list
# equal to the callers in both directions. #720 adds sign. Each call sits at
# column 0, even inside a function body: that census greps for it anchored.
# shellcheck disable=SC2034  # read by tests/trust-entry.bats
TRUST_ENTRY_POINTS=(
  pull next ship cleanup mergetoall mergemr comments capture/file sync
  transition-draft-start park resume switch stuck unstuck revise
  checklist-advance checklist-init checklist-log checklist-mark checklist-stuck
  checklist-unstuck commit branch spike promote-potholes
  migrate-checklist-numbering wbs-update statusreport wbs-init doctor
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
# shellcheck disable=SC2153  # TRUST_DIR is trust_locate's
trust_load() {
  _trust_load_try || refuse policy-defect "$TRUST_DIR/policy.toml" "$TRUST_LOAD_ERR"
}

# _trust_load_try: trust_load without the refusal — 1 with the reason in
# TRUST_LOAD_ERR, for doctor's report. SETTER-GLOBAL — call it bare.
# shellcheck disable=SC2034,SC2153  # setter-globals; TRUST_DIR is trust_locate's
_trust_load_try() {
  local out rc=0 err line kind name value forbid=()
  TRUST_LOAD_ERR=""
  mapfile -t forbid < <(_trust_forbid_roots)
  err="$(mktemp)"
  out="$(_trust_py load "$TRUST_DIR" "${forbid[@]}" 2>"$err")" || rc=$?
  if [ "$rc" -ne 0 ]; then
    TRUST_LOAD_ERR="$(head -n 1 "$err" | tr -d '\r')"
    TRUST_LOAD_ERR="${TRUST_LOAD_ERR:-trust_policy.py exited $rc}"
    rm -f "$err"
    return 1
  fi
  rm -f "$err"
  if [[ "$out" == *$'\r'* ]]; then TRUST_LOAD_ERR="a carriage return in the loader's output"; return 1; fi
  unset TRUST_ID TRUST_VAL
  declare -gA TRUST_ID=() TRUST_VAL=()
  TRUST_SCOPES=() TRUST_DIGEST="" TRUST_FILE=""
  while IFS= read -r line; do
    IFS=$'\t' read -r kind name value <<<"$line"
    if [[ "$_TRUST_KINDS" != *" $kind "* ]] || [ -z "$name" ] || [ -z "$value" ]; then
      TRUST_LOAD_ERR="a malformed loader line '$line'"
      return 1
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
    TRUST_LOAD_ERR="the loader printed no digest or no scope"
    return 1
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

# trust_key <backend> <repo> [<num>]: the canonical repo key, or issue key
# with <num>, the host taken from the policy's trackers.
trust_key() {
  local h
  h="$(_trust_tracker_host "$1")"
  _trust_py key "$1" "$2" ${3:+"$3"} ${h:+--host "$h"}
}

# _trust_in_scopes <key>: 0 iff <key> is one of TRUST_SCOPES (keys hold no
# space).
_trust_in_scopes() { [[ " ${TRUST_SCOPES[*]} " == *" $1 "* ]]; }

# _trust_candidate_keys <backend> <repo>: every repo key the source's calls can
# reach, one per line; non-zero when it cannot be keyed. A bare github
# OWNER/REPO is keyed on github.com, $GH_HOST and trackers.github.host: the
# backend sends a bare repo's calls by GH_HOST, so a key on the pin alone could
# put a project out of scope while its calls reach a scoped host.
_trust_candidate_keys() {
  local backend="$1" repo="$2" h
  if [ "$backend" = github ] && [[ "$repo" =~ ^[^/:@]+/[^/:@]+$ ]]; then
    _trust_py key github "$repo" --host github.com || return 1
    if [ -n "${GH_HOST:-}" ]; then _trust_py key github "$repo" --host "$GH_HOST" || return 1; fi
    h="$(_trust_tracker_host github)"
    if [ -n "$h" ]; then _trust_py key github "$repo" --host "$h" || return 1; fi
    return 0
  fi
  trust_key "$backend" "$repo"
}

# trust_project_scope <project> [origin|fork]: 0 iff an issue_source or
# issue_source_fork repo key equals a scope. SETTER-GLOBAL: TRUST_SCOPE_KEYS[]
# and, parallel to it, TRUST_SCOPE_BACKENDS[] / TRUST_SCOPE_REPOS[] — the
# in-scope sources to check, narrowed to <source> when it is in scope.
trust_project_scope() {
  local project="$1" only="${2:-}" section which backend repo key cands
  TRUST_SCOPE_KEYS=() TRUST_SCOPE_BACKENDS=() TRUST_SCOPE_REPOS=()
  local keys=() backends=() repos=() whichs=()
  for which in origin fork; do
    section=issue_source
    [ "$which" = fork ] && section=issue_source_fork
    backend="$(config_get_project_field "$project" "$section.backend" 2>/dev/null || true)"
    repo="$(config_get_project_field "$project" "$section.repo" 2>/dev/null || true)"
    backend="${backend//$'\r'/}" repo="${repo//$'\r'/}"
    if [ -z "$backend" ] || [ -z "$repo" ]; then continue; fi
    # A config edit must not turn trust off (spec §3.8): the backend name is
    # case-folded (a case-insensitive filesystem runs GitHub.sh as github.sh),
    # a built-in source that cannot be keyed refuses, and a non-built-in
    # backend whose repo keys onto a scope refuses rather than reading as
    # out of scope.
    backend="${backend,,}"
    case "$backend" in
      github|gitlab|jira)
        # no jira scope exists without trackers.jira.base_url (the loader
        # refuses one), so an unkeyable jira source is out of scope.
        if [ "$backend" = jira ] && [ -z "$(_trust_tracker_host jira)" ]; then continue; fi
        cands="$(_trust_candidate_keys "$backend" "$repo" 2>/dev/null)" \
          || refuse scope-unkeyable "$backend" "$repo" "$project" "not a $backend repo"
        ;;
      *)
        cands="$( { _trust_candidate_keys github "$repo"; trust_key gitlab "$repo"; } 2>/dev/null || true)"
        for key in $cands; do
          if _trust_in_scopes "$key"; then
            refuse scope-unkeyable "$backend" "$repo" "$project" "not a built-in backend, yet its repo matches scope $key"
          fi
        done
        continue ;;
    esac
    for key in $cands; do
      if _trust_in_scopes "$key"; then
        keys+=("$key") backends+=("$backend") repos+=("$repo") whichs+=("$which")
        break
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

# Why each hardening reads as not met, for hardening-unmet.
declare -gA TRUST_HARD_WHY=(
  [separate_identity]="single_identity = true, or no identity check passed"
  [signatures]="no signature is verified until #720"
  [system_policy]="unverified: not met until #902 verifies the system location"
)

# trust_hardening: SETTER-GLOBAL TRUST_HARD_MET[] / TRUST_HARD_MISSING[], in
# the order separate_identity, signatures, system_policy. separate_identity is
# met iff single_identity = false and the identity check passed (TRUST_WHOAMI
# set).
trust_hardening() {
  TRUST_HARD_MET=() TRUST_HARD_MISSING=()
  if [ "${TRUST_VAL[single_identity]:-false}" != true ] && [ -n "${TRUST_WHOAMI:-}" ]; then
    TRUST_HARD_MET+=(separate_identity)
  else
    TRUST_HARD_MISSING+=(separate_identity)
  fi
  if _trust_signatures_met; then TRUST_HARD_MET+=(signatures); else TRUST_HARD_MISSING+=(signatures); fi
  if _trust_system_policy_met; then TRUST_HARD_MET+=(system_policy); else TRUST_HARD_MISSING+=(system_policy); fi
}

# _trust_first_unmet: the first required_hardening member trust_hardening left
# missing, or nothing.
_trust_first_unmet() {
  local m
  while IFS= read -r m; do
    [ -n "$m" ] || continue
    if [[ " ${TRUST_HARD_MISSING[*]} " == *" $m "* ]]; then printf '%s' "$m"; return 0; fi
  done < <(_trust_list "${TRUST_VAL[required_hardening]:-[]}")
}

# _trust_whoami_verdict <backend> <rc> <out> <target> <host>: the identity
# verdict on one whoami answer. SETTER-GLOBAL TRUST_VERDICT_ID (<backend>:<id>,
# or ? when whoami gave none) and TRUST_VERDICT[] — the refuse/try_later argv,
# empty when the account passes. Clauses in order: whoami 2|78 unsupported,
# 75 could not run, other non-zero or a non-id answer failed; then the
# account must not be in a trusted set (unless single_identity) and must be
# in worker_identities.
_trust_whoami_verdict() {
  local backend="$1" rc="$2" id="${3//$'\r'/}" target="$4" host="$5" set
  TRUST_VERDICT=() TRUST_VERDICT_ID="?"
  case "$rc" in
    0) [[ "$id" =~ ^[^[:space:]]+$ ]] || { TRUST_VERDICT=(refuse whoami-failed "$target" "$rc"); return 0; } ;;
    2|78) TRUST_VERDICT=(refuse whoami-unsupported "$backend" "$rc"); return 0 ;;
    75) TRUST_VERDICT=(try_later whoami-unavailable "$host" "$rc"); return 0 ;;
    *) TRUST_VERDICT=(refuse whoami-failed "$target" "$rc"); return 0 ;;
  esac
  id="$backend:$id"
  TRUST_VERDICT_ID="$id"
  if [ "${TRUST_VAL[single_identity]:-false}" != true ]; then
    for set in "${_TRUST_TRUSTED_SETS[@]}"; do
      if [ -n "${TRUST_ID["$set|$id"]:-}" ]; then TRUST_VERDICT=(refuse trusted-worker "$id" "$set"); return 0; fi
    done
  fi
  [ -n "${TRUST_ID["worker_identities|$id"]:-}" ] || TRUST_VERDICT=(refuse not-worker "$id")
}

# _trust_hard_list <name>…: a comma list for humans, system_policy marked.
_trust_hard_list() {
  local out="" n
  for n in "$@"; do
    [ "$n" = system_policy ] && n="system_policy (unverified)"
    out+="${out:+, }$n"
  done
  printf '%s' "${out:-none}"
}

# trust_run_record <backend> <repo> <num>: pull's run-record line (after
# trust_entry_check and trust_hardening): the digest, the issue key, the
# hardenings met and missing, and a shadowed user policy.
trust_run_record() {
  local key met missing
  key="$(trust_key "$1" "$2" "$3" 2>/dev/null || echo "?")"
  met="$(IFS=,; echo "${TRUST_HARD_MET[*]}")"
  missing="$(IFS=,; echo "${TRUST_HARD_MISSING[*]}")"
  missing="${missing/system_policy/system_policy(unverified)}"
  printf 'trust: policy %s key %s hardening met=%s missing=%s%s\n' "$TRUST_DIGEST" "$key" \
    "${met:-none}" "${missing:-none}" "${TRUST_USER_IGNORED:+ user-ignored=$TRUST_USER_IGNORED}"
}

# trust_report: doctor's trust block, one `<ok|warn|fail>\t<label>\t<detail>`
# line per finding. Call bare, only when trust_locate_host found a policy; it
# never exits. SETTER-GLOBAL TRUST_REPORT_RC (0, 9 or 10) and
# TRUST_REPORT_REFUSAL (the refuse/try_later call doctor makes after printing
# the block). Unlike an entry point it checks every scope (whoami per scope
# repo) and asks `gh auth status` per GitHub host — doctor only, never on the
# entry-point path.
# shellcheck disable=SC2034  # TRUST_REPORT_REFUSAL is run by doctor.sh
trust_report() {
  TRUST_REPORT_RC=0 TRUST_REPORT_REFUSAL=() TRUST_WHOAMI=""
  local d
  for d in "${TRUST_EMPTY_DIRS[@]}"; do printf 'warn\ttrust location\tempty %s\n' "$d"; done
  if [ -n "$TRUST_DEFECT" ]; then
    printf 'fail\ttrust policy\t%s\n' "$TRUST_DEFECT"
    TRUST_REPORT_RC=9 TRUST_REPORT_REFUSAL=(refuse policy-defect "$TRUST_DIR" "$TRUST_DEFECT")
    return 0
  fi
  [ -z "$TRUST_USER_IGNORED" ] || printf 'warn\ttrust location\t%s\n' "$(_trust_detail user-ignored "$TRUST_USER_IGNORED")"
  if ! _trust_load_try; then
    printf 'fail\ttrust policy\t%s\n' "$TRUST_LOAD_ERR"
    TRUST_REPORT_RC=9 TRUST_REPORT_REFUSAL=(refuse policy-defect "$TRUST_DIR/policy.toml" "$TRUST_LOAD_ERR")
    return 0
  fi
  local rc
  printf 'ok\ttrust policy\t%s %s %s\n' "$TRUST_SOURCE" "$TRUST_FILE" "$TRUST_DIGEST"

  local key backend target host out hosts=()
  for key in "${TRUST_SCOPES[@]}"; do
    backend="${key%%:*}" target="${key#*:}" host="${target%%/*}"
    [ "$backend" = github ] && [[ " ${hosts[*]} " != *" $host "* ]] && hosts+=("$host")
    rc=0
    out="$("$(transition_backend_sh "$backend")" whoami "$target" 2>/dev/null)" || rc=$?
    _trust_whoami_verdict "$backend" "$rc" "$out" "$target" "$host"
    if [ "${#TRUST_VERDICT[@]}" -eq 0 ]; then
      TRUST_WHOAMI="$TRUST_VERDICT_ID"
      printf 'ok\ttrust whoami %s on %s\tin worker_identities; single_identity=%s\n' "$TRUST_VERDICT_ID" "$key" "${TRUST_VAL[single_identity]:-false}"
    else
      printf 'fail\ttrust whoami %s on %s\t%s\n' "$TRUST_VERDICT_ID" "$key" "$(_trust_detail "${TRUST_VERDICT[@]:1}")"
      if [ "$TRUST_REPORT_RC" -eq 0 ]; then
        TRUST_REPORT_REFUSAL=("${TRUST_VERDICT[@]}")
        TRUST_REPORT_RC=9
        [ "${TRUST_VERDICT[0]}" = try_later ] && TRUST_REPORT_RC=10
      fi
    fi
  done
  # a failed identity check means separate_identity is not met.
  [ "$TRUST_REPORT_RC" -eq 0 ] || TRUST_WHOAMI=""

  trust_hardening
  local unmet
  unmet="$(_trust_first_unmet)"
  if [ -n "$unmet" ]; then
    printf 'fail\ttrust hardening\t%s\n' "$(_trust_detail hardening-unmet "$unmet" "${TRUST_HARD_WHY[$unmet]}")"
    if [ "$TRUST_REPORT_RC" -eq 0 ]; then
      TRUST_REPORT_RC=9 TRUST_REPORT_REFUSAL=(refuse hardening-unmet "$unmet" "${TRUST_HARD_WHY[$unmet]}")
    fi
  elif [ "${#TRUST_HARD_MISSING[@]}" -gt 0 ]; then
    printf 'warn\ttrust hardening\tmet: %s; not met: %s\n' \
      "$(_trust_hard_list "${TRUST_HARD_MET[@]}")" "$(_trust_hard_list "${TRUST_HARD_MISSING[@]}")"
  else
    printf 'ok\ttrust hardening\tmet: %s\n' "$(_trust_hard_list "${TRUST_HARD_MET[@]}")"
  fi

  local v
  for v in GH_TOKEN GITHUB_TOKEN; do
    [ -z "${!v:-}" ] || printf 'warn\ttrust credentials\t%s is set: gh uses it ahead of the keyring account whoami checks\n' "$v"
  done
  local n
  for host in "${hosts[@]}"; do
    n="$(gh auth status --hostname "$host" 2>&1 | grep -c 'Logged in to' || true)"
    [ "${n:-0}" -le 1 ] || printf 'warn\ttrust gh accounts\t%s accounts on %s: gh may switch the active one\n' "$n" "$host"
  done
  if [ -n "${GH_HOST:-}" ] && [ "$GH_HOST" != github.com ]; then
    printf 'warn\ttrust host\tGH_HOST=%s (not github.com)\n' "$GH_HOST"
  fi
  if [ -n "${GITLAB_HOST:-}" ] && [ "$GITLAB_HOST" != gitlab.com ]; then
    printf 'warn\ttrust host\tGITLAB_HOST=%s (not gitlab.com)\n' "$GITLAB_HOST"
  fi
  return 0
}

# trust_project_for_devdoc <dir>: the one config project whose devdoc_dir is
# <dir> by file identity (-ef, as active_context_project: spelling and case
# differences still match); empty for none or several, which
# trust_entry_check reads as scope-unresolved. Never reads an ambient
# DEVAGENT_PROJECT.
trust_project_for_devdoc() {
  local p d hit="" n=0
  [ -n "${1:-}" ] || return 0
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    d="$(config_get_project_field "$p" devdoc_dir 2>/dev/null || true)"
    [ -n "$d" ] || continue
    if [ "$d" -ef "$1" ]; then
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
  TRUST_IN_SCOPE=0 TRUST_WHOAMI="" TRUST_PROJECT="$project"
  trust_locate_host || refuse policy-defect "$TRUST_DIR" "$TRUST_DEFECT"
  [ "$TRUST_HOST" = 1 ] || return 0
  trust_load
  [ -n "$project" ] || refuse scope-unresolved "$caller"
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

  local target host out rc
  for i in "${!TRUST_SCOPE_KEYS[@]}"; do
    backend="${TRUST_SCOPE_BACKENDS[$i]}" repo="${TRUST_SCOPE_REPOS[$i]}" key="${TRUST_SCOPE_KEYS[$i]}"
    target="$repo"
    [ "$backend" = github ] && target="${key#github:}"
    host="${key#*:}" host="${host%%/*}"
    rc=0
    out="$("$(transition_backend_sh "$backend")" whoami "$target")" || rc=$?
    _trust_whoami_verdict "$backend" "$rc" "$out" "$target" "$host"
    [ "${#TRUST_VERDICT[@]}" -eq 0 ] || "${TRUST_VERDICT[@]}"
    TRUST_WHOAMI="$TRUST_VERDICT_ID"
  done

  trust_hardening
  local m
  m="$(_trust_first_unmet)"
  [ -z "$m" ] || refuse hardening-unmet "$m" "${TRUST_HARD_WHY[$m]}"
  return 0
}
