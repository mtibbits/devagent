#!/usr/bin/env bats
# #565: run-suite.sh's only product is a provenance artifact that
# preship-evidence.sh consumes as authority. On a filesystem where chmod is a
# no-op (Windows noacl NTFS) a suite that asserts file modes fails wholesale,
# so an artifact written there is authoritative-looking false evidence
# (Issue-550's lesson). run-suite.sh therefore refuses — since #600 only when
# the suite REFERENCES a file mode (suite_mode_reference); otherwise it proceeds
# and records `file_modes: no-op; …` in the artifact.
#
# These tests drive run-suite.sh END TO END rather than grepping its source: a
# structural assertion would pass on `if false; then …probe…; fi` and redden on
# any innocuous reflow. The probe itself (posix_modes_representable, #289) is
# tested in tests/lib_secrets.bats; its #600 sibling suite_mode_reference is
# tested at the bottom of this file.
load 'helpers/common'

setup() {
    devagent_test_setup
    cd "$SOURCE_DIR" || return
    mkdir -p "$DEVAGENT_TMP/binstub"
    # Stub bats so run-suite's own bats branch is deterministic and fast.
    printf '%s\n' '#!/usr/bin/env bash' 'echo "1..1"' 'echo "ok 1 a"' \
        > "$DEVAGENT_TMP/binstub/bats"
    chmod +x "$DEVAGENT_TMP/binstub/bats"
}
teardown() { devagent_test_teardown; }

_seed_suite() {   # [<body of tests/x.bats>]
    mkdir -p tests && printf '%s\n' "${1:-# placeholder}" > tests/x.bats
    git add -A && git commit -q -m "seed tests"
}

# The tests/lib_secrets.bats technique: chmod no-ops and stat reports 644, so a
# posix_modes_representable probe file reads back != 600 on ANY platform.
_stub_noop_chmod() {
    printf '%s\n' '#!/usr/bin/env bash' 'exit 0'   > "$DEVAGENT_TMP/binstub/chmod"
    printf '%s\n' '#!/usr/bin/env bash' 'echo 644' > "$DEVAGENT_TMP/binstub/stat"
    chmod +x "$DEVAGENT_TMP/binstub/chmod" "$DEVAGENT_TMP/binstub/stat"
}

_run_suite() { PATH="$DEVAGENT_TMP/binstub:$PATH" run "$DEVAGENT_ROOT/scripts/run-suite.sh" "$TEST_PROJECT"; }
_art() { ls "$DEVDOC_DIR/Issue-1/analysis/"*-suite-count.txt; }
_no_artifact() {
    run bash -c "ls '$DEVDOC_DIR/Issue-1/analysis/'*-suite-count.txt 2>/dev/null | wc -l"
    [ "$output" = "0" ]
}

# _wrap_stub <cmd> <intercept-line>: a binstub that runs <intercept-line> and
# otherwise execs the REAL <cmd>, so only the call under test is faked.
_wrap_stub() {
    local real; real="$(command -v "$1")"
    printf '%s\n' '#!/usr/bin/env bash' "$2" "exec '$real' \"\$@\"" > "$DEVAGENT_TMP/binstub/$1"
    chmod +x "$DEVAGENT_TMP/binstub/$1"
}

# The producer's one no-op spelling (run-suite.sh), pinned exactly.
NOOP_LINE='file_modes: no-op; no test file references a file mode (scanned: tests/ + root conftest.py)'

# The guard must stay SILENT where its trigger is legitimately absent
# (#Fork-195) — a project with no suite at all still gets its artifact.
@test "#565: a tests-less tree still writes its artifact (preflight does not fire)" {
    git commit -q --allow-empty -m "no tests here"
    _run_suite
    [ "$status" -eq 0 ]
    art="$(_art)"
    grep -q '^bats: (none)$' "$art"
    grep -qx 'file_modes: (none)' "$art"
}

@test "#565: a tree WITH a suite still writes its artifact where chmod works" {
    _seed_suite
    local t="$SOURCE_DIR/.pc"; : > "$t"; chmod 600 "$t"
    [ "$(stat -c '%a' "$t" 2>/dev/null)" = 600 ] || skip "chmod is a no-op here; the die branch is asserted below"
    rm -f "$t"
    _run_suite
    [ "$status" -eq 0 ]
    grep -qx 'file_modes: posix' "$(_art)"
}

# Drives the real refusal branch on ANY platform via _stub_noop_chmod. Since #600
# the suite must REFERENCE a mode for the refusal to fire, and the refusal names
# what it saw.
@test "#565: run-suite REFUSES and writes NO artifact when chmod is a no-op and the suite references a mode" {
    _seed_suite 'chmod 600 "$f"'
    _stub_noop_chmod
    _run_suite
    [ "$status" -ne 0 ]
    [[ "$output" == *"chmod is a NO-OP"* ]]
    [[ "$output" == *"false evidence"* ]]
    [[ "$output" == *"1 lines; first: tests/x.bats:1:"* ]]
    _no_artifact
}

