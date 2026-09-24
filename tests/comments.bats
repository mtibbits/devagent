#!/usr/bin/env bats

load 'helpers/fixtures'

setup() {
  fixture_init volk Issue-676
  stub_mr_comments "$(cat <<'PAYLOAD'
# example/volk#842 — Comments

## Comments (2)

### @alice · 2026-05-20

Please add a test for the boundary case.

### @bob · 2026-05-20

Nit: rename `foo` to `foo_count`.
PAYLOAD
)"
}

run_comments() {
  run env \
    HOME="$HOME" \
    DEVAGENT_ROOT="$DEVAGENT_ROOT" \
    DEVAGENT_CODE_BACKEND_CMD="$DEVAGENT_CODE_BACKEND_CMD" \
    bash "$DEVAGENT_ROOT/scripts/comments.sh" "$@"
}

@test "comments writes revisions/r1/comments.md from stub backend" {
  run_comments volk Issue-676
  [ "$status" -eq 0 ]
  [ -f "$FIX_ISSUE_DIR/revisions/r1/comments.md" ]
  grep -q "alice" "$FIX_ISSUE_DIR/revisions/r1/comments.md"
  grep -q "bob"   "$FIX_ISSUE_DIR/revisions/r1/comments.md"
}

@test "comments with no project arg resolves the active project, not 'default' (#124)" {
  # Bare comments must route through active_resolve_project, not the literal 'default'.
  run env \
    HOME="$HOME" \
    DEVAGENT_ROOT="$DEVAGENT_ROOT" \
    DEVAGENT_CODE_BACKEND_CMD="$DEVAGENT_CODE_BACKEND_CMD" \
    DEVAGENT_ACTIVE_PROJECT=volk \
    bash "$DEVAGENT_ROOT/scripts/comments.sh"
  [ "$status" -eq 0 ]
  [[ "$output" != *"project 'default'"* ]]
  [ -f "$FIX_ISSUE_DIR/revisions/r1/comments.md" ]
}

@test "comments does NOT increment the revision counter" {
  run_comments volk Issue-676
  [ "$status" -eq 0 ]
  grep -q '^revision[[:space:]]*=[[:space:]]*1$' "$FIX_STATE_FILE"
}

@test "comments is idempotent — second run overwrites, never duplicates" {
  run_comments volk Issue-676
  [ "$status" -eq 0 ]
  local first_size
  first_size=$(wc -c <"$FIX_ISSUE_DIR/revisions/r1/comments.md")

  run_comments volk Issue-676
  [ "$status" -eq 0 ]
  local second_size
  second_size=$(wc -c <"$FIX_ISSUE_DIR/revisions/r1/comments.md")

  [ "$first_size" = "$second_size" ]
  local count
  count=$(find "$FIX_ISSUE_DIR/revisions" -name 'comments*' | wc -l)
  [ "$count" -eq 1 ]
}

@test "comments errors when mr_url is missing from state" {
  cat >"$FIX_STATE_FILE" <<EOF
active_issue = "Issue-676"
issue_dir    = "$FIX_ISSUE_DIR"
revision     = 1
EOF
  run_comments volk Issue-676
  [ "$status" -ne 0 ]
  [[ "$output" == *"mr_url"* ]]
  [[ "$output" == *"ship"* ]]
}

@test "comments appends a log entry naming the step" {
  run_comments volk Issue-676
  [ "$status" -eq 0 ]
  grep -q 'comments: fetched' "$FIX_ISSUE_DIR/checklist.md"
}

@test "comments log entry lands inside the Log section after a revision block (#75)" {
  # A later revision block sits after ## Log; the log entry must still go in-section.
  cat >> "$FIX_ISSUE_DIR/checklist.md" <<'EOF'

## Revision 2

- [ ]  2. draft
EOF
  run_comments volk Issue-676
  [ "$status" -eq 0 ]
  local logln revln
  logln="$(grep -n 'comments: fetched' "$FIX_ISSUE_DIR/checklist.md" | head -1 | cut -d: -f1)"
  revln="$(grep -n '^## Revision 2' "$FIX_ISSUE_DIR/checklist.md" | head -1 | cut -d: -f1)"
  [ "$logln" -lt "$revln" ]
}

@test "comments cleans up the partial file when backend exits non-zero" {
  cat >"$DEVAGENT_CODE_BACKEND_CMD" <<'EOF'
#!/usr/bin/env bash
echo "boom" >&2
exit 7
EOF
  chmod +x "$DEVAGENT_CODE_BACKEND_CMD"

  run_comments volk Issue-676
  [ "$status" -ne 0 ]
  [ ! -f "$FIX_ISSUE_DIR/revisions/r1/comments.md" ]
}

# #592: real code/github.sh behind comments.sh, with only `gh` stubbed.
_gh_review_stub() {
  local bin="$BATS_TEST_TMPDIR/ghbin"; mkdir -p "$bin"
  cat >"$bin/gh" <<'EOF'
#!/usr/bin/env bash
filter=""; prev=""; for a in "$@"; do [ "$prev" = "--jq" ] && filter="$a"; prev="$a"; done
if [ "$1" = api ]; then
  printf '%s' '[{"user":{"login":"jdemel"},"created_at":"2026-09-11T19:24:33Z","path":"kernels/x.h","line":324,"original_line":334,"body":"Use the fast path."}]' | jq -r "$filter"
else
  printf '%s' '{"comments":[],"reviews":[{"author":{"login":"jdemel"},"state":"COMMENTED","submittedAt":"2026-09-11T19:24:51Z","body":""}]}' | jq -r "$filter"
fi
EOF
  chmod +x "$bin/gh"
  echo "$bin/gh"
}

@test "comments captures an inline review comment on a PR with no conversation comments (#592)" {
  local gh; gh="$(_gh_review_stub)"
  run env HOME="$HOME" DEVAGENT_ROOT="$DEVAGENT_ROOT" \
    DEVAGENT_CODE_BACKEND_CMD="$DEVAGENT_ROOT/scripts/code/github.sh" \
    DEVAGENT_GH="$gh" \
    bash "$DEVAGENT_ROOT/scripts/comments.sh" volk Issue-676
  [ "$status" -eq 0 ]
  local f="$FIX_ISSUE_DIR/revisions/r1/comments.md"
  grep -qx '## Comments (1)' "$f"
  grep -qx '### @jdemel · 2026-09-11 · kernels/x.h:324' "$f"
  grep -qx 'Use the fast path.' "$f"
  [[ "$output" == *"(1 comments)"* ]]
}
