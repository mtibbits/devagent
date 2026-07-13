#!/usr/bin/env bats
# #440: the completion-handoff block is single-sourced COMMAND-side. It must
# appear exactly once per command file that carries it, and ZERO times in any
# core-* skill (those skills are user-invocable:false since #449 and are only
# reached via their command, whose copy drives the mark-done + STOP + CHAIN
# handoff). This canary stops the 25-way duplication from re-growing.

REPO="${BATS_TEST_DIRNAME}/.."
# Signature lines that uniquely identify the block (both must be absent skill-side;
# keying on both catches a partial re-add).
HEADING='^## Completion handoff'
STOP='^\*\*STOP\.\*\*'

@test "no core-* skill carries the completion-handoff block (#440)" {
  run grep -rlE "$HEADING" "$REPO"/skills/core-*/SKILL.md
  # #337 rc-precise: grep rc 1 = clean no-match; rc 0 = a skill still has it.
  [ "$status" -eq 1 ] || { echo "core-* skill(s) still carry '## Completion handoff':" >&2; echo "$output" >&2; return 1; }
  run grep -rlE "$STOP" "$REPO"/skills/core-*/SKILL.md
  [ "$status" -eq 1 ] || { echo "core-* skill(s) still carry the '**STOP.**' block:" >&2; echo "$output" >&2; return 1; }
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
