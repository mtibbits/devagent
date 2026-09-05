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
# #590: publish SOURCE_DIR's main to a local bare 'origin' so the fixture's
# default_baseline (origin/main) resolves; returns with HEAD == origin/main.
_origin() {
    git init -q --bare "$DEVAGENT_TMP/origin.git"
    ( cd "$SOURCE_DIR" && git remote add origin "$DEVAGENT_TMP/origin.git" && git push -q origin main )
}
# One throwaway commit on SOURCE_DIR's current branch.
_commit() { ( cd "$SOURCE_DIR" && echo "$1" >> lib.sh && git commit -qam "$1" ); }
# A git shim that faults ONLY the named subcommand; everything else reaches
# the real git. Exported as DEVAGENT_GIT for the rest of the test.
_faulty() {
    printf '%s\n' '#!/usr/bin/env bash' \
      'for a in "$@"; do [ "$a" = "$FAULT_ON" ] && { echo "fatal: injected $a fault" >&2; exit 128; }; done' \
      'exec git "$@"' > "$DEVAGENT_STUB_BIN/git-faulty"
    chmod +x "$DEVAGENT_STUB_BIN/git-faulty"
    export FAULT_ON="$1" DEVAGENT_GIT="$DEVAGENT_STUB_BIN/git-faulty"
}

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

@test "rederive: HEAD behind default_baseline → ✗ STALE CHECKOUT with a runnable remedy (#590)" {
    _commit c2; _commit c3; _origin
    ( cd "$SOURCE_DIR" && git reset -q --hard HEAD~2 )      # deliberately behind
    _issue <<'EOF'
# t
- Created: 2020-01-01

References `lib.sh`.
EOF
    _run
    [ "$status" -eq 0 ]                                       # advisory: never blocks
    grep -q '✗ HEAD [0-9a-f]* vs origin/main: behind 2, ahead 0 (fetch: ok)' "$(_art)"
    grep -q 'STALE CHECKOUT' "$(_art)"
    grep -q "merge --ff-only origin/main" "$(_art)"           # the remedy is a command, not a verb
    grep -q '✓ lib.sh' "$(_art)"                               # named-file probes still run
}

@test "rederive: HEAD at default_baseline → behind 0, no stale flag (#590)" {
    _origin
    _issue <<'EOF'
# t
- Created: 2020-01-01

References `lib.sh`.
EOF
    _run
    [ "$status" -eq 0 ]
    grep -q '✓ HEAD [0-9a-f]* vs origin/main: behind 0, ahead 0 (fetch: ok)' "$(_art)"
    run grep -c 'STALE CHECKOUT' "$(_art)"
    [ "$status" -eq 1 ]     # precise no-match (grep rc 1), never -ne 0 (#337)
}

@test "rederive: local commits ahead are reported as ahead, never as behind (#590)" {
    _origin; _commit local1
    _issue <<'EOF'
# t
- Created: 2020-01-01

References `lib.sh`.
EOF
    _run
    [ "$status" -eq 0 ]
    grep -q '✓ HEAD [0-9a-f]* vs origin/main: behind 0, ahead 1 (fetch: ok)' "$(_art)"
}

@test "rederive: on the recorded issue branch the gap is an ℹ row, never STALE (revision path, #590)" {
    _origin
    ( cd "$SOURCE_DIR" && git checkout -q -b feat/1 && git checkout -q main && echo up >> lib.sh \
      && git commit -qam upstream && git push -q origin main && git checkout -q feat/1 )   # origin/main now 1 ahead
    devagent_state_set "$HOME/.claude/devagent/state/$TEST_PROJECT.toml" branch feat/1
    _issue <<'EOF'
# t
- Created: 2020-01-01

References `lib.sh`.
EOF
    _run
    [ "$status" -eq 0 ]
    grep -q 'ℹ HEAD [0-9a-f]* on issue branch feat/1 vs origin/main: behind 1, ahead 0 (fetch: ok) — revision-time drift, not a premise' "$(_art)"
    run grep -c 'STALE CHECKOUT' "$(_art)"
    [ "$status" -eq 1 ]
}

