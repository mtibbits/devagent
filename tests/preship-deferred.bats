#!/usr/bin/env bats
# bats file_tags=gitbash
# #1097 preship-deferred.sh — what the preship verifier asks about an acceptance
# criterion that a required CI check meets only after ship: the project's required
# checks, whether its code backend can report them, a self-certification line, the
# criterion's static half and the fallback hand transcript. Every read is at the
# pinned head (preship_pin_head), never the working tree.
#
# Invariant: line 2 is the only comment line of this file that may hold both the tag
# key and the tag value (scripts/ci/gitbash-tagged.sh calls any other one malformed).
# A fixture's tag line is always the TAG variable.
load 'helpers/common'
bats_require_minimum_version 1.5.0

TAG='# bats file_tags=gitbash'

setup() {
    devagent_test_setup
    CFG="$HOME/.claude/devagent/config.toml"
    ST="$HOME/.claude/devagent/state/$TEST_PROJECT.toml"
    ISSUE_DIR="$DEVDOC_DIR/Issue-1"
    PD="$DEVAGENT_ROOT/scripts/preship-deferred.sh"
    USAGE="usage: preship-deferred.sh <project> <Issue-N> [static <check> <test-file> <test-name> | transcript <test-file>]"
    cd "$SOURCE_DIR" || return
}
teardown() { devagent_test_teardown; }

# _pd [args...] - run the script with stdout and stderr apart.
_pd() { run --separate-stderr "$PD" "$@"; }

# ---- usage ---------------------------------------------------------------------------

# shellcheck disable=SC2154  # $stderr is set by `run --separate-stderr`
@test "#1097 deferred: a bare call exits 2 with usage" {
    _pd
    [ "$status" -eq 2 ]; [ -z "$output" ]; [ "$stderr" = "$USAGE" ]
}

# shellcheck disable=SC2154
@test "#1097 deferred: a wrong argument count, an empty argument or an unknown subcommand exits 2 with usage" {
    local c
    for c in "$TEST_PROJECT" "$TEST_PROJECT Issue-1 static" "$TEST_PROJECT Issue-1 static Zeta tests/a.bats" \
             "$TEST_PROJECT Issue-1 static Zeta tests/a.bats name extra" "$TEST_PROJECT Issue-1 transcript" \
             "$TEST_PROJECT Issue-1 transcript tests/a.bats extra" "$TEST_PROJECT Issue-1 verify" \
             "$TEST_PROJECT Issue-1 --help"; do
        # shellcheck disable=SC2086  # word-split each case on purpose
        _pd $c
        [ "$status" -eq 2 ] || { echo "$c: rc $status"; return 1; }
        [ -z "$output" ]; [ "$stderr" = "$USAGE" ]
    done
    _pd "" Issue-1
    [ "$status" -eq 2 ]; [ -z "$output" ]; [ "$stderr" = "$USAGE" ]
    _pd "$TEST_PROJECT" Issue-1 static "Zeta check" tests/a.bats ""
    [ "$status" -eq 2 ]; [ -z "$output" ]; [ "$stderr" = "$USAGE" ]
}

# ---- fixtures --------------------------------------------------------------------------

ZETA="Zeta check"
WF=.github/workflows/ci.yml

# _proj_key <key> <toml value>: insert `<key> = <value>` right after the
# [project.$TEST_PROJECT] header. Fails unless exactly one header took the insert.
_proj_key() {
    local line out="" n=0
    while IFS= read -r line; do
        out+="$line"$'\n'
        if [ "$line" = "[project.$TEST_PROJECT]" ]; then out+="$1 = $2"$'\n'; n=$((n + 1)); fi
    done < "$CFG"
    [ "$n" -eq 1 ] || { echo "_proj_key: [project.$TEST_PROJECT] matched $n header lines in $CFG" >&2; return 1; }
    printf '%s' "$out" > "$CFG"
}
# _req: the project requires the check $ZETA.
_req() { _proj_key required_checks "[\"$ZETA\"]"; }
# _backend <name>: the project's code backend.
_backend() { devagent_config_set "$CFG" "project.$TEST_PROJECT.code_source.backend" "$1"; }
# _put <path> <line>...: write <path> in the issue tree, one argument per line.
_put() {
    local p="$SOURCE_DIR/$1"; shift
    mkdir -p "$(dirname "$p")"
    printf '%s\n' "$@" > "$p"
}
# _commit: commit every change in the issue tree. AT is the new commit.
_commit() {
    git -C "$SOURCE_DIR" add -A && git -C "$SOURCE_DIR" commit -q --allow-empty -m "${1:-c}"
    AT="$(git -C "$SOURCE_DIR" rev-parse HEAD)"
}
# _base: the changes so far are the base's (baseline_sha, BASE).
_base() { _commit base; BASE="$AT"; devagent_state_set "$ST" baseline_sha "$BASE"; }
# _pin: the changes since are the branch's; their commit is the pinned head (PIN).
_pin() { _commit head; PIN="$AT"; devagent_state_set "$ST" preship_pin_head "$PIN"; }
# _cnr <text>: the last run could not run: exit 2, nothing on stdout, <text> on stderr.
_cnr() {
    [ "$status" -eq 2 ] || { echo "rc $status, stdout: $output, stderr: $stderr"; return 1; }
    [ -z "$output" ] || { echo "stdout: $output"; return 1; }
    [[ "$stderr" == *"$1"* ]] || { echo "stderr: $stderr"; return 1; }
}
# _lines <line>...: the last run exited 0 and printed exactly these lines.
_lines() {
    [ "$status" -eq 0 ] || { echo "rc $status, stdout: $output, stderr: $stderr"; return 1; }
    [ "$output" = "$(printf '%s\n' "$@")" ] || { printf 'stdout:\n%s\nwant:\n%s\n' "$output" "$(printf '%s\n' "$@")"; return 1; }
}

