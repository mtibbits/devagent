# shellcheck shell=bash
# tests/fixtures/hold/test-tag.sh — #962: a test-only option tag, `probe`.
# Sourced after scripts/lib/question-actions.sh (a test appends it to a COPIED
# tree's library, or sources it directly); production registers no tag.
# Its check accepts only the value `ok`. Its perform appends one line to
# $PROBE_LOG on EVERY call — deliberately NOT idempotent, so a test can see the
# registry's once-per-question rule rather than the perform's own.
_probe_check() { [[ "$1" == ok ]]; }
_probe_perform() { printf '%s %s %s %s\n' "$1" "$2" "$3" "$4" >> "${PROBE_LOG:?PROBE_LOG unset}"; }
question_action_register probe _probe_check _probe_perform
