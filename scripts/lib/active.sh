#!/usr/bin/env bash
# scripts/lib/active.sh — context resolution: which project + which issue?
#
# Resolution priority (project):
#   1. positional arg
#   2. DEVAGENT_ACTIVE_PROJECT env var
#   3. global pointer at $(devagent_home)/state/_active.toml
#   4. config_active_project (single-project shortcut; dies with a
#      helpful message when 0 or 2+ projects are configured)
#
# Resolution priority (issue, given a project):
#   1. positional arg
#   2. DEVAGENT_ACTIVE_ISSUE env var
#   3. per-project state file's `active_issue`
#   4. scan <devdoc>/Issue-*/checklist.md for the most-recently-modified
#      checklist that still has at least one incomplete box
#
# Requires: paths.sh, io.sh, config.sh, state.sh sourced first.

active_pointer_path() {
  echo "$(devagent_home)/state/_active.toml"
}

# active_set_project <project>
# Writes the global active-project pointer (mode 600).
active_set_project() {
  local project="$1"
  [ -n "$project" ] || { echo "active_set_project: project required" >&2; return 2; }
  local f
  f="$(active_pointer_path)"
  mkdir -p "$(dirname "$f")"
  # _toml.py mutates in place and requires the file to exist (like state_init's
  # first write) — create an empty 0600 file only when absent. `-f` guard keeps
  # this from truncating an existing pointer (install copies /dev/null).
  [ -f "$f" ] || install -m 600 /dev/null "$f"
  # #328: atomic write — route through _toml.py set-many, which takes the sibling
  # .lock for the whole RMW and writes via tmp + same-dir atomic rename with mode
  # 0600 on create. The prior truncating `printf >` (no lock, O_TRUNC window,
  # post-hoc chmod) let a concurrent reader see an empty/partial pointer → false
  # fallback → config_active_project die with 2+ projects. Safe: _state_list_projects
  # skips _* files (state.sh), and active_get_project's awk parses the same
  # `key = "value"` output. Requires state.sh sourced first (this file's header
  # contract; next.sh, the sole production caller, complies).
  _state_toml set-many "$f" \
    str active_project "$project" \
    str last_active_at "$(date -Iseconds)"
}

# active_get_project
# Prints the global active-project pointer, or empty + exit 1 if absent.
active_get_project() {
  local f
  f="$(active_pointer_path)"
  [ -f "$f" ] || return 1
  awk -F' *= *' '$1=="active_project" { gsub(/"/, "", $2); print $2; exit }' "$f"
}

# active_resolve_project_src [arg]
# Resolution engine (#282). Sets, in the CALLING shell (no stdout — callers
# must NOT command-substitute this, or the variables die in the subshell):
#   ACTIVE_RESOLVED_PROJECT  the resolved project name
#   ACTIVE_RESOLVED_FROM     arg | env | pointer | fallback
# Writers gate the pointer write on the source so an arg/env-pinned session
# never clobbers the pointer another session relies on. NB: `fallback` also
# fires when the pointer names a project failing config_is_project — with
# 2+ projects config_active_project then dies, so no write happens there.
active_resolve_project_src() {
  local arg="${1:-}"
  ACTIVE_RESOLVED_PROJECT=""
  ACTIVE_RESOLVED_FROM=""
  if [ -n "$arg" ]; then
    ACTIVE_RESOLVED_FROM="arg"; ACTIVE_RESOLVED_PROJECT="$arg"; return 0
  fi
  if [ -n "${DEVAGENT_ACTIVE_PROJECT:-}" ]; then
    ACTIVE_RESOLVED_FROM="env"; ACTIVE_RESOLVED_PROJECT="$DEVAGENT_ACTIVE_PROJECT"; return 0
  fi
  local p
  p="$(active_get_project 2>/dev/null || true)"
  if [ -n "$p" ] && config_is_project "$p"; then
    ACTIVE_RESOLVED_FROM="pointer"; ACTIVE_RESOLVED_PROJECT="$p"; return 0
  fi
  # shellcheck disable=SC2034  # consumed by callers (next.sh gate), not here
  ACTIVE_RESOLVED_FROM="fallback"
  ACTIVE_RESOLVED_PROJECT="$(config_active_project)"
}

