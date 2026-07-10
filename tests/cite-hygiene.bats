#!/usr/bin/env bats
# #342: command/skill docs must cite templates by the §12-resolution prose
# ("the resolved `<key>.md` (§12 registry: project paths → devdoc → plugin
# default)"), NOT a bare `${CLAUDE_PLUGIN_ROOT}/templates/<key>.md` path — a
# bare-path cite steers a reader to hand-edit the shared plugin copy (the #136
# failure mode) instead of creating a project/devdoc override.

REPO="${BATS_TEST_DIRNAME}/.."

@test "no bare plugin-path template cite outside the allowlist (#342)" {
  run grep -rnE 'CLAUDE_PLUGIN_ROOT\}/templates/' "$REPO/commands" "$REPO/skills"
  # rc 0 = matches (expected: the allowlisted ones); rc 1 = none; rc 2 = grep
  # error (dir renamed/unreadable) which a bare `-ne 0` would false-pass.
  [ "$status" -ne 2 ] || { echo "grep error over commands/ or skills/:" >&2; echo "$output" >&2; return 1; }

  # Allowlist: core-document-actual-work's actualWork_template.md cites are the
  # §12-chain terminal owned by the sibling bypass issue (#341) — intentional.
  # Match on file AND template name (drift-proof — no line numbers), so BOTH a
  # bare cite for a different key IN that file AND an actualWork_template.md cite
  # in ANY OTHER file are still caught.
  local unallowed
  unallowed="$(printf '%s\n' "$output" \
    | grep -vE 'core-document-actual-work/SKILL\.md:[0-9]+:.*actualWork_template\.md' || true)"

  [ -z "$unallowed" ] || {
    echo "bare \${CLAUDE_PLUGIN_ROOT}/templates/ cites (rephrase to §12 prose):" >&2
    echo "$unallowed" >&2
    return 1
  }
}
