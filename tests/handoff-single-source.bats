#!/usr/bin/env bats
# #440: the completion-handoff block is single-sourced COMMAND-side. It must
# appear exactly once per command file that carries it, and ZERO times in any
# core-* skill (those skills are user-invocable:false since #449 and are only
# reached via their command, whose copy drives the mark-done + STOP + CHAIN
# handoff). This canary stops the 25-way duplication from re-growing.

. "${BATS_TEST_DIRNAME}/lib/hermetic-env.bash"

REPO="${BATS_TEST_DIRNAME}/.."
# Signatures that identify the block. The historical failure mode is a byte-
# identical copy, so the structural literals catch the real risk; we also key on
# the block's BEHAVIOR-anchored line (the next-step / CHAIN question) so a re-add
# that rewords the heading or the STOP marker but keeps the functional handoff is
# still caught. All must be absent skill-side. (Scope note: only core-* skills are
# command-paired, so the block is meaningless elsewhere; this guard is
# intentionally scoped to skills/core-*/SKILL.md — a re-add to a non-core skill is
# out of scope by construction.)
HEADING='^## Completion handoff'
STOP='^\*\*STOP\.\*\*'
CHAIN='Would you like to continue on to'   # behavior-anchored (#440 redmr MINOR)

@test "no core-* skill carries the completion-handoff block (#440)" {
  local sig
  for sig in "$HEADING" "$STOP" "$CHAIN"; do
    run grep -rlE "$sig" "$REPO"/skills/core-*/SKILL.md
    # #337 rc-precise: grep rc 1 = clean no-match; rc 0 = a skill still has it.
    [ "$status" -eq 1 ] || { echo "core-* skill(s) still carry a handoff signature (/$sig/):" >&2; echo "$output" >&2; return 1; }
  done
}

@test "every command file carries the block at most once (no in-file dup) (#440)" {
  local f n
  for f in "$REPO"/commands/*.md; do
    n="$(grep -cE "$HEADING" "$f" || true)"
    [ "$n" -le 1 ] || { echo "$(basename "$f"): $n '## Completion handoff' headings (expected <= 1)" >&2; return 1; }
  done
}

@test "the 10 paired-step commands still carry exactly one block (source intact) (#440)" {
  local cmd f n
  for cmd in scope improve prune tighten draftmr redmr preship document lessonslearned impact; do
    f="$REPO/commands/$cmd.md"
    [ -f "$f" ] || { echo "missing $f" >&2; return 1; }
    n="$(grep -cE "$HEADING" "$f" || true)"
    [ "$n" -eq 1 ] || { echo "commands/$cmd.md has $n handoff headings (expected exactly 1 — command-side source)" >&2; return 1; }
  done
}