@test "rederive: unresolvable default_baseline → explicit undetermined line, rc 0 (#590)" {
    # Fixture default: default_baseline = origin/main and NO origin remote —
    # the shape every pre-#590 rederive test runs in (Issue-242 blast radius).
    _issue <<'EOF'
# t
- Created: 2020-01-01

References `lib.sh`.
EOF
    _run
    [ "$status" -eq 0 ]
    grep -q "? behind-count undetermined — default_baseline 'origin/main' does not resolve" "$(_art)"
    grep -q "(fetch: skipped ('origin' is not a configured remote" "$(_art)"
    run grep -c 'behind 0' "$(_art)"
    [ "$status" -eq 1 ]     # undetermined must never print as a silent 0 (#243)
}

@test "rederive: no default_baseline configured → undetermined names the missing key; heading says none (#590)" {
    devagent_config_unset "$HOME/.claude/devagent/config.toml" "project.$TEST_PROJECT.default_baseline"
    _issue <<'EOF'
# t
- Created: 2020-01-01

References `lib.sh`.
EOF
    _run
    [ "$status" -eq 0 ]
    grep -q "? behind-count undetermined — no default_baseline configured for project '$TEST_PROJECT'" "$(_art)"
    grep -q 'base: (none configured)' "$(_art)"
}

@test "rederive: a local-branch base fetches nothing and says so neutrally; a FAILED fetch is stamped, count uses the last-known ref (#590)" {
    # Local-branch base: default_baseline = int (no slash), one commit ahead of main.
    ( cd "$SOURCE_DIR" && git branch int && git checkout -q int && echo i >> lib.sh \
      && git commit -qam int && git checkout -q main )
    devagent_config_set "$HOME/.claude/devagent/config.toml" "project.$TEST_PROJECT.default_baseline" int
    _issue <<'EOF'
# t
- Created: 2020-01-01

References `lib.sh`.
EOF
    _run
    [ "$status" -eq 0 ]
    grep -q '✗ HEAD [0-9a-f]* vs int: behind 1, ahead 0 (fetch: n/a (local branch))' "$(_art)"
    # FAILED fetch: a configured origin whose URL is dead, tracking ref already present.
    devagent_config_set "$HOME/.claude/devagent/config.toml" "project.$TEST_PROJECT.default_baseline" origin/main
    _origin
    ( cd "$SOURCE_DIR" && git remote set-url origin "$DEVAGENT_TMP/does-not-exist.git" )
    rm -f "$DEVDOC_DIR/Issue-1/analysis/"*-rederive.txt
    _run
    [ "$status" -eq 0 ]
    grep -q "✓ HEAD [0-9a-f]* vs origin/main: behind 0, ahead 0 (fetch: FAILED (offline?); count is against the last-known 'origin' state)" "$(_art)"
    [[ "$output" == *"fetch of 'origin' failed"* ]]            # upstream_fetch's warn reached stderr
}

@test "rederive: a .devagent-baseline marker is acknowledged by existence only — garbage content cannot die (#590)" {
    _origin
    printf '%s' '!! not a ref !!' > "$DEVDOC_DIR/Issue-1/.devagent-baseline"
    _issue <<'EOF'
# t
- Created: 2020-01-01

References `lib.sh`.
EOF
    _run
    [ "$status" -eq 0 ]
    grep -q 'base: default_baseline; a .devagent-baseline marker is present — step 8 cuts from it, this count is vs default_baseline' "$(_art)"
    grep -q '✓ HEAD [0-9a-f]* vs origin/main: behind 0' "$(_art)"
}

@test "rederive: dies loud when rev-list faults (#590)" {
    _origin; _faulty rev-list
    _issue <<'EOF'
# t
- Created: 2020-01-01

References `lib.sh`.
EOF
    _run
    [ "$status" -ne 0 ]
    [[ "$output" == *"rev-list"* ]] && [[ "$output" == *"failed"* ]]   # THIS die, not some other red (#337)
}

