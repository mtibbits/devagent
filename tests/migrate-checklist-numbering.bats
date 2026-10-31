#!/usr/bin/env bats
# #558 review M3: scripts/migrate-checklist-numbering.sh had zero coverage while
# already having been run destructively over 390 real checklists. These pin the
# properties that made that safe: correct on old-scheme, no-op on current, correct
# on MIXED (the /devagent:revise state the CHANGELOG recommends), fail-loud on an
# unrecognised name, completed checklists skipped, idempotent, and alignment +
# file mode preserved.

load 'lib/bats-helpers'

MIGRATE() { bash "$PLUGIN_ROOT/scripts/migrate-checklist-numbering.sh" "$@"; }

setup() {
    setup_tmp_devagent_home
    D="$BATS_TEST_TMPDIR/Issue-1"; mkdir -p "$D"
}
teardown() { teardown_tmp_devagent_home; }

_write() { printf '%s\n' "$@" > "$D/checklist.md"; }

_old_scheme_inflight() {
    _write '# Issue-1 — Workflow checklist' '' '## Revision 1' '' \
        '- [x]  0. pull' '- [-] 22. research' '- [x]  1. draft' '- [ ]  8. quality' \
        '- [ ] 21. preship' '- [ ] 15. ship' '- [ ] 20. cleanup' '' '## Log'
}

@test "migrate: renumbers an old-scheme in-flight checklist by name" {
    _old_scheme_inflight
    run MIGRATE "$D"
    [ "$status" -eq 0 ]
    grep -qE '^- \[-\]  1\. research' "$D/checklist.md"   # 22 -> 1
    grep -qE '^- \[x\]  2\. draft'    "$D/checklist.md"   # 1  -> 2
    grep -qE '^- \[ \] 10\. quality'  "$D/checklist.md"   # 8  -> 10
    grep -qE '^- \[ \] 17\. preship'  "$D/checklist.md"   # 21 -> 17
    grep -qE '^- \[ \] 18\. ship'     "$D/checklist.md"   # 15 -> 18
    grep -qE '^- \[ \] 24\. cleanup'  "$D/checklist.md"   # 20 -> 24
    grep -qE '^- \[x\]  0\. pull'     "$D/checklist.md"   # fixed point
}

@test "migrate: preserves glyphs, column alignment and file mode" {
    _old_scheme_inflight
    chmod 640 "$D/checklist.md"
    MIGRATE "$D"
    # single-digit rows keep their two-space gutter, double-digit one space
    grep -qE '^- \[x\]  2\. draft'   "$D/checklist.md"
    grep -qE '^- \[ \] 24\. cleanup' "$D/checklist.md"
    [ "$(stat -c '%a' "$D/checklist.md")" = "640" ]
    # no stray temp left behind
    [ ! -e "$D/checklist.md.tmp" ]
}

@test "migrate: is a no-op on an already-current checklist" {
    _old_scheme_inflight
    MIGRATE "$D"
    local before; before="$(cat "$D/checklist.md")"
    run MIGRATE "$D"
    [ "$status" -eq 0 ]
    [[ "$output" == *"0 migrated"* ]]
    [ "$(cat "$D/checklist.md")" = "$before" ]      # byte-identical: idempotent
}

@test "migrate: renumbers BOTH blocks of a mixed-scheme checklist (#558 revise state)" {
    # This is exactly what /devagent:revise produces on a pre-#558 issue.
    _write '# Issue-1' '' '## Revision 1' '' '- [x]  1. draft' '- [x]  3. improve' \
        '' '## Revision 2' '' '- [ ]  2. draft' '- [ ]  5. improve' '' '## Log'
    run MIGRATE "$D"
    [ "$status" -eq 0 ]
    [ "$(grep -cE '^- \[.\]  2\. draft'   "$D/checklist.md")" -eq 2 ]
    [ "$(grep -cE '^- \[.\]  5\. improve' "$D/checklist.md")" -eq 2 ]
    grep -qE '^- \[x\]  2\. draft' "$D/checklist.md"    # rev1 glyph preserved
    grep -qE '^- \[ \]  2\. draft' "$D/checklist.md"    # rev2 glyph preserved
}