# active_resolve_project [arg]
# Echo wrapper over the setter — keeps existing $(...) callers byte-compatible.
active_resolve_project() {
  active_resolve_project_src "${1:-}" || return $?
  printf '%s\n' "$ACTIVE_RESOLVED_PROJECT"
}

# ---- #572 scope guard -------------------------------------------------------

# active_resolve_project_try [arg]
# Non-fatal setter form of the resolution engine. Runs the engine in a SUBSHELL
# so that the fallback branch's config_active_project die (io.sh — `die` is
# `exit 1` in the CALLING shell) cannot kill the caller: every pre-#572 call
# site relies on exactly that containment, and checklist-init.sh documents it
# as deliberate. Both values are ferried back over stdout as one TAB-joined
# token — the "stdout-token" option the #282 lesson names as the alternative to
# setter-globals, chosen because setter-globals are precisely what does not
# survive the containment subshell.
# The engine's stderr is deliberately NOT redirected: command substitution
# captures stdout only, so the resolver's message flows through to this
# function's caller, and each call site keeps its historical choice — the
# sites that suppressed keep their own `2>/dev/null` on the call, the sites
# that surfaced the message still surface it.
# Sets, in the CALLING shell:
#   ACTIVE_RESOLVED_PROJECT / ACTIVE_RESOLVED_FROM   (both "" and rc 1 on failure)
active_resolve_project_try() {
  local _t
  _t="$( { active_resolve_project_src "${1:-}" >/dev/null \
         && printf '%s\t%s' "$ACTIVE_RESOLVED_PROJECT" "$ACTIVE_RESOLVED_FROM"; } )" || _t=""
  if [ -z "$_t" ]; then
    ACTIVE_RESOLVED_PROJECT=""; ACTIVE_RESOLVED_FROM=""; return 1
  fi
  ACTIVE_RESOLVED_PROJECT="${_t%%$'\t'*}"
  ACTIVE_RESOLVED_FROM="${_t##*$'\t'}"
  [ -n "$ACTIVE_RESOLVED_PROJECT" ] || { ACTIVE_RESOLVED_FROM=""; return 1; }
}

# active_context_project
# The project the operator is DEMONSTRABLY working in, derived independently of
# the resolver: the configured project whose source_dir is $PWD or an ancestor
# of it. Identity is `[ a -ef b ]` (device+inode), NEVER string equality —
# `pwd` yields /c/Programs/... where config.toml spells c:/Programs/..., and
# devDoc tracks koopmanGNN/ where config spells KoopmanGNN (the #553
# correction). -ef makes drive-form and case stop mattering.
# The project→source_dir list is enumerated ONCE, before the ancestor walk
# (register Issue-566: measure a guard's cost — the walk itself spawns no
# further processes), and the enumeration's own failure is DISTINGUISHED from
# "cwd under no project" (register Issue-314: `|| true` on a config-layer
# failure must not read as an empty list).
# Prints the project (rc 0); prints nothing and returns 1 when $PWD is under no
# configured source_dir; warns and returns 2 when the config enumeration itself
# failed. Both nonzero legs mean "CANNOT DECIDE" — never "no mismatch".
active_context_project() {
  local projects p src dir parent i
  # explicit pipefail: config_list_projects pipes _config_toml through awk, so
  # without it a parser failure exits 0 and reads as "no projects configured" —
  # the exact Issue-314 shape this branch exists to distinguish
  projects="$(set -o pipefail; config_list_projects 2>&1)" || {
    warn "active_context_project: project enumeration failed (cannot cross-check scope): $projects"
    return 2
  }
  local -a _names=() _srcs=()
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    src="$(config_get_project_field "$p" source_dir 2>/dev/null || true)"
    [ -n "$src" ] || continue
    [ -d "$src" ] || continue
    _names+=("$p"); _srcs+=("$src")
  done <<< "$projects"
  [ "${#_names[@]}" -gt 0 ] || return 1
  dir="$PWD"
  while :; do
    for i in "${!_names[@]}"; do
      if [ "$dir" -ef "${_srcs[$i]}" ]; then printf '%s\n' "${_names[$i]}"; return 0; fi
    done
    parent="$(dirname "$dir")"
    [ "$parent" = "$dir" ] && break
    dir="$parent"
  done
  return 1
}

