#!/usr/bin/env bats
# #714 Task 8: every skill-backed step command runs quarantine-check.sh as its
# first action, and quarantine-check refuses exactly as next.sh does.

bats_require_minimum_version 1.5.0   # run --separate-stderr
load 'lib/bats-helpers'
load 'lib/trust-fixture'
load 'lib/quarantine-fixture'

LEAD='First, run `bash "${CLAUDE_PLUGIN_ROOT}/scripts/quarantine-check.sh" $ARGUMENTS`. On any non-zero exit, print its stderr verbatim and STOP: no further step, no checklist write, no log line, no completion handoff. Exit 11 is a quarantine (wait for the operator); 9 and 10 are trust refusals.'

setup() {
  qf_project
  D="$DEVDOC/Issue-7"
  QC="$PLUGIN_ROOT/scripts/quarantine-check.sh"
}

teardown() { teardown_tmp_devagent_home; }

_mark() {
  printf 'devagent-quarantine 1\nkey github:github.com/acme/widgets#%s\nreason screen\nevent ? ?\n' \
    "${1##*-}" > "$1/QUARANTINE"
}

# _skill_steps: the skill-backed step names, by next.sh's own step_backing
# over the standard template's rows.
_skill_steps() {
  local name
  # shellcheck disable=SC1090
  eval "$(sed -n '/^STEP_NAMED_HELPERS=/p; /^step_backing() {/,/^}/p' "$PLUGIN_ROOT/scripts/next.sh")"
  grep -oE '^- \[.\] +[0-9]+\. +[a-z]+' "$PLUGIN_ROOT/templates/checklist-standard.md" | awk '{print $NF}' \
    | while read -r name; do
        if [ "$(step_backing "$name" "$PLUGIN_ROOT/scripts/$name.sh")" = skill-backed ]; then echo "$name"; fi
      done
}

@test "step commands: each skill-backed step command's Workflow lead is the quarantine-check line" {
  local steps s lead n=0 bad=""
  steps="$(_skill_steps)"
  [[ " $(echo $steps) " == *" spike "* ]]
  for s in $steps; do
    n=$((n + 1))
    # the first non-blank line after `## Workflow`
    lead="$(awk '/^## Workflow/{on=1; next} on && NF {print; exit}' "$PLUGIN_ROOT/commands/$s.md")"
    [ "$lead" = "$LEAD" ] || bad+=" $s"
  done
  [ -z "$bad" ] || { echo "no quarantine-check lead:$bad" >&2; false; }
  [ "$n" -eq 17 ]
}

@test "quarantine-check: no marker, no policy → rc 0, silent" {
  run --separate-stderr "$QC" wid
  [ "$status" -eq 0 ]
  [ "$output" = "" ] && [ "$stderr" = "" ]
}

@test "quarantine-check: draft <p> round-2 on a marked active issue → rc 11" {
  _mark "$D"
  run --separate-stderr "$QC" wid round-2
  [ "$status" -eq 11 ]
  run --separate-stderr "$QC" "a free-form note"
  [ "$status" -eq 11 ]
}

@test "quarantine-check: draft <p> Issue-7 on a marked dir → rc 11, stderr byte-equal to next's refusal" {
  _mark "$D"
  local want
  run --separate-stderr "$PLUGIN_ROOT/scripts/next.sh" wid
  [ "$status" -eq 11 ]
  want="$stderr"
  run --separate-stderr "$QC" wid Issue-7
  [ "$status" -eq 11 ]
  [ "$stderr" = "$want" ]
}

@test "quarantine-check: in scope it reads the tracker (a held label refuses with no marker)" {
  qf_policy separate
  qf_ev 2026-11-02T10:00:00Z 5 2002 user labeled
  run --separate-stderr "$QC" wid
  [ "$status" -eq 11 ]
  [ -f "$D/QUARANTINE" ]
}
