#!/usr/bin/env bats

load 'lib/bats-helpers'

setup() {
  setup_tmp_devagent_home
  # Put stub gh on PATH
  STUB_BIN="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$STUB_BIN"
  cp "$PLUGIN_ROOT/tests/fixtures/gh-stub" "$STUB_BIN/gh"
  chmod +x "$STUB_BIN/gh"
  export PATH="$STUB_BIN:$PATH"
  export GH_STUB_CASE="standard"
}

teardown() { teardown_tmp_devagent_home; }

@test "fetch prints the spec-shaped markdown" {
  run "$PLUGIN_ROOT/scripts/issue/github.sh" fetch gnuradio/volk 676
  [ "$status" -eq 0 ]
  [[ "$output" == *"# gnuradio/volk#676 — Demo issue title"* ]]
  [[ "$output" == *"- State: open"* ]]
  [[ "$output" == *"- Author: @alice"* ]]
  [[ "$output" == *"- Labels: bug, performance"* ]]
  [[ "$output" == *"- URL: https://github.com/gnuradio/volk/issues/676"* ]]
  [[ "$output" == *"Body line one."* ]]
  [[ "$output" == *"## Comments (1)"* ]]
  [[ "$output" == *"### @bob · 2026-05-12"* ]]
  [[ "$output" == *"First comment."* ]]
}

@test "fetch with zero comments still prints Comments (0) header" {
  export GH_STUB_CASE="nocomments"
  run "$PLUGIN_ROOT/scripts/issue/github.sh" fetch gnuradio/volk 676
  [ "$status" -eq 0 ]
  [[ "$output" == *"## Comments (0)"* ]]
}

@test "fetch propagates gh failure" {
  export GH_STUB_CASE="fail"
  run "$PLUGIN_ROOT/scripts/issue/github.sh" fetch gnuradio/volk 999
  [ "$status" -ne 0 ]
  [[ "$output" == *"gh issue view failed"* ]]
}

@test "fetch ignores gh stderr notices on success (#86)" {
  export GH_STUB_CASE="noisy"
  run "$PLUGIN_ROOT/scripts/issue/github.sh" fetch gnuradio/volk 676
  [ "$status" -eq 0 ]
  [[ "$output" == *"# gnuradio/volk#676 — Demo issue title"* ]]
  [[ "$output" == *"## Comments (1)"* ]]
  [[ "$output" != *"new release of gh"* ]]   # notice must not leak into output
}

@test "state ignores gh stderr notices on success (#86)" {
  export GH_STUB_CASE="noisy"
  run "$PLUGIN_ROOT/scripts/issue/github.sh" state gnuradio/volk 676
  [ "$status" -eq 0 ]
  [ "$output" = "open" ]
}

@test "comment-list ignores gh stderr notices on success (#86)" {
  export GH_STUB_CASE="noisy"
  run "$PLUGIN_ROOT/scripts/issue/github.sh" comment-list gnuradio/volk 676
  [ "$status" -eq 0 ]
  [[ "$output" == *"## Comments (1)"* ]]
  [[ "$output" == *"First comment."* ]]
  [[ "$output" != *"new release of gh"* ]]
}

@test "create returns the bare issue number, not the URL (#27)" {
  # Real gh prints the new issue's URL; the backend contract is a bare number.
  echo body > "$BATS_TEST_TMPDIR/body.md"
  run "$PLUGIN_ROOT/scripts/issue/github.sh" create gnuradio/volk "title" "$BATS_TEST_TMPDIR/body.md"
  [ "$status" -eq 0 ]
  [ "$output" = "85" ]
}

@test "create fails loudly when gh output has no parseable number (#27)" {
  export GH_STUB_CREATE_URL="not-a-url"
  echo body > "$BATS_TEST_TMPDIR/body.md"
  run "$PLUGIN_ROOT/scripts/issue/github.sh" create gnuradio/volk "title" "$BATS_TEST_TMPDIR/body.md"
  [ "$status" -ne 0 ]
  [[ "$output" == *"could not parse"* ]]   # pin to the numeric-guard branch, not any non-zero exit
}

