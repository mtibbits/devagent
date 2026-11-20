#!/usr/bin/env bats
# #1097: `[project.<name>] required_checks` and `required_checks_paths` — the reader
# (required_checks_resolve, lib/config.sh) and the list script (required-checks.sh).
# Neither key has a [defaults] layer, and a value that cannot be read as a list dies
# naming the key: it is never "no required checks" (devagent Issue-713, Issue-780).

bats_require_minimum_version 1.5.0   # run --separate-stderr
load 'helpers/common'

setup() {
    devagent_test_setup
    CFG="$HOME/.claude/devagent/config.toml"
    RCS="$DEVAGENT_ROOT/scripts/required-checks.sh"
    cp "$CFG" "$CFG.base"
}
teardown() { devagent_test_teardown; }

# The reader, sourced as its callers source it.
_lib() {
    source "$DEVAGENT_ROOT/scripts/lib/paths.sh"
    source "$DEVAGENT_ROOT/scripts/lib/io.sh"
    source "$DEVAGENT_ROOT/scripts/lib/config.sh"
}

# _reset: the fixture config as setup wrote it (one key line per table, per case).
_reset() { cp "$CFG.base" "$CFG"; }

# _ins <table> <key> <toml value>: insert `<key> = <value>` right after the [<table>]
# header line. `_toml.py set` cannot write an array (it stores the text as a string,
# and get-list then exits 3), so the line goes into the file as text. Fails unless
# exactly one header took the insert: an edit that no-ops must not pass.
_ins() {
    local line out="" n=0
    while IFS= read -r line; do
        out+="$line"$'\n'
        if [ "$line" = "[$1]" ]; then out+="$2 = $3"$'\n'; n=$((n + 1)); fi
    done < "$CFG"
    [ "$n" -eq 1 ] || { echo "_ins: [$1] matched $n header lines in $CFG" >&2; return 1; }
    printf '%s' "$out" > "$CFG"
}

# _list_ok <key>: get-list reads the project key as an array of strings (rc 0).
_list_ok() {
    python3 "$DEVAGENT_ROOT/scripts/lib/_toml.py" get-list "$CFG" "project.$TEST_PROJECT.$1" >/dev/null \
        || { echo "_list_ok: get-list does not read project.$TEST_PROJECT.$1 as an array" >&2; return 1; }
}

# _req '<toml array>' / _paths '<toml array>': the two keys under [project.$TEST_PROJECT].
_req()   { _ins "project.$TEST_PROJECT" required_checks "$1";       _list_ok required_checks; }
_paths() { _ins "project.$TEST_PROJECT" required_checks_paths "$1"; _list_ok required_checks_paths; }

# _dies <key> <needle>: the reader dies (exit 1) with <needle> in its message, and
# the message ends `; fix [project.$TEST_PROJECT] <key>` (the end, so that
# required_checks is not satisfied by required_checks_paths).
_dies() {
    run required_checks_resolve "$TEST_PROJECT"
    [ "$status" -eq 1 ] || { echo "status $status, output: $output" >&2; return 1; }
    [[ "$output" == *"$2"* ]] || { echo "no '$2' in: $output" >&2; return 1; }
    [[ "$output" == *"; fix [project.$TEST_PROJECT] $1" ]] || { echo "no fix line for $1 in: $output" >&2; return 1; }
}

@test "#1097 config: absent key and [] give no required checks" {
    _lib
    # Stale values from an earlier call must not survive: the reader sets both.
    REQUIRED_CHECKS=(stale); REQUIRED_CHECKS_PATHS=(stale)
    required_checks_resolve "$TEST_PROJECT"
    [ "${#REQUIRED_CHECKS[@]}" -eq 0 ]
    [ "${#REQUIRED_CHECKS_PATHS[@]}" -eq 0 ]
    _req '[]'
    REQUIRED_CHECKS=(stale); REQUIRED_CHECKS_PATHS=(stale)
    required_checks_resolve "$TEST_PROJECT"
    [ "${#REQUIRED_CHECKS[@]}" -eq 0 ]
    [ "${#REQUIRED_CHECKS_PATHS[@]}" -eq 0 ]
}

@test "#1097 config: an array is read in order, spaces intact, duplicates once" {
    _lib
    _req '["Git Bash tagged files", "build (ubuntu-24.04, gcc)", "Git Bash tagged files", "a  b", "git bash tagged files"]'
    required_checks_resolve "$TEST_PROJECT"
    [ "${#REQUIRED_CHECKS[@]}" -eq 4 ]
    [ "${REQUIRED_CHECKS[0]}" = "Git Bash tagged files" ]
    [ "${REQUIRED_CHECKS[1]}" = "build (ubuntu-24.04, gcc)" ]
    [ "${REQUIRED_CHECKS[2]}" = "a  b" ]
    [ "${REQUIRED_CHECKS[3]}" = "git bash tagged files" ]   # byte for byte: case differs, so it stays
    [ "${#REQUIRED_CHECKS_PATHS[@]}" -eq 0 ]
}

