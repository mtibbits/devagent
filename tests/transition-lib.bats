#!/usr/bin/env bats
# tests/transition-lib.bats — scripts/lib/transition.sh (#710): the stage→state
# resolver the three issue backends, the three callers and doctor share, and the
# gate/fire/classify step the callers share.

load 'lib/bats-helpers'

setup() {
  setup_tmp_devagent_home
  # A logging stub backend: one bracketed element per argv word, exit $STUB_RC.
  STUB_DIR="$BATS_TEST_TMPDIR/issue"
  STUB_LOG="$BATS_TEST_TMPDIR/backend.log"
  mkdir -p "$STUB_DIR"
  cat > "$STUB_DIR/github.sh" <<EOF
#!/usr/bin/env bash
line=""; for a in "\$@"; do line+="[\$a] "; done
printf '%s\n' "\${line% }" >> "$STUB_LOG"
exit "\${STUB_RC:-0}"
EOF
  chmod +x "$STUB_DIR/github.sh"
  export DEVAGENT_ISSUE_BACKEND_DIR="$STUB_DIR"
  # The skeleton's shape: issue_workflow names the state, the gate is open.
  cat > "$DA_HOME/config.toml" <<'TOML'
[project.testproj.permissions]
transition_issue = true

[project.testproj.issue_workflow]
on_draft_start = "In Progress"
on_ship        = "In Review"
on_merge       = "Done"
TOML
  # shellcheck source=../scripts/lib/paths.sh
  source "$PLUGIN_ROOT/scripts/lib/paths.sh"
  # shellcheck source=../scripts/lib/io.sh
  source "$PLUGIN_ROOT/scripts/lib/io.sh"
  # shellcheck source=../scripts/lib/config.sh
  source "$PLUGIN_ROOT/scripts/lib/config.sh"
  # shellcheck source=../scripts/lib/transition.sh
  source "$PLUGIN_ROOT/scripts/lib/transition.sh"
}

teardown() { teardown_tmp_devagent_home; }

_append_config() { printf '%s\n' "$@" >> "$DA_HOME/config.toml"; }

@test "stage_map_target: issue_workflow names the target with no table or override (#710)" {
  run stage_map_target github testproj on_ship
  [ "$status" -eq 0 ]
  [ "$output" = "In Review" ]
}

@test "stage_map_target: github_labels overrides issue_workflow per stage (#710)" {
  _append_config '' '[project.testproj.github_labels]' 'on_ship = "review: pending"'
  run stage_map_target github testproj on_ship
  [ "$status" -eq 0 ]
  [ "$output" = "review: pending" ]
  run stage_map_target github testproj on_merge
  [ "$status" -eq 0 ]
  [ "$output" = "Done" ]
}

@test "stage_map_target: gitlab_labels is read for gitlab only (#710)" {
  _append_config '' '[project.testproj.gitlab_labels]' 'on_ship = "status::review"'
  run stage_map_target gitlab testproj on_ship
  [ "$output" = "status::review" ]
  run stage_map_target jira testproj on_ship
  [ "$output" = "In Review" ]
  run stage_map_target github testproj on_ship
  [ "$output" = "In Review" ]
}

@test "stage_map_target: the env override beats both tables (#710)" {
  _append_config '' '[project.testproj.github_labels]' 'on_ship = "review: pending"'
  DEVAGENT_GITHUB_LABEL_ON_SHIP="env-ship" run stage_map_target github testproj on_ship
  [ "$output" = "env-ship" ]
  DEVAGENT_GITLAB_LABELS_ON_SHIP="env-gl" run stage_map_target gitlab testproj on_ship
  [ "$output" = "env-gl" ]
  DEVAGENT_JIRA_STAGE_ON_SHIP="env-jira" run stage_map_target jira testproj on_ship
  [ "$output" = "env-jira" ]
}