@test "#565: the refusal names the WSL remedy and a README section that exists" {
    # Two-sided constant (#106): the message points at a heading, so a rename
    # must redden here instead of silently misdirecting the reader.
    run grep -q '^## Running the test suite$' "$DEVAGENT_ROOT/README.md"
    [ "$status" -eq 0 ]
    run grep -q "Running the test suite" "$DEVAGENT_ROOT/scripts/run-suite.sh"
    [ "$status" -eq 0 ]
    run grep -q 'WSL clone on ext4' "$DEVAGENT_ROOT/scripts/run-suite.sh"
    [ "$status" -eq 0 ]
}

# ---- #600: the refusal fires only when the suite could be asserting modes ----

# #600's point: a suite with NO mode reference proceeds, and the artifact says what
# was NOT seen — never "modes verified".
@test "#600: chmod no-op + a suite that references no file mode PROCEEDS and records it" {
    _seed_suite '@test "t" { true; }'
    _stub_noop_chmod
    _run_suite
    [ "$status" -eq 0 ]
    [[ "$output" == *"no test file references a file mode"* ]]   # the stderr warn
    art="$(_art)"
    grep -qx "$NOOP_LINE" "$art"
    grep -q '^bats: 1/1 ' "$art"            # a real artifact, not a stub of one
}

# The scan is recursive: helpers are part of the suite.
@test "#600: a mode reference only in a tests/ subdirectory still REFUSES" {
    mkdir -p tests/helpers && echo 'umask 077' > tests/helpers/common.bash
    _seed_suite '@test "t" { true; }'
    _stub_noop_chmod
    _run_suite
    [ "$status" -ne 0 ]
    [[ "$output" == *"first: tests/helpers/common.bash:1:"* ]]
    _no_artifact
}

# pytest loads a root conftest.py from outside tests/.
@test "#600: a mode reference only in the root conftest.py still REFUSES" {
    echo 'os.chmod(p, m)' > conftest.py
    _seed_suite '@test "t" { true; }'
    _stub_noop_chmod
    _run_suite
    [ "$status" -ne 0 ]
    [[ "$output" == *"first: conftest.py:1:"* ]]
    _no_artifact
}

# The trigger agrees with the pytest MEASUREMENT (recursive, #605): a tree whose
# only tests are nested is a suite, so (none) would be a false claim.
@test "#600: a nested-only pytest tree is gated (never file_modes: (none))" {
    mkdir -p tests/unit && echo 'def test_ok(): pass' > tests/unit/test_x.py
    git add -A && git commit -q -m "nested pytest only"
    _wrap_stub python3 'case "$*" in *pytest*) echo "1 passed in 0.01s"; exit 0 ;; esac'
    _stub_noop_chmod
    _run_suite
    [ "$status" -eq 0 ]
    art="$(_art)"
    grep -qx "$NOOP_LINE" "$art"
    grep -q '^pytest: 1 passed' "$art"
}

# Could-not-determine fails CLOSED. Executes the real branch via a grep shim that
# fails only the predicate's recursive scan (-RnIE), passing every other grep through.
@test "#600: a failed mode scan REFUSES (fail closed), no artifact" {
    _seed_suite '@test "t" { true; }'
    _stub_noop_chmod
    _wrap_stub grep '[ "$1" = "-RnIE" ] && exit 2'
    _run_suite
    [ "$status" -ne 0 ]
    [[ "$output" == *"could not scan"* ]]
    _no_artifact
}

# A grep that can match NOTHING (a dialect that empties the token set) must not
# read as "no reference": the positive control inside the predicate catches it.
# The shim is keyed on the token ERE itself, so every other grep run-suite and
# its libs make (active.sh's own `grep -qE`, the TAP counters) passes through.
@test "#600: a grep that matches nothing fails the positive control and REFUSES" {
    _seed_suite '@test "t" { true; }'
    _stub_noop_chmod
    _wrap_stub grep 'case "$*" in *"chmod|fchmod"*) exit 1 ;; esac'
    _run_suite
    [ "$status" -ne 0 ]
    [[ "$output" == *"could not scan"* ]]
    _no_artifact
}

# ---- #600: suite_mode_reference, the predicate ----
# Rows, not "alternatives": each row pins one spelling, and the mutation record
# (analysis/<date>-mutation.txt) names the row each ERE clause's deletion reddens.
# The must-not-match rows include the REAL false positives the issue's own
# suggested regex hit (lectio, factorAI, lawfirm; #600 draft measurement).
_load_predicate() {
    . "$DEVAGENT_ROOT/scripts/lib/secrets.sh"
    type suite_mode_reference >/dev/null   # absence reddens HERE, not as a false rc (#337)
}
_mode_case() {  # <expected-rc> <line> — one row, one file, rewritten per row
    mkdir -p "$DEVAGENT_TMP/mc"; printf '%s\n' "$2" > "$DEVAGENT_TMP/mc/t.txt"
    local rc=0; suite_mode_reference "$DEVAGENT_TMP/mc" || rc=$?
    [ "$rc" -eq "$1" ] || { echo "rc=$rc want=$1 line: $2"; return 1; }
}

