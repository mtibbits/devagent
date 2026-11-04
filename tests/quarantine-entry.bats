#!/usr/bin/env bats
# #714 Task 7: every entry point refuses a quarantined issue. The census holds
# QUARANTINE_GUARD_POINTS equal to the scripts that carry a column-0 guard
# call and sweeps every script that resolves an issue dir; the matrix runs the
# real scripts against a marked issue and requires one byte-identical refusal
# that writes nothing.

bats_require_minimum_version 1.5.0   # run --separate-stderr
load 'lib/bats-helpers'
load 'lib/trust-fixture'
load 'lib/quarantine-fixture'

KEY="github:github.com/acme/widgets#7"
GUARD_RE='^quarantine_(pull_guard|guard|guard_marker|guard_dir) "'
RESOLVER_RE='issue_context_dir|issue_dir_for|active_resolve_issue|project_devdoc_dir|state_get "\$[a-zA-Z_{}]*" issue_dir'

setup() {
  qf_project
  D="$DEVDOC/Issue-7"
  STATE="$DA_HOME/state/wid.toml"
  S="$PLUGIN_ROOT/scripts"
}

teardown() { teardown_tmp_devagent_home; }

_lib() {
  source "$PLUGIN_ROOT/scripts/lib/paths.sh"
  source "$PLUGIN_ROOT/scripts/lib/io.sh"
  source "$PLUGIN_ROOT/scripts/lib/config.sh"
  source "$PLUGIN_ROOT/scripts/lib/trust.sh"
  source "$PLUGIN_ROOT/scripts/lib/quarantine.sh"
}

_mark() {
  printf 'devagent-quarantine 1\nkey github:github.com/acme/widgets#%s\nreason screen\nevent ? ?\n' \
    "${1##*-}" > "$1/QUARANTINE"
}

_msg() { bash -c 'source "$PLUGIN_ROOT/scripts/lib/refusals.sh"; quarantine_message "$1"' _ "${1:-$KEY}"; }

_sha() { sha256sum "$1" | cut -d' ' -f1; }

# _scripts: every script under scripts/ (and capture/) by its name minus .sh.
_names() { sed -e "s|^$PLUGIN_ROOT/scripts/||" -e 's|\.sh$||' | sort; }

@test "census: QUARANTINE_GUARD_POINTS equals the scripts carrying a column-0 quarantine_guard call (both directions; count asserted)" {
  _lib
  local found want
  found="$(MSYS_NO_PATHCONV=1 grep -lE "$GUARD_RE" "$PLUGIN_ROOT"/scripts/*.sh "$PLUGIN_ROOT"/scripts/capture/*.sh | _names)"
  want="$(printf '%s\n' "${QUARANTINE_GUARD_POINTS[@]}" | sort)"
  [ "$found" = "$want" ] || { diff <(echo "$want") <(echo "$found") >&2; false; }
  [ "${#QUARANTINE_GUARD_POINTS[@]}" -eq 42 ]
}

@test "census: every script calling issue_context_dir|issue_dir_for|active_resolve_issue is guarded or on the reader allow-list" {
  _lib
  local hits s stray=""
  hits="$( { MSYS_NO_PATHCONV=1 grep -lE "$RESOLVER_RE" "$PLUGIN_ROOT"/scripts/*.sh "$PLUGIN_ROOT"/scripts/capture/*.sh | _names
             printf '%s\n' "${TRUST_ENTRY_POINTS[@]}"; } | sort -u)"
  # positive control: the sweep sees known resolvers and a reader.
  [[ $'\n'"$hits"$'\n' == *$'\n'analyze-static$'\n'* && $'\n'"$hits"$'\n' == *$'\n'where$'\n'* ]]
  for s in $hits; do
    [[ " ${QUARANTINE_GUARD_POINTS[*]} " == *" $s "* ]] && continue
    [ -n "${QUARANTINE_UNGUARDED[$s]:-}" ] && continue
    stray+=" $s"
  done
  [ -z "$stray" ] || { echo "neither guarded nor allow-listed:$stray" >&2; false; }
  # the allow-list names no guarded script and no script the sweep misses.
  for s in "${!QUARANTINE_UNGUARDED[@]}"; do
    [[ " ${QUARANTINE_GUARD_POINTS[*]} " != *" $s "* ]] || { echo "$s is both" >&2; false; }
    [[ $'\n'"$hits"$'\n' == *$'\n'"$s"$'\n'* ]] || { echo "$s is not in the sweep" >&2; false; }
  done
}

# A read the census regex matches that resolves no issue to act on, before the
# trust check by its #713 placement.
declare -gA EARLY_READ=(
  [sync]="reads the shared slot only to skip a project with nothing to sync"
  [promote-potholes]="project_devdoc_dir: the devdoc root, for --list-pending"
)

