#!/usr/bin/env bats
# #125: the command docs must document the invocation their scripts actually
# accept (contracts re-derived from HEAD). Canary — pins each corrected form so
# the docs can't drift back.

REPO="${BATS_TEST_DIRNAME}/.."
C="$REPO/commands"

# --- Category 1: project is a REQUIRED positional $1 (die without) ----------
@test "project-required command docs show <project>, not optional/omitted (#125)" {
  local f
  for f in park resume switch stuck catchup unstuck where pull; do
    grep -qF '<project>' "$C/$f.md" || { echo "$f.md missing <project>" >&2; return 1; }
    # the old optional/wrong bracket form must be gone from the usage/hint
    run grep -F '[project]' "$C/$f.md"
    [ "$status" -ne 0 ] || { echo "$f.md still shows optional [project]" >&2; return 1; }
  done
}

# --- Category 2: project is the --project FLAG, not a positional ------------
@test "--project command docs document the flag and drop the positional [project] (#125)" {
  local f
  for f in depends grep history template; do
    grep -qF -- '--project' "$C/$f.md" || { echo "$f.md missing --project" >&2; return 1; }
    run grep -F '[project]' "$C/$f.md"
    [ "$status" -ne 0 ] || { echo "$f.md still shows positional [project]" >&2; return 1; }
  done
}

# --- sync: --all | <project> -----------------------------------------------
@test "sync.md documents the --all and <project> forms (#125)" {
  grep -qF -- '--all' "$C/sync.md"
  run grep -F '[issue-dir]' "$C/sync.md"      # the old bogus hint
  [ "$status" -ne 0 ]
}

# --- next.md: the stale zero-diff QUALITY paragraph is gone (#116 auto-skip) -
@test "next.md's quality zero-diff prose matches quality.md's auto-skip (#125/#116)" {
  run grep -F 'must be manually marked' "$C/next.md"
  [ "$status" -ne 0 ]
  run grep -F 'A follow-up is tracked' "$C/next.md"
  [ "$status" -ne 0 ]
  grep -qF 'auto-marks step 8' "$C/next.md"
}

# --- No command doc references the DELETED bash §6.1 parser (#121/#122) ------
# This is the precise, false-positive-free form of the #121 comment's "no
# command doc implies a BASH-level §6.1 parser": the concrete bash parser that
# existed was parse_devagent_args (deleted in #122), so banning its name is the
# testable assertion. A blanket "parses"/"parser" word-ban is WRONG — it would
# false-fire on legitimate non-§6.1 uses (redmr.md's §14.4 "parser-compatible"
# format, doctor.md's "config parses" TOML check). The correct "Invokes
# scripts/X.sh with the parsed arguments per spec §6.1" wording (the MODEL
# parses, then invokes) stays — the regex below does not match it.
@test "no command doc references the deleted parse-args parser (#125/#121)" {
  run grep -rEl 'parse_devagent_args|parse-args\.sh' "$C"
  [ "$status" -ne 0 ]
  [ -z "$output" ]
}

# --- #321: the SCRIPTS' own usage() heredocs (the surface #125 missed) must show
# [--project P], not the positional [project] their parsers reject. -----------
@test "--project scripts' usage() show [--project P], not a positional [project] (#321)" {
  local f
  for f in depends grep history template; do
    grep -qF -- '[--project' "$REPO/scripts/$f.sh" || { echo "$f.sh usage missing [--project" >&2; return 1; }
    run grep -F '[project]' "$REPO/scripts/$f.sh"
    [ "$status" -ne 0 ] || { echo "$f.sh still shows positional [project]" >&2; return 1; }
  done
}