# active_guard_scope <label>
# #572. Refuse a PROTECTED action when the scope was NOT asserted by THIS
# invocation and $PWD demonstrably belongs to a DIFFERENT configured project.
# Reads ACTIVE_RESOLVED_PROJECT / ACTIVE_RESOLVED_FROM from the CALLING shell,
# so it must NEVER be command-substituted (#282/#120) and must be preceded by
# active_resolve_project_try (or _src) in the same shell.
#
# Tri-state, and the blind spot is part of the contract (#558 — state what a
# checker cannot decide beside what it asserts):
#   FROM=arg            -> allow. An explicit scope is a per-invocation assertion.
#                          `env` is NOT in this class: an inherited pin is
#                          contamination, not an assertion (#458, run-suite.sh).
#   context == resolved -> allow, silently.
#   context != resolved -> DIE, naming both projects, both issues, and the source.
#   context undecidable -> allow + ONE stderr WARNING that MUST name the resolved
#                          project and its resolution source, so an
#                          undecidable-but-wrong run still leaves wrong-scope
#                          evidence in the transcript. This message is a
#                          CONTRACT, not diagnostics: it is the only artifact
#                          the undecidable branch produces. The
#                          enumeration-failed sub-case (rc 2) names that cause.
#
# Ships default-ON. Per-call opt-out: DEVAGENT_SCOPE_GUARD_OVERRIDE=1 — the
# shape hooks/active-pointer-guard.sh uses (DEVAGENT_ACTIVE_POINTER_GUARD_OVERRIDE).
# Deliberately truth-valued, not presence-valued: an empty or 0/false/no value
# does NOT disable the guard, because an inherited-but-empty export is exactly
# the contamination shape this issue exists to stop (#458).
ACTIVE_SCOPE_MISMATCH_TAG="SCOPE MISMATCH"

active_guard_scope() {
  local label="${1:-devagent}"
  local project="${ACTIVE_RESOLVED_PROJECT:-}" from="${ACTIVE_RESOLVED_FROM:-}"
  [ -n "$project" ] || return 0
  [ "$from" = "arg" ] && return 0
  case "${DEVAGENT_SCOPE_GUARD_OVERRIDE:-}" in
    ''|0|false|no) : ;;
    *)             return 0 ;;
  esac

  # FAST PATH (register Issue-566 — a guard's cost must be measured and
  # prefiltered): the overwhelmingly common case is $PWD inside the RESOLVED
  # project's own tree. Deciding that needs ONE config lookup, not a full
  # project enumeration (measured on Windows: ~0.7s vs ~5.5s per call). The
  # full enumeration below runs only on the abnormal paths (mismatch — which
  # dies anyway — or undecidable — which warns).
  # Blind spot (#558 — state what a checker cannot decide): with NESTED
  # configured source_dirs, cwd inside the inner project still satisfies this
  # ancestor walk for the OUTER resolved project and is allowed, where the
  # full innermost-first derivation would call it a mismatch. No configured
  # projects nest today; if they ever do, drop this fast path.
  local res_src _dir _parent
  res_src="$(config_get_project_field "$project" source_dir 2>/dev/null || true)"
  if [ -n "$res_src" ] && [ -d "$res_src" ]; then
    _dir="$PWD"
    while :; do
      [ "$_dir" -ef "$res_src" ] && return 0
      _parent="$(dirname "$_dir")"
      [ "$_parent" = "$_dir" ] && break
      _dir="$_parent"
    done
  fi

  local ctx="" ctx_rc=0 res_issue="" ctx_issue="" cause
  res_issue="$(state_get "$project" active_issue 2>/dev/null || true)"
  case "$res_issue" in null|'""') res_issue="" ;; esac

  ctx="$(active_context_project)" || ctx_rc=$?
  if [ "$ctx_rc" -ne 0 ]; then
    # Q2 CONTRACT: the resolved project + its resolution source are MANDATORY
    # tokens here; rc 2 additionally names the enumeration failure (its own
    # warn was already emitted by active_context_project).
    cause="\$PWD is under no configured source_dir"
    [ "$ctx_rc" -eq 2 ] && cause="the project enumeration failed"
    warn "$label: acting on project '${project}' (resolved from ${from})${res_issue:+, issue ${project}/${res_issue}} — ${cause}, so the scope could NOT be cross-checked. If this is not the project you are working on, re-run with the project passed explicitly."
    return 0
  fi
  [ "$ctx" = "$project" ] && return 0

  ctx_issue="$(state_get "$ctx" active_issue 2>/dev/null || true)"
  case "$ctx_issue" in null|'""') ctx_issue="" ;; esac
  die "$label: ${ACTIVE_SCOPE_MISMATCH_TAG} — no project was passed, so this resolved '${project}'${res_issue:+ (${project}/${res_issue})} from ${from}; but \$PWD is inside project '${ctx}'${ctx_issue:+ (${ctx}/${ctx_issue})}, the work under way. Refusing to act on '${project}'. Re-run with the scope (\`${label} ${ctx}\` or \`--project ${ctx}\`), move the pointer with \`/devagent:use ${ctx}\`, or override this single call with DEVAGENT_SCOPE_GUARD_OVERRIDE=1."
}