@test "census: in each guarded script the guard line precedes the first resolver line and follows trust_entry_check" {
  _lib
  local s f g te r sc bad=""
  for s in "${QUARANTINE_GUARD_POINTS[@]}"; do
    f="$PLUGIN_ROOT/scripts/$s.sh"
    g="$(grep -nE "$GUARD_RE" "$f" | head -n 1 | cut -d: -f1)"
    te="$(grep -nE '^trust_entry_check(_devdoc)? "' "$f" | head -n 1 | cut -d: -f1)"
    r="$(grep -nE "$RESOLVER_RE" "$f" | grep -vE '^[0-9]+:[[:space:]]*#' | grep -vE "^[0-9]+:$GUARD_RE" | head -n 1 | cut -d: -f1)"
    # a tracker-reading guard without a trust check would run marker-only.
    if [ -z "$te" ] && grep -qE '^quarantine_(pull_)?guard "' "$f"; then bad+=" $s:tracker-guard-without-te"; fi
    # #572: the scope guard refuses before the guard's tracker/devDoc writes.
    sc="$(grep -nE '^[[:space:]]*active_guard_scope ' "$f" | head -n 1 | cut -d: -f1)"
    if [ -n "$sc" ] && [ "$sc" -gt "$g" ]; then bad+=" $s:scope@$sc>guard@$g"; fi
    if [ -n "$te" ] && [ "$g" -le "$te" ]; then bad+=" $s:guard@$g<=te@$te"; fi
    if [ -n "$te" ] && [ "$((g - te))" -gt 1 ] && ! sed -n "$((te + 1)),$((g - 1))p" "$f" | grep -qE '^\s*(done|fi|#|$)'; then
      bad+=" $s:guard@$g-not-next-to-te@$te"
    fi
    if [ -n "$r" ] && [ "$r" -lt "$g" ] && [ -z "${EARLY_READ[$s]:-}" ]; then bad+=" $s:resolver@$r<guard@$g"; fi
  done
  [ -z "$bad" ] || { echo "misplaced:$bad" >&2; false; }
}

# The matrix (trust off, marker present): every entry refuses 11 with the
# same bytes and changes nothing.
@test "entry: byte-identical refusals across the entry points, no state or checklist change, no CHAIN:, no backend call" {
  _mark "$D"
  printf 'Step:        2 draft\nReason:      fixture\n' > "$D/STUCK"
  local want st cl fails=0 i
  want="$(_msg)"
  st="$(_sha "$STATE")" cl="$(_sha "$D/checklist.md")"
  local -a cases=(
    "next wid" "next wid --auto" "PIN next" "unstuck wid" "checklist-unstuck --pending $D"
    "resume wid Issue-7" "switch wid Issue-8" "park wid" "revise wid --no-chain" "cleanup wid"
    "commit wid" "mergetoall wid" "ship wid Issue-7" "checklist-mark $D 2 x"
    "checklist-advance $D" "checklist-init --project wid $D" "checklist-stuck $D a-reason"
    "checklist-log $D draft a-message" "stuck wid a-reason" "branch wid" "spike create wid"
    "mergemr wid" "comments wid" "analyze wid" "rebaseline wid" "depends --project wid Issue-7 on Issue-8"
  )
  for i in "${cases[@]}"; do
    # shellcheck disable=SC2086  # word-split each case on purpose
    set -- $i
    if [ "$1" = PIN ]; then
      shift
      DEVAGENT_ACTIVE_ISSUE=Issue-7 run --separate-stderr "$S/$1.sh" wid
    else
      local ep="$1"; shift
      run --separate-stderr "$S/$ep.sh" "$@"
    fi
    if [ "$status" -ne 11 ] || [ "$stderr" != "$want" ] || [[ "$output" == *CHAIN:* ]]; then
      echo "$i: rc=$status out=$output err=$stderr" >&2
      fails=$((fails + 1))
    fi
  done
  [ "$(_sha "$STATE")" = "$st" ] || { echo "state changed" >&2; fails=$((fails + 1)); }
  [ "$(_sha "$D/checklist.md")" = "$cl" ] || { echo "checklist changed" >&2; fails=$((fails + 1)); }
  [ ! -s "$QB_DIR/calls" ] || { echo "backend calls: $(cat "$QB_DIR/calls")" >&2; fails=$((fails + 1)); }
  [ "$fails" -eq 0 ]
}