@test "migrate: skips a COMPLETED checklist (the #558 operator waiver)" {
    _write '# Issue-1' '' '## Revision 1' '' '- [x]  1. draft' '- [-]  8. quality' \
        '- [x] 20. cleanup' '' '## Log'
    local before; before="$(cat "$D/checklist.md")"
    run MIGRATE "$D"
    [ "$status" -eq 0 ]
    [[ "$output" == *"1 completed (skipped)"* ]]
    [ "$(cat "$D/checklist.md")" = "$before" ]
}

@test "migrate: --include-completed overrides the waiver" {
    _write '# Issue-1' '' '## Revision 1' '' '- [x]  1. draft' '- [x] 20. cleanup' '' '## Log'
    run MIGRATE --include-completed "$D"
    [ "$status" -eq 0 ]
    grep -qE '^- \[x\]  2\. draft'   "$D/checklist.md"
    grep -qE '^- \[x\] 24\. cleanup' "$D/checklist.md"
}

@test "migrate: --dry-run reports but does not write" {
    _old_scheme_inflight
    local before; before="$(cat "$D/checklist.md")"
    run MIGRATE --dry-run "$D"
    [ "$status" -eq 0 ]
    [[ "$output" == *"would migrate"* ]]
    [ "$(cat "$D/checklist.md")" = "$before" ]
}

@test "migrate: dies fail-loud on an unrecognised step name, leaving the file intact" {
    _write '# Issue-1' '' '## Revision 1' '' '- [x]  1. draft' '- [ ]  9. redissue' '' '## Log'
    local before; before="$(cat "$D/checklist.md")"
    run MIGRATE "$D"
    [ "$status" -ne 0 ]
    [[ "$output" == *"redissue"* ]] 
    [ "$(cat "$D/checklist.md")" = "$before" ]      # never a partial rewrite
}

@test "migrate: warns and skips a checklist with no step rows" {
    _write '# Issue-1' '' '## Log' '- nothing here'
    run MIGRATE "$D"
    [ "$status" -eq 0 ]
    [[ "$output" == *"no checklist rows"* ]]
}

@test "migrate: requires an argument" {
    run MIGRATE
    [ "$status" -ne 0 ]
    [[ "$output" == *"usage"* ]]
}

@test "migrate: --reverse-558 round-trips back to the pre-#558 scheme (#558 redmr MAJOR-4)" {
    # Rollback story: `git revert` restores old-scheme code, so the in-flight
    # checklists must be able to go back with it.
    _old_scheme_inflight
    local original; original="$(cat "$D/checklist.md")"
    MIGRATE "$D"
    grep -qE '^- \[ \] 18\. ship' "$D/checklist.md"      # forward applied
    MIGRATE --reverse-558 "$D"
    [ "$(cat "$D/checklist.md")" = "$original" ]         # byte-identical round-trip
}

@test "migrate: widens a too-narrow field instead of fusing the row (#558 r2 MAJOR-1)" {
    # Hand-authored single-space gutter: 8 -> 10 cannot fit the old field.
    # rjust cannot widen, so the number fused to the checkbox ('- [ ]10.')
    # and the row exited the ROW grammar — invisible to the migrator and to
    # every checklist_* reader, while still reported as migrated.
    _write '# Issue-1 — Workflow checklist' '' '## Revision 1' '' \
        '- [x] 0. pull' '- [ ] 8. quality' '- [ ] 9. document' '' '## Log'
    run MIGRATE "$D"
    [ "$status" -eq 0 ]
    grep -qE '^- \[ \] 10\. quality'  "$D/checklist.md"
    grep -qE '^- \[ \] 11\. document' "$D/checklist.md"
}

@test "migrate: --reverse-558 widens too instead of fusing (#558 r2 MAJOR-1 mirror)" {
    # research NEW=1 -> OLD=22: at a single-space gutter the width-2 field
    # holds '22' with no room for the separator.
    _write '# Issue-1 — Workflow checklist' '' '## Revision 1' '' \
        '- [x] 0. pull' '- [ ] 1. research' '' '## Log'
    run MIGRATE --reverse-558 "$D"
    [ "$status" -eq 0 ]
    grep -qE '^- \[ \] 22\. research' "$D/checklist.md"
}

@test "migrate: -h prints the whole header, not a truncated range" {
    run MIGRATE -h
    [ "$status" -eq 0 ]
    [[ "$output" == *"--include-completed"* ]]
    [[ "$output" == *"re-driven."* ]]     # the previously-cut final line
}

# ---- #885: mergemr joins at 20; updatewbs..cleanup move to 21-24 -------------

