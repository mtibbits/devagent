#!/usr/bin/env bash
# tests/fixtures/hold/holding-step.sh — #962: a script-backed step for
# tests/next-hold.bats. A test copies it into a staged tree as
# scripts/commit.sh and writes in its three values with sed: @COUNTER@ (a file
# that gets one line per run), @HOLD@ (1 to call hold.sh, 0 not to) and @EXIT@
# (this step's exit status). With @HOLD@ = 1 it asks or holds on commit, using
# the question file @QFILE@, as a step would.
COUNTER='@COUNTER@' HOLD='@HOLD@' EXIT='@EXIT@' QFILE='@QFILE@'
printf 'run\n' >> "$COUNTER"
if [ "$HOLD" = 1 ]; then
  "$(dirname "$0")/hold.sh" "$1" Issue-7 --step commit --reason "commit: a question" --question-file "$QFILE" || true
fi
exit "$EXIT"
