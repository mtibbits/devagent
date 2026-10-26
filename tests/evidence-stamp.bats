#!/usr/bin/env bats
# #894 evidence-stamp.sh: writes the suite:, files: and platform: lines of mr.md's
# ## Evidence block from the newest suite-count artifact and git, and refuses (mr.md
# untouched) when the artifact cannot honestly describe HEAD. The stamper and
# preship-evidence.sh rebuild those lines from ONE sourced helper, scripts/lib/evidence.sh,
# so the two cannot drift (O1, O2).
# Every @test name here is ASCII, and nothing here asserts a file mode, so this one file
# also runs in Git Bash (LC_ALL=C.UTF-8 bats tests/evidence-stamp.bats); W1 alone needs
# a real symlink and skips there. Fixture bytes are built in-test with printf, never
# read from tracked files: .gitattributes forces eol=lf, and a CRLF fixture must be
# CRLF whatever the checkout does. Byte checks use cmp and _cr_count, never a grep or
# sed over CR-bearing files (Git Bash hides the CR from those).
load 'helpers/common'

USAGE="usage: evidence-stamp.sh <project> <Issue-N> [--attest-tree '<attestation>']"
FOREIGN_TREE="/nonexistent/other-env/devagent"
PLAT="os=Linux kernel=6.6.87 fs=ext4 modes=posix"

setup() {
    devagent_test_setup
    cd "$SOURCE_DIR" || return
    BASELINE="$(git rev-parse HEAD)"                       # the seed commit
    devagent_state_set "$HOME/.claude/devagent/state/$TEST_PROJECT.toml" baseline_sha "$BASELINE"
    devagent_state_set "$HOME/.claude/devagent/state/$TEST_PROJECT.toml" branch main
    mkdir -p "$DEVAGENT_TMP/binstub"
    printf '%s\n' '#!/usr/bin/env bash' 'echo "1..1"' 'echo "ok 1 a"' > "$DEVAGENT_TMP/binstub/bats"
    chmod +x "$DEVAGENT_TMP/binstub/bats"
    # The pytest interpreter seam: run-suite checks it with command -v only (U3).
    printf '%s\n' '#!/usr/bin/env bash' 'echo "3 passed in 0.01s"' > "$DEVAGENT_TMP/py"
    chmod +x "$DEVAGENT_TMP/py"
    MR="$DEVDOC_DIR/Issue-1/mr.md"
    ST="$DEVAGENT_ROOT/scripts/evidence-stamp.sh"
}
teardown() { devagent_test_teardown; }

