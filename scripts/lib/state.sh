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
    # #96: old value read from INSIDE the write lock (set-many --print-old) —
    # a get-then-set could interleave with another session and miss the clobber.
    local old_value
    old_value="$(_state_toml set-many --print-old "$key" "$f" str "$key" "$value" str updated_at "$(_state_now)")"
    _state_warn_active_clobber "$old_value" "$value"
  else
    # Single transaction: value + timestamp atomic, one spawn (was two).
    _state_toml set-many "$f" str "$key" "$value" str updated_at "$(_state_now)"
  fi
}

# _state_warn_active_clobber <old> <new> — the advisory concurrency warning
# (#96: one predicate + message shared by state_set and state_set_many;
# fires only when old and new are both non-empty and different).
_state_warn_active_clobber() {
  local old="$1" new="$2"
  if [ -n "$old" ] && [ -n "$new" ] && [ "$old" != "$new" ]; then
    echo "warning: state_set: active_issue is changing from '$old' to '$new' — another session may be working a different issue concurrently" >&2
  fi
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
  # #96 (quality F10): when the transaction includes active_issue, the old
  # value is emitted from INSIDE the same lock (set-many --print-old) — the
  # clobber-warn cannot interleave-miss on the path that owns all production
  # active_issue writes.
  local i new_active=""
  local -a args=("$@")
  for ((i = 0; i + 2 < ${#args[@]}; i += 3)); do
    if [ "${args[i+1]}" = "active_issue" ]; then new_active="${args[i+2]}"; fi
  done
  if [ -n "$new_active" ]; then
    local old_active
    old_active="$(_state_toml set-many --print-old active_issue "$f" "$@" str updated_at "$(_state_now)")"
    _state_warn_active_clobber "$old_active" "$new_active"
  else
    _state_toml set-many "$f" "$@" str updated_at "$(_state_now)"
  fi
}

# state_set_int <project> <key> <int> — write an unquoted integer value in one
# locked transaction, folding the updated_at bump in (#330: was two _toml calls,
# so a reader could see the new int with a stale timestamp). set-many takes typed
# <str|int|bool> triplets. NB: currently uncalled — the revision counter uses
# state_ctx_set_many (revise.sh) — kept as a correct primitive for future use.
state_set_int() {
  local project="$1" key="$2" value="$3"
  state_init "$project"
  local f
  f="$(state_path "$project")"
  _state_toml set-many "$f" int "$key" "$value" str updated_at "$(_state_now)"
}

# state_unset <project> <key> — delete a key and bump updated_at in ONE locked
# transaction (#330: previously never bumped updated_at, so live callers —
# park/resume/cleanup/pull — left a mutated state with a stale timestamp). The
# #327 transact verb composes the unset + set in one _locked_rmw + atomic replace.
state_unset() {
  local project="$1" key="$2"
  state_exists "$project" || return 0
  _state_toml transact "$(state_path "$project")" \
    --set str updated_at "$(_state_now)" \
    --unset "$key"
}

# Canonical per-issue key set (#98). These travel with an issue across
# park/resume and are cleared on pull/cleanup. Defaults mirror state_init.
STATE_ISSUE_KEYS="branch baseline_sha worktree_path mr_url revision pending_comments_file last_step last_step_name"

# state_context_save <project> <issue> — snapshot current top-level per-issue
# keys into [context.<issue>], replacing any stale snapshot for the same issue
# (a merge would resurrect keys the issue no longer has, e.g. an old mr_url).
# Empty/absent keys are not snapshotted.
state_context_save() {
  local project="$1" issue="$2" f
  [[ -n "$issue" ]] || die "state_context_save: issue required"
  state_init "$project"
  f="$(state_path "$project")"
  # #327: ONE locked transaction — the stale-table replace AND the gather now
  # happen inside the same lock (transact --snapshot), so the #98 torn-gather
  # class and the old crash-after-unset hazard (a crash between the unset and
  # the set-many destroyed the only snapshot) are both structurally gone.
  # Empty/absent keys are skipped in-verb (the old [[ -n "$v" ]]); int values
  # keep their type (the old path stringified them; restore coerces both).
  # shellcheck disable=SC2086  # STATE_ISSUE_KEYS is a deliberate word list
  _state_toml transact "$f" --snapshot "context.${issue}" $STATE_ISSUE_KEYS \
      --set str updated_at "$(_state_now)"
}

# ---- #240: issue-keyed live state -------------------------------------------
# [context.<issue>] is the AUTHORITATIVE home of an issue's STATE_ISSUE_KEYS;
# the top-level copies are a compatibility MIRROR maintained only while that
# issue is the shared active_issue. Per-key truth table for reads:
#   table hit                        → table value (always wins)
#   table miss + issue == active     → top-level value (adopt-on-first-write
#                                      migration for pre-#240 state)
#   table miss + issue != active     → per-key state_init default
# The mirror predicate is evaluated INSIDE the write lock (set-many-if, #240)
# — a read-then-write pair would let a concurrent pull flip active_issue in
# between and launder one issue's keys into another via the fallback.

# _state_issue_default <key> — the state_init default for a per-issue key.
_state_issue_default() {
  case "$1" in
    revision)  printf '1\n' ;;
    last_step) printf '0\n' ;;
    *)         printf '\n' ;;
  esac
}

