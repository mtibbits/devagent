#!/usr/bin/env bats
# #361 rederive.sh — advisory re-derive-at-HEAD prober.
load 'helpers/common'

setup() {
    devagent_test_setup
    cd "$SOURCE_DIR" || return
    printf 'line one\nline two\n' > lib.sh
    git add -A && git commit -q -m "add lib.sh"
}
teardown() { devagent_test_teardown; }

# Write an issue.md whose backticks stay literal (quoted heredoc).
_issue() { cat > "$DEVDOC_DIR/Issue-1/issue.md"; }
_run() { run "$DEVAGENT_ROOT/scripts/rederive.sh" "$TEST_PROJECT" Issue-1; }
_art() { ls "$DEVDOC_DIR/Issue-1/analysis/"*-rederive.txt; }

@test "rederive: existing file ✓, missing file ✗ (#361)" {
    _issue <<'EOF'
# t
- Created: 2020-01-01

References `lib.sh` and `missing.sh`.
EOF
    _run
    [ "$status" -eq 0 ]
    grep -q '✓ lib.sh' "$(_art)"
    grep -q '✗ missing.sh' "$(_art)"
}

@test "rederive: file:line shows current content at HEAD (drift) (#361)" {
    _issue <<'EOF'
# t
- Created: 2020-01-01

See `lib.sh:2`.
EOF
    _run
    [ "$status" -eq 0 ]
    grep -q 'lib.sh:2 → line two' "$(_art)"
}

@test "rederive: since-date lists commits touching named files while queued (#361)" {
    _issue <<'EOF'
# t
- Created: 2020-01-01

Touches `lib.sh`.
EOF
    _run
    [ "$status" -eq 0 ]
    grep -q 'add lib.sh' "$(_art)"     # the commit landed after the (2020) filing date
}

@test "rederive: 0 named inputs prints the explicit line, not vacuous (#361)" {
    _issue <<'EOF'
# t
- Created: 2020-01-01

Plain prose with no code tokens at all.
EOF
    _run
    [ "$status" -eq 0 ]
    grep -q '0 named inputs found' "$(_art)"
}

@test "rederive: falls back to checklist scaffold date, noted, when no Created header (#361)" {
    _issue <<'EOF'
# t

References `lib.sh`.
EOF
    printf 'Created: 2021-05-05\n' >> "$DEVDOC_DIR/Issue-1/checklist.md"
    _run
    [ "$status" -eq 0 ]
    grep -q 'fallback: checklist scaffold date' "$(_art)"
}

@test "rederive: dies loud on a non-repo source_dir (#361)" {
    rm -rf "$SOURCE_DIR/.git"
    _issue <<'EOF'
# t
References `lib.sh`.
EOF
    _run
    [ "$status" -ne 0 ]
    [[ "$output" == *"git repo"* ]]
}

@test "rederive artifact name honors DEVAGENT_DATE_OVERRIDE (#413/#338)" {
    _issue <<'EOF'
# t
- Created: 2020-01-01

References `lib.sh`.
EOF
    export DEVAGENT_DATE_OVERRIDE=2020-02-02
    _run
    [ "$status" -eq 0 ]
    [ -f "$DEVDOC_DIR/Issue-1/analysis/2020-02-02-rederive.txt" ]
}
