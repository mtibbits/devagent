# shellcheck shell=bash
# shellcheck disable=SC2034,SC2154  # the variables are read by the bats files that load this helper; $status, $output and $stderr are set by bats `run`
# tests/helpers/preship-deferred.bash — setup and helpers shared by the two test files
# of scripts/preship-deferred.sh (#1097): tests/preship-deferred.bats (tagged gitbash:
# every read at the pinned head, so the Git Bash job runs it) and
# tests/preship-deferred-parse.bats (Linux only: usage, the bare call and the skip-guard
# reader). Load it after helpers/common.
#
# A fixture's tag line is always the TAG variable, never a comment line of a test file
# (scripts/ci/gitbash-tagged.sh calls any comment line other than line 2 that holds both
# the tag key and the tag value malformed).

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

# _callrec: a stand-in for gh that records that it ran.
_callrec() {
    CALLED="$DEVAGENT_TMP/called"
    printf '%s\n' '#!/usr/bin/env bash' "echo called >> '$CALLED'" 'exit 1' > "$DEVAGENT_TMP/rec"
    chmod +x "$DEVAGENT_TMP/rec"
    export DEVAGENT_GH="$DEVAGENT_TMP/rec"
}
# _capline: the code backend line of the last run.
_capline() { sed -n 2p <<<"$output"; }

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

# _trips_in <fixture> <test-name> <guard line>: the named test of that fixture fails on
# that line.
_trips_in() {
    local n
    n="$(_lineno "$1" "$3")" || return 1
    _static "tests/$1" "$2"
    _failed "tests/$1:$n: Git Bash skip guard in '$2': $3"
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

# ---- every call only reads -----------------------------------------------------------------

# _snap: the state and config files, the issue directory and the tree's refs and status.
_snap() {
    find "$HOME/.claude/devagent" "$ISSUE_DIR" -type f -exec sha256sum {} + | sort
    git -C "$SOURCE_DIR" for-each-ref
    git -C "$SOURCE_DIR" rev-parse HEAD
    git -C "$SOURCE_DIR" status --porcelain
}