# _state_issue_id_ok <issue> — defensive shape check (dots nest TOML tables;
# '#'/']' corrupt or brick the file). The env resolver validates too
# (active_resolve_issue_src); this guards direct callers.
_state_issue_id_ok() {
  case "$1" in
    ''|*[!A-Za-z0-9_-]*) return 1 ;;
    *) return 0 ;;
  esac
}

# state_issue_get <project> <issue> <key>
state_issue_get() {
  local project="$1" issue="$2" key="$3" f out rc
  [[ -n "$issue" && -n "$key" ]] || { echo "state_issue_get: issue and key required" >&2; return 2; }
  _state_issue_id_ok "$issue" || die "state_issue_get: invalid issue id '$issue'"
  state_exists "$project" || { _state_issue_default "$key"; return 0; }
  f="$(state_path "$project")"
  out="$(_state_toml get "$f" "context.${issue}.${key}" 2>/dev/null)"; rc=$?
  if [ "$rc" -eq 2 ]; then
    echo "state_issue_get: state file for '$project' is unparseable and needs repair: $f" >&2
    return 2
  fi
  # rc 0 = table HIT, even for an empty value (the truth table's "table hit
  # wins"); only rc 1 (key absent) falls through to fallback/defaults.
  if [ "$rc" -eq 0 ]; then printf '%s\n' "$out"; return 0; fi
  local active
  active="$(state_get "$project" active_issue 2>/dev/null || true)"
  if [ "$active" = "$issue" ]; then
    out="$(state_get "$project" "$key" 2>/dev/null || true)"
    if [ -n "$out" ]; then printf '%s\n' "$out"; return 0; fi
  fi
  _state_issue_default "$key"
}

