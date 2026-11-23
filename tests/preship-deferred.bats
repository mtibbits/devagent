#!/usr/bin/env bats
# bats file_tags=gitbash
# #1097 preship-deferred.sh, the reads at the pinned head: a criterion's static half
# (the tag line, a skip guard, which files the job selects, a CRLF file, the pinned
# commit not the working tree, a file git cannot read), the fallback hand transcript,
# and that no call writes. These are the paths MSYS argument rewriting and CRLF could
# break, so the Git Bash job runs this file. The usage, bare-call and guard-reader
# tests are in tests/preship-deferred-parse.bats, which runs on Linux only (#1097: the
# whole set took 791s of the job's 30-minute limit on Windows).
#
# Invariant: line 2 is the only comment line of this file that may hold both the tag
# key and the tag value (scripts/ci/gitbash-tagged.sh calls any other one malformed).
load 'helpers/common'
load 'helpers/preship-deferred'
bats_require_minimum_version 1.5.0

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

@test "#1097 deferred: a name that more than one test carries fails as named more than once" {
    _req
    _base
    _fixture names.bats
    _static tests/names.bats dup
    _failed "test 'dup' in tests/names.bats at ${PIN:0:7} is named more than once"
    # one test displays it, the other spells it
    _static tests/names.bats 'shown twice: a\b'
    _failed "test 'shown twice: a\\b' in tests/names.bats at ${PIN:0:7} is named more than once"
    # three tests: the same words
    _static tests/names.bats 'thrice'
    _failed "test 'thrice' in tests/names.bats at ${PIN:0:7} is named more than once"
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
    _tfailed "evidence/$n line 1 is not a full commit id: $UNAME_LINE"
}

@test "#1097 transcript: no pin exits 2" {
    _base
    _tx "2026-11-20-gitbash-guards-${OTHER:0:12}.txt" "$OTHER" "$UNAME_LINE"
    _transcript
    _cnr "preship-deferred: no pinned head is recorded for Issue-1 (preship_pin_head)"
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
    [ "$status" -eq 1 ]; [[ "$output" == "static check failed: tests/guards.bats:"*": Git Bash skip guard in 'trip: and-skip': "* ]]
    _transcript
    [ "$status" -eq 0 ]
    _gitshim cat-file 128 "cat-file blob"           # could not run, after the temporary directory was made
    _static tests/guards.bats "pass: or-skip"
    _cnr "preship-deferred: tests/guards.bats at ${PIN:0:7} cannot be read in $SOURCE_DIR (git cat-file exited 128)"
    after="$(_snap)"
    [ "$after" = "$before" ] || { printf 'before:\n%s\nafter:\n%s\n' "$before" "$after"; return 1; }
    [ -z "$(ls -A "$TMPDIR")" ] || { echo "left in TMPDIR: $(ls -A "$TMPDIR")"; return 1; }
}