@test "#600: suite_mode_reference matches every mode-token row" {
    _load_predicate
    local -a hit=(
        'chmod 600 "$f"'
        'os.fchmod(fd, m)'
        'os.lchmod(p, m)'
        'umask 077'
        'm = p.stat().st_mode'
        'stat.S_IMODE(m)'
        'm & stat.S_IRUSR'
        'm & stat.S_IRGRP'
        'm & stat.S_IWOTH'
        'm & stat.S_IRWXG'
        'os.access(p, mode)'
        'flag = os.R_OK'
        'flag = os.W_OK'
        'flag = os.X_OK'
        'pytest.raises(PermissionError)'
        'errno.EACCES'
        'shutil.copymode(a, b)'
        'stat.filemode(m)'
        "stat -c '%a' \"\$f\""
        "stat -f '%Lp' \"\$f\""
        'stat --format=%a "$f"'
        "stat --printf '%a' \"\$f\""
        "stat -L -c '%a' \"\$f\""
        "stat -Lc '%a' \"\$f\""
        'ls -l "$f"'
        '[[ "$(ls -ld "$d")" == drwx* ]]'
        'mkdir -m 700 "$d"'
        'mkdir --mode=700 "$d"'
        'install -m 600 a b'
        'install --mode=600 a b'
        'os.open(p, flags, 0o600)'
    )
    local n=0 l
    for l in "${hit[@]}"; do _mode_case 0 "$l"; n=$((n + 1)); done
    [ "$n" -eq 31 ]   # subject COUNT, so a silently emptied array cannot pass (#151)
}

@test "#600: suite_mode_reference ignores non-mode near-misses (incl. measured false positives)" {
    _load_predicate
    local -a miss=(
        'def test_mode():'
        'def test_mode_split_ensemble_not_overstated_and_rhat_flags_it():'
        '#: permission text, and presenting a composed string as a quotation'
        'assert "Permission is hereby granted, free of charge" in text'
        '    "permission_denials": [],'
        'assert stat.S_ISDIR(m)'
        'chmodder = 1'
        'x = 0o12'
        'status -c foo'
        'lsof -l'
        'ls tests/'
        'ls -a "$d"'
    )
    local n=0 l
    for l in "${miss[@]}"; do _mode_case 1 "$l"; n=$((n + 1)); done
    [ "$n" -eq 12 ]
}

@test "#600: suite_mode_reference names the lexically-first hit, counts all, fails CLOSED on error" {
    _load_predicate
    mkdir -p "$DEVAGENT_TMP/s/tests" && cd "$DEVAGENT_TMP/s"
    # b.bats written FIRST, and a.bats hits at lines 2 and 10: the first hit must
    # be a.bats:2 whatever the readdir order and despite "10" < "2" lexically.
    printf 'chmod 600 f\n' > tests/b.bats
    printf 'x\numask 077\nx\nx\nx\nx\nx\nx\nx\nchmod 600 g\n' > tests/a.bats
    local rc=0; suite_mode_reference tests || rc=$?
    [ "$rc" -eq 0 ]
    [ "$SUITE_MODE_HIT" = "tests/a.bats:2:umask 077" ]
    [ "$SUITE_MODE_COUNT" -eq 3 ]
    rc=0; suite_mode_reference "$DEVAGENT_TMP/does-not-exist" || rc=$?
    [ "$rc" -eq 2 ]                  # -eq 2, never -ne 0: rc 1 would be a false "clean" (#337)
    [ -z "$SUITE_MODE_HIT" ]         # reset on every call: a stale hit cannot leak forward
    [ "$SUITE_MODE_COUNT" -eq 0 ]
}

@test "#600: suite_mode_reference follows a symlinked helper" {
    _load_predicate
    mkdir -p "$DEVAGENT_TMP/y/tests" "$DEVAGENT_TMP/y/shared" && cd "$DEVAGENT_TMP/y"
    echo 'umask 077' > shared/helper.bash
    ln -s ../shared/helper.bash tests/helper.bash
    local rc=0; suite_mode_reference tests || rc=$?
    [ "$rc" -eq 0 ]
    [ "$SUITE_MODE_HIT" = "tests/helper.bash:1:umask 077" ]
}

@test "#600: suite_mode_reference fails CLOSED when grep cannot match its own control" {
    _load_predicate
    mkdir -p "$DEVAGENT_TMP/z/tests" "$DEVAGENT_TMP/g1" && cd "$DEVAGENT_TMP/z"
    echo 'true' > tests/a.bats
    printf '%s\n' '#!/usr/bin/env bash' 'exit 1' > "$DEVAGENT_TMP/g1/grep"
    chmod +x "$DEVAGENT_TMP/g1/grep"
    local rc=0; ( PATH="$DEVAGENT_TMP/g1:$PATH"; suite_mode_reference tests ) || rc=$?
    [ "$rc" -eq 2 ]
}
