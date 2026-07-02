#!/usr/bin/env bash
# scripts/lib/state.sh — read/write ~/.claude/devagent/state/<project>.toml.
# Requires paths.sh and io.sh sourced first.

_state_toml() {
  python3 "$(plugin_root)/scripts/lib/_toml.py" "$@"
}

_state_now() {
  date -Iseconds
}

state_init() {
  local project="$1" f
  [[ -n "$project" ]] || die "state_init: project required"
  f="$(state_path "$project")"
  mkdir -p "$(dirname "$f")"
  chmod 700 "$(dirname "$f")" 2>/dev/null || true
  mkdir -p "$(secrets_dir)"
  chmod 700 "$(secrets_dir)" 2>/dev/null || true
  if [[ ! -f "$f" ]]; then
    install -m 600 /dev/null "$f"
    _state_toml set     "$f" active_issue   '""'
    _state_toml set     "$f" issue_dir      '""'
    _state_toml set     "$f" branch         '""'
    _state_toml set     "$f" baseline_sha   '""'
    _state_toml set     "$f" worktree_path  '""'
    _state_toml set-int "$f" last_step      0
    _state_toml set     "$f" last_step_name '""'
    _state_toml set     "$f" mr_url         '""'
    _state_toml set-int "$f" revision       1
    _state_toml set     "$f" updated_at     '""'
    chmod 600 "$f"
  fi
}

state_exists() {
  local project="$1"
  [[ -f "$(state_path "$project")" ]]
}

state_get() {
  local project="$1" key="$2" out rc
  state_exists "$project" || return 1
  out="$(_state_toml get "$(state_path "$project")" "$key" 2>/dev/null)"; rc=$?
  # #99: _toml get returns 2 when the file is unparseable (vs 1 for a missing
  # key). Surface that loudly instead of letting the old 2>/dev/null masquerade
  # a corrupt state file as "no active issue", which silently bricks the project.
  if [ "$rc" -eq 2 ]; then
    echo "state_get: state file for '$project' is unparseable and needs repair: $(state_path "$project")" >&2
    return 2
  fi
  [ "$rc" -eq 0 ] || return "$rc"
  printf '%s\n' "$out"
}

state_set() {
  local project="$1" key="$2" value="$3"
  state_init "$project"
  local f
  f="$(state_path "$project")"
  # Warn on active_issue clobber: another session may be working a different
  # issue concurrently. Only meaningful for active_issue; other keys
  # (last_step, mr_url) change legitimately on every step.
  if [ "$key" = "active_issue" ] && [ -n "$value" ]; then
    # #96: read the old value from INSIDE the write lock (--print-old) — the
    # previous get-then-set could interleave with another session and miss.
    local old_value
    old_value="$(_state_toml set --print-old "$f" "$key" "$value")"
    if [ -n "$old_value" ] && [ "$old_value" != "$value" ]; then
      echo "warning: state_set: active_issue is changing from '$old_value' to '$value' — another session may be working a different issue concurrently" >&2
    fi
  else
    _state_toml set "$f" "$key" "$value"
  fi
  _state_toml set "$f" updated_at "$(_state_now)"
}