# _shape both|bats|pytest|neither - give the tree that framework shape, then commit.
_shape() {
    mkdir -p tests
    case "$1" in
        both)    echo '# placeholder' > tests/x.bats; echo 'def test_ok(): pass' > tests/test_x.py ;;
        bats)    echo '# placeholder' > tests/x.bats ;;
        pytest)  echo 'def test_ok(): pass' > tests/test_x.py ;;
        neither) echo 'notes' > notes.txt ;;
    esac
    git add -A && git commit -q -m "shape $1"
}
# _rs - the REAL run-suite on the fixture issue (register 232: two components agreeing
# on a format are tested against each other's real output, never a hand-written copy).
_rs() {
    PATH="$DEVAGENT_TMP/binstub:$PATH" DEVAGENT_PYTEST_PYTHON="$DEVAGENT_TMP/py" \
        run "$DEVAGENT_ROOT/scripts/run-suite.sh" "$TEST_PROJECT" Issue-1
    [ "$status" -eq 0 ] || { echo "run-suite rc $status: $output"; return 1; }
}
_st() { run "$ST" "$TEST_PROJECT" Issue-1 "$@"; }
_pe() { run "$DEVAGENT_ROOT/scripts/preship-evidence.sh" "$TEST_PROJECT" Issue-1 "$@"; }
_mr_tpl() { cp "$DEVAGENT_ROOT/templates/mr_template.md" "$MR"; }
_art() { ls -1 "$DEVDOC_DIR/Issue-1/analysis/"*-suite-count.txt | sort | tail -1; }
_canon() { (cd "$SOURCE_DIR" && pwd -P); }
# _ev_line <key> - the Evidence block's column-0 <key>: line(s).
_ev_line() { awk -v k="$1:" '/^## Evidence/{f=1;next} /^## /{f=0} f && index($0, k) == 1' "$MR"; }
# _hand_art <head> <tree> <bats body> <pytest body> [platform body] - a #660-era
# artifact; with no fifth argument it has no platform: line.
_hand_art() {
    { printf 'head: %s  dirty: no\ntree: %s\nbats: %s\npytest: %s\nbranch: main\nupstream: (no-origin)\n' \
        "$1" "$2" "$3" "$4"
      [ $# -lt 5 ] || printf 'platform: %s\n' "$5"; } \
        > "$DEVDOC_DIR/Issue-1/analysis/2026-07-09-suite-count.txt"
}
# _refused <token> - the last run refused with <token>, rc 1, and mr.md is byte-identical
# to the copy saved in $DEVAGENT_TMP/mr.before.
_refused() {
    [ "$status" -eq 1 ] || { echo "status $status, want 1: $output"; return 1; }
    [[ "$output" == *"$1"* ]] || { echo "no '$1' in: $output"; return 1; }
    cmp -s "$DEVAGENT_TMP/mr.before" "$MR" || { echo "mr.md changed"; return 1; }
}
_save() { cp "$MR" "$DEVAGENT_TMP/mr.before"; }
# _cr_count <file> - how many CR bytes it holds (copied from tests/preship-evidence.bats).
_cr_count() {
    od -An -c "$1" | awk '{ for (i = 1; i <= NF; i++) if ($i == "\\r") n++ } END { print n + 0 }'
}
# _diff_n - git diff --name-only BASELINE..HEAD | wc -l, as the AC states it.
_diff_n() { git diff --name-only "$BASELINE..HEAD" | wc -l | tr -d ' '; }

# --- Task 2: stamp shapes and one source ----------------------------------------

# _stamp_shape <shape> <expected suite parts> - S1-S4's one body.
_stamp_shape() {
    local head art
    _shape "$1"; _rs; _mr_tpl
    _st
    [ "$status" -eq 0 ] || { echo "stamp rc $status: $output"; return 1; }
    head="$(git rev-parse HEAD)"
    [[ "$head" =~ ^[0-9a-f]{40}$ ]]
    [ "$(_ev_line suite)" = "suite: $2 @ $head" ] || { echo "suite: $(_ev_line suite)"; return 1; }
    [ "$(_ev_line files)" = "files: $(_diff_n) changed" ] || { echo "files: $(_ev_line files)"; return 1; }
    art="$(_art)"
    [ "$(_ev_line platform)" = "$(grep '^platform:' "$art")" ] || { echo "platform: $(_ev_line platform)"; return 1; }
    _pe
    [ "$status" -eq 0 ] || { echo "checker rc $status: $output"; return 1; }
    [[ "$output" == *"[tree=checked]"* ]]
}

@test "#894 S1 stamp both frameworks" {
    _stamp_shape both "1/1 bats, 3 pytest"
}

@test "#894 S2 stamp bats only" {
    _stamp_shape bats "1/1 bats"
}

@test "#894 S3 stamp pytest only" {
    _stamp_shape pytest "3 pytest"
}

@test "#894 S4 stamp neither framework" {
    _stamp_shape neither "none"
}

@test "#894 O1 stamper and checker rebuild the same suite line" {
    # Starts from a STAMPED mr.md, plants a wrong suite: line, and takes the checker's own
    # rebuilt line from its mismatch message: the two must agree on every shape.
    local head tree shape b p stamped x
    head="$(git rev-parse HEAD)"; tree="$(_canon)"
    for shape in both bats pytest neither; do
        case "$shape" in
            both)    b="1/1 notok=0"; p="3 passed, 0 failed, 0 errors" ;;
            bats)    b="1/1 notok=0"; p="(none)" ;;
            pytest)  b="(none)";      p="3 passed, 0 failed, 0 errors" ;;
            neither) b="(none)";      p="(none)" ;;
        esac
        _hand_art "$head" "$tree" "$b" "$p" "$PLAT"
        _mr_tpl
        _st
        [ "$status" -eq 0 ] || { echo "$shape: stamp rc $status: $output"; return 1; }
        stamped="$(_ev_line suite)"; stamped="${stamped#suite: }"
        sed -i 's/^suite: .*/suite: WRONG/' "$MR"
        _pe
        [ "$status" -eq 1 ] || { echo "$shape: checker rc $status: $output"; return 1; }
        x="$(printf '%s\n' "$output" | sed -n "s/.*vs artifact='\([^']*\)'.*/\1/p")"
        [ -n "$x" ] || { echo "$shape: no rebuilt line in: $output"; return 1; }
        [ "$x" = "$stamped" ] || { echo "$shape: checker '$x' vs stamper '$stamped'"; return 1; }
        _st
        [ "$status" -eq 0 ] || { echo "$shape: re-stamp rc $status: $output"; return 1; }
        [ "$(_ev_line suite)" = "suite: $x" ] || { echo "$shape: re-stamped $(_ev_line suite)"; return 1; }
    done
}

