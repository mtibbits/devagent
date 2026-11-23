#!/usr/bin/env bats
# #1097 preship-deferred.sh, the parts that do not depend on the host: usage, the bare
# call (required checks, the code backend's mr-checks line, the self-certification
# line, could-not-run and quarantine exits) and the skip-guard reader (guard tables,
# guard forms, helpers, documented misses, test names). Linux only; the reads at the
# pinned head are in tests/preship-deferred.bats, which the Git Bash job runs.
load 'helpers/common'
load 'helpers/preship-deferred'
bats_require_minimum_version 1.5.0

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
    # the survivor of the second: its inner helper, called by the test itself, is one level
    _trips "trip: the inner helper called directly" '_inner_skipper "called by the test itself"'
}

# scripts/preship-deferred.sh lists what the static check does not see (KNOWN MISSES).
# Each is a test that is skipped on Git Bash and deferred all the same; this holds every
# one of them as a miss, so that closing one is a change someone makes on purpose.
@test "#1097 deferred: every miss the script lists is pinned as a miss" {
    _req
    _base
    _fixture misses.bats misses-word.bats
    local t n=0
    for t in "miss: a skip in setup" "miss: a helper from another file" "miss: no line names Git Bash" \
             "miss: a backslash continuation" "miss: an early return" "miss: a helper that returns early" \
             "miss: a case over several lines, default arm" "miss: a guard after a heredoc that holds a closing brace" \
             "miss: a helper with a subshell body" "miss: a helper with a hyphenated name" \
             "miss: a helper whose brace follows a blank line" "miss: a helper defined after another on its line" \
             "miss: a helper with a redirected closing brace before its guard" \
             "miss: a helper with a heredoc brace before its guard" "miss: an extglob Git Bash arm on its own line"; do
        _static tests/misses.bats "$t"
        _deferred || { echo "for '$t'"; return 1; }
        n=$((n + 1))
    done
    [ "$n" -eq "$(grep -c '^@test "miss: ' "$FIX/misses.bats")" ]    # the fixture holds no miss this does not ask about
    _static tests/misses-word.bats "miss: is_git_bash taken at its word"
    _deferred
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

# The job's host is what a guard is read against: `uname -s` is MINGW64_NT-..., `uname -o`
# is Msys, OSTYPE is msys. A test for another flavour, or one that can never be true,
# leaves its skip running there.
@test "#1097 deferred guard forms: a guard for another flavour, or one that is never true, trips" {
    _req
    _base
    _fixture guards.bats
    _trips "trip3: uname equals MSYS or-skip" '[[ "$(uname -s)" == MSYS* ]] || skip "MSYS flavour only, and the job'"'"'s host is MINGW"'
    _trips "trip3: uname equals CYGWIN or-skip" '[[ "$(uname -s)" == CYGWIN* ]] || skip "Cygwin only, so skipped on the job'"'"'s host"'
    _trips "trip3: OSTYPE equals cygwin or-skip" '[ "$OSTYPE" = cygwin ] || skip "OSTYPE is msys on the job'"'"'s host"'
    _trips "trip3: MSYSTEM equals MSYS or-skip" '[ "$MSYSTEM" = MSYS ] || skip "MSYSTEM is not a subject the check reads"'
    _trips "trip3: case with an empty CYGWIN arm" 'case "$(uname -s)" in CYGWIN*) ;; *) skip "the job'"'"'s host takes the default arm" ;; esac'
    _trips "trip3: single brackets compare, they do not match" '[ "$(uname -s)" = MINGW* ] || skip "never equal, so skipped on every host"'
    _trips "trip3: the 32-bit MINGW" '[[ "$(uname -s)" == MINGW32* ]] || skip "the job'"'"'s host is MINGW64"'
    _trips "trip3: one build's exact name" '[[ "$(uname -s)" == MINGW64_NT-10.0-26100 ]] || skip "true on one Windows build only"'
    _trips "trip3: a quoted pattern is text" '[[ "$(uname -s)" == "MINGW*" ]] || skip "quoted, the star matches nothing"'
    _trips "trip3: a pattern kept in a variable" '[[ "$(uname -s)" == $WINDOWS_PATTERN ]] && skip "the pattern is not there to read"'
    _trips "trip3: a case nested in the host's own arm" 'case "$(uname -s)" in MINGW*) case "${MODE:-}" in fast) ;; *) skip "inside the arm the host takes" ;; esac ;; esac'
    _trips "trip3: not the first command of the host's arm" 'case "$(uname -s)" in MINGW*) echo "here"; skip "after another command, in the host'"'"'s arm" ;; esac'
    _trips "trip3: uname kept in a variable" '[[ "$UNAME_S" == MINGW* ]] || skip "a variable is not a subject the check reads"'
}

@test "#1097 deferred guard forms: an open Git Bash arm stays open through a nested case and a fall-through; more helper shapes are read" {
    _req
    _base
    _fixture guards.bats
    _trips "trip3: a case inside the Git Bash arm" 'skip "after the inner case, still in the Git Bash arm"'
    _trips "trip3: the Git Bash arm keeps testing" '*) skip "reached after the Git Bash arm" ;;'
    _trips "trip3: the Git Bash arm keeps testing past another arm" 'skip "reached through the arms after the Git Bash arm"'
    _trips "trip3: the Git Bash arm falls through" 'skip "fallen into from the Git Bash arm"'
    _trips "trip3: helper with its brace on the next line" '_next_line_brace_skipper'
    _trips "trip3: helper defined with an indent" '_indented_skipper'
    _trips "trip3: helper that skips after an inner block" '_block_then_skipper'
    _trips "trip3: a guard after an inner block" 'is_git_bash && skip "after the block'"'"'s closing brace"'
}

# Every line of the file is read for a definition. A function whose end is not where
# the check looks for it (a closing brace with a redirection, a command or a comment
# after it), a function that holds another, a heredoc with half a definition and a
# test's local stub each once hid the helper defined after them.
@test "#1097 deferred: a skipping helper is found wherever it is defined" {
    _req
    _base
    _fixture helpers.bats
    _trips_in helpers.bats "trip: a helper defined after a test's local stub" 'skip_on_git_bash "chmod 000"'
    _trips_in helpers.bats "trip: a helper defined after a redirected closing brace" '_after_noisy_skipper'
    _trips_in helpers.bats "trip: a helper defined after three more closing braces" '_after_those_skipper'
    _trips_in helpers.bats "trip: a helper defined inside a function" '_nested_skipper'
    _trips_in helpers.bats "trip: a helper defined after a heredoc's half definition" '_after_heredoc_skipper'
    _trips_in helpers.bats "trip: a helper whose first statement shares the brace's line" '_first_statement_skipper "chmod 000"'
    _trips_in helpers.bats "trip: a helper whose guard shares the brace's line" '_guard_on_the_brace_line'
    # a function is read to its own closing brace, whatever follows the brace: the
    # helpers that do not skip are not taken for ones that do
    local t
    for t in "pass: a local stub with a redirected closing brace" "pass: helpers whose closing brace carries more"; do
        _static tests/helpers.bats "$t"
        _deferred || { echo "for '$t'"; return 1; }
    done
}

@test "#1097 deferred guard forms: more spellings where skip runs only off Git Bash do not trip" {
    _req
    _base
    _fixture guards.bats
    # one body holds them all: a form that tripped would be named by its line
    [ "$(sed -n '/^@test "pass2: every form/,/^}$/p' "$FIX/guards.bats" | grep -c 'skip')" -ge 28 ]
    _passes "pass2: every form in which skip runs only off Git Bash"
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
    local n
    n="$(_lineno names.bats 'is_git_bash && skip "the next test'"'"'s guard"')"
    _static tests/names.bats 'after trailing blanks'
    _failed "tests/names.bats:$n: Git Bash skip guard in 'after trailing blanks': is_git_bash && skip \"the next test's guard\""
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