@test "entry: tracker label applied mid-work → next rc 11, marker created; ship makes no push call" {
  qf_policy separate
  qf_ev 2026-11-02T10:00:00Z 5 2002 user labeled
  run --separate-stderr "$S/next.sh" wid
  [ "$status" -eq 11 ]
  [ "$stderr" = "$(_msg)" ]
  [ "$(sed -n 3,4p "$D/QUARANTINE")" = "reason tracker
event 2026-11-02T10:00:00Z 5" ]
  run --separate-stderr "$S/ship.sh" wid Issue-7
  [ "$status" -eq 11 ]
  run grep -E '^\[pr\]|push' "$QB_DIR/calls"
  [ "$status" -eq 1 ]
}

@test "entry: in-work marker deleted (git clean -fd) → park and revise each rc 11, no glyph change, marker recreated" {
  qf_policy separate
  qf_ev 2026-11-02T10:00:00Z 5 2002 user labeled
  local cl ep
  cl="$(_sha "$D/checklist.md")"
  for ep in "park wid Issue-7" "revise wid Issue-7 --no-chain"; do
    rm -f "$D/QUARANTINE"
    # shellcheck disable=SC2086
    run --separate-stderr "$S/${ep%% *}.sh" ${ep#* }
    [ "$status" -eq 11 ] || { echo "$ep: rc=$status $stderr" >&2; return 1; }
    [ -f "$D/QUARANTINE" ]
  done
  [ "$(_sha "$D/checklist.md")" = "$cl" ]
  run grep -E '^Issue-7 *=' "$STATE"
  [ "$status" -eq 1 ]
}

@test "entry: checklist-mark is marker-only in scope (operator: step-level reads)" {
  qf_policy separate
  qf_ev 2026-11-02T10:00:00Z 5 2002 user labeled
  run --separate-stderr "$S/checklist-mark.sh" "$D" 4 x
  [ "$status" -eq 0 ]
  run grep -c '^events' "$QB_DIR/calls"
  [ "$output" = 0 ]
  _mark "$D"
  run --separate-stderr "$S/checklist-mark.sh" "$D" 8 x
  [ "$status" -eq 11 ]
  [ "$stderr" = "$(_msg)" ]
}

@test "entry: marker refuses before the scope guard, pinned and arg'd" {
  _mark "$D"
  mkdir -p "$BATS_TEST_TMPDIR/other"
  printf '\n[project.other]\nsource_dir = "%s"\ndevdoc_dir = "%s"\n' "$BATS_TEST_TMPDIR/other" "$BATS_TEST_TMPDIR/dd-other" \
    >> "$DA_HOME/config.toml"
  cd "$BATS_TEST_TMPDIR/other"
  DEVAGENT_ACTIVE_PROJECT=wid run --separate-stderr "$S/next.sh"
  [ "$status" -eq 11 ] || { echo "rc=$status $stderr" >&2; return 1; }
  [ "$stderr" = "$(_msg)" ]
  DEVAGENT_ACTIVE_PROJECT=wid DEVAGENT_ACTIVE_ISSUE=Issue-7 run --separate-stderr "$S/revise.sh" --no-chain
  [ "$status" -eq 11 ]
  run --separate-stderr "$S/revise.sh" wid Issue-7 --no-chain
  [ "$status" -eq 11 ]
}

@test "entry: revise with an empty slot refuses the scan-picked marked issue (final review #1)" {
  _mark "$D"
  sed -i -E '/^(active_issue|issue_dir) *=/d' "$STATE"
  # Issue-7's checklist is the most recently touched incomplete one: the scan
  # tier of revise's resolver picks it.
  touch -d '2020-01-01' "$DEVDOC/Issue-8/checklist.md"
  local cl
  cl="$(_sha "$D/checklist.md")"
  run --separate-stderr "$S/revise.sh" wid --no-chain
  [ "$status" -eq 11 ] || { echo "rc=$status out=$output err=$stderr" >&2; return 1; }
  [ "$stderr" = "$(_msg)" ]
  [ "$(_sha "$D/checklist.md")" = "$cl" ]
}

@test "entry: sync --all keeps errexit inside each project (final review #2)" {
  # wid: shipped, an MR, no merge marker and no code_source.backend — the
  # config read fails, and under errexit that ends the run as it did before
  # #714 (a subshell on the left of || would run on past it).
  sed -i '1i mr_url = "https://github.com/acme/widgets/pull/9"' "$STATE"
  sed -i 's/^- \[ \] 18\. ship$/- [x] 18. ship/' "$D/checklist.md"
  grep -q '^- \[x\] 18\. ship$' "$D/checklist.md"
  run --separate-stderr "$S/sync.sh" --all
  # config_get_project_field's failure exit, as before #714
  [ "$status" -eq 1 ] || { echo "rc=$status out=$output err=$stderr" >&2; return 1; }
}

@test "entry: checklist-init on a marked dir that is not active → rc 11" {
  _mark "$DEVDOC/Issue-8"
  local cl
  cl="$(_sha "$DEVDOC/Issue-8/checklist.md")"
  run --separate-stderr "$S/checklist-init.sh" --project wid "$DEVDOC/Issue-8"
  [ "$status" -eq 11 ]
  [ "$stderr" = "$(_msg github:github.com/acme/widgets#8)" ]
  [ "$(_sha "$DEVDOC/Issue-8/checklist.md")" = "$cl" ]
}

@test "entry: sync --all with one marked project still processes the next" {
  _mark "$D"
  local dd2="$BATS_TEST_TMPDIR/devDoc/wid2"
  mkdir -p "$dd2/Issue-3"
  cp "$D/checklist.md" "$dd2/Issue-3/"
  printf 'devagent-quarantine 1\nkey github:github.com/acme/gadgets#3\nreason screen\nevent ? ?\n' > "$dd2/Issue-3/QUARANTINE"
  printf '\n[project.wid2]\nsource_dir = "%s"\ndevdoc_dir = "%s"\n\n[project.wid2.issue_source]\nbackend = "github"\nrepo = "acme/gadgets"\ndir_prefix = "Issue-"\n' \
    "$BATS_TEST_TMPDIR/wid2" "$dd2" >> "$DA_HOME/config.toml"
  printf 'active_issue = "Issue-3"\nissue_dir = "%s"\nmr_url = "https://github.com/acme/gadgets/pull/4"\n' "$dd2/Issue-3" \
    > "$DA_HOME/state/wid2.toml"
  # top level: the fixture's state ends in a [parked] table
  sed -i '1i mr_url = "https://github.com/acme/widgets/pull/9"' "$STATE"
  run --separate-stderr "$S/sync.sh" --all
  [ "$status" -eq 11 ] || { echo "rc=$status err=$stderr" >&2; return 1; }
  [[ "$stderr" == *"QUARANTINED: $KEY is held"* ]]
  [[ "$stderr" == *"QUARANTINED: github:github.com/acme/gadgets#3 is held"* ]]
}

@test "entry: stuck <p> blocked on a marked active issue → rc 11" {
  _mark "$D"
  run --separate-stderr "$S/stuck.sh" wid "blocked on review"
  [ "$status" -eq 11 ]
  [ ! -e "$D/STUCK" ]
}

@test "entry: depends <marked> on Issue-8 → rc 11, no write" {
  _mark "$D"
  local before
  before="$(find "$DEVDOC" "$DA_HOME" -type f -exec sha256sum {} + | sort)"
  run --separate-stderr "$S/depends.sh" --project wid Issue-7 on Issue-8
  [ "$status" -eq 11 ]
  [ "$(find "$DEVDOC" "$DA_HOME" -type f -exec sha256sum {} + | sort)" = "$before" ]
}

@test "entry: migrate-checklist-numbering refuses an explicit marked dir; --all skips it" {
  _mark "$D"
  local cl
  cl="$(_sha "$D/checklist.md")"
  run --separate-stderr "$S/migrate-checklist-numbering.sh" "$DEVDOC/Issue-8" "$D"
  [ "$status" -eq 11 ]
  [ "$(_sha "$D/checklist.md")" = "$cl" ]
  # --all reads config with tomllib (python >= 3.11); without it the run
  # cannot start, which is not this check's subject.
  python3 -c 'import tomllib' 2>/dev/null || skip "python3 has no tomllib: --all cannot run here"
  run --separate-stderr "$S/migrate-checklist-numbering.sh" --dry-run --all
  [ "$status" -eq 0 ] || { echo "rc=$status out=$output err=$stderr" >&2; return 1; }
  [[ "$output$stderr" != *"Issue-7"* ]]
}

@test "entry: promote-potholes --list-pending skips a marked dir; an explicit one refuses" {
  _mark "$D"
  printf 'status: pending\n' > "$D/potholes-promotion.md"
  run --separate-stderr "$S/promote-potholes.sh" wid --list-pending
  [ "$status" -eq 0 ]
  [[ "$output" != *Issue-7* ]]
  run --separate-stderr "$S/promote-potholes.sh" wid "$D" --check
  [ "$status" -eq 11 ]
}

@test "entry: re-entry end to end — held: next rc 11; approver removes the label; pull rc 0; next proceeds" {
  qf_policy separate
  qf_ev 2026-11-02T10:00:00Z 5 1001 user labeled
  run --separate-stderr "$S/next.sh" wid
  [ "$status" -eq 11 ]
  qf_ev 2026-11-02T11:00:00Z 9 2002 user unlabeled
  run --separate-stderr "$S/pull.sh" wid origin 7
  [ "$status" -eq 0 ] || { echo "pull rc=$status $stderr" >&2; return 1; }
  run --separate-stderr "$S/next.sh" wid
  [ "$status" -eq 0 ] || { echo "next rc=$status $stderr" >&2; return 1; }
  [[ "$output" == *"/devagent:scope"* ]]
}