@test "#894 O2 the suite line has one home" {
    local lib="$DEVAGENT_ROOT/scripts/lib/evidence.sh" s
    run bash -c '. "$1" && type evidence_suite_resolve evidence_tree_rung evidence_files_count' _ "$lib"
    [ "$status" -eq 0 ]
    # planted control: the needle matches an assignment
    [ "$(printf 'EVIDENCE_SUITE_LINE="x"\n' | grep -c 'EVIDENCE_SUITE_LINE=')" -eq 1 ]
    [ "$(grep -c 'EVIDENCE_SUITE_LINE=' "$lib")" -ge 1 ]
    for s in scripts/preship-evidence.sh scripts/evidence-stamp.sh; do
        [ "$(grep -c '^\. "\$DEVAGENT_ROOT/scripts/lib/evidence\.sh"$' "$DEVAGENT_ROOT/$s")" -eq 1 ] \
            || { echo "$s does not source the lib exactly once"; return 1; }
        run grep -c 'EVIDENCE_SUITE_LINE=' "$DEVAGENT_ROOT/$s"
        [ "$status" -eq 1 ] && [ "$output" = 0 ] || { echo "$s assigns the suite line itself"; return 1; }
    done
}

# --- Task 3: re-stamp, refusals, attestation -------------------------------------

@test "#894 R0 re-stamp after a late commit" {
    local old cmd
    _shape bats; _rs; _mr_tpl
    _st
    [ "$status" -eq 0 ]
    old="$(git rev-parse HEAD)"
    echo three > f3.txt && git add -A && git commit -q -m three
    _save
    _st
    _refused "STALE ARTIFACT"
    # register 353: the printed remedy, executed as printed.
    cmd="$(printf '%s\n' "$output" | grep -o '`bash "$CLAUDE_PLUGIN_ROOT/scripts/run-suite.sh"[^`]*`' | head -1)"
    cmd="${cmd//\`/}"
    [ -n "$cmd" ] || { echo "no run-suite remedy in: $output"; return 1; }
    CLAUDE_PLUGIN_ROOT="$DEVAGENT_ROOT" PATH="$DEVAGENT_TMP/binstub:$PATH" run bash -c "$cmd"
    [ "$status" -eq 0 ] || { echo "remedy rc $status: $output"; return 1; }
    _st
    [ "$status" -eq 0 ]
    [[ "$(_ev_line suite)" == *"@ $(git rev-parse HEAD)" ]]
    [[ "$(_ev_line suite)" != *"@ $old" ]]
    [ "$(_ev_line files)" = "files: $(_diff_n) changed" ]
    _pe
    [ "$status" -eq 0 ]
}

@test "#894 F1 refuses with no artifact" {
    _mr_tpl; _save
    _st
    _refused "no suite-count artifact"
    [[ "$output" == *'scripts/run-suite.sh" testproj Issue-1'* ]]
}