# active_scan_recent_incomplete <project>
# Walks <devdoc>/Issue-* (and Issue-Fork-*), prints the basename of the
# most-recently-modified checklist that still has any "- [ ]" or "- [~]"
# line. Empty + exit 1 if no candidate.
active_scan_recent_incomplete() {
  local project="$1"
  local devdoc
  devdoc="$(config_get_project_field "$project" devdoc_dir 2>/dev/null || true)"
  devdoc="$(expand_tilde "$devdoc")"
  [ -d "$devdoc" ] || return 1
  local best="" best_ts=0
  local d cl ts
  shopt -s nullglob
  for d in "$devdoc"/Issue-*/; do
    [ -d "$d" ] || continue
    cl="$d/checklist.md"
    [ -f "$cl" ] || continue
    grep -qE '^- \[[ ~]\]' "$cl" || continue
    ts="$(stat -c '%Y' "$cl")"
    if [ "$ts" -gt "$best_ts" ]; then
      best_ts="$ts"
      best="$(basename "$d")"
    fi
  done
  shopt -u nullglob
  [ -n "$best" ] || return 1
  printf '%s\n' "$best"
}

# active_resolve_issue_src <project> [arg]
# Issue resolution engine (#240, mirroring #282's project _src). Sets, in the
# CALLING shell (no stdout — callers must NOT command-substitute this, or the
# variables die in the subshell):
#   ACTIVE_RESOLVED_ISSUE      the resolved issue id
#   ACTIVE_ISSUE_RESOLVED_FROM arg | env | state | scan
# Writers gate shared-pointer writes on the source: an env-pinned session's
# pin IS its pointer — writing the shared one is the same-project clobber.
# The env pin is validated here (the choke point): ids become TOML table
# names ([context.<issue>]), so dots (table nesting), '#' (comment-guard
# brick), and any non-token character are rejected before they can touch
# the state file.
active_resolve_issue_src() {
  local project="$1" arg="${2:-}"
  [ -n "$project" ] || { echo "active_resolve_issue_src: project required" >&2; return 2; }
  ACTIVE_RESOLVED_ISSUE=""
  ACTIVE_ISSUE_RESOLVED_FROM=""
  if [ -n "$arg" ]; then
    case "$arg" in
    *[!A-Za-z0-9_-]*)
      die "active_resolve_issue_src: issue arg '$arg' is not a valid issue id (allowed: A-Za-z0-9 _ -)" ;;
    esac
    ACTIVE_ISSUE_RESOLVED_FROM="arg"; ACTIVE_RESOLVED_ISSUE="$arg"; return 0
  fi
  if [ -n "${DEVAGENT_ACTIVE_ISSUE:-}" ]; then
    case "$DEVAGENT_ACTIVE_ISSUE" in
    *[!A-Za-z0-9_-]*)
      die "active_resolve_issue_src: DEVAGENT_ACTIVE_ISSUE '$DEVAGENT_ACTIVE_ISSUE' is not a valid issue id (allowed: A-Za-z0-9 _ - ; no dots — they nest TOML tables)" ;;
    esac
    ACTIVE_ISSUE_RESOLVED_FROM="env"; ACTIVE_RESOLVED_ISSUE="$DEVAGENT_ACTIVE_ISSUE"; return 0
  fi
  local ai
  ai="$(state_get "$project" active_issue 2>/dev/null || true)"
  if [ -n "$ai" ] && [ "$ai" != "null" ] && [ "$ai" != '""' ]; then
    ACTIVE_ISSUE_RESOLVED_FROM="state"; ACTIVE_RESOLVED_ISSUE="$ai"; return 0
  fi
  # shellcheck disable=SC2034  # consumed by callers, not here
  ACTIVE_ISSUE_RESOLVED_FROM="scan"
  ACTIVE_RESOLVED_ISSUE="$(active_scan_recent_incomplete "$project")" || return 1
}

