#!/usr/bin/env bats
# Completion-handoff step-marking + next-step wording (#129).
#
# Every workflow completion handoff said "After marking the step [x] ..." but
# never showed the checklist-mark.sh invocation. next.sh keys off the checklist
# MARK (not the log), so a model that logs-but-doesn't-mark makes an
# --auto/--through chain re-dispatch the same step forever. Every file with a
# "## Completion handoff" section must now (a) state the checklist-mark.sh
# invocation and (b) use the corrected next-step wording matching
# checklist_current_step ("first step not marked [x]/[-]"), not the old
# "first line that starts with `- [ ]`".
#
# #440: the handoff block is single-sourced COMMAND-side — the 10 paired core-*
# skills no longer carry it (they are user-invocable:false and reached only via
# their command). So the handoff-file set is now the command files only; this
# test scopes to them, and tests/handoff-single-source.bats enforces the skill
# side is empty.

. "${BATS_TEST_DIRNAME}/lib/hermetic-env.bash"

REPO="${BATS_TEST_DIRNAME}/.."

# All files carrying a Completion-handoff section (command-side only since #440).
_handoff_files() {
  grep -rl '## Completion handoff' "$REPO/skills" "$REPO/commands"
}

@test "every Completion-handoff file states the checklist-mark.sh invocation (#129)" {
  local files; mapfile -t files < <(_handoff_files)
  # Guard against a vacuous pass: 15 command files carry the block (#440: the
  # skill-side copies were removed; the block is single-sourced command-side).
  [ "${#files[@]}" -ge 15 ]  # #440: command-side only (was >=23 incl. skills)
  local f missing=()
  for f in "${files[@]}"; do
    grep -q 'checklist-mark.sh' "$f" || missing+=("$f")
  done
  if [ "${#missing[@]}" -ne 0 ]; then
    printf 'missing checklist-mark.sh: %s\n' "${missing[@]}" >&2
  fi
  [ "${#missing[@]}" -eq 0 ]
}

@test "no Completion-handoff file uses the stale 'starts with - [ ]' next-step wording (#129)" {
  local files; mapfile -t files < <(_handoff_files)
  [ "${#files[@]}" -ge 15 ]  # #440: command-side only (was >=23 incl. skills)
  local f stale=()
  for f in "${files[@]}"; do
    # Old wording: "... that starts with `- [ ]`". New wording names the mark.
    if grep -qF 'that starts with `- [ ]`' "$f"; then
      stale+=("$f")
    fi
    # And each must use the corrected phrasing (single-line marker; the prose
    # may wrap "not" onto the previous line).
    grep -qF 'marked `[x]` or `[-]`' "$f" || stale+=("$f:no-new-wording")
  done
  if [ "${#stale[@]}" -ne 0 ]; then
    printf 'stale/missing wording: %s\n' "${stale[@]}" >&2
  fi
  [ "${#stale[@]}" -eq 0 ]
}