@test "#894 F2 refuses an artifact whose head is not HEAD" {
    echo two > f2.txt && git add -A && git commit -q -m two
    _hand_art "$BASELINE" "$(_canon)" "1/1 notok=0" "(none)" "$PLAT"
    _mr_tpl; _save
    _st
    _refused "STALE ARTIFACT"
    [[ "$output" == *"$BASELINE"* ]]
    [[ "$output" == *"$(git rev-parse HEAD)"* ]]
}

@test "#894 F3 refuses an artifact recording dirty yes" {
    _shape bats
    echo junk > junk.txt
    _rs
    grep -q 'dirty: yes' "$(_art)"
    _mr_tpl; _save
    _st
    _refused "dirty: yes"
    [[ "$output" == *"commit or clean"* ]]
}

@test "#894 F4 refuses a local tree that is not the issue tree" {
    _hand_art "$(git rev-parse HEAD)" "$DEVAGENT_TMP" "1/1 notok=0" "(none)" "$PLAT"
    _mr_tpl; _save
    _st
    _refused "artifact was produced from tree"
}

@test "#894 F5 refuses an absent tree with no attestation" {
    local tag
    tag="$(sed -n 's/^tree_unattested="\(.*\)"$/\1/p' "$DEVAGENT_ROOT/scripts/lib/evidence.sh")"
    [ -n "$tag" ]
    _hand_art "$(git rev-parse HEAD)" "$FOREIGN_TREE" "1/1 notok=0" "(none)" "$PLAT"
    _mr_tpl; _save
    _st
    _refused "$tag"
    [[ "$output" == *"--attest-tree 'head="* ]]
}

# _f6 <attestation> <token> - an absent tree, attested wrongly.
_f6() {
    _hand_art "$(git rev-parse HEAD)" "$FOREIGN_TREE" "1/1 notok=0" "(none)" "$PLAT"
    _mr_tpl; _save
    _st --attest-tree "$1"
    _refused "$2"
}

@test "#894 F6a attestation naming another head is refused" {
    _f6 "head=$BASELINE$BASELINE dirty=no path=$FOREIGN_TREE" "names head"
}

@test "#894 F6b attestation reporting dirty yes is refused" {
    _f6 "head=$(git rev-parse HEAD) dirty=yes path=$FOREIGN_TREE" "reports dirty=yes"
}

@test "#894 F6c attestation naming another path is refused" {
    _f6 "head=$(git rev-parse HEAD) dirty=no path=/nonexistent/another-clone" "names path"
}

@test "#894 F6d a malformed attestation is refused" {
    _f6 "garbage" "malformed --attest-tree"
}

@test "#894 F7 refuses an artifact with no platform line" {
    _hand_art "$(git rev-parse HEAD)" "$(_canon)" "1/1 notok=0" "(none)"
    _mr_tpl; _save
    _st
    _refused "no platform: line"
}

@test "#894 F7b refuses a malformed platform line" {
    _hand_art "$(git rev-parse HEAD)" "$(_canon)" "1/1 notok=0" "(none)" "garbage"
    _mr_tpl; _save
    _st
    _refused "is not the one shape run-suite writes"
}

@test "#894 F8 refuses an unmeasured pytest" {
    _hand_art "$(git rev-parse HEAD)" "$(_canon)" "1/1 notok=0" "(error)" "$PLAT"
    _mr_tpl; _save
    _st
    _refused "pytest: (error)"
}

@test "#894 F9 zero-file diff stamps files: 0 changed and the checker passes" {
    _shape bats; _rs
    devagent_state_set "$HOME/.claude/devagent/state/$TEST_PROJECT.toml" baseline_sha "$(git rev-parse HEAD)"
    _mr_tpl
    _st
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [ "$(_ev_line files)" = "files: 0 changed" ]
    _pe
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
}