@test "rederive: bare basename that matches ONE tracked path → ✓ resolved, feeds the since-log, never ✗ (#590)" {
    ( cd "$SOURCE_DIR" && mkdir -p skills/x && echo s > skills/x/SKILL.md && git add -A && git commit -qm addskill )
    _issue <<'EOF'
# t
- Created: 2020-01-01

See `SKILL.md`.
EOF
    _run
    [ "$status" -eq 0 ]
    grep -q '✓ SKILL.md → skills/x/SKILL.md (resolved: one tracked path ends in /SKILL.md)' "$(_art)"
    grep -qE '^  [0-9a-f]+ addskill$' "$(_art)"   # the RESOLVED path is what the since-log walks
    run grep -c '✗ SKILL.md' "$(_art)"
    [ "$status" -eq 1 ]
}

@test "rederive: a path SUFFIX (dir/file) resolves the same way (#590)" {
    ( cd "$SOURCE_DIR" && mkdir -p scripts/capture && echo c > scripts/capture/capture.sh && git add -A && git commit -qm addcap )
    _issue <<'EOF'
# t
- Created: 2020-01-01

See `capture/capture.sh`.
EOF
    _run
    [ "$status" -eq 0 ]
    grep -q '✓ capture/capture.sh → scripts/capture/capture.sh (resolved' "$(_art)"
}

@test "rederive: ambiguous basename → ~ advisory row listing the hits, never ✗ (#590)" {
    ( cd "$SOURCE_DIR" && mkdir -p skills/a skills/b && echo a > skills/a/SKILL.md && echo b > skills/b/SKILL.md \
      && git add -A && git commit -qm two )
    _issue <<'EOF'
# t
- Created: 2020-01-01

See `SKILL.md`.
EOF
    _run
    [ "$status" -eq 0 ]
    grep -q '~ SKILL.md — ambiguous: 2 tracked paths end in /SKILL.md (skills/a/SKILL.md, skills/b/SKILL.md); advisory, not a falsified premise' "$(_art)"
    run grep -c '✗ SKILL.md' "$(_art)"
    [ "$status" -eq 1 ]
}

@test "rederive: genuinely absent paths still ✗ — wrong full path, near-miss basename, missing file (#590)" {
    ( cd "$SOURCE_DIR" && mkdir -p skills/a && echo a > skills/a/SKILL.md && git add -A && git commit -qm one )
    _issue <<'EOF'
# t
- Created: 2020-01-01

See `skills/foo/SKILL.md`, `xSKILL.md` and `missing.sh`.
EOF
    _run
    [ "$status" -eq 0 ]
    grep -q '✗ skills/foo/SKILL.md' "$(_art)"     # a suffix match must not rescue a WRONG full path
    grep -q '✗ xSKILL.md' "$(_art)"               # the `/` boundary: xSKILL.md is not SKILL.md
    grep -q '✗ missing.sh' "$(_art)"
    run grep -c '✓ skills/foo/SKILL.md' "$(_art)"
    [ "$status" -eq 1 ]
}

@test "rederive: line-cite on a bare basename resolves and shows the line (#590)" {
    ( cd "$SOURCE_DIR" && mkdir -p sub && printf 'one\ntwo\n' > sub/util.sh && git add -A && git commit -qm util )
    _issue <<'EOF'
# t
- Created: 2020-01-01

See `util.sh:2`.
EOF
    _run
    [ "$status" -eq 0 ]
    grep -q 'util.sh:2 → (sub/util.sh) two' "$(_art)"
}

@test "rederive: line-cite on an ambiguous basename says so instead of 'absent' (#590)" {
    ( cd "$SOURCE_DIR" && mkdir -p p q && echo 1 > p/util.sh && echo 2 > q/util.sh && git add -A && git commit -qm utils )
    _issue <<'EOF'
# t
- Created: 2020-01-01

See `util.sh:1`.
EOF
    _run
    [ "$status" -eq 0 ]
    grep -q 'util.sh:1 → <ambiguous: 2 tracked paths end in /util.sh>' "$(_art)"
    run grep -c 'file/line absent' "$(_art)"
    [ "$status" -eq 1 ]
}

@test "rederive: dies loud when ls-tree faults (#590)" {
    _origin; _faulty ls-tree
    _issue <<'EOF'
# t
- Created: 2020-01-01

References `lib.sh`.
EOF
    _run
    [ "$status" -ne 0 ]
    [[ "$output" == *"ls-tree"* ]] && [[ "$output" == *"failed"* ]]
}