# active_resolve_issue <project> [arg]
# Echo wrapper over the setter — keeps existing $(...) callers byte-compatible.
active_resolve_issue() {
  active_resolve_issue_src "$@" || return $?
  printf '%s\n' "$ACTIVE_RESOLVED_ISSUE"
}

# ---- #240 session-view accessors --------------------------------------------
# Step scripts act on "the session's issue": the env pin or an explicit arg
# routes reads/writes to that issue's [context] table; an unpinned bare
# invocation keeps today's shared-slot behavior byte-for-byte (including the
# stale-issue_dir edge after cleanup — deliberately unchanged).

# state_ctx_get <project> <key> [issue-arg] — session-view read.
state_ctx_get() {
  local project="$1" key="$2" arg="${3:-}"
  if [ -n "${DEVAGENT_ACTIVE_ISSUE:-}" ] || [ -n "$arg" ]; then
    local issue
    issue="$(active_resolve_issue "$project" "$arg")" || return 1
    state_issue_get "$project" "$issue" "$key"
  else
    state_get "$project" "$key"
  fi
}

# state_ctx_set_many <project> <issue> <type key value>... — session-view
# write: always issue-keyed (the in-lock mirror keeps the unpinned shared
# view identical; see state_issue_set_many).
state_ctx_set_many() {
  state_issue_set_many "$@"
}

# issue_context_dir <project> [issue-arg] — the issue dir a step script acts
# on: derived from the resolved issue when pinned/arg'd, else the shared slot.
issue_context_dir() {
  local project="$1" arg="${2:-}"
  if [ -n "${DEVAGENT_ACTIVE_ISSUE:-}" ] || [ -n "$arg" ]; then
    local issue
    issue="$(active_resolve_issue "$project" "$arg")" || return 1
    issue_dir_for "$project" "$issue"
  else
    state_get "$project" issue_dir
  fi
}

# ---- #571 tree resolution + guard -------------------------------------------

