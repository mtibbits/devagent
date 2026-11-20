#!/usr/bin/env bats
# bats file_tags=gitbash
# tests/watchdog-dispatch.bats — #932: what next.sh's dispatch does for the
# watchdog. In an unattended session it records the step in the session's
# heartbeat directory and prints one wrapping line after the `dispatch:` header;
# in an attended one it does neither.
# Method (tests/next-backing.bats): the REAL next.sh runs from a copied tree in
# which the one script-backed step used here is a stub, so no real commit runs.
# The wrapping line's sentence is provisional (it is reworded until the
# wrapping-line eval passes), so these pin its facts — one line, right after the
# header, the wrapper's path, the interval — and never the sentence.

bats_require_minimum_version 1.5.0   # run --separate-stderr

load 'lib/bats-helpers'

ID=0f8fad5b-d9cb-469f-a165-70867728950e

setup() {
  setup_tmp_devagent_home
  WD="$DA_HOME/state/watchdog"
  root="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$root" "$BATS_TEST_TMPDIR/dd/Issue-1"
  cp -r "$PLUGIN_ROOT/scripts" "$root/scripts"
  cp -r "$PLUGIN_ROOT/templates" "$root/templates"
  # The stub: exit 3 is distinct from every real refusal, and next.sh's set -e
  # passes it on; the header prints before the step runs.
  printf '#!/usr/bin/env bash\necho STUB-RAN\nexit 3\n' > "$root/scripts/commit.sh"
  chmod +x "$root/scripts/commit.sh"
  write_cfg
  printf 'active_issue = "Issue-1"\nissue_dir = "%s/dd/Issue-1"\n' "$BATS_TEST_TMPDIR" \
    > "$DA_HOME/state/p.toml"
  # The root as the line prints it: the form Claude Code expands on Windows.
  shown="$root"
  if command -v cygpath >/dev/null 2>&1; then shown="$(cygpath -m "$root")"; fi
}
teardown() { teardown_tmp_devagent_home; }

# write_cfg [<[defaults] lines>] [<[project.p] lines>]
write_cfg() {
  cat > "$DA_HOME/config.toml" <<CFG
[defaults]
checklist_template = "standard"
${1:-}

[project.p]
source_dir = "$root"
devdoc_dir = "$BATS_TEST_TMPDIR/dd"
${2:-}
CFG
}

# row <number> <name> — the issue's checklist is that one pending row.
row() {
  printf '%s\n' "- [ ] $1. $2" '' '## Log' > "$BATS_TEST_TMPDIR/dd/Issue-1/checklist.md"
}

# nxt [<env assignment>...] — the staged next.sh for project p.
nxt()      { run --separate-stderr env "$@" bash "$root/scripts/next.sh" p; }
watched()  { nxt DEVAGENT_UNATTENDED=1 "CLAUDE_CODE_SESSION_ID=$ID" "$@"; }
attended() { nxt "CLAUDE_CODE_SESSION_ID=$ID" "$@"; }

# wrap_lines — the stdout lines that start "long-run: ".
wrap_lines() { grep -c '^long-run: ' <<<"$output" || true; }

# header_then_wrap <header> — the wrapping line is the line after the header.
header_then_wrap() {
  local i
  for i in "${!lines[@]}"; do
    [ "${lines[$i]}" = "$1" ] || continue
    [[ "${lines[$((i + 1))]:-}" == "long-run: "* ]] || { echo "after the header: ${lines[$((i + 1))]:-}" >&2; return 1; }
    WRAP="${lines[$((i + 1))]}"
    return 0
  done
  echo "no header '$1' in: $output" >&2
  return 1
}

@test "dispatch records v1, project, issue, step number and name" {
  # a skill-backed row
  row 2 draft
  watched
  [ "$status" -eq 0 ] || { echo "rc=$status out=$output err=$stderr" >&2; return 1; }
  [[ "$output" == *"dispatch: p/Issue-1 — step 2 (draft), skill-backed"* ]]
  [ "$(cat "$WD/$ID/dispatch")" = "v1 p Issue-1 2 draft" ]
  # a script-backed row replaces it
  row 12 commit
  watched
  [ "$status" -eq 3 ]
  [[ "$output" == *"dispatch: p/Issue-1 — step 12 (commit), script-backed"* ]]
  [[ "$output" == *STUB-RAN* ]]
  [ "$(cat "$WD/$ID/dispatch")" = "v1 p Issue-1 12 commit" ]
  # one line, five fields: the form a later reader splits
  [ "$(wc -l < "$WD/$ID/dispatch")" -eq 1 ]
}