@test "create returns the bare number via the inline-body path (empty body file) (#27)" {
  # Empty body_file → cmd_create's inline --body "" branch; still returns the number.
  run "$PLUGIN_ROOT/scripts/issue/github.sh" create gnuradio/volk "title" ""
  [ "$status" -eq 0 ]
  [ "$output" = "85" ]
}

@test "create fails when a non-empty body file does not exist (#89)" {
  run "$PLUGIN_ROOT/scripts/issue/github.sh" create gnuradio/volk "title" /tmp/does-not-exist-89
  [ "$status" -eq 2 ]
  [[ "$output" == *"body file not found"* ]]
}

@test "create forwards --label to gh (#89)" {
  echo body > "$BATS_TEST_TMPDIR/body.md"
  export GH_STUB_ARGS_LOG="$BATS_TEST_TMPDIR/gh-args"
  run "$PLUGIN_ROOT/scripts/issue/github.sh" create gnuradio/volk "title" "$BATS_TEST_TMPDIR/body.md" --label audit --label priority
  [ "$status" -eq 0 ]
  [ "$output" = "85" ]
  grep -q -- '--label audit' "$GH_STUB_ARGS_LOG"
  grep -q -- '--label priority' "$GH_STUB_ARGS_LOG"
}

@test "create rejects an unknown arg (#89)" {
  echo body > "$BATS_TEST_TMPDIR/body.md"
  run "$PLUGIN_ROOT/scripts/issue/github.sh" create gnuradio/volk "title" "$BATS_TEST_TMPDIR/body.md" --bogus x
  [ "$status" -eq 2 ]
}

@test "unknown verb returns 2 (usage error per spec 9.1 contract)" {
  run "$PLUGIN_ROOT/scripts/issue/github.sh" nonsense
  [ "$status" -eq 2 ]
}

# ---- #710 (supersedes #87's block): transitions write the configured mapping ----
# The gh-stub logs `issue view`, `issue edit` and `label list` to GH_STUB_ARGV_LOG
# one bracketed element per argv word, so a test asserts the exact native write
# at gh's boundary: which label is added, which are removed, and that a missing
# label is never created. The project arrives as `--project`, never through an
# ambient DEVAGENT_PROJECT.

# The skeleton's config shape (templates/config.toml.skel): issue_workflow
# names a label on GitHub; no github_labels table, no env override.
_write_skeleton_config() {
  cat > "$DA_HOME/config.toml" <<TOML
[project.testproj.issue_workflow]
on_draft_start = "In Progress"
on_ship        = "In Review"
on_merge       = "Done"

[project.other.issue_workflow]
on_ship = "WRONG"
TOML
}

_transition_setup() {
  _write_skeleton_config
  export GH_STUB_ARGV_LOG="$BATS_TEST_TMPDIR/gh-argv"
  : > "$GH_STUB_ARGV_LOG"
  # The repo's labels: the three stage labels, a lookalike and a non-stage one.
  export GH_STUB_REPO_LABELS='[{"name":"In Progress"},{"name":"In Review"},{"name":"Done"},{"name":"In Review (old)"},{"name":"bug"}]'
}

# _assert_stage_write <stage> <issue-labels-json> <expected edit line>
_assert_stage_write() {
  _transition_setup
  export GH_STUB_LABELS_JSON="$2"
  run "$PLUGIN_ROOT/scripts/issue/github.sh" transition gnuradio/volk 676 "$1" --project testproj
  [ "$status" -eq 0 ]
  grep -qxF "$3" "$GH_STUB_ARGV_LOG"
  # bug is not a stage label, and an absent stage label is never named
  run grep -F '[--remove-label] [bug]' "$GH_STUB_ARGV_LOG"
  [ "$status" -eq 1 ]
}

@test "transition on_draft_start: the skeleton mapping adds the label and removes present stage labels (#710)" {
  _assert_stage_write on_draft_start '[{"name":"Done"},{"name":"bug"}]' \
    '[issue] [edit] [676] [--repo] [gnuradio/volk] [--add-label] [In Progress] [--remove-label] [Done]'
  run grep -F '[--remove-label] [In Review]' "$GH_STUB_ARGV_LOG"
  [ "$status" -eq 1 ]
}