# An in-flight #558-scheme checklist: Revision 1 closed through ship, Revision 2
# (the ACTIVE block) open at preship.
_mid_scheme_two_blocks() {
    _write '# Issue-1 — Workflow checklist' '' 'Template: standard' '' '## Revision 1' '' \
        '- [x]  0. pull' '- [x]  2. draft' '- [x] 17. preship' '- [x] 18. ship' \
        '- [-] 19. mergetoall' '- [ ] 20. updatewbs' '- [ ] 21. impact' \
        '- [ ] 22. lessonslearned' '- [ ] 23. cleanup' '' '## Log' \
        '- 2026-10-01 10:00  revise: revision 2' '' '## Revision 2' '' \
        '- [x]  2. draft' '- [ ] 17. preship' '- [ ] 18. ship' '- [-] 19. mergetoall' \
        '- [ ] 20. updatewbs' '- [ ] 21. impact' '- [ ] 22. lessonslearned' '- [ ] 23. cleanup'
}

# The #885-scheme twin of the above, mergemr in BOTH blocks.
_new_scheme_two_blocks() {
    _write '# Issue-1 — Workflow checklist' '' '## Revision 1' '' \
        '- [x]  0. pull' '- [x] 18. ship' '- [x] 20. mergemr' \
        '- [ ] 21. updatewbs' '- [ ] 24. cleanup' '' '## Log' '' '## Revision 2' '' \
        '- [ ] 18. ship' '- [-] 19. mergetoall' '- [ ] 20. mergemr' '- [ ] 21. updatewbs' \
        '- [ ] 22. impact' '- [ ] 23. lessonslearned' '- [ ] 24. cleanup'
}

_block() { awk -v b="## Revision $1" '$0==b{f=1;next} f&&/^## /{exit} f' "$D/checklist.md"; }

@test "migrate #885: inserts [ ] mergemr after mergetoall, active block only" {
    _mid_scheme_two_blocks
    run MIGRATE "$D"
    [ "$status" -eq 0 ]
    [[ "$output" == *"+mergemr"* ]]
    # the active block gains the row directly after mergetoall
    [ "$(_block 2 | grep -A1 -E '^- \[-\] 19\. mergetoall$' | tail -1)" = '- [ ] 20. mergemr' ]
    [ "$(_block 2 | grep -cE '^- \[.\] +20\. mergemr$')" -eq 1 ]
    # the older block is renumbered but gains no row
    [ "$(_block 1 | grep -c mergemr)" -eq 0 ]
    _block 1 | grep -qE '^- \[ \] 21\. updatewbs$'
    _block 1 | grep -qE '^- \[ \] 24\. cleanup$'
    _block 2 | grep -qE '^- \[ \] 22\. impact$'
    _block 2 | grep -qE '^- \[ \] 23\. lessonslearned$'
    [ "$(grep -c mergemr "$D/checklist.md")" -eq 1 ]
}

@test "migrate #885: inserts after ship when the block has no mergetoall row" {
    _write '# Issue-1' '' '## Revision 1' '' '- [x]  0. pull' '- [ ] 18. ship' \
        '- [ ] 20. updatewbs' '- [ ] 23. cleanup' '' '## Log'
    run MIGRATE "$D"
    [ "$status" -eq 0 ]
    [ "$(grep -A1 -E '^- \[ \] 18\. ship$' "$D/checklist.md" | tail -1)" = '- [ ] 20. mergemr' ]
}

@test "migrate #885: inserts [-] when ship is [-]" {
    _write '# Issue-1' '' '## Revision 1' '' '- [x]  0. pull' '- [-] 18. ship' \
        '- [-] 19. mergetoall' '- [ ] 20. updatewbs' '- [ ] 23. cleanup' '' '## Log'
    run MIGRATE "$D"
    [ "$status" -eq 0 ]
    [ "$(grep -A1 -E '^- \[-\] 19\. mergetoall$' "$D/checklist.md" | tail -1)" = '- [-] 20. mergemr' ]
}

@test "migrate #885: no ship row → no insert" {
    # the research tier: no ship, so no merge step; it only renumbers.
    _write '# Issue-1' '' '## Revision 1' '' '- [x]  0. pull' '- [ ]  2. draft' \
        '- [ ] 11. document' '- [ ] 22. lessonslearned' '- [ ] 23. cleanup' '' '## Log'
    run MIGRATE "$D"
    [ "$status" -eq 0 ]
    [[ "$output" != *"mergemr"* ]]
    run grep -c mergemr "$D/checklist.md"
    [ "$output" -eq 0 ]
    grep -qE '^- \[ \] 23\. lessonslearned$' "$D/checklist.md"
    grep -qE '^- \[ \] 24\. cleanup$' "$D/checklist.md"
}