@test "#1097 config: a string value, an empty entry, a TAB, a leading space and 201 characters each die naming the key" {
    _lib
    local long
    printf -v long '%201s' ''; long="${long// /x}"
    [ "${#long}" -eq 201 ]
    _ins "project.$TEST_PROJECT" required_checks '"Git Bash tagged files"'
    _dies required_checks 'required_checks must be an array of single-line strings, e.g. required_checks = ["Git Bash tagged files"]'
    _reset; _req '["ok", ""]'
    _dies required_checks "required_checks entry '' is not a check-run name"
    _reset; _req '["a\tb"]'
    _dies required_checks "required_checks entry 'a"$'\t'"b' is not a check-run name"
    _reset; _req '[" lead"]'
    _dies required_checks "required_checks entry ' lead' is not a check-run name"
    _reset; _req "[\"$long\"]"
    _dies required_checks "required_checks entry '$long' is not a check-run name"
    # The rest of the entry rule: a trailing space, and a line break (get-list refuses it).
    _reset; _req '["trail "]'
    _dies required_checks "required_checks entry 'trail ' is not a check-run name"
    _reset; _ins "project.$TEST_PROJECT" required_checks '["a\nb"]'
    _dies required_checks 'required_checks must be an array of single-line strings'
    # Control: 200 characters is a name, so the bound is 200 and not lower.
    _reset; _req "[\"${long%x}\"]"
    required_checks_resolve "$TEST_PROJECT"
    [ "${#REQUIRED_CHECKS[@]}" -eq 1 ]
    [ "${REQUIRED_CHECKS[0]}" = "${long%x}" ]
}

@test "#1097 config: required_checks_paths is read in order, a trailing slash kept; absent gives none" {
    _lib
    _req '["Git Bash tagged files"]'
    REQUIRED_CHECKS_PATHS=(stale)
    required_checks_resolve "$TEST_PROJECT"
    [ "${#REQUIRED_CHECKS_PATHS[@]}" -eq 0 ]
    [ "${REQUIRED_CHECKS[0]}" = "Git Bash tagged files" ]
    _paths '["scripts/ci/", "tools/win/run.ps1", "a b/c"]'
    required_checks_resolve "$TEST_PROJECT"
    [ "${#REQUIRED_CHECKS_PATHS[@]}" -eq 3 ]
    [ "${REQUIRED_CHECKS_PATHS[0]}" = "scripts/ci/" ]
    [ "${REQUIRED_CHECKS_PATHS[1]}" = "tools/win/run.ps1" ]
    [ "${REQUIRED_CHECKS_PATHS[2]}" = "a b/c" ]
    [ "${#REQUIRED_CHECKS[@]}" -eq 1 ]
    # [] is none, as an absent key is.
    _reset; _req '["Git Bash tagged files"]'; _paths '[]'
    REQUIRED_CHECKS_PATHS=(stale)
    required_checks_resolve "$TEST_PROJECT"
    [ "${#REQUIRED_CHECKS_PATHS[@]}" -eq 0 ]
}

@test "#1097 config: a leading /, a .. component, a glob character and an empty entry in required_checks_paths each die naming the key" {
    _lib
    local e
    # The four named, then the rest of the entry rule: the other two glob characters,
    # a drive letter, a . component, an empty component and a second trailing slash.
    for e in '/etc/ci' 'scripts/../ci' 'scripts/*.yml' '' \
             'a?b' 'a[b' 'C:/ci' './ci' 'a//b' 'ci//'; do
        _reset; _req '["Git Bash tagged files"]'; _paths "[\"$e\"]"
        _dies required_checks_paths "required_checks_paths entry '$e' is not a repo-relative file or directory"
    done
    _reset; _req '["Git Bash tagged files"]'; _paths '["a\tb"]'
    _dies required_checks_paths "required_checks_paths entry 'a"$'\t'"b' is not a repo-relative file or directory"
    _reset; _req '["Git Bash tagged files"]'
    _ins "project.$TEST_PROJECT" required_checks_paths '"scripts/ci/"'
    _dies required_checks_paths 'required_checks_paths must be an array of single-line strings, e.g. required_checks_paths = ["scripts/ci/"]'
}

@test "#1097 config: either key under [defaults] dies, with or without a project key" {
    _lib
    local k msg
    for k in required_checks required_checks_paths; do
        msg="$k is per project (its values belong to one repository); move it from [defaults] to [project.<name>]"
        # without a project key
        _reset; _ins defaults "$k" '["x"]'
        run required_checks_resolve "$TEST_PROJECT"
        [ "$status" -eq 1 ]
        [[ "$output" == *": $msg" ]]
        # with both project keys
        _reset; _ins defaults "$k" '["x"]'; _req '["Git Bash tagged files"]'; _paths '["scripts/ci/"]'
        run required_checks_resolve "$TEST_PROJECT"
        [ "$status" -eq 1 ]
        [[ "$output" == *": $msg" ]]
        # whatever its type there: a string is as misplaced as an array
        _reset; _ins defaults "$k" '"x"'
        run required_checks_resolve "$TEST_PROJECT"
        [ "$status" -eq 1 ]
        [[ "$output" == *": $msg" ]]
    done
}