@test "transition on_ship: the skeleton mapping adds the label and removes present stage labels (#710)" {
  _assert_stage_write on_ship '[{"name":"In Progress"},{"name":"bug"}]' \
    '[issue] [edit] [676] [--repo] [gnuradio/volk] [--add-label] [In Review] [--remove-label] [In Progress]'
  run grep -F '[--remove-label] [Done]' "$GH_STUB_ARGV_LOG"
  [ "$status" -eq 1 ]
}

@test "transition on_merge: the skeleton mapping adds the label and removes present stage labels (#710)" {
  _assert_stage_write on_merge '[{"name":"In Review"},{"name":"bug"}]' \
    '[issue] [edit] [676] [--repo] [gnuradio/volk] [--add-label] [Done] [--remove-label] [In Review]'
  run grep -F '[--remove-label] [In Progress]' "$GH_STUB_ARGV_LOG"
  [ "$status" -eq 1 ]
}

@test "transition: an ambient DEVAGENT_PROJECT never picks the mapping (#710)" {
  _transition_setup
  export GH_STUB_LABELS_JSON='[{"name":"bug"}]'
  # (a) ambient `other` maps WRONG; the explicit --project wins
  DEVAGENT_PROJECT=other run "$PLUGIN_ROOT/scripts/issue/github.sh" transition gnuradio/volk 676 on_ship --project testproj
  [ "$status" -eq 0 ]
  grep -qxF '[issue] [edit] [676] [--repo] [gnuradio/volk] [--add-label] [In Review]' "$GH_STUB_ARGV_LOG"
  run grep -F 'WRONG' "$GH_STUB_ARGV_LOG"
  [ "$status" -eq 1 ]
  # (b) ambient `testproj` without --project reads no config: no gh call at all
  : > "$GH_STUB_ARGV_LOG"
  DEVAGENT_PROJECT=testproj run "$PLUGIN_ROOT/scripts/issue/github.sh" transition gnuradio/volk 676 on_ship
  [ "$status" -eq 0 ]
  [ ! -s "$GH_STUB_ARGV_LOG" ]
  [[ "$output" == *"github.sh: no tracker state mapped for 'on_ship' (no --project: only DEVAGENT_GITHUB_LABEL_ON_SHIP is read); transition skipped"* ]]
}

@test "transition: an unmapped stage warns once, exits 0, makes no gh call (#710)" {
  _transition_setup
  run "$PLUGIN_ROOT/scripts/issue/github.sh" transition gnuradio/volk 676 on_merge --project other
  [ "$status" -eq 0 ]
  [ ! -s "$GH_STUB_ARGV_LOG" ]
  [ "$output" = "github.sh: no tracker state mapped for 'on_merge' (project other); transition skipped" ]
}

@test "transition: a missing mapped label exits 4 naming it; no edit, no create (#710)" {
  _transition_setup
  # "In Review" is gone; only its lookalike remains — a substring match must not pass
  export GH_STUB_REPO_LABELS='[{"name":"In Progress"},{"name":"Done"},{"name":"In Review (old)"}]'
  export GH_STUB_LABELS_JSON='[{"name":"In Progress"}]'
  run "$PLUGIN_ROOT/scripts/issue/github.sh" transition gnuradio/volk 676 on_ship --project testproj
  [ "$status" -eq 4 ]
  [[ "$output" == *"github.sh: label 'In Review' (on_ship) not found on gnuradio/volk; devagent does not create labels — create it or change the mapping"* ]]
  run grep -F '[issue] [edit]' "$GH_STUB_ARGV_LOG"
  [ "$status" -eq 1 ]
  grep -qF '[label] [list]' "$GH_STUB_ARGV_LOG"
}

@test "transition: the target already present with a stale stage label still removes it (#710 review)" {
  _assert_stage_write on_ship '[{"name":"In Review"},{"name":"In Progress"}]' \
    '[issue] [edit] [676] [--repo] [gnuradio/volk] [--add-label] [In Review] [--remove-label] [In Progress]'
}