# state_issue_set_many <project> <issue> <type key value>...
# One locked transaction: table triplets always; top-level mirror triplets
# iff <issue> is the active_issue AT WRITE TIME (predicate inside the lock).
# NB: values may not be the literal strings "--then"/"--also" (set-many-if's
# reserved bucket tokens — rejected loudly, never silently corrupted).
state_issue_set_many() {
  local project="$1" issue="$2"; shift 2
  [[ $# -gt 0 && $(( $# % 3 )) -eq 0 ]] || die "state_issue_set_many: <type key value> triplets required"
  _state_issue_id_ok "$issue" || die "state_issue_set_many: invalid issue id '$issue'"
  state_init "$project"
  local f; f="$(state_path "$project")"
  local -a table=() mirror=()
  local typ key val
  while [ $# -gt 0 ]; do
    typ="$1"; key="$2"; val="$3"; shift 3
    table+=("$typ" "context.${issue}.${key}" "$val")
    mirror+=("$typ" "$key" "$val")
  done
  _state_toml set-many-if "$f" active_issue "$issue" \
      --then "${mirror[@]}" \
      --also "${table[@]}" str updated_at "$(_state_now)" \
    || die "state_issue_set_many: write failed for '$project'"
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
  local project="$1" f
  state_init "$project"
  f="$(state_path "$project")"
  # #327: ONE transaction (was ~8 — mid-sequence readers saw half-cleared
  # state). The defaults are _STATE_RESTORE_SPECS (single source of truth —
  # review MINOR: literal copies would drift when STATE_ISSUE_KEYS grows);
  # the fixed set→unset order inside transact makes pending_comments_file's
  # "" land and then be deleted — its default is a REAL unset (absent form).
  _state_toml transact "$f" \
      --set "${_STATE_RESTORE_SPECS[@]}" str updated_at "$(_state_now)" \
      --unset pending_comments_file
}

# state_cleanup_finish <project> — #418: cleanup's shared-slot finish as ONE
# transaction: reset the per-issue keys to defaults, STAMP the closeout
# (last_step=20 / last_step_name=cleanup), and clear the active_issue pointer.
# Was state_context_clear + a separate state_set_many — a crash between them left
# active_issue=<old> over default branch="" (the #316/#327 corruption shape the
# #326 epic hardened against). last_step/last_step_name appear twice in the --set
# group (the _STATE_RESTORE_SPECS defaults, then the cleanup override); transact
# applies --set in order and last-wins, so 20/cleanup land — identical final
# state to the old two-call sequence, minus the crash window.
state_cleanup_finish() {
  local project="$1" f
  state_init "$project"
  f="$(state_path "$project")"
  _state_toml transact "$f" \
      --set "${_STATE_RESTORE_SPECS[@]}" \
            str last_step "20" str last_step_name "cleanup" \
            str active_issue "" str updated_at "$(_state_now)" \
      --unset pending_comments_file
}

# _STATE_RESTORE_SPECS — the shared <type key default> triplet list (typed
# defaults mirror state_init; #327). SINGLE SOURCE OF TRUTH for the per-issue
# defaults: --restore specs in restore/resume AND the --set defaults in
# clear/pull_promote all use it — keep in lockstep with STATE_ISSUE_KEYS
# (a key added there but not here would be snapshotted yet never reset — a
# cross-issue value leak; review MINOR). pending_comments_file's default
# lands as "" on the RESTORE paths (restore can't conditionally unset);
# consumers treat "" ≡ absent (verified #317); the clear/displace paths
# re-delete it via --unset in the same transaction.
_STATE_RESTORE_SPECS=(str branch '""' str baseline_sha '""'
                      str worktree_path '""' str mr_url '""'
                      int revision 1 int last_step 0
                      str last_step_name '""' str pending_comments_file '""')

# state_context_restore <project> <issue> — restore the snapshotted keys from
# [context.<issue>] (defaults for missing keys), delete the snapshot — ONE
# locked transaction (#327: was clear+per-key sets+unset, ~12; the in-lock
# table→top-level copy replaces the lock-free gather). Ints stay unquoted
# (#97; digit-string legacy snapshots are coerced in-verb). Missing snapshot
# (legacy park) → defaults + warning (advisory, lock-free — the transaction
# is uniform either way). The plain non-promoting form; resume's
# state_resume_promote_restore rides the same verb with its promote triplets.
state_context_restore() {
  local project="$1" issue="$2" f
  [[ -n "$issue" ]] || die "state_context_restore: issue required"
  state_init "$project"
  f="$(state_path "$project")"
  if ! state_context_has "$project" "$issue"; then
    echo "warning: state_context_restore: no saved context for '$issue' — per-issue keys reset to defaults" >&2
  fi
  _state_toml transact "$f" \
      --restore "context.${issue}" "${_STATE_RESTORE_SPECS[@]}" \
      --set str updated_at "$(_state_now)" \
      --unset "context.${issue}"
}

# state_resume_promote_restore <project> <issue> <issue_dir> — #317: resume's
# promote (active_issue/issue_dir) and per-issue restore land in ONE locked
# transaction, closing the promote-before-restore window (active_issue = NEW
# paired with the OLD issue's top-level keys; the table-miss fallback
# laundered them for concurrent readers, a crash persisted them).
# #327 re-home: the gather now happens IN-LOCK (transact --restore) and the
# snapshot delete rides the SAME transaction — #317's lock-free-gather and
# benign-second-write caveats are retired. Clobber-warn preserved in-lock via
# --print-old (#96).
state_resume_promote_restore() {
  local project="$1" issue="$2" issue_dir="$3" f old_active
  [[ -n "$issue" && -n "$issue_dir" ]] || die "state_resume_promote_restore: issue and issue_dir required"
  _state_issue_id_ok "$issue" || die "state_resume_promote_restore: invalid issue id '$issue'"
  state_init "$project"
  f="$(state_path "$project")"
  if ! state_context_has "$project" "$issue"; then
    echo "warning: resume: no saved context for '$issue' — per-issue keys reset to defaults" >&2
  fi
  # #415: also clear the displacement marker in-lock — the issue is becoming
  # active, so it is neither parked nor displaced. Folded into THIS transact so
  # resume stays within the #317 ≤2-mutation cap (no extra call).
  old_active="$(_state_toml transact "$f" --print-old active_issue \
      --restore "context.${issue}" "${_STATE_RESTORE_SPECS[@]}" \
      --set str active_issue "$issue" str issue_dir "$issue_dir" \
            str updated_at "$(_state_now)" \
      --unset "context.${issue}" "displaced.${issue}")"
  _state_warn_active_clobber "$old_active" "$issue"
}

# state_pull_promote <project> <issue> <issue_dir> [prev_issue] — #327: pull's
# displacement as ONE locked transaction: snapshot the displaced issue's keys
# (when prev given), reset the per-issue keys to defaults, and promote
# active_issue/issue_dir — was save→clear→set_many (3 compound calls, ~12
# locks), whose mid-sequence crash left active_issue=prev over defaults (the
# #316 branch="" shape). Now a crash lands old-complete or new-complete,
# nothing between. Clobber-warn preserved in-lock via --print-old. NOT for
# re-pull of the live issue (never clear live context) — pull.sh keeps that
# branch on plain state_set_many.
state_pull_promote() {
  local project="$1" issue="$2" issue_dir="$3" prev="${4:-}" f old_active
  [[ -n "$issue" && -n "$issue_dir" ]] || die "state_pull_promote: issue and issue_dir required"
  _state_issue_id_ok "$issue" || die "state_pull_promote: invalid issue id '$issue'"
  state_init "$project"
  f="$(state_path "$project")"
  local -a snap=()
  if [[ -n "$prev" ]]; then
    _state_issue_id_ok "$prev" || die "state_pull_promote: invalid issue id '$prev'"
    # shellcheck disable=SC2206  # STATE_ISSUE_KEYS is a deliberate word list
    snap=(--snapshot "context.${prev}" $STATE_ISSUE_KEYS)
  fi
  # Defaults from _STATE_RESTORE_SPECS (lockstep source of truth); the
  # set→unset order deletes the pending_comments_file "" again (absent form).
  old_active="$(_state_toml transact "$f" --print-old active_issue \
      "${snap[@]}" \
      --set "${_STATE_RESTORE_SPECS[@]}" \
            str active_issue "$issue" str issue_dir "$issue_dir" \
            str updated_at "$(_state_now)" \
      --unset pending_comments_file)"
  _state_warn_active_clobber "$old_active" "$issue"
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

# #415: the [displaced] table marks a park that pull/resume created by DISPLACING
# an in-flight issue (as opposed to a deliberate /devagent:park). Both are parked
# (so resume/switch find them), but they diverge on re-pull: an operator-park is
# GC'd (fresh start, #98 MAJ-1), a displacement-park is RESTORED (bring the work
# back). The marker is the only thing that tells the two apart.
state_add_displaced() {
  local project="$1" issue="$2"
  state_init "$project"
  _state_toml set-bool "$(state_path "$project")" "displaced.${issue}" true
}

state_remove_displaced() {
  local project="$1" issue="$2"
  state_exists "$project" || return 0
  _state_toml unset "$(state_path "$project")" "displaced.${issue}"
}

# Returns 0 iff issue carries the displacement-park marker.
state_is_displaced() {
  local project="$1" issue="$2"
  state_exists "$project" || return 1
  _state_toml get "$(state_path "$project")" "displaced.${issue}" >/dev/null 2>&1
}

# (#330: state_active_project deleted — zero production callers; project
# resolution is active.sh's job now. _state_list_projects stays: live via sync.)

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

