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
    printf '%s\n' '#!/usr/bin/env bash' "echo ran >> '$ran'" '# mr-checks) is only named in this comment' 'case "$1" in' \
        '  mr-state) echo "usage: mr-checks) <url>" ;;' '  *) exit 2 ;;' 'esac' > "$d/none.sh"
    chmod +x "$d"/*.sh
    local b want
    for b in has:yes stub:no none:no; do
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
