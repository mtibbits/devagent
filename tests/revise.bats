#!/usr/bin/env bats

load 'helpers/fixtures'

setup() {
  fixture_init volk Issue-676
  # Seed a prior revision's comments.md so revise can proceed.
  mkdir -p "$FIX_ISSUE_DIR/revisions/r1"
  cat >"$FIX_ISSUE_DIR/revisions/r1/comments.md" <<'EOF'
# example/volk#842 — Comments

## Comments (3)

### @alice · 2026-05-20
nit
### @bob · 2026-05-20
nit
### @carol · 2026-05-21
nit
EOF
  stub_chain_recorder
}

run_revise() {
  run env \
    HOME="$HOME" \
    DEVAGENT_ROOT="$DEVAGENT_ROOT" \
    DEVAGENT_CHAIN_CMD="$DEVAGENT_CHAIN_CMD" \
    bash "$DEVAGENT_ROOT/scripts/revise.sh" "$@"
}

@test "revise increments revision from 1 to 2 in state" {
  run_revise volk Issue-676 --no-chain
  [ "$status" -eq 0 ]
  grep -q '^revision[[:space:]]*=[[:space:]]*2$' "$FIX_STATE_FILE"
}

@test "revise creates revisions/r2 directory" {
  run_revise volk Issue-676 --no-chain
  [ "$status" -eq 0 ]
  [ -d "$FIX_ISSUE_DIR/revisions/r2" ]
}

@test "revise appends a new ## Revision 2 block to checklist.md" {
  run_revise volk Issue-676 --no-chain
  [ "$status" -eq 0 ]
  grep -q '^## Revision 2$' "$FIX_ISSUE_DIR/checklist.md"
  grep -q '\[ \]  1\. draft' "$FIX_ISSUE_DIR/checklist.md"
  grep -q '\[ \] 15\. ship' "$FIX_ISSUE_DIR/checklist.md"
}

@test "revise preserves the original ## Revision 1 block" {
  run_revise volk Issue-676 --no-chain
  [ "$status" -eq 0 ]
  grep -q '^## Revision 1$' "$FIX_ISSUE_DIR/checklist.md"
  [ "$(grep -c '^## Revision ' "$FIX_ISSUE_DIR/checklist.md")" -eq 2 ]
}

@test "revise records the previous revision's comments as pending_comments_file" {
  run_revise volk Issue-676 --no-chain
  [ "$status" -eq 0 ]
  grep -q "^pending_comments_file[[:space:]]*=[[:space:]]*\"$FIX_ISSUE_DIR/revisions/r1/comments.md\"$" \
    "$FIX_STATE_FILE"
}

@test "revise logs the revision start with the comment count" {
  run_revise volk Issue-676 --no-chain
  [ "$status" -eq 0 ]
  grep -q 'revise: revision 2 started, 3 comments to address' "$FIX_ISSUE_DIR/checklist.md"
}

@test "revise errors when revisions/r<N>/comments.md is missing" {
  rm -f "$FIX_ISSUE_DIR/revisions/r1/comments.md"
  run_revise volk Issue-676 --no-chain
  [ "$status" -ne 0 ]
  [[ "$output" == *"/devagent:comments"* ]]
  grep -q '^revision[[:space:]]*=[[:space:]]*1$' "$FIX_STATE_FILE"
}

@test "revise chains to /devagent:next by default" {
  run_revise volk Issue-676
  [ "$status" -eq 0 ]
  [ -f "$BATS_TEST_TMPDIR/chain.log" ]
  grep -q '/devagent:next' "$BATS_TEST_TMPDIR/chain.log"
}

@test "revise does NOT chain when --no-chain is passed" {
  run_revise volk Issue-676 --no-chain
  [ "$status" -eq 0 ]
  [ ! -f "$BATS_TEST_TMPDIR/chain.log" ]
}

@test "monotonic counter — two revisions advances 1->2->3" {
  run_revise volk Issue-676 --no-chain
  [ "$status" -eq 0 ]
  cp "$FIX_ISSUE_DIR/revisions/r1/comments.md" "$FIX_ISSUE_DIR/revisions/r2/comments.md"
  run_revise volk Issue-676 --no-chain
  [ "$status" -eq 0 ]
  grep -q '^revision[[:space:]]*=[[:space:]]*3$' "$FIX_STATE_FILE"
  [ "$(grep -c '^## Revision ' "$FIX_ISSUE_DIR/checklist.md")" -eq 3 ]
}

@test "revise writes pending_comments_file top-level, not under [parked] (#97)" {
  # Append a [parked] table. The old EOF-append writer lands a not-found key INSIDE it
  # → pending_comments_file becomes parked.pending_comments_file (a bogus parked issue
  # to status/where/resume). The canonical state_set must place it top-level.
  cat >>"$FIX_STATE_FILE" <<'PARKED'

[parked]
Issue-999 = "2026-06-01T00:00:00Z"
PARKED
  run_revise volk Issue-676 --no-chain
  [ "$status" -eq 0 ]
  # pending_comments_file is a TOP-LEVEL key: it appears BEFORE the [parked] header.
  pcf=$(grep -n '^pending_comments_file' "$FIX_STATE_FILE" | head -1 | cut -d: -f1)
  parked=$(grep -n '^\[parked\]' "$FIX_STATE_FILE" | head -1 | cut -d: -f1)
  [ -n "$pcf" ]
  [ -n "$parked" ]
  [ "$pcf" -lt "$parked" ]
  # the real parked entry survives; nothing masquerades inside [parked].
  grep -q '^Issue-999 = ' "$FIX_STATE_FILE"
}