@test "stage_map_target: an empty project ignores an ambient DEVAGENT_PROJECT (#710)" {
  DEVAGENT_PROJECT=testproj run stage_map_target github "" on_ship
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "stage_map_target: a non-on_* stage reads no config (#710)" {
  _append_config 'in_progress = "In Progress"' '' '[project.testproj.github_labels]' 'in_progress = "status: wip"'
  run stage_map_target github testproj in_progress
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "stage_map_target on an unparseable config is failed, not unmapped (#710)" {
  printf '[project.testproj\nbroken = \n' > "$DA_HOME/config.toml"
  run stage_map_target github testproj on_ship
  [ "$status" -eq 1 ]
}

@test "stage_map_target: no config file at all is no mapping (#710)" {
  rm -f "$DA_HOME/config.toml"
  run stage_map_target github testproj on_ship
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "stage_map_others: stage order, deduped, target excluded (#710)" {
  # on_merge is a case-only twin of the on_ship target: GitHub names labels
  # case-insensitively, so it is the target there; GitLab compares exactly.
  _append_config '' '[project.testproj.github_labels]' 'on_merge = "in review"' \
    '' '[project.testproj.gitlab_labels]' 'on_merge = "in review"'
  run stage_map_others github testproj on_ship
  [ "$status" -eq 0 ]
  [ "$output" = "In Progress" ]
  run stage_map_others gitlab testproj on_ship
  [ "$output" = $'In Progress\nin review' ]
  # two other stages naming one state print it once
  DEVAGENT_JIRA_STAGE_ON_DRAFT_START="Done" run stage_map_others jira testproj on_ship
  [ "$output" = "Done" ]
}

@test "stage_map_kind: label on github and gitlab, status on jira (#710)" {
  run stage_map_kind github
  [ "$output" = label ]
  run stage_map_kind gitlab
  [ "$output" = label ]
  run stage_map_kind jira
  [ "$output" = status ]
  run stage_map_kind mytracker
  [ "$output" = state ]
}

@test "transition_gate_open: only the literal true opens the gate (#710)" {
  run transition_gate_open testproj
  [ "$status" -eq 0 ]
  printf '%s\n' '[project.other.issue_workflow]' 'on_ship = "x"' > "$DA_HOME/config.toml"
  run transition_gate_open other
  [ "$status" -eq 1 ]
  printf '%s\n' '[project.other.permissions]' 'transition_issue = false' > "$DA_HOME/config.toml"
  run transition_gate_open other
  [ "$status" -eq 1 ]
  printf '%s\n' '[project.other.permissions]' 'transition_issue = "yes"' > "$DA_HOME/config.toml"
  run transition_gate_open other
  [ "$status" -eq 1 ]
}

@test "transition_fire: gated off calls no backend (#710)" {
  sed -i 's/transition_issue = true/transition_issue = false/' "$DA_HOME/config.toml"
  transition_fire draft testproj Issue-1 on_draft_start github acme/x 1 2>"$BATS_TEST_TMPDIR/err"
  [ "$TRANSITION_OUTCOME" = gated ]
  [ ! -e "$STUB_LOG" ]
  grep -qxF "draft: on_draft_start transition for testproj/Issue-1 skipped — permissions.transition_issue not enabled (remote tracker state left unchanged)" "$BATS_TEST_TMPDIR/err"
}

@test "transition_fire: appends --project; rc 0 with a target is landed (#710)" {
  transition_fire ship testproj Issue-1 on_ship github acme/x 1 2>"$BATS_TEST_TMPDIR/err"
  [ "$TRANSITION_OUTCOME" = landed ]
  [ "$TRANSITION_RC" -eq 0 ]
  [ "$TRANSITION_TARGET" = "In Review" ]
  grep -qxF '[transition] [acme/x] [1] [on_ship] [--project] [testproj]' "$STUB_LOG"
  [ ! -s "$BATS_TEST_TMPDIR/err" ]
}

@test "transition_fire: rc 0 without a mapping is unmapped (#710)" {
  sed -i '/^on_ship/d' "$DA_HOME/config.toml"
  transition_fire ship testproj Issue-1 on_ship github acme/x 1
  [ "$TRANSITION_OUTCOME" = unmapped ]
  [ -z "$TRANSITION_TARGET" ]
  grep -qxF '[transition] [acme/x] [1] [on_ship] [--project] [testproj]' "$STUB_LOG"
}

@test "transition_fire: a custom backend with rc 0 and no generic mapping is landed (#710)" {
  cp "$STUB_DIR/github.sh" "$STUB_DIR/mytracker.sh"
  sed -i '/^on_ship/d' "$DA_HOME/config.toml"
  transition_fire ship testproj Issue-1 on_ship mytracker acme/x 1
  [ "$TRANSITION_OUTCOME" = landed ]
  [ -z "$TRANSITION_TARGET" ]
}

@test "transition_fire: a non-zero rc is failed, keeps the rc, and an errexit caller continues (#710)" {
  run env STUB_RC=4 bash -euo pipefail -c '
    source "$1/scripts/lib/paths.sh"; source "$1/scripts/lib/io.sh"
    source "$1/scripts/lib/config.sh"; source "$1/scripts/lib/transition.sh"
    transition_fire sync testproj Issue-1 on_merge github acme/x 1 " — no merge marker written; sync retries it next run"
    echo "outcome=$TRANSITION_OUTCOME rc=$TRANSITION_RC"
    echo CALLER-CONTINUES' _ "$PLUGIN_ROOT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"outcome=failed rc=4"* ]]
  [[ "$output" == *"CALLER-CONTINUES"* ]]
  [[ "$output" == *"warning: on_merge transition failed for testproj/Issue-1 (exit 4) — continuing per spec §11 — no merge marker written; sync retries it next run"* ]]
}

@test "transition_fire: no backend or repo is no-tracker; a non-executable script is no-backend (#710)" {
  transition_fire ship testproj Issue-1 on_ship "" acme/x 1 2>"$BATS_TEST_TMPDIR/err"
  [ "$TRANSITION_OUTCOME" = no-tracker ]
  grep -qxF "ship: no issue tracker configured for Issue-1; skipping on_ship transition" "$BATS_TEST_TMPDIR/err"
  transition_fire ship testproj Issue-1 on_ship github "" 1 2>/dev/null
  [ "$TRANSITION_OUTCOME" = no-tracker ]
  transition_fire ship testproj Issue-1 on_ship nosuch acme/x 1 2>"$BATS_TEST_TMPDIR/err"
  [ "$TRANSITION_OUTCOME" = no-backend ]
  grep -qxF "ship: issue backend $STUB_DIR/nosuch.sh not executable; skipping on_ship transition" "$BATS_TEST_TMPDIR/err"
  [ ! -e "$STUB_LOG" ]
}

@test "transition_plan_note: prints all four forms (#710)" {
  run transition_plan_note testproj on_ship github acme/x
  [ "$output" = '"In Review" on acme/x' ]
  run transition_plan_note testproj on_ship "" ""
  [ "$output" = "skipped (no issue tracker configured)" ]
  sed -i '/^on_ship/d' "$DA_HOME/config.toml"
  run transition_plan_note testproj on_ship github acme/x
  [ "$output" = "skipped (no tracker state mapped)" ]
  sed -i 's/transition_issue = true/transition_issue = false/' "$DA_HOME/config.toml"
  run transition_plan_note testproj on_ship github acme/x
  [ "$output" = "skipped (permissions.transition_issue not enabled)" ]
}