# active_tree_resolve <project> [issue-arg]
# The CHECKOUT the issue's work lives in — the tree an EVIDENCE step must measure.
# Same rule commit.sh:110-111 and ship.sh:92-98 already apply, given one shared
# home here for the evidence pair (#571; register Issue-82/94 — migrating the
# commit/ship pair onto this helper is a recorded follow-up).
# SETTER-GLOBALS, and it dies: never command-substitute it (#282/#120).
#   ACTIVE_TREE_DIR   the tree to act on
#   ACTIVE_TREE_FROM  "state" (recorded worktree_path) | "config" (source_dir)
active_tree_resolve() {
  local project="$1" arg="${2:-}" wt src
  # same shape as ship.sh:92 — kept byte-identical deliberately; the fail-closed
  # liveness check below is what makes the `|| true` safe (register Issue-314/316).
  wt="$(state_ctx_get "$project" worktree_path "$arg" 2>/dev/null || true)"
  case "$wt" in null|'""') wt="" ;; esac
  if [ -n "$wt" ]; then
    "${DEVAGENT_GIT:-git}" -C "$wt" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
      || die "active_tree_resolve: recorded worktree_path is not a usable git tree: $wt — refusing to silently measure a different tree instead (#571/#148)"
    ACTIVE_TREE_DIR="$wt"; ACTIVE_TREE_FROM="state"; return 0
  fi
  # source_dir resolved only on this fallback branch — a worktree-recorded issue
  # never pays the config read (one python3 spawn, ~0.5s on Windows).
  src="$(config_get_project_field "$project" source_dir)"
  [ -n "$src" ] || die "active_tree_resolve: no source_dir configured for '$project'"
  [ -d "$src" ] || die "active_tree_resolve: source_dir missing: $src"
  ACTIVE_TREE_DIR="$src"
  # shellcheck disable=SC2034  # consumed by active_guard_tree in the calling shell
  ACTIVE_TREE_FROM="config"
}

# #571. Refuse an EVIDENCE action that would measure a checkout other than the one
# the operator is demonstrably working in. Reads ACTIVE_TREE_DIR/ACTIVE_TREE_FROM
# from the CALLING shell — never command-substitute; must follow active_tree_resolve
# in the same shell.
#
# Verdicts, and the blind spots are part of the contract (register Issue-558):
#   FROM=state             -> allow, silently. devAgent RECORDED this tree; commit.sh
#                             and ship.sh act on it regardless of cwd and this must not
#                             disagree with them.
#   cwd outside any repo   -> allow. Nothing to compare against.
#   cwd in a DIFFERENT
#     project's checkout   -> allow. Running from devdoc, the plugin repo, or a second
#                             project is normal and is how the skill caller runs.
#   cwd in another checkout
#     of the SAME project  -> DIE, naming both trees. The Issue-553 shape. "Same
#                             project" is two clauses in order: a shared
#                             --git-common-dir (a linked git worktree), else an equal
#                             `remote get-url origin` (a separate CLONE — the
#                             ~/devagent-wsl shape, and the likeliest live divergence).
# STATED BLIND SPOT — the clone clause FAILS OPEN, by decision, in two shapes:
#   * either side has no `origin` remote (every bats fixture repo, any local-only
#     checkout): the URLs read empty and the clause cannot decide, so the run
#     PROCEEDS on ACTIVE_TREE_DIR;
#   * the two clones' origins differ past the cosmetic normalization below —
#     different transports (ssh vs https), or a clone made FROM a local path
#     (measured 2026-08-07: ~/devagent-wsl's origin is /mnt/c/Programs/src/devagent,
#     so THAT pair is not covered): the URLs read as different projects.
# KNOWN FALSE-REFUSAL SHAPE (documented, not handled): a source_dir configured as a
# SUBDIRECTORY of a repo (monorepo subproject) makes cwd-inside-the-measured-tree
# look like clause 1. All configured projects are repo toplevels today; the
# active_guard_scope-style ancestor walk (active.sh fast path above) is the
# recorded follow-up (Issue-571's imPlan-potentialFutureEnhancements.md).
# In all fail-open shapes, the `tree:` line run-suite stamps is what makes the run
# legible after the fact — the guard is not the only mechanism, and must not be
# described as if it were.
ACTIVE_TREE_MISMATCH_TAG="TREE MISMATCH"

# Normalize a remote URL for comparison: trailing '/' and '.git' are cosmetic and
# differ between clones of one project. Nothing further is normalized on purpose —
# a transport difference is a real difference to this comparison (register
# Issue-548: compare the strings that are actually emitted, do not invent equalities).
_active_norm_url() { local u="${1%/}"; printf '%s' "${u%.git}"; }