@test "transition: already in the target state makes no edit (#710)" {
  _transition_setup
  export GH_STUB_LABELS_JSON='[{"name":"in review"},{"name":"bug"}]'
  run "$PLUGIN_ROOT/scripts/issue/github.sh" transition gnuradio/volk 676 on_ship --project testproj
  [ "$status" -eq 0 ]
  # the issue WAS read (the mapping resolved), and that read found nothing to do
  grep -qxF '[issue] [view] [676] [--repo] [gnuradio/volk] [--json] [labels]' "$GH_STUB_ARGV_LOG"
  run grep -F '[issue] [edit]' "$GH_STUB_ARGV_LOG"
  [ "$status" -eq 1 ]
}

@test "transition: a 403 from issue edit exits 1 (#710)" {
  _transition_setup
  export GH_STUB_LABELS_JSON='[{"name":"bug"}]'
  export GH_STUB_EDIT_FAIL=403
  run "$PLUGIN_ROOT/scripts/issue/github.sh" transition gnuradio/volk 676 on_ship --project testproj
  [ "$status" -eq 1 ]
  [[ "$output" == *"HTTP 403"* ]]
}

@test "transition: issue 401 exits 1 before any edit (#710)" {
  _transition_setup
  run "$PLUGIN_ROOT/scripts/issue/github.sh" transition gnuradio/volk 401 on_ship --project testproj
  [ "$status" -eq 1 ]
  [[ "$output" == *"HTTP 401"* ]]
  run grep -F '[issue] [edit]' "$GH_STUB_ARGV_LOG"
  [ "$status" -eq 1 ]
}

@test "transition: a failed label lookup exits 1, not 4 (#710)" {
  _transition_setup
  export GH_STUB_LABELS_JSON='[{"name":"bug"}]'
  export GH_STUB_LABEL_LIST_FAIL=1
  run "$PLUGIN_ROOT/scripts/issue/github.sh" transition gnuradio/volk 676 on_ship --project testproj
  [ "$status" -eq 1 ]
  run grep -F '[issue] [edit]' "$GH_STUB_ARGV_LOG"
  [ "$status" -eq 1 ]
}

@test "transition: an absent stage label is never named for removal (#710)" {
  _transition_setup
  export GH_STUB_LABELS_JSON='[{"name":"bug"}]'
  run "$PLUGIN_ROOT/scripts/issue/github.sh" transition gnuradio/volk 676 on_merge --project testproj
  [ "$status" -eq 0 ]
  grep -qxF '[issue] [edit] [676] [--repo] [gnuradio/volk] [--add-label] [Done]' "$GH_STUB_ARGV_LOG"
  run grep -F -- '--remove-label' "$GH_STUB_ARGV_LOG"
  [ "$status" -eq 1 ]
}

@test "transition: DEVAGENT_GITHUB_LABEL_ON_SHIP env overrides config (#87, #710)" {
  _transition_setup
  export GH_STUB_LABELS_JSON='[{"name":"bug"}]'
  export GH_STUB_REPO_LABELS='[{"name":"env-ship"}]'
  export DEVAGENT_GITHUB_LABEL_ON_SHIP="env-ship"
  run "$PLUGIN_ROOT/scripts/issue/github.sh" transition gnuradio/volk 676 on_ship --project testproj
  [ "$status" -eq 0 ]
  grep -qF '[--add-label] [env-ship]' "$GH_STUB_ARGV_LOG"
}

@test "transition: the built-in in_progress default is retired (#710)" {
  _transition_setup
  run "$PLUGIN_ROOT/scripts/issue/github.sh" transition gnuradio/volk 676 in_progress --project testproj
  [ "$status" -eq 0 ]
  [ ! -s "$GH_STUB_ARGV_LOG" ]
}

@test "transition: a missing or empty --project value, --project=x, or an unknown flag exits 2 (#710)" {
  _transition_setup
  run "$PLUGIN_ROOT/scripts/issue/github.sh" transition gnuradio/volk 676 on_ship --project
  [ "$status" -eq 2 ]
  run "$PLUGIN_ROOT/scripts/issue/github.sh" transition gnuradio/volk 676 on_ship --project ""
  [ "$status" -eq 2 ]
  run "$PLUGIN_ROOT/scripts/issue/github.sh" transition gnuradio/volk 676 on_ship --project=testproj
  [ "$status" -eq 2 ]
  run "$PLUGIN_ROOT/scripts/issue/github.sh" transition gnuradio/volk 676 on_ship --bogus
  [ "$status" -eq 2 ]
  run "$PLUGIN_ROOT/scripts/issue/github.sh" transition gnuradio/volk 676
  [ "$status" -eq 2 ]
  [ ! -s "$GH_STUB_ARGV_LOG" ]
}

