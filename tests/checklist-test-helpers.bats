#!/usr/bin/env bats
# #420: mark_step/assert_step/delete_step must be revision-scoped like production
# (the masking class #335 killed). A multi-revision checklist reuses step numbers
# across `## Revision N` blocks; the helpers must read/edit only the ACTIVE (last)
# block, else they pass off revision-1's stale glyph or flip every block.
load 'helpers/common'

setup() { devagent_test_setup; }
teardown() { devagent_test_teardown; }

_multi_rev() {   # rev-1 step 2 = [x], active rev-2 step 2 = [ ]
    F="$DEVAGENT_TMP/multi-rev.md"
    cat > "$F" <<'EOF'
# Issue — Workflow checklist

## Revision 1

- [x]  2. draft
- [x]  4. scope

## Revision 2

- [ ]  2. draft
- [ ]  4. scope
EOF
}

@test "assert_step reads the ACTIVE revision block, not rev-1's stale glyph (#420)" {
    _multi_rev
    assert_step "$F" 2 ' '           # active rev-2 is [ ] → passes
    run assert_step "$F" 2 x         # rev-1's [x] must NOT be picked up
    [ "$status" -ne 0 ]
}

@test "mark_step flips only the active revision block (#420)" {
    _multi_rev
    mark_step "$F" 2 '~'
    [ "$(grep -cE '^- \[~\] +2\. ' "$F")" -eq 1 ]   # only rev-2 flipped
    [ "$(grep -cE '^- \[x\] +2\. ' "$F")" -eq 1 ]   # rev-1 untouched
}

@test "delete_step deletes only from the active revision block (#420)" {
    _multi_rev
    delete_step "$F" 2
    [ "$(grep -cE '^- \[.\] +2\. ' "$F")" -eq 1 ]   # rev-1's step 2 survives
    grep -qE '^- \[x\] +2\. ' "$F"                  # and it is rev-1's
}

@test "helpers stay file-wide on a checklist with no revision headings (#420)" {
    F="$DEVAGENT_TMP/legacy.md"
    printf '%s\n' '- [x]  0. pull' '- [ ]  2. draft' > "$F"
    assert_step "$F" 0 x
    mark_step "$F" 2 x
    assert_step "$F" 2 x
}