# _active_common_root <dir>: canonical (pwd -P) path of <dir>'s repo COMMON dir.
# --git-common-dir is RELATIVE (".git") from a main worktree and ABSOLUTE from a
# linked one, so it must be resolved from inside <dir> and then canonicalized
# (measured on a scratch repo before this was written, #33; re-run in WSL
# 2026-08-07 — Issue-571's analysis/2026-08-07-probes.txt). Nonzero rc on failure.
_active_common_root() {
  # The common-dir is captured and tested non-empty BEFORE the cd: bash's
  # `cd ""` succeeds in place, so piping an empty rev-parse result straight
  # into cd silently yields the INPUT dir instead of failing — which routed
  # a not-a-repo tree past the warn branch into the clone clause's silent
  # fail-open (caught by the warn-branch test on its first WSL run).
  ( cd "$1" 2>/dev/null || exit 1
    _c="$("${DEVAGENT_GIT:-git}" rev-parse --git-common-dir 2>/dev/null)" || exit 1
    [ -n "$_c" ] || exit 1
    cd "$_c" 2>/dev/null || exit 1
    pwd -P )
}

active_guard_tree() {
  local label="${1:-devagent}" git="${DEVAGENT_GIT:-git}"
  # Guard-before-resolve is programmer error, not a topology blind spot: an
  # unset ACTIVE_TREE_DIR must DIE, never silently no-op — a future caller
  # (e.g. the recorded commit/ship migration) that forgets the resolve call
  # would otherwise get an unguarded run that looks guarded (#571 redmr MINOR).
  [ -n "${ACTIVE_TREE_DIR:-}" ] \
    || die "$label: active_guard_tree called before active_tree_resolve — no tree is resolved, so there is nothing to guard; call active_tree_resolve first in the same shell (#571)"
  [ "${ACTIVE_TREE_FROM:-}" = "config" ] || return 0
  case "${DEVAGENT_TREE_GUARD_OVERRIDE:-}" in
    ''|0|false|no) : ;;
    *)             return 0 ;;
  esac
  local top c_cwd c_tree u_cwd u_tree why
  top="$("$git" rev-parse --show-toplevel 2>/dev/null || true)"
  [ -n "$top" ] || return 0
  # identity by device+inode, NEVER string equality: `pwd` yields /c/Programs/...
  # where git yields C:/Programs/... (the #553 correction, active_context_project).
  [ "$top" -ef "$ACTIVE_TREE_DIR" ] && return 0
  # Clause 1 — linked worktree: both sides' common dirs via _active_common_root.
  c_cwd="$(_active_common_root "$top")" || c_cwd=""
  c_tree="$(_active_common_root "$ACTIVE_TREE_DIR")" || c_tree=""
  if [ -z "$c_cwd" ] || [ -z "$c_tree" ]; then
    warn "$label: could not compare \$PWD's checkout ($top) with the tree about to be measured ($ACTIVE_TREE_DIR) — proceeding on $ACTIVE_TREE_DIR; verify the artifact's head: before trusting it."
    return 0
  fi
  if [ "$c_cwd" -ef "$c_tree" ]; then
    why="a linked git worktree of the tree it would measure"
  else
    # Clause 2 — separate clone of the same project. Empty on either side means
    # "cannot decide" and PROCEEDS: the documented fail-open above.
    u_cwd="$(_active_norm_url "$("$git" -C "$top" remote get-url origin 2>/dev/null || true)")"
    u_tree="$(_active_norm_url "$("$git" -C "$ACTIVE_TREE_DIR" remote get-url origin 2>/dev/null || true)")"
    [ -n "$u_cwd" ] && [ -n "$u_tree" ] && [ "$u_cwd" = "$u_tree" ] || return 0
    why="a separate clone of the same project (origin $u_cwd)"
  fi
  die "$label: ${ACTIVE_TREE_MISMATCH_TAG} — \$PWD is inside the checkout '$top', but this would measure '$ACTIVE_TREE_DIR' (the configured source_dir; no worktree_path is recorded for this issue). '$top' is ${why}, so the evidence would be a true statement about a tree you are not working in (#571/#553). Re-run from '$ACTIVE_TREE_DIR', or record '$top' as this issue's tree (set worktree_path in ~/.claude/devagent/state/<project>.toml), or override this single call with DEVAGENT_TREE_GUARD_OVERRIDE=1."
}