# ---- the bare call: required checks, capability, self-certification ---------------------

@test "#1097 no key: one line, exit 0, no pin needed" {
    _pd "$TEST_PROJECT" Issue-1
    _lines "required checks: (none)"
    [ -z "$stderr" ]
    _proj_key required_checks "[]"                 # an empty list is no list
    _pd "$TEST_PROJECT" Issue-1
    _lines "required checks: (none)"
}

@test "#1097 no pin with a key: exit 2" {
    _req
    _base
    _pd "$TEST_PROJECT" Issue-1
    _cnr "preship-deferred: no pinned head is recorded for Issue-1 (preship_pin_head)"
    _pin                                           # the survivor: the same call with a pin
    _pd "$TEST_PROJECT" Issue-1
    [ "$status" -eq 0 ]
}

@test "#1097 no baseline, a pin that is not a commit id, and a pin the tree lacks each exit 2 and print nothing" {
    _req
    _pin
    devagent_state_set "$ST" baseline_sha ""
    _pd "$TEST_PROJECT" Issue-1
    _cnr "preship-deferred: no baseline_sha is recorded for Issue-1"
    _base
    devagent_state_set "$ST" preship_pin_head "main"
    _pd "$TEST_PROJECT" Issue-1
    _cnr "preship-deferred: preship_pin_head 'main' is not a full commit id"
    devagent_state_set "$ST" preship_pin_head "1111111111111111111111111111111111111111"
    _pd "$TEST_PROJECT" Issue-1
    _cnr "preship-deferred: 1111111 is not a commit in $SOURCE_DIR"
}

@test "#1097 warning: no change, and an added tag line, give the no-change line" {
    _req
    _put tests/a.bats '#!/usr/bin/env bats' '@test "a" {' '  true' '}'
    _base
    _put f.txt one
    _pin
    _pd "$TEST_PROJECT" Issue-1
    _lines "required checks: $ZETA" "code backend: github (mr-checks: yes)" \
        "self-certification: nothing self-certifying changed in ${BASE:0:7}..${PIN:0:7}"
    [ -z "$stderr" ]
    _put tests/a.bats '#!/usr/bin/env bats' "$TAG" '@test "a" {' '  true' '}'
    _put tests/new.bats '#!/usr/bin/env bats' "$TAG" '@test "n" {' '  true' '}'
    _pin
    _pd "$TEST_PROJECT" Issue-1
    _lines "required checks: $ZETA" "code backend: github (mr-checks: yes)" \
        "self-certification: nothing self-certifying changed in ${BASE:0:7}..${PIN:0:7}"
}

@test "#1097 warning: a workflow file, and a file under a listed path, each give the one warning line, exit 0" {
    _proj_key required_checks "[\"$ZETA\", \"Eta check\"]"
    _put "$WF" 'name: ci'
    _put scripts/ci/gate.sh 'echo gate'
    _base
    _put "$WF" 'name: ci' 'on: push'
    _pin
    _pd "$TEST_PROJECT" Issue-1
    _lines "required checks: $ZETA; Eta check" "code backend: github (mr-checks: yes)" \
        "self-certification warning: $WF changed in ${BASE:0:7}..${PIN:0:7}; mergemr stops [!] until an operator records a review in .devagent-selfcert-ack"
    # a listed path: named only with the paths key
    git -C "$SOURCE_DIR" reset -q --hard "$BASE"
    _put scripts/ci/gate.sh 'echo gate' 'echo more'
    _pin
    _pd "$TEST_PROJECT" Issue-1
    _lines "required checks: $ZETA; Eta check" "code backend: github (mr-checks: yes)" \
        "self-certification: nothing self-certifying changed in ${BASE:0:7}..${PIN:0:7}"
    _proj_key required_checks_paths '["scripts/ci/"]'
    _pd "$TEST_PROJECT" Issue-1
    _lines "required checks: $ZETA; Eta check" "code backend: github (mr-checks: yes)" \
        "self-certification warning: scripts/ci/gate.sh changed in ${BASE:0:7}..${PIN:0:7}; mergemr stops [!] until an operator records a review in .devagent-selfcert-ack"
}

@test "#1097 warning: a diff that cannot be read exits 2 with the scan's reason" {
    _req
    _proj_key required_checks_paths '["tools/absent/"]'
    _base
    _put f.txt one
    _pin
    _pd "$TEST_PROJECT" Issue-1
    _cnr "preship-deferred: required_checks_paths entry 'tools/absent/' names no path at ${BASE:0:7} or ${PIN:0:7}"
}

# _callrec: a stand-in for gh that records that it ran.
_callrec() {
    CALLED="$DEVAGENT_TMP/called"
    printf '%s\n' '#!/usr/bin/env bash' "echo called >> '$CALLED'" 'exit 1' > "$DEVAGENT_TMP/rec"
    chmod +x "$DEVAGENT_TMP/rec"
    export DEVAGENT_GH="$DEVAGENT_TMP/rec"
}
# _capline: the code backend line of the last run.
_capline() { sed -n 2p <<<"$output"; }

@test "#1097 deferred: code backend line says mr-checks: no for local and custom, yes for github" {
    _req
    _base
    _pin
    _callrec
    local b
    for b in local custom; do
        _backend "$b"
        _pd "$TEST_PROJECT" Issue-1
        [ "$status" -eq 0 ] || { echo "$b: rc $status $stderr"; return 1; }
        [ "$(_capline)" = "code backend: $b (mr-checks: no)" ] || { echo "$b: $output"; return 1; }
    done
    _backend github
    _pd "$TEST_PROJECT" Issue-1
    [ "$status" -eq 0 ]
    [ "$(_capline)" = "code backend: github (mr-checks: yes)" ]
    [ ! -e "$CALLED" ]                              # decided without a call
}

