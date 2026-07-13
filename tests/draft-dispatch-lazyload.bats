#!/usr/bin/env bats
# #441: the #284 dispatch contract is loaded conditionally. Its full text lives in
# docs/draft-dispatch-contract.md and is read only when dispatch can fire; the
# draft.md stub carries only a pointer + BOTH load conditions. These guards ensure
# the contract wasn't silently truncated on the move and that the stub can't drop a
# load condition (which would make the operator-instructed / empty-tier dispatch
# path run without the contract).

REPO="${BATS_TEST_DIRNAME}/.."
DRAFT="$REPO/commands/draft.md"
CONTRACT="$REPO/docs/draft-dispatch-contract.md"

@test "the extracted contract file exists and carries the full #284 contract (#441)" {
  [ -f "$CONTRACT" ] || { echo "missing $CONTRACT" >&2; return 1; }
  # All 7 numbered rules present (the contract must not be truncated on the move).
  local rule
  for rule in \
    '1\. \*\*When to dispatch' \
    '2\. \*\*Package intent to disk' \
    '3\. \*\*Question-return protocol' \
    '4\. \*\*Round overwrite exemption' \
    '5\. \*\*Provenance header' \
    '6\. \*\*Finalization is the MAIN' \
    '7\. \*\*Generalization note'; do
    run grep -qE "$rule" "$CONTRACT"
    [ "$status" -eq 0 ] || { echo "contract missing rule: /$rule/" >&2; return 1; }
  done
}

@test "draft.md carries only the stub — the full contract body was moved out (#441)" {
  # The stub keeps the '## Dispatch contract' heading + a reference to the file,
  # but the load-bearing BODY (rules 2-7's prose) must no longer live in draft.md.
  run grep -qF 'docs/draft-dispatch-contract.md' "$DRAFT"
  [ "$status" -eq 0 ] || { echo "draft.md stub does not reference the contract file" >&2; return 1; }
  # rc-precise (#337): these body phrases must be ABSENT from draft.md now.
  local phrase
  for phrase in \
    'Question-return protocol (ask-don' \
    'Round overwrite exemption' \
    'Finalization is the MAIN session' \
    'Generalization note'; do
    run grep -qF "$phrase" "$DRAFT"
    [ "$status" -ne 0 ] || { echo "draft.md STILL contains moved contract body: /$phrase/" >&2; return 1; }
  done
}

@test "the draft.md stub states BOTH load conditions (#441)" {
  # Condition 1: non-empty resolved step-1 tier.
  run grep -qE 'tier is non-empty|non-empty resolved.*tier|step-model.sh' "$DRAFT"
  [ "$status" -eq 0 ] || { echo "stub missing the non-empty-tier load condition" >&2; return 1; }
  # Condition 2: explicit operator dispatch instruction (fires even on empty tier).
  run grep -qE 'operator explicitly instructs dispatch|explicit operator dispatch|even on an EMPTY tier' "$DRAFT"
  [ "$status" -eq 0 ] || { echo "stub missing the operator-dispatch (empty-tier) load condition" >&2; return 1; }
}