# state_set_many <project> <str|int|bool> <key> <value> [...] — one locked
# transaction for N typed keys + updated_at (#96): multi-key transitions can
# no longer tear across sessions (active_issue from A + issue_dir from B).
# Carries the active_issue clobber-warn (exact predicate: old and new both
# non-empty and different) when the transaction includes that key.
state_set_many() {
  local project="$1"; shift
  state_init "$project"
  local f
  f="$(state_path "$project")"
  # Clobber-warn input: pre-read is advisory only (the WRITE is atomic either
  # way; a racing writer can still change the value between this read and the
  # transaction, but the transaction itself cannot tear).
  local i new_active="" old_active=""
  local -a args=("$@")
  for ((i = 0; i + 2 < ${#args[@]}; i += 3)); do
    if [ "${args[i+1]}" = "active_issue" ]; then new_active="${args[i+2]}"; fi
  done
  if [ -n "$new_active" ]; then
    old_active="$(_state_toml get "$f" active_issue 2>/dev/null || true)"
  fi
  _state_toml set-many "$f" "$@" str updated_at "$(_state_now)"
  if [ -n "$new_active" ] && [ -n "$old_active" ] && [ "$old_active" != "$new_active" ]; then
    echo "warning: state_set: active_issue is changing from '$old_active' to '$new_active' — another session may be working a different issue concurrently" >&2
  fi
}

# state_set_if <project> <key> <expected|--absent> <new> — CAS (#96). Exit 0
# on swap; exit 3 with the actual value on stdout on compare-fail. Callers
# under `set -e` must invoke in a condition. Zero production callers today
# (the #240 consumer); tested + documented for that arrival.
state_set_if() {
  local project="$1" key="$2" expected="$3" new="$4"
  state_init "$project"
  local f rc
  f="$(state_path "$project")"
  _state_toml set-if "$f" "$key" "$expected" "$new" && rc=0 || rc=$?
  if [ "$rc" -eq 0 ]; then
    _state_toml set "$f" updated_at "$(_state_now)"
  fi
  return "$rc"
}

# state_set_int <project> <key> <int> — write an unquoted integer value, placed in
# the top-level table (section-correct, locked) like state_set. Used for the revision
# counter; mirrors state_init's `set-int` so the stored form stays an int (#97).
state_set_int() {
  local project="$1" key="$2" value="$3"
  state_init "$project"
  local f
  f="$(state_path "$project")"
  _state_toml set-int "$f" "$key" "$value"
  _state_toml set "$f" updated_at "$(_state_now)"
}

state_unset() {
  local project="$1" key="$2"
  state_exists "$project" || return 0
  _state_toml unset "$(state_path "$project")" "$key"
}

# Canonical per-issue key set (#98). These travel with an issue across
# park/resume and are cleared on pull/cleanup. Defaults mirror state_init.
STATE_ISSUE_KEYS="branch baseline_sha worktree_path mr_url revision pending_comments_file last_step last_step_name"

# state_context_save <project> <issue> — snapshot current top-level per-issue
# keys into [context.<issue>], replacing any stale snapshot for the same issue
# (a merge would resurrect keys the issue no longer has, e.g. an old mr_url).
# Empty/absent keys are not snapshotted.
state_context_save() {
  local project="$1" issue="$2" f key v
  [[ -n "$issue" ]] || die "state_context_save: issue required"
  state_init "$project"
  f="$(state_path "$project")"
  _state_toml unset "$f" "context.${issue}"
  # #96: gather then write the whole snapshot in ONE transaction — a torn
  # snapshot (half of session A's keys, half of B's) was the #98 failure
  # class. (The unset above remains a separate transaction; see the issue's
  # scoping note — the SET loop is the atomic part.)
  local -a triplets=()
  for key in $STATE_ISSUE_KEYS; do
    v="$(_state_toml get "$f" "$key" 2>/dev/null || true)"
    [[ -n "$v" ]] || continue
    triplets+=(str "context.${issue}.${key}" "$v")
  done
  if [[ ${#triplets[@]} -gt 0 ]]; then
    _state_toml set-many "$f" "${triplets[@]}" str updated_at "$(_state_now)"
  fi
}

# state_context_has <project> <issue> — exit 0 iff a non-empty [context.<issue>]
# snapshot exists. state_context_save only snapshots non-empty keys, so this
# tells a caller whether anything was actually set aside (e.g. so pull.sh can
# notify on a real displacement but stay silent when nothing was in-flight, #247).
state_context_has() {
  local project="$1" issue="$2" f
  [[ -n "$issue" ]] || return 2
  f="$(state_path "$project")"
  _state_toml list-keys "$f" "context.${issue}" >/dev/null 2>&1
}

# state_context_clear <project> — reset per-issue keys to state_init defaults.
state_context_clear() {
  local project="$1" f key
  state_init "$project"
  f="$(state_path "$project")"
  for key in $STATE_ISSUE_KEYS; do
    case "$key" in
      revision)              _state_toml set-int "$f" revision 1 ;;
      last_step)             _state_toml set-int "$f" last_step 0 ;;
      pending_comments_file) _state_toml unset "$f" pending_comments_file ;;
      *)                     _state_toml set "$f" "$key" '""' ;;
    esac
  done
  _state_toml set "$f" updated_at "$(_state_now)"
}

# state_context_restore <project> <issue> — clear to defaults, then restore
# any snapshotted keys from [context.<issue>] and delete the snapshot.
# revision/last_step go back through set-int so the stored form stays an
# unquoted int (#97). Missing snapshot (legacy park) → defaults + warning.
state_context_restore() {
  local project="$1" issue="$2" f key v
  [[ -n "$issue" ]] || die "state_context_restore: issue required"
  state_init "$project"
  f="$(state_path "$project")"
  state_context_clear "$project"
  if ! _state_toml list-keys "$f" "context.${issue}" >/dev/null 2>&1; then
    echo "warning: state_context_restore: no saved context for '$issue' — per-issue keys reset to defaults" >&2
    return 0
  fi
  for key in $STATE_ISSUE_KEYS; do
    v="$(_state_toml get "$f" "context.${issue}.${key}" 2>/dev/null || true)"
    [[ -n "$v" ]] || continue
    case "$key" in
      revision|last_step)
        [[ "$v" =~ ^[0-9]+$ ]] || v=1
        _state_toml set-int "$f" "$key" "$v" ;;
      *)
        _state_toml set "$f" "$key" "$v" ;;
    esac
  done
  _state_toml unset "$f" "context.${issue}"
  _state_toml set "$f" updated_at "$(_state_now)"
}

state_add_parked() {
  local project="$1" issue="$2"
  state_init "$project"
  _state_toml set-bool "$(state_path "$project")" "parked.${issue}" true
}

state_remove_parked() {
  local project="$1" issue="$2"
  state_exists "$project" || return 0
  _state_toml unset "$(state_path "$project")" "parked.${issue}"
}

state_list_parked() {
  local project="$1"
  state_exists "$project" || return 0
  _state_toml list-keys "$(state_path "$project")" parked 2>/dev/null || true
}

state_active_project() {
  local best="" best_ts=""
  local p ts ai
  while IFS= read -r p; do
    [[ -z "$p" ]] && continue
    ai="$(state_get "$p" active_issue 2>/dev/null || true)"
    [[ -z "$ai" ]] && continue
    ts="$(state_get "$p" updated_at 2>/dev/null || true)"
    if [[ -z "$best_ts" || "$ts" > "$best_ts" ]]; then
      best="$p"
      best_ts="$ts"
    fi
  done < <(_state_list_projects)
  [[ -n "$best" ]] || return 1
  echo "$best"
}

_state_list_projects() {
  local dir
  dir="$(devagent_home)/state"
  [[ -d "$dir" ]] || return 0
  ( cd "$dir" && for f in *.toml; do
      [[ -e "$f" ]] || continue
      # #83/B11: only real projects. Skip global pointers (`_active`) and dotted
      # sidecars (`volk.depends`); real project names are simple identifiers.
      # (`*.toml.lock` sidecars never match the `*.toml` glob.)
      case "${f%.toml}" in
        _*|*.*) continue ;;
      esac
      echo "${f%.toml}"
    done )
}