@test "#1097 config: required_checks_paths without required_checks dies naming both keys" {
    _lib
    local msg="required_checks_paths is set but required_checks is not (the paths are watched only where a check is required); set required_checks or remove required_checks_paths"
    _paths '["scripts/ci/"]'
    _dies required_checks_paths "$msg"
    # An empty required_checks is none, so the paths still stand alone.
    _reset; _req '[]'; _paths '["scripts/ci/"]'
    _dies required_checks_paths "$msg"
    # Control: an empty paths list adds no path, so there is nothing to refuse.
    _reset; _paths '[]'
    required_checks_resolve "$TEST_PROJECT"
    [ "${#REQUIRED_CHECKS[@]}" -eq 0 ]
    [ "${#REQUIRED_CHECKS_PATHS[@]}" -eq 0 ]
}

@test "#1097 config: a config that cannot be read dies naming the key, never none" {
    _lib
    _req '["Git Bash tagged files"]'
    printf 'this is [not toml\n' >> "$CFG"
    run required_checks_resolve "$TEST_PROJECT"
    [ "$status" -eq 1 ]
    [[ "$output" == *": could not read [project.$TEST_PROJECT] required_checks (exit 2)" ]]
}

@test "#1097 config: an append_only entry and a required_checks_paths entry are held to one path rule" {
    # Both become git pathspecs, so a hole closed for one must be closed for the
    # other: each predicate has to go through config_repo_path_valid.
    _lib
    source "$DEVAGENT_ROOT/scripts/lib/merge-forward.sh"
    # Control: the real rule accepts this path for both.
    merge_forward_entry_valid docs/NEWS.md
    required_checks_path_valid docs/NEWS.md
    # Replace the shared rule with one that refuses everything: both must follow it.
    config_repo_path_valid() { return 1; }
    run merge_forward_entry_valid docs/NEWS.md
    [ "$status" -eq 1 ]
    run required_checks_path_valid docs/NEWS.md
    [ "$status" -eq 1 ]
}

@test "#1097 list: prints the names; nothing without the key; exit 1 on a bad value" {
    # without the key: exit 0 and no output
    run --separate-stderr "$RCS" "$TEST_PROJECT"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    [ -z "$stderr" ]
    # the names, one per line, in config order
    _req '["Git Bash tagged files", "lint"]'; _paths '["scripts/ci/"]'
    run --separate-stderr "$RCS" "$TEST_PROJECT"
    [ "$status" -eq 0 ]
    [ "$output" = $'Git Bash tagged files\nlint' ]
    [ -z "$stderr" ]
    # a bad value: exit 1, the reason on stderr, nothing on stdout
    _reset; _ins "project.$TEST_PROJECT" required_checks '"Git Bash tagged files"'
    run --separate-stderr "$RCS" "$TEST_PROJECT"
    [ "$status" -eq 1 ]
    [ -z "$output" ]
    [[ "$stderr" == "required-checks.sh: required_checks must be an array of single-line strings"*"; fix [project.$TEST_PROJECT] required_checks" ]]
    # a bad required_checks_paths stops the list too: the config is wrong either way
    _reset; _req '["Git Bash tagged files"]'; _paths '["/etc/ci"]'
    run --separate-stderr "$RCS" "$TEST_PROJECT"
    [ "$status" -eq 1 ]
    [ -z "$output" ]
    [[ "$stderr" == *"; fix [project.$TEST_PROJECT] required_checks_paths" ]]
    # an unknown project is a stop, not an empty list
    _reset
    run --separate-stderr "$RCS" nosuchproject
    [ "$status" -eq 1 ]
    [ -z "$output" ]
    [[ "$stderr" == *"unknown project 'nosuchproject'"* ]]
    # a config that is not TOML says so, rather than calling the project unknown
    _req '["Git Bash tagged files"]'
    printf 'this is [not toml\n' >> "$CFG"
    run --separate-stderr "$RCS" "$TEST_PROJECT"
    [ "$status" -eq 1 ]
    [ -z "$output" ]
    [[ "$stderr" == *"required-checks.sh: config at $CFG is not valid TOML"* ]]
    [[ "$stderr" != *"unknown project"* ]]
    _reset
    # usage: no project, an empty one, a second argument
    run --separate-stderr "$RCS"
    [ "$status" -eq 2 ]
    [ -z "$output" ]
    [[ "$stderr" == *"usage: required-checks.sh <project>"* ]]
    run --separate-stderr "$RCS" ""
    [ "$status" -eq 2 ]
    run --separate-stderr "$RCS" "$TEST_PROJECT" extra
    [ "$status" -eq 2 ]
    [ -z "$output" ]
}