@test "migrate #885: a completed checklist is skipped — no renumber, no insert" {
    _write '# Issue-1' '' '## Revision 1' '' '- [x]  0. pull' '- [x] 18. ship' \
        '- [-] 19. mergetoall' '- [x] 20. updatewbs' '- [x] 23. cleanup' '' '## Log'
    local before; before="$(cat "$D/checklist.md")"
    run MIGRATE "$D"
    [ "$status" -eq 0 ]
    [[ "$output" == *"1 completed (skipped)"* ]]
    [ "$(cat "$D/checklist.md")" = "$before" ]
}

@test "migrate #885: a second run reports ALREADY and changes nothing" {
    _mid_scheme_two_blocks
    MIGRATE "$D"
    local before; before="$(cat "$D/checklist.md")"
    run MIGRATE "$D"
    [ "$status" -eq 0 ]
    [[ "$output" == *"0 migrated, 1 already current"* ]]
    [ "$(cat "$D/checklist.md")" = "$before" ]
}

@test "migrate #885: --reverse drops mergemr in every block and maps to #558" {
    _new_scheme_two_blocks
    run MIGRATE --reverse "$D"
    [ "$status" -eq 0 ]
    [[ "$output" == *"-mergemr"* ]]
    run grep -c mergemr "$D/checklist.md"
    [ "$output" -eq 0 ]
    _block 2 | grep -qE '^- \[ \] 18\. ship$'
    _block 2 | grep -qE '^- \[-\] 19\. mergetoall$'
    _block 2 | grep -qE '^- \[ \] 20\. updatewbs$'
    _block 2 | grep -qE '^- \[ \] 23\. cleanup$'
    _block 1 | grep -qE '^- \[ \] 20\. updatewbs$'
    _block 1 | grep -qE '^- \[ \] 23\. cleanup$'
}

@test "migrate #885: forward then --reverse restores an in-flight #558 checklist byte-for-byte" {
    _mid_scheme_two_blocks
    local original; original="$(cat "$D/checklist.md")"
    MIGRATE "$D"
    grep -qE '^- \[ \] 20\. mergemr$' "$D/checklist.md"   # forward applied
    run MIGRATE --reverse "$D"
    [ "$status" -eq 0 ]
    [ "$(cat "$D/checklist.md")" = "$original" ]
}

@test "migrate #885: --reverse-558 drops mergemr and maps to pre-#558" {
    _write '# Issue-1' '' '## Revision 1' '' '- [x]  0. pull' '- [ ] 18. ship' \
        '- [ ] 19. mergetoall' '- [ ] 20. mergemr' '- [ ] 21. updatewbs' '- [ ] 24. cleanup' \
        '' '## Log'
    run MIGRATE --reverse-558 "$D"
    [ "$status" -eq 0 ]
    [[ "$output" == *"-mergemr"* ]]
    run grep -c mergemr "$D/checklist.md"
    [ "$output" -eq 0 ]
    grep -qE '^- \[ \] 15\. ship$' "$D/checklist.md"
    grep -qE '^- \[ \] 16\. mergetoall$' "$D/checklist.md"
    grep -qE '^- \[ \] 17\. updatewbs$' "$D/checklist.md"
    grep -qE '^- \[ \] 20\. cleanup$' "$D/checklist.md"
}

@test "migrate #885: --reverse with --reverse-558 dies, file unchanged" {
    _new_scheme_two_blocks
    local before; before="$(cat "$D/checklist.md")"
    run MIGRATE --reverse --reverse-558 "$D"
    [ "$status" -ne 0 ]
    [[ "$output" == *"--reverse and --reverse-558 are mutually exclusive"* ]]
    [ "$(cat "$D/checklist.md")" = "$before" ]
}

@test "migrate #885: --help names which flag undoes which renumber" {
    run MIGRATE --help
    [ "$status" -eq 0 ]
    grep -qE -- '--reverse +undoes #885' <<<"$output"
    grep -qE -- '--reverse-558 +undoes #558' <<<"$output"
    grep -qF 'No flag: migrate to the current scheme (#885)' <<<"$output"
}
