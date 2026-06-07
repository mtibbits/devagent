#!/usr/bin/env bats
load 'helpers/common'

setup() {
    devagent_test_setup
    # die() lives in io.sh; paths.sh is its dependency. coauthor.sh needs die.
    . "$DEVAGENT_ROOT/scripts/lib/paths.sh"
    . "$DEVAGENT_ROOT/scripts/lib/io.sh"
    . "$DEVAGENT_ROOT/scripts/lib/coauthor.sh"
}
teardown() { devagent_test_teardown; }

@test "strip_coauthor removes canonical trailer, keeps Signed-off-by and body" {
    f="$DEVAGENT_TMP/msg"
    printf '%s\n' 'subject line' '' 'body text' \
        'Signed-off-by: Test User <t@example.com>' \
        'Co-authored-by: Claude <noreply@anthropic.com>' > "$f"
    strip_coauthor "$f"
    run grep -qi 'co-authored-by' "$f"
    [ "$status" -ne 0 ]
    grep -q '^Signed-off-by:' "$f"
    grep -qx 'body text' "$f"
    grep -qx 'subject line' "$f"
}

@test "strip_coauthor is case-insensitive (Co-Authored-By)" {
    f="$DEVAGENT_TMP/msg"
    printf '%s\n' 'subj' 'Co-Authored-By: A B <a@b.c>' > "$f"
    strip_coauthor "$f"
    run grep -qi 'co-authored-by' "$f"
    [ "$status" -ne 0 ]
    grep -qx 'subj' "$f"
}

@test "strip_coauthor tolerates leading whitespace and multiple trailers" {
    f="$DEVAGENT_TMP/msg"
    printf '%s\n' 'subj' '  Co-authored-by: One <1@x>' \
        "$(printf '\tCo-Authored-By: Two <2@x>')" 'keep me' > "$f"
    strip_coauthor "$f"
    run grep -qi 'co-authored-by' "$f"
    [ "$status" -ne 0 ]
    grep -qx 'keep me' "$f"
    [ "$(grep -c . "$f")" -eq 2 ]   # only 'subj' + 'keep me' remain
}

@test "strip_coauthor leaves a trailer-free file byte-identical" {
    f="$DEVAGENT_TMP/msg"
    printf '%s\n' 'subj' '' 'body' 'Signed-off-by: X <x@y>' > "$f"
    before="$(cat "$f")"
    strip_coauthor "$f"
    [ "$(cat "$f")" = "$before" ]
}

@test "strip_coauthor dies on a missing file" {
    run strip_coauthor "$DEVAGENT_TMP/does-not-exist"
    [ "$status" -ne 0 ]
    [[ "$output" == *"no such file"* ]]
}