@test "#894 A1 attested stamp passes the checker with the same attestation" {
    local h att
    h="$(git rev-parse HEAD)"; att="head=$h dirty=no path=$FOREIGN_TREE"
    _hand_art "$h" "$FOREIGN_TREE" "1/1 notok=0" "(none)" "$PLAT"
    _mr_tpl
    _st --attest-tree "$att"
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$output" == *"[tree=attested: head="* ]]
    _pe --attest-tree "$att"
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$output" == *"[tree=attested:"* ]]
}

@test "#894 A2 an unneeded attestation is warned about and ignored" {
    local h
    h="$(git rev-parse HEAD)"
    _hand_art "$h" "$(_canon)" "1/1 notok=0" "(none)" "$PLAT"
    _mr_tpl
    _st --attest-tree "head=$h dirty=no path=$FOREIGN_TREE"
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$output" == *"evidence-stamp: --attest-tree ignored"* ]]
    [[ "$output" == *"[tree=checked]"* ]]
}

@test "#894 U1 usage contract" {
    local -a c
    run bash -c '"$1" --help 2>/dev/null' _ "$ST"
    [ "$status" -eq 0 ]
    [ "$output" = "$USAGE" ]
    # Each case: stderr only, rc 2, the usage line named.
    for c in "--bogus" "--attest-tree" "--attest-tree=" "--attest-tree=a --attest-tree=b" "extra"; do
        # shellcheck disable=SC2086  # word splitting is the case list's encoding
        run bash -c '"$@" 2>&1 >/dev/null' _ "$ST" "$TEST_PROJECT" Issue-1 $c
        [ "$status" -eq 2 ] || { echo "'$c': rc $status: $output"; return 1; }
        [[ "$output" == *"usage: evidence-stamp.sh"* ]] || { echo "'$c': $output"; return 1; }
    done
}

@test "#894 U2 issue precedence" {
    _shape bats; _rs; _mr_tpl; _save
    run "$ST" "$TEST_PROJECT"
    _refused "ISSUE UNSTATED"
    DEVAGENT_ACTIVE_ISSUE=Issue-1 run "$ST" "$TEST_PROJECT"
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$(_ev_line suite)" == "suite: 1/1 bats @ $(git rev-parse HEAD)" ]]
}

# --- Task 4: only the three lines change ----------------------------------------

# _mr_fx <lf|crlf> <suite body|-> <files body|-> <platform body|-> [noeol]
# One fixed mr.md: prose, a column-0 decoy suite: outside the block, an HTML comment with
# an indented suite: in the block, the three lines (a '-' omits one), the analyzer: and
# born-red: lines, and a hand-written Checklist. noeol ends the file at the Evidence
# lines, the last one unterminated.
_mr_fx() {
    local eol=$'\n' out="" i n
    [ "$1" = crlf ] && eol=$'\r\n'
    local -a ls=('## Summary' 'Prose about the change.' '' '## Testing'
        'suite: prose outside the block' '' '## Evidence'
        '<!-- written by the stamper; a comment it must not touch:'
        '       both -> suite: <bats-ok>/<bats-plan> bats @ <full head sha>'
        '     end of comment -->')
    [ "$2" = - ] || ls+=("suite: $2")
    [ "$3" = - ] || ls+=("files: $3")
    [ "$4" = - ] || ls+=("platform: $4")
    if [ "${5:-}" != noeol ]; then
        ls+=('analyzer: shellcheck 0.10.0' 'born-red: PASS (3 legs)' '' '## Checklist'
             '- [x] Commits are signed off')
    fi
    n="${#ls[@]}"
    for ((i = 0; i < n; i++)); do
        out+="${ls[i]}"
        if [ "$i" -lt $((n - 1)) ] || [ "${5:-}" != noeol ]; then out+="$eol"; fi
    done
    printf '%s' "$out"
}
S0="<bats-ok>/<bats-plan> bats, <pytest-passed> pytest @ <full head sha>"
F0="<n> changed"
P0="<replace this line with the artifact's platform: line, copied whole>"
# _fx_art - a real bats-only artifact; sets WANT_S/WANT_F/WANT_P to the stamped bodies.
_fx_art() {
    local p
    _shape bats; _rs
    p="$(grep '^platform:' "$(_art)")"
    WANT_S="1/1 bats @ $(git rev-parse HEAD)"; WANT_F="$(_diff_n) changed"; WANT_P="${p#platform: }"
}

@test "#894 B1 LF block: only the three lines change, and a second run is a no-op" {
    _fx_art
    printf '%s\n' '=== shellcheck (diff-scoped + untracked) ===' 'analyzer: shellcheck 0.10.0' \
        > "$DEVDOC_DIR/Issue-1/analysis/2026-10-26-shellcheck.txt"
    _mr_fx lf "$S0" "$F0" "$P0" > "$MR"
    _st
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    _mr_fx lf "$WANT_S" "$WANT_F" "$WANT_P" > "$DEVAGENT_TMP/want"
    cmp "$DEVAGENT_TMP/want" "$MR"
    _pe
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    cp "$MR" "$DEVAGENT_TMP/first"
    _st
    [ "$status" -eq 0 ]
    [[ "$output" == *"unchanged"* ]]
    cmp "$DEVAGENT_TMP/first" "$MR"
}

@test "#894 B2 CRLF block keeps every CR" {
    _fx_art
    _mr_fx crlf "$S0" "$F0" "$P0" > "$MR"
    _st
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    _mr_fx crlf "$WANT_S" "$WANT_F" "$WANT_P" > "$DEVAGENT_TMP/want"
    cmp "$DEVAGENT_TMP/want" "$MR"
    [ "$(_cr_count "$MR")" -eq "$(wc -l < "$MR")" ]
    _st
    [ "$status" -eq 0 ]
    [[ "$output" == *"unchanged"* ]]
    cmp "$DEVAGENT_TMP/want" "$MR"
    [ "$(_cr_count "$MR")" -eq "$(wc -l < "$MR")" ]
}

@test "#894 B3 missing files and platform lines are inserted after suite" {
    _fx_art
    _mr_fx crlf "$S0" - - > "$MR"
    _st
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    _mr_fx crlf "$WANT_S" "$WANT_F" "$WANT_P" > "$DEVAGENT_TMP/want"
    cmp "$DEVAGENT_TMP/want" "$MR"
}

@test "#894 B4 an unterminated final platform line stays unterminated" {
    _fx_art
    _mr_fx lf "$S0" "$F0" "$P0" noeol > "$MR"
    _st
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    _mr_fx lf "$WANT_S" "$WANT_F" "$WANT_P" noeol > "$DEVAGENT_TMP/want"
    cmp "$DEVAGENT_TMP/want" "$MR"
    [ "$(tail -c 1 "$MR" | od -An -c | tr -d ' ')" != '\n' ]
    # files: ending the file unterminated: it gains the file's terminator, and the
    # inserted platform: line is the one left unterminated.
    _mr_fx crlf "$S0" "$F0" - noeol > "$MR"
    _st
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    _mr_fx crlf "$WANT_S" "$WANT_F" "$WANT_P" noeol > "$DEVAGENT_TMP/want"
    cmp "$DEVAGENT_TMP/want" "$MR"
}

@test "#894 B5a no Evidence block warns and leaves mr.md alone" {
    printf '## Summary\nno evidence block here\n' > "$MR"; _save
    _st
    [ "$status" -eq 0 ]
    [[ "$output" == *"mr.md has no '## Evidence' block — nothing to stamp (#149)"* ]]
    cmp -s "$DEVAGENT_TMP/mr.before" "$MR"
}

@test "#894 B5b two suite lines die unchanged, before any refusal" {
    _hand_art "$BASELINE$BASELINE" "$(_canon)" "1/1 notok=0" "(none)" "$PLAT"   # stale too
    printf '## Evidence\nsuite: a\nsuite: b\nfiles: 1 changed\n' > "$MR"; _save
    _st
    _refused "'suite:' lines — keep one"
    [[ "$output" != *"REFUSED"* ]]
}

@test "#894 B5c an embedded NUL dies unchanged" {
    printf '## Evidence\nsuite: a\0b\nfiles: 1 changed\n' > "$MR"; _save
    _st
    _refused "NUL bytes"
}