@test "the wrapping line follows the header and names the wrapper path and the project's interval" {
  write_cfg "watchdog_telemetry_secs = 600" "watchdog_telemetry_secs = 240"
  row 2 draft
  watched
  [ "$status" -eq 0 ]
  [ -z "$stderr" ]
  header_then_wrap "dispatch: p/Issue-1 — step 2 (draft), skill-backed"
  [ "$(wrap_lines)" -eq 1 ]
  [[ "$WRAP" == *"bash \"$shown/libexec/long-run.sh\" "* ]] || { echo "WRAP=$WRAP shown=$shown" >&2; return 1; }
  [[ "$WRAP" == *" 240 s"* ]]
  [[ "$WRAP" != *" 600 s"* ]]
  # the skill-backed instruction still follows
  [[ "$output" == *"/devagent:draft p"* ]]

  # a script-backed row carries it too, before the step's own output
  row 12 commit
  watched
  [ "$status" -eq 3 ]
  header_then_wrap "dispatch: p/Issue-1 — step 12 (commit), script-backed"
  [ "$(wrap_lines)" -eq 1 ]
  [[ "$WRAP" == *" 240 s"* ]]
}

@test "the interval comes from [defaults], else the shipped 180 s" {
  row 2 draft
  watched
  [ "$status" -eq 0 ]
  header_then_wrap "dispatch: p/Issue-1 — step 2 (draft), skill-backed"
  [[ "$WRAP" == *" 180 s"* ]]
  write_cfg "watchdog_telemetry_secs = 600"
  watched
  [ "$status" -eq 0 ]
  header_then_wrap "dispatch: p/Issue-1 — step 2 (draft), skill-backed"
  [[ "$WRAP" == *" 600 s"* ]]
}

@test "a malformed interval prints the line with 180 s and one warning, and next exits as before" {
  write_cfg "" 'watchdog_telemetry_secs = "abc"'
  row 2 draft
  watched
  [ "$status" -eq 0 ]
  header_then_wrap "dispatch: p/Issue-1 — step 2 (draft), skill-backed"
  [[ "$WRAP" == *" 180 s"* ]]
  [ "$(grep -c 'watchdog_telemetry_secs' <<<"$stderr")" -eq 1 ]
  [[ "$stderr" == *WARNING* ]]
}

@test "the wrapping line says how to wrap: the Bash tool, commands that finish, the declared-window flag" {
  row 2 draft
  watched
  [ "$status" -eq 0 ]
  header_then_wrap "dispatch: p/Issue-1 — step 2 (draft), skill-backed"
  [[ "$WRAP" == *"Bash tool"* ]]
  [[ "$WRAP" == *"tail -f"* ]]
  [[ "$WRAP" == *"## Declared silent windows"* ]]
  [[ "$WRAP" == *"--silent <window>"* ]]
  [[ "$WRAP" == *"bash -c '"* ]]
}

@test "the wrapping line prints a C:/ root on Git Bash" {
  row 2 draft
  watched
  [ "$status" -eq 0 ]
  header_then_wrap "dispatch: p/Issue-1 — step 2 (draft), skill-backed"
  local printed="${WRAP#*bash \"}"
  printed="${printed%%/libexec/long-run.sh\"*}"
  if command -v cygpath >/dev/null 2>&1; then
    [[ "$printed" =~ ^[A-Za-z]:/ ]] || { echo "printed=$printed" >&2; return 1; }
    [[ "$printed" != *\\* ]]
  else
    [[ "$printed" == /* ]] || { echo "printed=$printed" >&2; return 1; }
  fi
  [ "$printed" = "$shown" ]
}

@test "no marker: no wrapping line and no state/watchdog directory" {
  row 2 draft
  watched
  [ "$status" -eq 0 ]
  [ "$(wrap_lines)" -eq 1 ]
  [ -f "$WD/$ID/dispatch" ]
  local watched_out="$output"
  rm -rf "$WD"

  attended
  [ "$status" -eq 0 ]
  [ -z "$stderr" ]
  [ "$(wrap_lines)" -eq 0 ]
  [[ "$output" != *long-run* ]]
  [ ! -e "$WD" ]
  # the attended output is the watched output minus that one line
  [ "$output" = "$(grep -v '^long-run: ' <<<"$watched_out")" ]

  # marked, but no usable session id: the line (the session is still watched
  # through its transcript), and nothing written
  nxt DEVAGENT_UNATTENDED=1
  [ "$status" -eq 0 ]
  [ "$(wrap_lines)" -eq 1 ]
  [ ! -e "$WD" ]
}

@test "a failed heartbeat write leaves next's exit and stdout unchanged" {
  row 12 commit
  watched
  [ "$status" -eq 3 ]
  [ -f "$WD/$ID/dispatch" ]
  local good="$output"
  # state/watchdog is a regular file, so no session directory can be made (no chmod)
  rm -rf "$WD"
  : > "$WD"
  watched
  [ "$status" -eq 3 ]
  [ "$output" = "$good" ]
  [[ "$stderr" == *"heartbeat: warning: cannot write $WD/$ID/dispatch"* ]]
  [ -f "$WD" ]
}
