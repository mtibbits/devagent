#!/usr/bin/env bats
# #458: the dedicated checker agents for steps 14 (redmr) and 21 (preship).
#
# These agents are the STRUCTURAL half of fresh-context checking: the isolation
# is enforced by the harness (tool denial + pinned model + system prompt) rather
# than depending on the model choosing to spawn a generic subagent correctly.
# The named failure mode is silently-ignored frontmatter — `claude plugin
# validate --strict` never opens these files (verified 2.1.211), so these
# canaries plus the live smoke test are the only gates. Field spellings are
# probe-verified: agents take `disallowedTools` (camelCase); the hyphenated
# `disallowed-tools` is the SKILL.md spelling and is silently ignored here.

load 'lib/bats-helpers'

REPO="${BATS_TEST_DIRNAME}/.."
PRESHIP="$REPO/agents/preship-verifier.md"
REDTEAM="$REPO/agents/redteam-reviewer.md"

# Read each frontmatter ONCE per test rather than re-awking per assertion.
setup() {
    FM_PRESHIP="$(skill_frontmatter "$PRESHIP")"
    FM_REDTEAM="$(skill_frontmatter "$REDTEAM")"
}

@test "both checker agents exist at the plugin's auto-discovered agents/ root (#458)" {
  # agents/ is scanned by default; plugin.json must NOT gain an "agents" key —
  # that REPLACES the default scan rather than adding to it.
  [ -s "$PRESHIP" ]
  [ -s "$REDTEAM" ]
  run grep -c '"agents"' "$REPO/.claude-plugin/plugin.json"
  [ "$output" -eq 0 ]
}

@test "agent identity comes from name: frontmatter and matches its binding (#458)" {
  run grep -c '^name: preship-verifier$' <<<"$FM_PRESHIP"
  [ "$output" -eq 1 ]
  run grep -c '^name: redteam-reviewer$' <<<"$FM_REDTEAM"
  [ "$output" -eq 1 ]
  # The skills bind these exact names; a typo'd agent: silently falls back to
  # general-purpose (no system prompt, no tool denial, no isolation).
  run grep -c '^agent: devagent:preship-verifier$' "$REPO/skills/core-preship/SKILL.md"
  [ "$output" -eq 1 ]
  run grep -c '^agent: devagent:redteam-reviewer$' "$REPO/skills/core-redmr/SKILL.md"
  [ "$output" -eq 1 ]
}

@test "both checker agents deny Write/Edit with the camelCase agent spelling (#458)" {
  local fm
  for fm in "$FM_PRESHIP" "$FM_REDTEAM"; do
    run grep -c '^disallowedTools:' <<<"$fm"
    [ "$output" -eq 1 ] || { echo "no disallowedTools in: $fm" >&2; false; }
    grep -qE '^disallowedTools:.*\bWrite\b' <<<"$fm"
    grep -qE '^disallowedTools:.*\bEdit\b' <<<"$fm"
    # The hyphenated skill spelling here would be silently ignored — the exact
    # failure mode this issue exists to close.
    run grep -c '^disallowed-tools:' <<<"$fm"
    [ "$output" -eq 0 ] || { echo "uses the SKILL spelling (silently ignored on agents)" >&2; false; }
  done
}

@test "both checker agents pin model and effort (#458)" {
  local fm
  for fm in "$FM_PRESHIP" "$FM_REDTEAM"; do
    grep -qE '^model:[[:space:]]+(opus|sonnet|haiku|fable|claude-[a-z0-9.-]+)$' <<<"$fm"
    grep -qE '^effort:[[:space:]]+(low|medium|high|xhigh|max)$' <<<"$fm"
  done
}

@test "preship-verifier names all five verifications (#458)" {
  grep -qi 'acceptance criteria' "$PRESHIP"
  grep -qi 'findings applied' "$PRESHIP"
  grep -qi 'push preview' "$PRESHIP"
  grep -qi 'evidence cross-check' "$PRESHIP"
  grep -qi 'spec-touch' "$PRESHIP"
}

@test "redteam-reviewer carries the severity taxonomy and template precedence (#458)" {
  local t
  for t in '[BLOCKING]' '[MAJOR]' '[MINOR]' '[INFO]'; do
    grep -qF "$t" "$REDTEAM" || { echo "missing severity tag: $t" >&2; false; }
  done
  # §12 registry stays authoritative for WHAT to attack; this file owns OUTPUT.
  grep -qF 'redteam_mr' "$REDTEAM"
  grep -qi 'authority for WHAT to attack' "$REDTEAM"
  # The statusreport-parsed count line is contract.
  grep -qF 'B blocking, M major, m minor, I info' "$REDTEAM"
}

@test "both checker agents return the artifact instead of writing it (#458)" {
  local f
  for f in "$PRESHIP" "$REDTEAM"; do
    grep -qi 'cannot write files' "$f"
    grep -qi 'final message' "$f"
    # context: subagent is the linter's required token; a fork must never stamp
    # 'context: fork' into an artifact header.
    grep -qF 'context: subagent' "$f"
    grep -qi 'never .*context: fork' "$f"
  done
}
