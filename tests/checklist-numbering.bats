#!/usr/bin/env bats
# tests/checklist-numbering.bats — #558. Step numbers are POSITIONS, not IDs:
# every checklist template's rows carry strictly increasing numbers in file order,
# and the standard template is contiguous 0..23. Retires the permanent-ID scheme.
# NOTE: bats-support is not installed here, so diagnostics use printf+return 1.

setup() {
    PLUGIN_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
}

_die() { printf '%s\n' "$1" >&2; return 1; }

# Emit "<num> <name>" per checklist row.
_rows() {
    sed -n 's/^- \[.\] *\([0-9]*\)\. *\([A-Za-z][A-Za-z0-9_-]*\).*$/\1 \2/p' "$1"
}

@test "numbering: every checklist template is strictly increasing in file order" {
    local n_templates=0
    for f in "$PLUGIN_ROOT"/templates/checklist-*.md "$PLUGIN_ROOT"/templates/revision_block.md; do
        n_templates=$((n_templates + 1))
        local prev=-1 num name rows=0
        while read -r num name; do
            rows=$((rows + 1))
            [ "$num" -gt "$prev" ] \
                || _die "$(basename "$f"): row '$num $name' not > previous '$prev'"
            prev="$num"
        done < <(_rows "$f")
        # Issue-151: a loop that never iterates passes vacuously.
        [ "$rows" -ge 5 ] || _die "$(basename "$f"): only $rows rows parsed — selector broke"
    done
    # Issue-439: assert the SUBJECT COUNT so a renamed template cannot empty this guard.
    [ "$n_templates" -eq 6 ] || _die "expected 6 templates, selected $n_templates"
}

@test "numbering: the standard template is contiguous 0..23" {
    local expect=0 num name
    while read -r num name; do
        [ "$num" -eq "$expect" ] || _die "standard: expected $expect for '$name', got $num"
        expect=$((expect + 1))
    done < <(_rows "$PLUGIN_ROOT/templates/checklist-standard.md")
    [ "$expect" -eq 24 ] || _die "standard: expected 24 rows, got $expect"
}

@test "numbering: execution order matches the canonical step sequence" {
    local expected="pull research draft spike scope improve prune tighten branch \
implement quality document commit analyze draftmr review redmr preship ship \
mergetoall updatewbs impact lessonslearned cleanup"
    local actual
    actual="$(_rows "$PLUGIN_ROOT/templates/checklist-standard.md" | cut -d' ' -f2 | tr '\n' ' ')"
    [ "$(echo $actual)" = "$(echo $expected)" ] || _die "standard step order drifted: $actual"
}
