#!/usr/bin/env bats

load 'helpers/fixtures'

setup() {
  fixture_init volk Issue-676
  stub_chain_recorder
}

@test "two-cycle: comments,revise,comments,revise leaves state revision=3 and 3 ## Revision blocks" {
  stub_mr_comments "$(cat <<'P1'
### @alice · 2026-05-20
first round nit
P1
)"
  run env HOME="$HOME" DEVAGENT_ROOT="$DEVAGENT_ROOT" \
    DEVAGENT_CODE_BACKEND_CMD="$DEVAGENT_CODE_BACKEND_CMD" \
    bash "$DEVAGENT_ROOT/scripts/comments.sh" volk Issue-676
  [ "$status" -eq 0 ]
  [ -f "$FIX_ISSUE_DIR/revisions/r1/comments.md" ]

  run env HOME="$HOME" DEVAGENT_ROOT="$DEVAGENT_ROOT" \
    DEVAGENT_CODE_BACKEND_CMD="$DEVAGENT_CODE_BACKEND_CMD" \
    bash "$DEVAGENT_ROOT/scripts/comments.sh" volk Issue-676
  [ "$status" -eq 0 ]
  [ ! -d "$FIX_ISSUE_DIR/revisions/r2" ]
  [ "$(find "$FIX_ISSUE_DIR/revisions" -name 'comments*' | wc -l)" -eq 1 ]

  run env HOME="$HOME" DEVAGENT_ROOT="$DEVAGENT_ROOT" \
    DEVAGENT_CHAIN_CMD="$DEVAGENT_CHAIN_CMD" \
    bash "$DEVAGENT_ROOT/scripts/revise.sh" volk Issue-676 --no-chain
  [ "$status" -eq 0 ]
  grep -q '^revision[[:space:]]*=[[:space:]]*2$' "$FIX_STATE_FILE"

  stub_mr_comments "$(cat <<'P2'
### @alice · 2026-05-21
second round
### @bob · 2026-05-21
also second round
P2
)"
  run env HOME="$HOME" DEVAGENT_ROOT="$DEVAGENT_ROOT" \
    DEVAGENT_CODE_BACKEND_CMD="$DEVAGENT_CODE_BACKEND_CMD" \
    bash "$DEVAGENT_ROOT/scripts/comments.sh" volk Issue-676
  [ "$status" -eq 0 ]
  [ -f "$FIX_ISSUE_DIR/revisions/r2/comments.md" ]

  run env HOME="$HOME" DEVAGENT_ROOT="$DEVAGENT_ROOT" \
    DEVAGENT_CHAIN_CMD="$DEVAGENT_CHAIN_CMD" \
    bash "$DEVAGENT_ROOT/scripts/revise.sh" volk Issue-676 --no-chain
  [ "$status" -eq 0 ]

  grep -q '^revision[[:space:]]*=[[:space:]]*3$' "$FIX_STATE_FILE"

  [ "$(grep -c '^## Revision ' "$FIX_ISSUE_DIR/checklist.md")" -eq 3 ]
  grep -q '^## Revision 1$' "$FIX_ISSUE_DIR/checklist.md"
  grep -q '^## Revision 2$' "$FIX_ISSUE_DIR/checklist.md"
  grep -q '^## Revision 3$' "$FIX_ISSUE_DIR/checklist.md"

  grep -q 'revise: revision 2 started, 1 comments to address' "$FIX_ISSUE_DIR/checklist.md"
  grep -q 'revise: revision 3 started, 2 comments to address' "$FIX_ISSUE_DIR/checklist.md"

  grep -q "^pending_comments_file[[:space:]]*=[[:space:]]*\"$FIX_ISSUE_DIR/revisions/r2/comments.md\"$" \
    "$FIX_STATE_FILE"
}