# The line is read from the backend script's text. This holds it equal to what each
# shipped backend answers when asked: `mr-checks` with no URL exits 78 (not
# implemented) or 2 (no such verb) exactly where lib/ci.sh reads "not checked", and
# an implementing backend exits 1 (bad arguments, never 2: spec 9.2). No URL, so
# nothing is looked up.
@test "#1097 deferred: the code backend line agrees with each shipped backend's own answer to mr-checks" {
    _req
    _base
    _pin
    _callrec
    local f b rc want n=0
    for f in "$DEVAGENT_ROOT"/scripts/code/*.sh; do
        b="$(basename "$f" .sh)"
        rc=0
        "$f" mr-checks </dev/null >/dev/null 2>&1 || rc=$?
        case "$rc" in 78|2) want=no ;; *) want=yes ;; esac
        _backend "$b"
        _pd "$TEST_PROJECT" Issue-1
        [ "$status" -eq 0 ] || { echo "$b: rc $status $stderr"; return 1; }
        [ "$(_capline)" = "code backend: $b (mr-checks: $want)" ] || { echo "$b (its exit: $rc): $(_capline)"; return 1; }
        n=$((n + 1))
    done
    [ "$n" -ge 4 ]                                  # github, gitlab, local, custom
    [ ! -e "$CALLED" ]
}

@test "#1097 deferred: a backend script is read, never run; a not-implemented arm, no arm and no backend read no; a missing script exits 2" {
    _req
    _base
    _pin
    local d="$DEVAGENT_TMP/backends" ran="$DEVAGENT_TMP/ran"
    mkdir -p "$d"
    export DEVAGENT_CODE_BACKEND_DIR="$d"
    printf '%s\n' '#!/usr/bin/env bash' "echo ran >> '$ran'" 'case "$1" in' '  mr-state|mr-checks)' '    echo open' '    ;;' \
        '  *) exit 2 ;;' 'esac' > "$d/has.sh"
    printf '%s\n' '#!/usr/bin/env bash' "echo ran >> '$ran'" 'case "$1" in' '  mr-state) echo open ;;' \
        '  merge-mr|mr-checks|mr-view)' '    echo "$1: not implemented" >&2' '    exit 78' '    ;;' '  *) exit 2 ;;' 'esac' > "$d/stub.sh"
    printf '%s\n' '#!/usr/bin/env bash' "echo ran >> '$ran'" '#   mr-state|mr-checks)   an arm that is commented out' 'case "$1" in' \
        '  mr-state) echo "usage: mr-checks) <url>" ;;' '  *) exit 2 ;;' 'esac' > "$d/none.sh"
    # the local backend is never asked, whatever its script holds (lib/ci.sh: not applicable)
    cp "$d/has.sh" "$d/local.sh"
    chmod +x "$d"/*.sh
    local b want
    for b in has:yes stub:no none:no local:no; do
        want="${b#*:}"; b="${b%%:*}"
        _backend "$b"
        _pd "$TEST_PROJECT" Issue-1
        [ "$status" -eq 0 ] || { echo "$b: rc $status $stderr"; return 1; }
        [ "$(_capline)" = "code backend: $b (mr-checks: $want)" ] || { echo "$b: $(_capline)"; return 1; }
    done
    [ ! -e "$ran" ]
    devagent_config_unset "$CFG" "project.$TEST_PROJECT.code_source.backend"
    _pd "$TEST_PROJECT" Issue-1
    [ "$status" -eq 0 ]
    [ "$(_capline)" = "code backend: (none) (mr-checks: no)" ]
    _backend ghost
    _pd "$TEST_PROJECT" Issue-1
    _cnr "preship-deferred: ghost.sh not found or not executable"
}

# ---- could not run is 2, never 1; quarantine is 11 ----------------------------------------

@test "#1097 deferred: an unknown project, an issue with no directory and a bad required_checks value each exit 2 and print nothing" {
    _pd nosuchproj Issue-1
    _cnr "preship-deferred: unknown project 'nosuchproj'"
    _pd "$TEST_PROJECT" Issue-404
    _cnr "preship-deferred: no issue directory for Issue-404"
    _pd "$TEST_PROJECT" 'Issue 1'
    _cnr "is not a valid issue id"
    _proj_key required_checks "\"$ZETA\""           # a string where the key takes an array
    _pd "$TEST_PROJECT" Issue-1
    _cnr "required_checks must be an array of single-line strings"
    [[ "$stderr" == *"preship-deferred: could not run"* ]]
}

@test "#1097 deferred: a quarantined issue is refused with exit 11" {
    _req
    _base
    _pin
    printf 'devagent-quarantine 1\nkey github:github.com/acme/testproj#1\nreason screen\nevent ? ?\n' > "$ISSUE_DIR/QUARANTINE"
    _pd "$TEST_PROJECT" Issue-1
    [ "$status" -eq 11 ] || { echo "rc $status: $stderr"; return 1; }
    [ -z "$output" ]
    [[ "$stderr" == *"QUARANTINED: github:github.com/acme/testproj#1 is held"* ]]
    rm -f "$ISSUE_DIR/QUARANTINE"                   # the survivor
    _pd "$TEST_PROJECT" Issue-1
    [ "$status" -eq 0 ]
}

# ---- static: the criterion's half that can be read before ship ---------------------------

FIX="$BATS_TEST_DIRNAME/fixtures/preship-deferred"
OK_LINE="deferred to CI at merge: $ZETA"

# _fixture <name>...: the fixture files, committed as tests/<name>; that commit pinned.
_fixture() {
    local f
    mkdir -p "$SOURCE_DIR/tests"
    for f in "$@"; do cp "$FIX/$f" "$SOURCE_DIR/tests/$f"; done
    _pin
}
# _static <test-file> <test-name> [<check>]
_static() { _pd "$TEST_PROJECT" Issue-1 static "${3:-$ZETA}" "$1" "$2"; }
# _deferred: the last run passed: exit 0 and the one line, nothing on stderr.
_deferred() {
    [ "$status" -eq 0 ] || { echo "rc $status, stdout: $output, stderr: $stderr"; return 1; }
    [ "$output" = "$OK_LINE" ] || { echo "stdout: $output"; return 1; }
    [ -z "$stderr" ] || { echo "stderr: $stderr"; return 1; }
}
# _failed <reason>: the last run failed the check: exit 1 and the one line.
_failed() {
    [ "$status" -eq 1 ] || { echo "rc $status, stdout: $output, stderr: $stderr"; return 1; }
    [ "$output" = "static check failed: $1" ] || { printf 'stdout: %s\nwant:   static check failed: %s\n' "$output" "$1"; return 1; }
    [ -z "$stderr" ] || { echo "stderr: $stderr"; return 1; }
}
# _lineno <fixture> <text>: the number of the fixture's line that is <text> once its
# outer blanks are trimmed, or, with a third argument, that holds <text>. One line must.
_lineno() {
    local l t i=0 n=""
    while IFS= read -r l; do
        i=$((i + 1))
        t="${l#"${l%%[![:space:]]*}"}"; t="${t%"${t##*[![:space:]]}"}"
        if [ -n "${3:-}" ]; then [[ "$l" == *"$2"* ]] || continue; else [ "$t" = "$2" ] || continue; fi
        n+="${n:+ }$i"
    done < "$FIX/$1"
    [[ "$n" =~ ^[0-9]+$ ]] || { echo "_lineno: '$2' is on lines '$n' of $1, not on one" >&2; return 1; }
    printf '%s\n' "$n"
}
# _trips <test-name> <guard line>: the named test of guards.bats fails on that line.
_trips() {
    local n
    n="$(_lineno guards.bats "$2")" || return 1
    _static tests/guards.bats "$1"
    _failed "tests/guards.bats:$n: Git Bash skip guard in '$1': $2"
}
# _passes <test-name>...: each named test of guards.bats is deferred.
_passes() {
    local t
    for t in "$@"; do
        _static tests/guards.bats "$t"
        _deferred || { echo "in '$t'"; return 1; }
    done
}

@test "#1097 deferred: tag present, check listed, no skip guard" {
    _req
    _base
    _fixture guards.bats
    _static tests/guards.bats "pass: or-skip"
    [ "$status" -eq 0 ]
    [ "${lines[${#lines[@]}-1]}" = "deferred to CI at merge: Zeta check" ]
    _deferred
}

@test "#1097 deferred: the tag line absent fails" {
    _req
    _base
    _put tests/plain.bats '#!/usr/bin/env bats' '@test "a" {' '  true' '}'
    _pin
    _static tests/plain.bats a
    [ "$status" -eq 1 ]
    _failed "tests/plain.bats carries no gitbash tag line at ${PIN:0:7}"
    # a tag line the job's selector rejects is no tag line: spaced, indented
    _put tests/plain.bats '#!/usr/bin/env bats' "${TAG/=/ = }" '@test "a" {' '  true' '}'
    _pin
    _static tests/plain.bats a
    _failed "tests/plain.bats carries no gitbash tag line at ${PIN:0:7}"
    _put tests/plain.bats '#!/usr/bin/env bats' "  $TAG" '@test "a" {' '  true' '}'
    _pin
    _static tests/plain.bats a
    _failed "tests/plain.bats carries no gitbash tag line at ${PIN:0:7}"
    _put tests/plain.bats '#!/usr/bin/env bats' "$TAG" '@test "a" {' '  true' '}'    # the survivor
    _pin
    _static tests/plain.bats a
    _deferred
}

@test "#1097 deferred: the named test guarded by is_git_bash && skip fails naming file and line" {
    _req
    _base
    _fixture guards.bats
    local n
    n="$(_lineno guards.bats 'is_git_bash && skip "Git Bash: no POSIX folder modes"')"
    _static tests/guards.bats "trip: and-skip"
    [ "$status" -eq 1 ]
    [ "$output" = "static check failed: tests/guards.bats:$n: Git Bash skip guard in 'trip: and-skip': is_git_bash && skip \"Git Bash: no POSIX folder modes\"" ]
    [ "$(sed -n "${n}p" "$FIX/guards.bats")" = '  is_git_bash && skip "Git Bash: no POSIX folder modes"' ]
}

@test "#1097 deferred guard table: must trip" {
    _req
    _base
    _fixture guards.bats
    _trips "trip: and-skip" 'is_git_bash && skip "Git Bash: no POSIX folder modes"'
    _trips "trip: not-or-skip" '! is_git_bash || skip "POSIX hosts only"'
    _trips "trip: one-line case arm" 'case "$(uname -s)" in MINGW*|MSYS*) skip "no read-only directories on Windows" ;; esac'
    _trips "trip: multi-line case arm" 'skip "no symlinks without Developer Mode"'
    _trips "trip: skipping helper" 'skip_on_git_bash "chmod 000"'
}

@test "#1097 deferred guard table: must not trip" {
    _req
    _base
    _fixture guards.bats
    _passes "pass: or-skip" "pass: not-and-skip" "pass: uname equals MINGW or-skip" "pass: OSTYPE equals msys or-skip" \
        "pass: if-not then skip" "pass: case with an empty Git Bash arm" "pass: reason names Git Bash" "pass: a comment" \
        "pass: the next test is guarded"
    # the survivor of the last row: that next test, named, does trip
    _trips "trip: the guarded neighbour" 'is_git_bash && skip "the neighbour'"'"'s guard"'
}

@test "#1097 deferred: documented misses stay misses" {
    _req
    _base
    _fixture guards.bats
    _passes "miss: multi-line if block" "miss: two-level helper"
    # the inner helper, called by the test itself, is one level: seen
    grep -q '^_inner_skipper() {$' "$FIX/guards.bats"
}

@test "#1097 deferred guard forms: more spellings where skip runs on Git Bash trip" {
    _req
    _base
    _fixture guards.bats
    _trips "trip2: uname equals MINGW and-skip" '[[ "$(uname -s)" == MINGW* ]] && skip "bracket: skipped on Git Bash"'
    _trips "trip2: OSTYPE differs or-skip" '[ "$OSTYPE" != "msys" ] || skip "differs-or: skipped on Git Bash"'
    _trips "trip2: one-line if" 'if is_git_bash; then skip "one-line if: skipped on Git Bash"; fi'
    _trips "trip2: Linux only" '[ "$(uname -s)" = Linux ] || skip "Linux only, so skipped on Git Bash"'
    _trips "trip2: a variable that only names MSYS" '[ "$MSYSTEM" = "" ] || skip "MSYSTEM is set on Git Bash"'
    _trips "trip2: second arm is a Git Bash arm" 'case "$(uname -s)" in MINGW*) ;; MSYS*) skip "the MSYS arm skips" ;; esac'
    _trips "trip2: fall-through to the default arm" 'case "$(uname -s)" in MINGW*|MSYS*) ;;& *) skip "every host falls through to here" ;; esac'
    _trips "trip2: a second case statement on the line" 'case x in msys) ;; esac; case "$(uname -s)" in Linux) ;; *) skip "the second case skips off Linux" ;; esac'
    _trips "trip2: second skip on the line" '[ -n "${HOME:-}" ] || skip "no HOME"; is_git_bash && skip "the second skip on its line"'
    _trips "trip2: a safe skip, then one that is not" 'is_git_bash || skip "the first is Git Bash only"; skip "the second runs on every host"'
    _trips "trip2: brace group" 'is_git_bash && { skip "inside a brace group"; }'
    _trips "trip2: lower-case arm on its own line" 'skip "lower-case arm: skipped on Git Bash"'
    _trips "trip2: one-line helper" '_one_line_skipper'
    _trips "trip2: function keyword helper" 'keyword_skipper'
    _trips "trip2: a guard after a trailing comment mark inside quotes" 'local hash="#"; is_git_bash && skip "the # above is quoted, not a comment"'
}

@test "#1097 deferred guard forms: more spellings where skip runs only off Git Bash do not trip" {
    _req
    _base
    _fixture guards.bats
    # one body holds them all: a form that tripped would be named by its line
    [ "$(sed -n '/^@test "pass2: every form/,/^}$/p' "$FIX/guards.bats" | grep -c 'skip')" -ge 18 ]
    _passes "pass2: every form in which skip runs only off Git Bash"
}

@test "#1097 deferred: a named test file in a subdirectory of tests/, or outside tests/, fails as not selected" {
    _req
    _base
    mkdir -p "$SOURCE_DIR/tests/sub" "$SOURCE_DIR/test"
    cp "$FIX/guards.bats" "$SOURCE_DIR/tests/sub/guards.bats"
    cp "$FIX/guards.bats" "$SOURCE_DIR/test/guards.bats"
    cp "$FIX/guards.bats" "$SOURCE_DIR/guards.bats"
    cp "$FIX/guards.bats" "$SOURCE_DIR/tests/.guards.bats"
    cp "$FIX/guards.bats" "$SOURCE_DIR/tests/guards.sh"
    _fixture guards.bats
    local f
    for f in tests/sub/guards.bats test/guards.bats guards.bats tests/.guards.bats tests/guards.sh \
             ./tests/guards.bats "$SOURCE_DIR/tests/guards.bats"; do
        _static "$f" "pass: or-skip"
        _failed "$f is not selected by the job: it must be tests/<name>.bats" || { echo "for $f"; return 1; }
    done
    _static tests/guards.bats "pass: or-skip"       # the survivor
    _deferred
}

@test "#1097 deferred: a test name given in its displayed (unescaped) form matches" {
    _req
    _base
    _fixture names.bats
    local t
    # as bats displays it, and as the source spells it
    for t in 'disk: C:/x and C:\x exit 1 on Linux' 'disk: C:/x and C:\\x exit 1 on Linux' \
             'says "hi" for $1 and `id`' 'says \"hi\" for \$1 and \`id\`' \
             'single: quoted with a \\ kept as written' 'trailing blanks' 'indented' '--starts with a dash'; do
        _static tests/names.bats "$t"
        _deferred || { echo "for $t"; return 1; }
    done
    # single quotes escape nothing: one backslash is another name
    _static tests/names.bats 'single: quoted with a \ kept as written'
    _failed "no test named 'single: quoted with a \\ kept as written' in tests/names.bats at ${PIN:0:7}"
    # a one-line test is not read
    _static tests/names.bats 'one-liner'
    _failed "no test named 'one-liner' in tests/names.bats at ${PIN:0:7}"
    # the test after "trailing blanks" is guarded: its body is its own
    _static tests/names.bats 'after trailing blanks'
    [ "$status" -eq 1 ]
}

@test "#1097 deferred: a name that two tests carry fails as named twice" {
    _req
    _base
    _fixture names.bats
    _static tests/names.bats dup
    _failed "test 'dup' in tests/names.bats at ${PIN:0:7} is named twice"
    # one test displays it, the other spells it
    _static tests/names.bats 'shown twice: a\b'
    _failed "test 'shown twice: a\\b' in tests/names.bats at ${PIN:0:7} is named twice"
}

@test "#1097 deferred: a check outside the list, a missing file and an unknown test each fail" {
    _req
    _base
    mkdir -p "$SOURCE_DIR/tests/dir.bats"
    cp "$FIX/names.bats" "$SOURCE_DIR/tests/dir.bats/names.bats"
    _fixture guards.bats
    _static tests/guards.bats "pass: or-skip" "Eta check"
    _failed "'Eta check' is not in [project.$TEST_PROJECT] required_checks"
    _static tests/guards.bats "pass: or-skip" "zeta check"                # byte for byte
    _failed "'zeta check' is not in [project.$TEST_PROJECT] required_checks"
    _static tests/absent.bats "pass: or-skip"
    _failed "tests/absent.bats does not exist at ${PIN:0:7}"
    _static tests/dir.bats "pass: or-skip"                                # a directory is not a file
    _failed "tests/dir.bats does not exist at ${PIN:0:7}"
    _static tests/guards.bats "no such test"
    _failed "no test named 'no such test' in tests/guards.bats at ${PIN:0:7}"
    _static tests/guards.bats "pass: or-skip"                             # the survivor
    _deferred
}

@test "#1097 deferred: a project with no required checks defers nothing; no pin exits 2" {
    _base
    _fixture guards.bats
    _static tests/guards.bats "pass: or-skip"
    _failed "'$ZETA' is not in [project.$TEST_PROJECT] required_checks"
    _req
    devagent_state_set "$ST" preship_pin_head ""
    _static tests/guards.bats "pass: or-skip"
    _cnr "preship-deferred: no pinned head is recorded for Issue-1 (preship_pin_head)"
}

@test "#1097 deferred: reads the pinned commit, not the working tree" {
    _req
    _base
    _put tests/t.bats '#!/usr/bin/env bats' "$TAG" '@test "t" {' '  true' '}'
    _pin
    local clean="$PIN"
    # HEAD and the working tree gain a guard after the pin: the pin has none
    _put tests/t.bats '#!/usr/bin/env bats' "$TAG" '@test "t" {' '  is_git_bash && skip "added later"' '  true' '}'
    _commit later
    _put tests/t.bats '#!/usr/bin/env bats' '@test "other" {' '  true' '}'       # uncommitted: no tag, no such test
    _static tests/t.bats t
    _deferred
    # the pin moves to the guarded commit; the working tree loses the file
    devagent_state_set "$ST" preship_pin_head "$AT"
    rm -f "$SOURCE_DIR/tests/t.bats"
    _static tests/t.bats t
    _failed "tests/t.bats:4: Git Bash skip guard in 't': is_git_bash && skip \"added later\""
    [ "$(git -C "$SOURCE_DIR" rev-parse HEAD)" = "$AT" ]
    [ "$AT" != "$clean" ]
}

@test "#1097 deferred: a CRLF test file reads the same" {
    _req
    _base
    mkdir -p "$SOURCE_DIR/tests"
    git -C "$SOURCE_DIR" config core.autocrlf false     # the CRs reach the blob on every host
    sed 's/$/\r/' "$FIX/guards.bats" > "$SOURCE_DIR/tests/guards.bats"
    sed 's/$/\r/' "$FIX/names.bats" > "$SOURCE_DIR/tests/names.bats"
    _pin
    [[ "$(git -C "$SOURCE_DIR" ls-files --eol tests/guards.bats)" == i/crlf* ]]   # the blob itself is CRLF
    _passes "pass: the next test is guarded" "pass2: every form in which skip runs only off Git Bash"
    _trips "trip: multi-line case arm" 'skip "no symlinks without Developer Mode"'
    _trips "trip: skipping helper" 'skip_on_git_bash "chmod 000"'
    _static tests/names.bats 'disk: C:/x and C:\x exit 1 on Linux'
    _deferred
}

@test "#1097 deferred: the guard's text is cut to 120 characters, never inside one" {
    _req
    _base
    _fixture names.bats
    local n ten="0123456789" nine="abcdefghi" want i
    want='is_git_bash && skip "'
    for i in 1 2 3 4 5 6 7 8; do want+="$ten "; done
    want+="$ten"                                    # 119 bytes; byte 120 would be half of the next character
    n="$(_lineno names.bats "${ten}ééé and the rest" holds)"
    _static tests/names.bats "long reason, cut inside a character"
    # 119 bytes where the C locale counts bytes; 120 characters where it counts characters
    _failed "tests/names.bats:$n: Git Bash skip guard in 'long reason, cut inside a character': $want" \
        || _failed "tests/names.bats:$n: Git Bash skip guard in 'long reason, cut inside a character': ${want}é"
    want='is_git_bash && skip "'
    for i in 1 2 3 4 5 6 7 8 9; do want+="$nine "; done
    want+="ABCDEFGHI"
    [ "${#want}" -eq 120 ]
    n="$(_lineno names.bats "ABCDEFGHIJ and the rest" holds)"
    _static tests/names.bats "long reason, cut between characters"
    _failed "tests/names.bats:$n: Git Bash skip guard in 'long reason, cut between characters': $want"
}

# _gitshim <subcommand> <rc> [<argv text>]: DEVAGENT_GIT logs every call (its
# GIT_NO_LAZY_FETCH, GIT_ALLOW_PROTOCOL and argv) to $GITLOG, exits <rc> when the first
# word that is not an option is <subcommand> (and argv holds <argv text>, when given),
# else runs git.
_gitshim() {
    GITLOG="$DEVAGENT_TMP/git.log"; : > "$GITLOG"
    local real; real="$(command -v git)"
    printf '%s\n' '#!/usr/bin/env bash' \
        "printf 'NLF=%s GAP=%s %s\n' \"\${GIT_NO_LAZY_FETCH-unset}\" \"\${GIT_ALLOW_PROTOCOL-unset}\" \"\$*\" >> '$GITLOG'" \
        'a=("$@"); i=0' \
        'while [ "$i" -lt "${#a[@]}" ]; do case "${a[$i]}" in -C) i=$((i + 2)) ;; -*) i=$((i + 1)) ;; *) break ;; esac; done' \
        "if [ \"\${a[\$i]-}\" = '$1' ]; then case \"\$*\" in *'${3-}'*) exit $2 ;; esac; fi" \
        "exec '$real' \"\$@\"" > "$DEVAGENT_TMP/gitshim"
    chmod +x "$DEVAGENT_TMP/gitshim"
    export DEVAGENT_GIT="$DEVAGENT_TMP/gitshim"
}

@test "#1097 deferred: a file that cannot be read at the pin exits 2, never as a file that is not there; no read can fetch" {
    _req
    _base
    _fixture guards.bats
    _gitshim cat-file 128 "cat-file blob"
    _static tests/guards.bats "pass: or-skip"
    _cnr "preship-deferred: tests/guards.bats at ${PIN:0:7} cannot be read in $SOURCE_DIR (git cat-file exited 128)"
    _gitshim ls-tree 128
    _static tests/guards.bats "pass: or-skip"
    _cnr "preship-deferred: tests/guards.bats at ${PIN:0:7} cannot be read in $SOURCE_DIR (git ls-tree exited 128)"
    _gitshim no-such-subcommand 1                   # the survivor: every call passes through
    _static tests/guards.bats "pass: or-skip"
    _deferred
    grep -q ' ls-tree ' "$GITLOG"
    grep -q ' cat-file blob ' "$GITLOG"
    run grep -v '^NLF=1 GAP=none ' "$GITLOG"        # every git call of the run is one that cannot fetch
    [ "$status" -eq 1 ] || { echo "calls that could fetch: $output"; return 1; }
}

# ---- transcript: the fallback hand transcript ----------------------------------------------

UNAME_LINE='MINGW64_NT-10.0-26100 runner 3.5.4-1e8cf1df.x86_64 2024-09-19 18:03 UTC x86_64 Msys'
OTHER=2222222222222222222222222222222222222222

# _tx <name> <line>...: write <issue-dir>/evidence/<name>, one argument per line.
_tx() {
    local n="$1"; shift
    mkdir -p "$ISSUE_DIR/evidence"
    printf '%s\n' "$@" > "$ISSUE_DIR/evidence/$n"
}
# _transcript [<test-file>]
_transcript() { _pd "$TEST_PROJECT" Issue-1 transcript "${1:-tests/guards.bats}"; }
# _accepted <name>: exit 0 and the one line, naming that file and the full pinned head.
_accepted() {
    [ "$status" -eq 0 ] || { echo "rc $status, stdout: $output, stderr: $stderr"; return 1; }
    [ "$output" = "transcript accepted: evidence/$1 is at the pinned head $PIN" ] || { echo "stdout: $output"; return 1; }
    [ -z "$stderr" ] || { echo "stderr: $stderr"; return 1; }
}
# _tfailed <reason>: exit 1 and the one line.
_tfailed() {
    [ "$status" -eq 1 ] || { echo "rc $status, stdout: $output, stderr: $stderr"; return 1; }
    [ "$output" = "transcript check failed: $1" ] || { printf 'stdout: %s\nwant:   transcript check failed: %s\n' "$output" "$1"; return 1; }
    [ -z "$stderr" ] || { echo "stderr: $stderr"; return 1; }
}

@test "#1097 transcript: accepted at the pinned head" {
    _base
    _pin
    local n="2026-11-20-gitbash-guards-$PIN.txt"
    _tx "$n" "$PIN" "$UNAME_LINE" '1..1' 'ok 1 a test'
    _transcript
    _accepted "$n"
    _tx "$n" "sha: $PIN" "uname: MSYS_NT-10.0-26100 runner 3.5.4 x86_64 Msys" '1..1'      # the labelled header
    _transcript
    _accepted "$n"
    _transcript guards.bats                         # the file is named by its basename
    _accepted "$n"
    # no project key is needed, and a quarantined issue is still refused
    printf 'devagent-quarantine 1\nkey github:github.com/acme/testproj#1\nreason screen\nevent ? ?\n' > "$ISSUE_DIR/QUARANTINE"
    _transcript
    [ "$status" -eq 11 ]
}

@test "#1097 transcript: a CRLF transcript, and a 12-hex short SHA in the name, are accepted; two matching files, the last name wins" {
    _base
    _pin
    local short="2026-11-20-gitbash-guards-${PIN:0:12}.txt" early="2026-11-19-gitbash-guards-${PIN:0:7}.txt"
    mkdir -p "$ISSUE_DIR/evidence"
    printf '%s\r\n' "$PIN" "$UNAME_LINE" 'ok 1 a test' > "$ISSUE_DIR/evidence/$short"
    _transcript
    _accepted "$short"
    # the earlier name is sound, the last is not: the last is the one read, and named
    _tx "$early" "$PIN" "$UNAME_LINE"
    _tx "$short" "$PIN" "Linux runner 6.8.0-149-generic x86_64 GNU/Linux"
    _transcript
    _tfailed "evidence/$short line 2 is not a Git Bash uname line (MINGW... or MSYS...): Linux runner 6.8.0-149-generic x86_64 GNU/Linux"
    # the other way round: the last name wins again
    _tx "$early" "$PIN" "Linux runner 6.8.0-149-generic x86_64 GNU/Linux"
    _tx "$short" "$PIN" "$UNAME_LINE"
    _transcript
    _accepted "$short"
}

@test "#1097 transcript: a header SHA that is not the pin, a file named for another head and a Linux uname each fail" {
    _base
    _pin
    local n="2026-11-20-gitbash-guards-${PIN:0:12}.txt"
    _tx "$n" "$OTHER" "$UNAME_LINE"
    _transcript
    _tfailed "evidence/$n line 1 records head ${OTHER:0:7}, not the pinned head ${PIN:0:7}"
    _tx "$n" "$PIN" "Linux runner 6.8.0-149-generic x86_64 GNU/Linux"
    _transcript
    _tfailed "evidence/$n line 2 is not a Git Bash uname line (MINGW... or MSYS...): Linux runner 6.8.0-149-generic x86_64 GNU/Linux"
    rm -f "$ISSUE_DIR/evidence/$n"
    _tx "2026-11-20-gitbash-guards-${OTHER:0:12}.txt" "$OTHER" "$UNAME_LINE"
    _transcript
    _tfailed "evidence/2026-11-20-gitbash-guards-${OTHER:0:12}.txt is named for another head, not the pinned head ${PIN:0:7}"
    _tx "$n" "$PIN" "$UNAME_LINE"                   # the survivor, beside the other head's file
    _transcript
    _accepted "$n"
}

@test "#1097 transcript: no file, a file for another test file, a name that is not the form, and a header that is not the form each fail" {
    _base
    _pin
    local want="no evidence/<YYYY-MM-DD>-gitbash-guards-<sha>.txt is in the issue directory for the pinned head ${PIN:0:7}"
    _transcript                                     # no evidence directory
    _tfailed "$want"
    _tx "2026-11-20-gitbash-guards-extra-${PIN:0:12}.txt" "$PIN" "$UNAME_LINE"      # another test file's
    _tx "2026-11-20-gitbash-guard-${PIN:0:12}.txt" "$PIN" "$UNAME_LINE"
    _tx "2026-11-20-gitbash-guards-${PIN:0:6}.txt" "$PIN" "$UNAME_LINE"             # six digits name no head
    _tx "2026-11-2x-gitbash-guards-${PIN:0:12}.txt" "$PIN" "$UNAME_LINE"            # not a date
    _tx "2026-11-20-gitbash-guards-${PIN:0:12}.log" "$PIN" "$UNAME_LINE"
    # upper case names no head; the F keeps one such digit in the name whatever the pin's are
    _tx "2026-11-20-gitbash-guards-$(tr 'a-f' 'A-F' <<<"${PIN:0:12}")F.txt" "$PIN" "$UNAME_LINE"
    mkdir -p "$ISSUE_DIR/evidence/2026-11-21-gitbash-guards-${PIN:0:12}.txt"        # a directory is no transcript
    _transcript
    _tfailed "$want"
    _transcript tests/guards-extra.bats             # the survivor: that one is guards-extra's
    _accepted "2026-11-20-gitbash-guards-extra-${PIN:0:12}.txt"
    local n="2026-11-20-gitbash-guards-${PIN:0:12}.txt"
    _tx "$n" "${PIN:0:12}" "$UNAME_LINE"            # a short id in the header
    _transcript
    _tfailed "evidence/$n line 1 is not a full commit id: ${PIN:0:12}"
    _tx "$n" "head $PIN" "$UNAME_LINE"
    _transcript
    _tfailed "evidence/$n line 1 is not a full commit id: head $PIN"
    : > "$ISSUE_DIR/evidence/$n"                    # zero bytes
    _transcript
    _tfailed "evidence/$n line 1 is not a full commit id: (empty)"
    _tx "$n" "$PIN"                                 # no second line
    _transcript
    _tfailed "evidence/$n line 2 is not a Git Bash uname line (MINGW... or MSYS...): (empty)"
    _tx "$n" "$PIN" "MINGW64_NT-10.0"               # the kernel name alone is not a uname -a line
    _transcript
    _tfailed "evidence/$n line 2 is not a Git Bash uname line (MINGW... or MSYS...): MINGW64_NT-10.0"
    _tx "$n" "$UNAME_LINE" "$PIN"                   # the two lines swapped
    _transcript
    [ "$status" -eq 1 ]
}

@test "#1097 transcript: no pin exits 2" {
    _base
    _tx "2026-11-20-gitbash-guards-${OTHER:0:12}.txt" "$OTHER" "$UNAME_LINE"
    _transcript
    _cnr "preship-deferred: no pinned head is recorded for Issue-1 (preship_pin_head)"
}

# ---- every call only reads -----------------------------------------------------------------

# _snap: the state and config files, the issue directory and the tree's refs and status.
_snap() {
    find "$HOME/.claude/devagent" "$ISSUE_DIR" -type f -exec sha256sum {} + | sort
    git -C "$SOURCE_DIR" for-each-ref
    git -C "$SOURCE_DIR" rev-parse HEAD
    git -C "$SOURCE_DIR" status --porcelain
}

@test "#1097 deferred: no call writes to the state, the issue directory or the tree, and none leaves a temporary file" {
    _req
    _base
    _put "$WF" 'name: ci'
    _fixture guards.bats
    _tx "2026-11-20-gitbash-guards-$PIN.txt" "$PIN" "$UNAME_LINE"
    export TMPDIR="$DEVAGENT_TMP/scratch"
    mkdir -p "$TMPDIR"
    local before after
    before="$(_snap)"
    _pd "$TEST_PROJECT" Issue-1                     # the three lines, with a warning
    [ "$status" -eq 0 ]; [[ "$output" == *"self-certification warning: $WF changed"* ]]
    _static tests/guards.bats "pass: or-skip"
    [ "$status" -eq 0 ]
    _static tests/guards.bats "trip: and-skip"      # fails after the file was copied out
    [ "$status" -eq 1 ]
    _transcript
    [ "$status" -eq 0 ]
    _gitshim cat-file 128 "cat-file blob"           # could not run, after the temporary directory was made
    _static tests/guards.bats "pass: or-skip"
    [ "$status" -eq 2 ]
    after="$(_snap)"
    [ "$after" = "$before" ] || { printf 'before:\n%s\nafter:\n%s\n' "$before" "$after"; return 1; }
    [ -z "$(ls -A "$TMPDIR")" ] || { echo "left in TMPDIR: $(ls -A "$TMPDIR")"; return 1; }
}