@test "state-exists: 0 for a case-insensitive exact match, 4 when absent, 1 when gh fails (#710)" {
  _transition_setup
  run "$PLUGIN_ROOT/scripts/issue/github.sh" state-exists gnuradio/volk "in review"
  [ "$status" -eq 0 ]
  # a substring of "In Review" and of its lookalike is not a match
  run "$PLUGIN_ROOT/scripts/issue/github.sh" state-exists gnuradio/volk "Review"
  [ "$status" -eq 4 ]
  export GH_STUB_LABEL_LIST_FAIL=1
  run "$PLUGIN_ROOT/scripts/issue/github.sh" state-exists gnuradio/volk "In Review"
  [ "$status" -eq 1 ]
  run "$PLUGIN_ROOT/scripts/issue/github.sh" state-exists gnuradio/volk
  [ "$status" -eq 2 ]
}

@test "transition: no executable 'gh label create' introduced (#87 scope guard)" {
  # Label creation (#87's Option 3) stays deferred: devagent never creates a
  # label. Lock that against drift.
  run grep -nE '^[[:space:]]*gh[[:space:]]+label[[:space:]]+create' \
    "$PLUGIN_ROOT/scripts/issue/github.sh"
  [ "$status" -eq 1 ]
}

@test "transition: a comma in a stale stage label the issue does not carry blocks nothing (#710 red-team)" {
  _transition_setup
  export DEVAGENT_GITHUB_LABEL_ON_MERGE="done, shipped"
  export GH_STUB_LABELS_JSON='[{"name":"In Progress"},{"name":"bug"}]'
  run "$PLUGIN_ROOT/scripts/issue/github.sh" transition gnuradio/volk 676 on_ship --project testproj
  [ "$status" -eq 0 ]
  grep -qxF '[issue] [edit] [676] [--repo] [gnuradio/volk] [--add-label] [In Review] [--remove-label] [In Progress]' "$GH_STUB_ARGV_LOG"
}

@test "transition: a stale stage label the issue carries is refused when it holds a comma (#710 red-team)" {
  _transition_setup
  export DEVAGENT_GITHUB_LABEL_ON_MERGE="done, shipped"
  export GH_STUB_LABELS_JSON='[{"name":"done, shipped"}]'
  run "$PLUGIN_ROOT/scripts/issue/github.sh" transition gnuradio/volk 676 on_ship --project testproj
  [ "$status" -eq 1 ]
  [[ "$output" == *"github.sh: stage label 'done, shipped' on the issue contains a comma, which gh splits into two labels; rename it or change the mapping"* ]]
  run grep -F '[issue] [edit]' "$GH_STUB_ARGV_LOG"
  [ "$status" -eq 1 ]
}

@test "transition: a mapped label containing a comma is refused, never split by gh (#710 review)" {
  # gh's --add-label/--remove-label are comma-separated lists, so "a, b" would
  # reach GitHub as two labels — a wrong write on the tracker.
  _transition_setup
  export GH_STUB_LABELS_JSON='[{"name":"bug"}]'
  export GH_STUB_REPO_LABELS='[{"name":"review, pending"}]'
  export DEVAGENT_GITHUB_LABEL_ON_SHIP="review, pending"
  run "$PLUGIN_ROOT/scripts/issue/github.sh" transition gnuradio/volk 676 on_ship --project testproj
  [ "$status" -eq 1 ]
  [[ "$output" == *"github.sh: label 'review, pending' (on_ship) contains a comma, which gh splits into two labels; rename it or change the mapping"* ]]
  run grep -F '[issue] [edit]' "$GH_STUB_ARGV_LOG"
  [ "$status" -eq 1 ]
}
