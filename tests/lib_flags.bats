#!/usr/bin/env bats

load 'lib/bats-helpers'

setup() {
  source "$PLUGIN_ROOT/scripts/lib/flags.sh"
  MD="$BATS_TEST_TMPDIR/issue.md"
  cat > "$MD" <<'EOF'
# repo#1 — demo

- State: open

---

Intro prose.

## Workflow flags
tier: oneshot
future-key: something

## Motivation
tier: bogus-in-prose

---

## Comments (1)

### @bob
quoting a block:
## Workflow flags
tier: research
EOF
}

@test "flags_get reads tier from the body flags block (#537)" {
  run flags_get "$MD" tier
  [ "$status" -eq 0 ]
  [ "$output" = "oneshot" ]
}

@test "flags_get ignores a flags block quoted in comments (#537)" {
  MD2="$BATS_TEST_TMPDIR/comment-only.md"
  cat > "$MD2" <<'EOF'
# repo#2 — demo

---

Body with no flags block.

---

## Comments (1)

### @bob
quoting a block:
## Workflow flags
tier: research
EOF
  run flags_get "$MD2" tier
  [ "$status" -ne 0 ]
  [ -z "$output" ]
}

@test "flags_get is key-scoped: unknown keys ride along untouched (#537)" {
  run flags_get "$MD" future-key
  [ "$status" -eq 0 ]
  [ "$output" = "something" ]
}

@test "flags_get returns 1 on missing file or absent block (#537)" {
  run flags_get "$BATS_TEST_TMPDIR/nope.md" tier
  [ "$status" -ne 0 ]
}

@test "tier_is_legal accepts registered tiers, rejects reserved and bogus (#537)" {
  tier_is_legal oneshot
  tier_is_legal docs-only
  run tier_is_legal simple
  [ "$status" -ne 0 ]
  run tier_is_legal ultra
  [ "$status" -ne 0 ]
  run tier_is_legal ../evil
  [ "$status" -ne 0 ]
}
