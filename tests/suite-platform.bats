#!/usr/bin/env bats
# #654: every suite-count artifact records the platform that produced it, and the operator
# who RUNS preship may declare which platforms count. run-suite.sh appends
#   platform: os=<uname -s> kernel=<uname -r> fs=<filesystem type of the measured tree> modes=posix|no-op
# (grammar: scripts/lib/platform.sh), and preship-evidence.sh echoes it on its PASS line as
# [platform=...]. With [project.<name>] evidence_platforms in the CHECKING config, an
# artifact from any other platform fails PLATFORM UNATTESTED unless the operator passes a
# per-run --attest-platform, and an artifact with no platform: line fails. mr.md's Evidence
# block carries the same line, compared byte for byte; under a declaration it must (b',
# intent.md ## Answers). Platforms are
# SIMULATED with PATH shims for uname and df (the #565 binstub idiom of
# tests/suite-fs-preflight.bats), with the values measured at draft (imPlan U1/U2); the
# suite is never run on an undeclared platform on purpose (#550 was an accident).
load 'helpers/common'

setup() {
    devagent_test_setup
    cd "$SOURCE_DIR" || return
    mkdir -p tests && echo '# placeholder' > tests/x.bats            # a suite with no file-mode reference
    git add -A && git commit -q -m "seed tests"
    ST="$HOME/.claude/devagent/state/$TEST_PROJECT.toml"
    CFG="$HOME/.claude/devagent/config.toml"
    devagent_state_set "$ST" branch main
    devagent_state_set "$ST" baseline_sha "$(git rev-parse HEAD~1)"   # baseline..HEAD = 1 file
    cp "$CFG" "$DEVAGENT_TMP/config.pristine"
    mkdir -p "$DEVAGENT_TMP/binstub"
    printf '%s\n' '#!/usr/bin/env bash' 'echo "1..1"' 'echo "ok 1 a"' > "$DEVAGENT_TMP/binstub/bats"
    chmod +x "$DEVAGENT_TMP/binstub/bats"
}
teardown() { devagent_test_teardown; }

D=$'\xe2\x80\x94'                                                  # the em dash the scripts print
WSL_EXT4='os=Linux kernel=6.18.33.2-microsoft-standard-WSL2 fs=ext4 modes=posix'
WSL_MNTC='os=Linux kernel=6.18.33.2-microsoft-standard-WSL2 fs=9p modes=no-op'
GIT_BASH='os=MINGW64_NT-10.0-26200 kernel=3.6.9-b4195d69.x86_64 fs=ntfs modes=no-op'
FOREIGN_TREE="/nonexistent/other-env/devagent"                    # a VALUE, never created

_rs()   { PATH="$DEVAGENT_TMP/binstub:$PATH" run "$DEVAGENT_ROOT/scripts/run-suite.sh" "$TEST_PROJECT" Issue-1; }
_pe()   { run "$DEVAGENT_ROOT/scripts/preship-evidence.sh" "$TEST_PROJECT" Issue-1 "$@"; }
_art()  { ls "$DEVDOC_DIR/Issue-1/analysis/"*-suite-count.txt | sort | tail -1; }
_line() { sed -n "/^$1:/{s/^$1:[[:space:]]*//p;q;}" "$(_art)"; }   # one field of the newest artifact
_tag()  { sed -n "s/^$1=\"\\(.*\\)\"\$/\\1/p" "$DEVAGENT_ROOT/scripts/$2"; }   # from its ONE home
_head() { git -C "$SOURCE_DIR" rev-parse HEAD; }
_lib()  {
    . "$DEVAGENT_ROOT/scripts/lib/paths.sh"; . "$DEVAGENT_ROOT/scripts/lib/io.sh"
    . "$DEVAGENT_ROOT/scripts/lib/config.sh"; . "$DEVAGENT_ROOT/scripts/lib/platform.sh"
}
# _shim <cmd> <intercept line>: a binstub that runs the line and otherwise execs the REAL
# <cmd>, resolved with binstub stripped from PATH, so a shim never execs itself.
_shim() {
    local real
    real="$(PATH="${PATH//"$DEVAGENT_TMP/binstub:"/}"; command -v "$1" || true)"
    printf '%s\n' '#!/usr/bin/env bash' "$2" "exec '${real:-/bin/false}' \"\$@\"" > "$DEVAGENT_TMP/binstub/$1"
    chmod +x "$DEVAGENT_TMP/binstub/$1"
}
# _platform <os> <kernel> <fstype>: a simulated platform. df answers only the lib's exact
# three-word call, `df --output=fstype -- <dir>`, matched ELEMENT-WISE (register wf
# devagent-593: a joined "$*" cannot tell one argv word from three). It answers <fstype> for
# the MEASURED tree (.../src/testproj) and `wrong-dir` for any other path, so a stamp that
# probed the wrong directory is visible; any other argv reaches the real df. The host-name
# answers are PLANTED for R5.
_platform() {
    _shim uname "case \"\$1\" in -s) echo '$1'; exit 0 ;; -r) echo '$2'; exit 0 ;; -n|-a) echo PLANTED-HOSTNAME; exit 0 ;; esac"
    _shim df "if [ \"\$#\" -eq 3 ] && [ \"\$1\" = --output=fstype ] && [ \"\$2\" = -- ]; then case \"\$3\" in */src/testproj) printf 'Type\\n%s\\n' '$3' ;; *) printf 'Type\\nwrong-dir\\n' ;; esac; exit 0; fi"
}
# The ONE hand-written artifact: #660-era, in SOURCE_DIR's canonical tree (tree=checked,
# upstream=no-origin), so each test fails on the platform rung only. $1 = the platform
# body ("" omits the line); $2 = tree (default the canonical SOURCE_DIR).
_art654() {
    local t="${2:-$(cd "$SOURCE_DIR" && pwd -P)}"
    {   printf 'head: %s  dirty: no\ntree: %s\nbats: 1/1 notok=0\npytest: (none)\nbranch: main\nupstream: (no-origin)\n' "$(_head)" "$t"
        [ -z "$1" ] || printf 'platform: %s\n' "$1"
    } > "$DEVDOC_DIR/Issue-1/analysis/2026-07-09-suite-count.txt"
}
# _mr654 [<platform body>]: an mr.md whose Evidence block matches _art654's suite: and files:.
# With a body, the block also carries `platform: <body>`, the line draftmr copies from the
# artifact (b'). preship compares it with the artifact's and requires it under a declaration,
# so every test that expects a pass under a declaration passes the artifact's body here.
_mr654() {
    { echo '## Summary'; echo x; echo '## Evidence'
      echo "suite: 1/1 bats @ $(_head)"; echo "files: 1 changed"
      [ -z "${1:-}" ] || echo "platform: $1"; } > "$DEVDOC_DIR/Issue-1/mr.md"
}
_att_tree() { printf 'head=%s dirty=no path=%s' "$(_head)" "$FOREIGN_TREE"; }
# _declare <TOML array literal>: evidence_platforms in [project.testproj] of a PRISTINE
# config. ENVIRON, not awk -v, so a literal \n in the TOML text stays two characters.
_declare() {
    cp "$DEVAGENT_TMP/config.pristine" "$CFG"
    DECL="evidence_platforms = $1" awk -v hdr="[project.$TEST_PROJECT]" \
        '{ print } $0 == hdr { print ENVIRON["DECL"] }' "$CFG" > "$CFG.new"
    mv "$CFG.new" "$CFG"
    [ "$(grep -c '^evidence_platforms = ' "$CFG")" -eq 1 ]
}

# ---- lib: scripts/lib/platform.sh --------------------------------------------------

@test "#654 lib: platform.sh defines the stamp and declaration helpers (a 127 must not satisfy the rows below)" {
    _lib
    type platform_stamp_resolve
    type platform_body_valid
    type platform_entry_valid
    type platform_entry_matches
    type platform_declaration_resolve
}

@test "#654 lib: platform_stamp_resolve records uname -s, uname -r and the directory's df fstype, plus the given modes" {
    _lib
    _platform Linux 6.18.33.2-microsoft-standard-WSL2 ext4
    PATH="$DEVAGENT_TMP/binstub:$PATH"; hash -r
    platform_stamp_resolve "$SOURCE_DIR" posix
    [ "$PLATFORM_BODY" = "$WSL_EXT4" ]
    platform_stamp_resolve "$SOURCE_DIR" no-op
    [ "$PLATFORM_BODY" = "os=Linux kernel=6.18.33.2-microsoft-standard-WSL2 fs=ext4 modes=no-op" ]
    platform_stamp_resolve "$DEVAGENT_TMP" posix                     # another directory: df's other answer
    [ "$PLATFORM_BODY" = "os=Linux kernel=6.18.33.2-microsoft-standard-WSL2 fs=wrong-dir modes=posix" ]
}

@test "#654 lib: a probe that fails or prints only a header records (unknown), and the body keeps the one shape" {
    _lib
    _shim uname 'exit 1'
    _shim df 'echo Type; exit 0'                                     # a header and no value
    PATH="$DEVAGENT_TMP/binstub:$PATH"; hash -r
    platform_stamp_resolve "$SOURCE_DIR" posix
    [ "$PLATFORM_BODY" = "os=(unknown) kernel=(unknown) fs=(unknown) modes=posix" ]
    platform_body_valid "$PLATFORM_BODY"
    _shim df 'exit 1'
    hash -r
    platform_stamp_resolve "$SOURCE_DIR" no-op
    [ "$PLATFORM_BODY" = "os=(unknown) kernel=(unknown) fs=(unknown) modes=no-op" ]
}

@test "#654 lib: a byte outside the value class is recorded as _, identically under C and C.UTF-8" {
    # Without the lib's own LC_ALL=C, C.UTF-8 replaces per CHARACTER (Lin_x) and C per BYTE
    # (Lin__x): the same platform would record two lines (imPlan U10; register Issue-600).
    _lib
    _shim uname "case \"\$1\" in -s) printf 'Lin\\303\\274x\\n'; exit 0 ;; -r) echo '1.0 (custom)/x'; exit 0 ;; esac"
    _shim df "printf 'Type\\n%s\\n' 'fuse.sshfs '; exit 0"
    PATH="$DEVAGENT_TMP/binstub:$PATH"; hash -r
    local want='os=Lin__x kernel=1.0__custom__x fs=fuse.sshfs modes=posix'
    LC_ALL=C.UTF-8 platform_stamp_resolve "$SOURCE_DIR" posix
    [ "$PLATFORM_BODY" = "$want" ]
    LC_ALL=C platform_stamp_resolve "$SOURCE_DIR" posix
    [ "$PLATFORM_BODY" = "$want" ]
}

@test "#654 lib: platform_body_valid accepts the producer's shapes and rejects every other" {
    _lib
    local u=$'Lin\xc3\xbcx'
    local -a ok=("$WSL_EXT4" "$WSL_MNTC" "$GIT_BASH" 'os=(unknown) kernel=(unknown) fs=(unknown) modes=posix')
    local -a bad=(
        ''
        'os=Linux fs=ext4 modes=posix'                        # a key missing
        "$WSL_EXT4 "                                          # trailing blank (#601: unparseable)
        " $WSL_EXT4"                                          # leading blank
        'os=Linux  kernel=x fs=ext4 modes=posix'              # doubled separator
        'kernel=x os=Linux fs=ext4 modes=posix'               # keys out of order
        'os=Linux kernel=x fs=ext2/ext3 modes=posix'          # a byte outside the class
        'os=Linux kernel=x fs=ext4 modes=maybe'               # modes outside its two values
        'os=Linux kernel=x fs=ext4 modes=posix host=h'        # an extra key
        "os=$u kernel=x fs=ext4 modes=posix"                  # non-ASCII, whatever the locale
    )
    local b n=0
    for b in "${ok[@]}"; do
        platform_body_valid "$b" || { echo "rejected: [$b]"; return 1; }
        n=$((n + 1))
    done
    [ "$n" -eq 4 ]
    n=0
    for b in "${bad[@]}"; do
        if platform_body_valid "$b"; then echo "accepted: [$b]"; return 1; fi
        n=$((n + 1))
    done
    [ "$n" -eq 10 ]                                           # subject COUNT (register Issue-151)
}

@test "#654 lib: platform_entry_valid accepts key=value subsets of the stamp and rejects the rest" {
    _lib
    local -a ok=('os=Linux fs=ext4' 'fs=ext4' 'modes=no-op' 'fs=ext4 os=Linux'
                 'os=Linux kernel=6.18.33.2-microsoft-standard-WSL2 fs=ext4 modes=posix')
    local -a bad=('' ' ' 'os=Linux  fs=ext4' ' fs=ext4' 'fs=ext4 ' $'os=Linux\tfs=ext4' 'host=nuc'
                  'fs=' 'fs=(unknown)' 'modes=maybe' 'os=Linux os=Darwin' 'fs=ext2/ext3' 'os=Linux,fs=ext4')
    local e n=0
    for e in "${ok[@]}"; do
        platform_entry_valid "$e" || { echo "rejected: [$e]"; return 1; }
        n=$((n + 1))
    done
    [ "$n" -eq 5 ]
    n=0
    for e in "${bad[@]}"; do
        if platform_entry_valid "$e"; then echo "accepted: [$e]"; return 1; fi
        n=$((n + 1))
    done
    [ "$n" -eq 13 ]
}

@test "#654 lib: platform_entry_matches is exact per field, and an empty entry matches nothing" {
    _lib
    platform_entry_matches 'os=Linux fs=ext4' "$WSL_EXT4"
    platform_entry_matches 'fs=ext4 os=Linux' "$WSL_EXT4"
    platform_entry_matches 'kernel=6.18.33.2-microsoft-standard-WSL2' "$WSL_MNTC"
    local e rc n=0
    for e in 'os=Linux fs=ext4' 'fs=ext' 'os=Lin' 'modes=posix' ''; do
        rc=0; platform_entry_matches "$e" "$WSL_MNTC" || rc=$?
        [ "$rc" -eq 1 ] || { echo "matched: [$e]"; return 1; }
        n=$((n + 1))
    done
    [ "$n" -eq 5 ]
}

@test "#654 lib: platform_entry_valid and platform_entry_matches do not depend on the caller's IFS" {
    # The pairs are split and re-joined on single spaces; an ambient IFS (a caller that set
    # IFS=: for its own parsing) must not turn every valid entry into an invalid one.
    _lib
    local IFS=:
    platform_entry_valid 'os=Linux fs=ext4'
    platform_entry_matches 'os=Linux fs=ext4' "$WSL_EXT4"
    local rc=0
    platform_entry_matches 'os=Linux fs=9p' "$WSL_EXT4" || rc=$?
    [ "$rc" -eq 1 ]
    rc=0
    platform_entry_valid 'os=Linux  fs=ext4' || rc=$?
    [ "$rc" -eq 1 ]
}

@test "#654 lib: platform_declaration_resolve - absent declares nothing, a list keeps its order, an empty last entry dies" {
    _lib
    platform_declaration_resolve "$TEST_PROJECT"
    [ "$PLATFORM_DECLARED_SET" = false ]
    [ "${#PLATFORM_DECLARED[@]}" -eq 0 ]
    _declare '["os=Linux fs=ext4", "fs=ntfs"]'
    platform_declaration_resolve "$TEST_PROJECT"
    [ "$PLATFORM_DECLARED_SET" = true ]
    [ "${#PLATFORM_DECLARED[@]}" -eq 2 ]
    [ "${PLATFORM_DECLARED[0]}" = "os=Linux fs=ext4" ]
    [ "${PLATFORM_DECLARED[1]}" = "fs=ntfs" ]
    _declare '["os=Linux fs=ext4", ""]'                            # $( ... ) alone would drop this entry (U4)
    run platform_declaration_resolve "$TEST_PROJECT"
    [ "$status" -eq 1 ]
    [[ "$output" == *"entry ''"* ]]
}

# ---- run-suite: the platform: stamp -------------------------------------------------

@test "#654 AC1: every artifact ends with one platform: line after upstream:, in the one shape, from this host's uname, df and chmod probe" {
    _rs
    [ "$status" -eq 0 ]
    local art body fs
    art="$(_art)"
    [ "$(grep -c '^platform:' "$art")" -eq 1 ]
    [ "$(grep -n '^platform:' "$art" | cut -d: -f1)" -gt "$(grep -n '^upstream:' "$art" | cut -d: -f1)" ]
    body="$(_line platform)"
    _lib
    platform_body_valid "$body"                              # the checker's own predicate (Issue-232/585)
    fs="$(df --output=fstype -- "$SOURCE_DIR" | sed -n '2p')" # derived here, not by the lib's parse
    [[ " $body " == *" os=$(uname -s) "* ]]
    [[ " $body " == *" kernel=$(uname -r) "* ]]
    [[ " $body " == *" fs=$fs "* ]]
    # modes= is the SAME probe run file_modes: renders (D3), whichever way this host answers.
    case "$(_line file_modes)" in
        posix)     [[ " $body " == *" modes=posix "* ]] ;;
        "no-op; "*) [[ " $body " == *" modes=no-op "* ]] ;;
        *)         echo "unexpected file_modes: $(_line file_modes)"; return 1 ;;
    esac
}

@test "#654 AC1: a simulated WSL ext4 clone and a simulated /mnt/c checkout differ only in fs=, under the same kernel" {
    _platform Linux 6.18.33.2-microsoft-standard-WSL2 ext4
    _rs
    [ "$status" -eq 0 ]
    local a b
    a="$(_line platform)"
    _platform Linux 6.18.33.2-microsoft-standard-WSL2 9p
    DEVAGENT_DATE_OVERRIDE=2099-01-01 _rs                      # a second artifact, sorting after the first
    [ "$status" -eq 0 ]
    b="$(_line platform)"
    [[ " $a " == *" fs=ext4 "* ]]
    [[ " $b " == *" fs=9p "* ]]
    [ "${a/ fs=ext4 / fs=9p }" = "$b" ]                        # the kernel string is identical; only fs= differs
}

@test "#654 AC1: a simulated Git Bash checkout records its os, kernel and fs, and modes=no-op beside file_modes: no-op" {
    _platform MINGW64_NT-10.0-26200 3.6.9-b4195d69.x86_64 ntfs
    _shim chmod 'exit 0'                                       # the #565 no-op pair (suite-fs-preflight.bats)
    _shim stat 'echo 644; exit 0'
    _rs
    [ "$status" -eq 0 ]
    [ "$(_line platform)" = "$GIT_BASH" ]
    [[ "$(_line file_modes)" == "no-op; "* ]]
}

@test "#654: a tests-less tree still records modes= from the probe, while file_modes: stays (none)" {
    _shim chmod 'exit 0'
    _shim stat 'echo 644; exit 0'
    git -C "$SOURCE_DIR" rm -q -r tests
    git -C "$SOURCE_DIR" commit -q -m "no tests"
    _rs
    [ "$status" -eq 0 ]
    [ "$(_line file_modes)" = "(none)" ]                         # no suite, so no gate ran (unchanged)
    [[ " $(_line platform) " == *" modes=no-op "* ]]             # the probe itself did run (D3)
}

@test "#654: the stamp never records a host name (planted: uname -n and -a, hostname, HOSTNAME)" {
    # register lawfirm Issue-6/18: an absence claim ships with a planted control. First
    # prove the plants answer, so an implementation that asked WOULD see them.
    _platform Linux 6.18.33.2-microsoft-standard-WSL2 ext4
    _shim hostname 'echo PLANTED-HOSTNAME; exit 0'
    run env PATH="$DEVAGENT_TMP/binstub:$PATH" uname -n
    [ "$output" = "PLANTED-HOSTNAME" ]
    run env PATH="$DEVAGENT_TMP/binstub:$PATH" hostname
    [ "$output" = "PLANTED-HOSTNAME" ]
    HOSTNAME=PLANTED-HOSTNAME _rs
    [ "$status" -eq 0 ]
    [ "$(grep -c '^platform:' "$(_art)")" -eq 1 ]               # non-vacuous: there IS a stamp to inspect
    run grep -c 'PLANTED-HOSTNAME' "$(_art)"
    [ "$status" -eq 1 ]
}

@test "#654: failed probes record (unknown) and the run still writes its artifact" {
    _shim uname 'exit 1'
    _shim df 'exit 1'
    _rs
    [ "$status" -eq 0 ]
    [[ "$(_line platform)" == "os=(unknown) kernel=(unknown) fs=(unknown) modes="* ]]
}

@test "#654: DEVAGENT_TREE_GUARD_OVERRIDE neither removes nor changes the platform: line" {
    _platform Linux 6.18.33.2-microsoft-standard-WSL2 ext4
    DEVAGENT_TREE_GUARD_OVERRIDE=1 _rs
    [ "$status" -eq 0 ]
    [[ "$(_line platform)" == "os=Linux kernel=6.18.33.2-microsoft-standard-WSL2 fs=ext4 modes="* ]]
}

# ---- preship-evidence: the platform rung --------------------------------------------

@test "#654 AC3 back-compat: no declaration, no platform: line - the PASS line is the pre-654 line plus [platform=unstamped], exactly" {
    # The whole output, not a substring: at 81bd632 it was exactly this line minus the
    # suffix (imPlan U6, measured), so the suffix is the ONLY change.
    _art654 ""
    _mr654
    _pe
    [ "$status" -eq 0 ]
    [ "$output" = "preship-evidence: PASS $D mr.md Evidence matches $(_art) (1/1 bats @ $(_head); files=1) [tree=checked] [upstream=no-origin] [platform=unstamped]" ]
}

@test "#654 AC1: no declaration - a stamped artifact passes and the PASS line echoes it as [platform=undeclared: ...]" {
    _art654 "$GIT_BASH"                                            # nothing declared, so nothing refuses it
    _mr654
    _pe
    [ "$status" -eq 0 ]
    [[ "$output" == *"[upstream=no-origin] [platform=undeclared: $GIT_BASH]" ]]
}

@test "#654 AC3: with a declaration, an artifact with no platform: line fails, and re-running run-suite on a declared platform clears it" {
    _declare '["os=Linux fs=ext4"]'
    _art654 ""
    _mr654
    _pe
    [ "$status" -eq 1 ]
    [[ "$output" == *"no 'platform:' line"* ]]
    [[ "$output" == *"evidence_platforms"* ]]
    [[ "$output" != *"preship-evidence: PASS"* ]]
    _platform Linux 6.18.33.2-microsoft-standard-WSL2 ext4             # the remedy, on a declared platform
    DEVAGENT_DATE_OVERRIDE=2099-01-01 _rs
    [ "$status" -eq 0 ]
    _mr654 "$(_line platform)"                                          # draftmr copies the new line (b')
    _pe
    [ "$status" -eq 0 ]
    [[ "$output" == *"[platform=checked: os=Linux kernel=6.18.33.2-microsoft-standard-WSL2 fs=ext4 modes="* ]]
}

@test "#654 AC2: with a declaration, an undeclared platform fails PLATFORM UNATTESTED with rc 1, naming it, the entries and the file" {
    local tag; tag="$(_tag platform_unattested preship-evidence.sh)"
    [ "$tag" = "PLATFORM UNATTESTED" ]
    _declare '["os=Linux fs=ext4"]'
    _art654 "$GIT_BASH"
    _mr654 "$GIT_BASH"                                              # disclosed, so the rung is the only failure
    _pe
    [ "$status" -eq 1 ]                                             # rc 1: never "warn + exit 0" (AC2)
    [[ "$output" == *"$tag"* ]]
    [[ "$output" == *"'$GIT_BASH'"* ]]
    [[ "$output" == *"'os=Linux fs=ext4'"* ]]
    [[ "$output" == *"$CFG"* ]]
    [[ "$output" != *"preship-evidence: PASS"* ]]
    [ "$(grep -o '([1-3]) ' <<<"$output" | wc -l)" -eq 3 ]           # three remedies; X1-X3 run each
}

@test "#654 AC2: sanctioned flow on day one - a WSL ext4 artifact checked from another environment passes; its /mnt/c twin fails" {
    _declare '["os=Linux fs=ext4 modes=posix"]'                     # the documented declaration (imPlan D12)
    _art654 "$WSL_EXT4" "$FOREIGN_TREE"                             # produced in the WSL clone, checked from here
    _mr654 "$WSL_EXT4"
    _pe --attest-tree "$(_att_tree)"
    [ "$status" -eq 0 ]
    [[ "$output" == *"[tree=attested: head=$(_head)"* ]]
    [[ "$output" == *"[platform=checked: $WSL_EXT4 $D matches evidence_platforms 'os=Linux fs=ext4 modes=posix']" ]]
    _art654 "$WSL_MNTC" "$FOREIGN_TREE"                             # the same kernel, a /mnt/c checkout
    _mr654 "$WSL_MNTC"
    _pe --attest-tree "$(_att_tree)"
    [ "$status" -eq 1 ]
    [[ "$output" == *"PLATFORM UNATTESTED"* ]]
    [[ "$output" != *"TREE UNATTESTED"* ]]                          # only the platform rung fails
}

@test "#654: a platform: line that is not the one shape fails, declared or not, an empty one is not an absent one, and re-running run-suite clears it" {
    _mr654
    local b n=0
    for b in "$WSL_EXT4 " 'os=Linux fs=ext4' '(none)'; do
        _art654 "$b"
        _pe
        [ "$status" -eq 1 ] || { echo "passed: [$b]"; return 1; }
        [[ "$output" == *"'platform:' line"* ]] || { echo "unnamed: [$b]"; return 1; }
        n=$((n + 1))
    done
    [ "$n" -eq 3 ]
    _art654 ""
    printf 'platform:\n' >> "$(_art)"                                # present but empty: NOT unstamped
    _pe
    [ "$status" -eq 1 ]
    [[ "$output" == *"'platform:' line ''"* ]]
    _declare '["os=Linux fs=ext4"]'
    _art654 "$WSL_EXT4 host=h"
    _pe
    [ "$status" -eq 1 ]
    [[ "$output" == *"'platform:' line"* ]]
    [[ "$output" == *"re-run run-suite (#654)"* ]]
    # The printed remedy, executed (register Fork-132): re-run run-suite, on a declared platform.
    _platform Linux 6.18.33.2-microsoft-standard-WSL2 ext4
    DEVAGENT_DATE_OVERRIDE=2099-01-01 _rs
    [ "$status" -eq 0 ]
    _mr654 "$(_line platform)"
    _pe
    [ "$status" -eq 0 ]
    [[ "$output" == *"[platform=checked: os=Linux kernel=6.18.33.2-microsoft-standard-WSL2 fs=ext4 modes="* ]]
}

@test "#654: any matching entry passes and the PASS line names it; an entry naming fewer keys matches more" {
    _declare '["os=Darwin", "fs=ntfs modes=no-op"]'
    _art654 "$GIT_BASH"
    _mr654 "$GIT_BASH"
    _pe
    [ "$status" -eq 0 ]
    [[ "$output" == *"[platform=checked: $GIT_BASH $D matches evidence_platforms 'fs=ntfs modes=no-op']" ]]
    _declare '["os=Linux"]'
    _art654 "$WSL_MNTC"
    _mr654 "$WSL_MNTC"
    _pe
    [ "$status" -eq 0 ]                                              # os alone admits /mnt/c: the operator's choice
    [[ "$output" == *"matches evidence_platforms 'os=Linux'"* ]]
}

@test "#654 AC2: an --attest-platform matching the artifact passes, in both spellings, and the PASS line records it" {
    _declare '["os=Linux fs=ext4"]'
    _art654 "$GIT_BASH"
    _mr654 "$GIT_BASH"                                                 # the disclosure b' requires once declared
    local ack; ack="head=$(_head) platform=$GIT_BASH"
    _pe --attest-platform "$ack"
    [ "$status" -eq 0 ]
    [[ "$output" == *"[platform=attested: $ack $D acknowledged by the caller for this run; not in this project's evidence_platforms]" ]]
    _pe "--attest-platform=$ack"
    [ "$status" -eq 0 ]
    [[ "$output" == *"[platform=attested: $ack "* ]]
}

@test "#654: an --attest-platform naming another head or another platform, or malformed, is refused" {
    _declare '["os=Linux fs=ext4"]'
    _art654 "$GIT_BASH"
    _mr654 "$GIT_BASH"
    local other; other="$(git -C "$SOURCE_DIR" rev-parse HEAD~1)"
    _pe --attest-platform "head=$other platform=$GIT_BASH"
    [ "$status" -eq 1 ]
    [[ "$output" == *"names head $other"* ]]
    _pe --attest-platform "head=$(_head) platform=$WSL_MNTC"
    [ "$status" -eq 1 ]
    [[ "$output" == *"names platform '$WSL_MNTC'"* ]]
    _pe --attest-platform "platform=$GIT_BASH head=$(_head)"           # right facts, wrong shape
    [ "$status" -eq 1 ]
    [[ "$output" == *"malformed --attest-platform"* ]]
}

@test "#654: --attest-platform with no value, an empty value, or given twice is a usage error; unknown options name it" {
    # register wf Issue-655: one leg per parser clause, both spellings.
    _art654 "$GIT_BASH"
    _mr654
    _pe --attest-platform
    [ "$status" -eq 1 ]
    [[ "$output" == *"--attest-platform needs a value"* ]]
    _pe --attest-platform ""
    [ "$status" -eq 1 ]
    [[ "$output" == *"--attest-platform needs a value"* ]]
    _pe --attest-platform=
    [ "$status" -eq 1 ]
    [[ "$output" == *"--attest-platform needs a value"* ]]
    _pe --attest-platform "head=x platform=y" --attest-platform "head=x platform=y"
    [ "$status" -eq 1 ]
    [[ "$output" == *"--attest-platform given more than once"* ]]
    _pe --attest_platform x
    [ "$status" -eq 1 ]
    [[ "$output" == *"[--attest-platform '<attestation>']"* ]]
}

@test "#654: an --attest-platform the rung did not need is ignored with a warning" {
    _art654 "$WSL_EXT4"
    _mr654 "$WSL_EXT4"
    local ack; ack="head=$(_head) platform=$WSL_EXT4"
    _pe --attest-platform "$ack"                                       # nothing declared
    [ "$status" -eq 0 ]
    [[ "$output" == *"--attest-platform ignored"* ]]
    [[ "$output" == *"[platform=undeclared: $WSL_EXT4]"* ]]
    _declare '["os=Linux fs=ext4"]'
    _pe --attest-platform "$ack"                                       # declared and matched
    [ "$status" -eq 0 ]
    [[ "$output" == *"--attest-platform ignored"* ]]
    [[ "$output" == *"[platform=checked: "* ]]
}

@test "#654: --attest-tree, --attest-upstream and DEVAGENT_TREE_GUARD_OVERRIDE do not acknowledge an undeclared platform" {
    # register wf Issue-597: cross the new policy with every existing flag near it.
    _declare '["os=Linux fs=ext4"]'
    _art654 "$WSL_MNTC" "$FOREIGN_TREE"
    _mr654 "$WSL_MNTC"
    DEVAGENT_TREE_GUARD_OVERRIDE=1 _pe --attest-tree "$(_att_tree)" --attest-upstream "head=$(_head) upstream=(unpushed)"
    [ "$status" -eq 1 ]
    [[ "$output" == *"PLATFORM UNATTESTED"* ]]
}

@test "#654: a malformed evidence_platforms dies before any check, naming the key and the file" {
    _art654 "$WSL_EXT4"                                             # an artifact that would PASS
    _mr654 "$WSL_EXT4"
    local -a bad=('"os=Linux fs=ext4"' '[]' '[""]' '["host=nuc"]' '["os=Linux  fs=ext4"]'
                  '["modes=maybe"]' '["os=Linux os=Darwin"]' '["fs=(unknown)"]' '["os=Linux\nfs=ext4"]' '[1, 2]')
    # Each row's own reason, so no row passes on another class's die (M7, M8 depend on it).
    local -a why=('must be an array' 'is empty' "entry ''" "entry 'host=nuc'" "entry 'os=Linux  fs=ext4'"
                  "entry 'modes=maybe'" "entry 'os=Linux os=Darwin'" "entry 'fs=(unknown)'" 'single-line strings' 'must be an array')
    [ "${#why[@]}" -eq "${#bad[@]}" ]
    local i n=0
    for i in "${!bad[@]}"; do
        _declare "${bad[$i]}"
        _pe
        [ "$status" -eq 1 ] || { echo "accepted: ${bad[$i]}"; return 1; }
        [[ "$output" == *"evidence_platforms"* ]] || { echo "unnamed: ${bad[$i]}"; return 1; }
        [[ "$output" == *"$CFG"* ]] || { echo "no file: ${bad[$i]}"; return 1; }
        [[ "$output" == *"${why[$i]}"* ]] || { echo "wrong reason for ${bad[$i]}: $output"; return 1; }
        [[ "$output" != *"FAIL"* ]] || { echo "checks ran first: ${bad[$i]}"; return 1; }
        n=$((n + 1))
    done
    [ "$n" -eq 10 ]
}

@test "#654 AC2: PLATFORM UNATTESTED remedy 1 - run-suite's real /mnt/c artifact fails, and re-running on a declared ext4 platform clears it" {
    # register Issue-232: the producer's REAL artifact through the consumer, both outcomes.
    _declare '["os=Linux fs=ext4"]'
    _platform Linux 6.18.33.2-microsoft-standard-WSL2 9p
    _rs
    [ "$status" -eq 0 ]
    _mr654 "$(_line platform)"                                          # draftmr copies the artifact's line (b')
    _pe
    [ "$status" -eq 1 ]
    [[ "$output" == *"PLATFORM UNATTESTED"* ]]
    [[ "$output" == *"fs=9p"* ]]
    [[ "$output" == *"(1) re-run run-suite on a declared platform"* ]]
    _platform Linux 6.18.33.2-microsoft-standard-WSL2 ext4
    DEVAGENT_DATE_OVERRIDE=2099-01-01 _rs
    [ "$status" -eq 0 ]
    _mr654 "$(_line platform)"                                          # and re-copies it after the re-run
    _pe
    [ "$status" -eq 0 ]
    [[ "$output" == *"[platform=checked: os=Linux kernel=6.18.33.2-microsoft-standard-WSL2 fs=ext4 modes="* ]]
}

@test "#654: PLATFORM UNATTESTED remedy 2 (add the platform to evidence_platforms) clears it" {
    _declare '["os=Linux fs=ext4"]'
    _art654 "$GIT_BASH"
    _mr654 "$GIT_BASH"
    _pe
    [ "$status" -eq 1 ]
    [[ "$output" == *"(2) if this platform is in fact supported"* ]]
    _declare '["os=Linux fs=ext4", "os=MINGW64_NT-10.0-26200 fs=ntfs"]'
    _pe
    [ "$status" -eq 0 ]
    [[ "$output" == *"matches evidence_platforms 'os=MINGW64_NT-10.0-26200 fs=ntfs'"* ]]
}

@test "#654: PLATFORM UNATTESTED remedy 3 - the printed --attest-platform, run as printed, passes and is recorded" {
    # register Issue-594/Fork-132: execute the message's own remedy (every one of three).
    _declare '["os=Linux fs=ext4"]'
    _art654 "$GIT_BASH"
    _mr654 "$GIT_BASH"
    _pe
    [ "$status" -eq 1 ]
    local ack
    ack="$(printf '%s\n' "$output" | sed -n "s/.*(3) .*--attest-platform '\([^']*\)'.*/\1/p")"
    [ -n "$ack" ]
    [ "$ack" = "head=$(_head) platform=$GIT_BASH" ]
    _pe --attest-platform "$ack"
    [ "$status" -eq 0 ]
    [[ "$output" == *"[platform=attested: $ack "* ]]
}

# ---- the #149 no-Evidence exit ----------------------------------------------------

@test "#654 (D10): with a declaration and no Evidence block, an artifact always fails - the missing block first, then the rung's failures, with no acknowledgment offered" {
    # register Issue-466 MAJOR-2 / lawfirm Issue-14: deleting the Evidence block must not
    # sidestep the declaration (tests/preship-evidence.bats pins the same for pytest: (error)).
    # b' (intent.md ## Answers): under a declaration the MR body must carry the platform:
    # line, attested or not, and an mr.md with no Evidence block carries none.
    _declare '["os=Linux fs=ext4"]'
    { echo '## Summary'; echo 'no evidence block here'; } > "$DEVDOC_DIR/Issue-1/mr.md"
    _art654 "$GIT_BASH"
    _pe
    [ "$status" -eq 1 ]
    [[ "$output" == *"PLATFORM UNATTESTED"* ]]
    [[ "$output" == *"mr.md has no '## Evidence' block, and"* ]]
    [[ "$output" != *"skipping evidence checks"* ]]                        # never the #149 WARN-and-pass
    # imPlan D10 (improve A4): the missing block is reported FIRST, and remedy (3) is not
    # offered here, because an acknowledgment cannot clear a missing block.
    local out="$output" first
    first="$(grep -m1 '^  - ' <<<"$out")"
    [[ "$first" == *"mr.md has no '## Evidence' block, and"* ]]
    [[ "$out" == *"(1) re-run run-suite on a declared platform"* ]]
    [[ "$out" == *"(2) if this platform is in fact supported"* ]]
    [[ "$out" == *"No acknowledgment can clear this exit"* ]]
    [ "$(printf "x --attest-platform 'y'\n" | grep -cF -- "--attest-platform '")" -eq 1 ]   # planted control
    run grep -cF -- "--attest-platform '" <<<"$out"
    [ "$status" -eq 1 ]
    _pe --attest-platform "head=$(_head) platform=$GIT_BASH"               # acknowledged: the disclosure is still missing
    [ "$status" -eq 1 ]
    [[ "$output" != *"PLATFORM UNATTESTED"* ]]
    [[ "$output" == *"mr.md has no '## Evidence' block, and"* ]]
    [[ "$output" == *"platform: $GIT_BASH"* ]]                             # names the line the block must carry
    _art654 ""
    _pe
    [ "$status" -eq 1 ]
    [[ "$output" == *"no 'platform:' line"* ]]
    _art654 "$WSL_EXT4"                                                    # a declared platform: still no disclosure
    _pe
    [ "$status" -eq 1 ]
    [[ "$output" == *"platform: $WSL_EXT4"* ]]
    _mr654 "$WSL_EXT4"                                                     # the remedy: an Evidence block carrying the named line
    _pe
    [ "$status" -eq 0 ]
    [[ "$output" == *"[platform=checked: $WSL_EXT4 "* ]]
    { echo '## Summary'; echo 'no evidence block here'; } > "$DEVDOC_DIR/Issue-1/mr.md"
    rm "$(_art)"                                                           # no artifact at all: the plain #149 path
    _pe
    [ "$status" -eq 0 ]
    [[ "$output" == *"skipping evidence checks"* ]]
    [[ "$output" != *"[platform="* ]]
}

@test "#654 back-compat: no declaration and no Evidence block - the #149 WARN is byte-identical whatever the platform (pin)" {
    # A pin, green before #654 too (allow-listed for born-red). Measured exact at 81bd632.
    { echo '## Summary'; echo 'no evidence block here'; } > "$DEVDOC_DIR/Issue-1/mr.md"
    _art654 "$GIT_BASH"
    _pe
    [ "$status" -eq 0 ]
    [ "$output" = "preship-evidence: WARN $D mr.md has no '## Evidence' block; skipping evidence checks (#149 absent"$'\xe2\x87\x92'"no-gate)" ]
}

@test "#654: the preship verifier names PLATFORM UNATTESTED, has no form to attest it, and knows the [platform=] suffix" {
    # register Issue-286/598: a checker must be TOLD the gate's contract, the tag taken from
    # the script. The acknowledgment is the operator's (imPlan D7), so the verifier carries no
    # form to fill: an absence leg, with a positive control on the same grep (lawfirm Issue-6).
    local f="$DEVAGENT_ROOT/agents/preship-verifier.md" tag
    tag="$(_tag platform_unattested preship-evidence.sh)"
    [ "$tag" = "PLATFORM UNATTESTED" ]
    grep -qF -- "$tag" "$f"
    grep -qF -- '[platform=' "$f"
    grep -qF -- '--attest-platform' "$DEVAGENT_ROOT/scripts/preship-evidence.sh"   # control: the grep sees the flag
    run grep -cF -- '--attest-platform' "$f"
    [ "$status" -eq 1 ]
}

# ---- the MR body: the Evidence platform: line (b', intent.md ## Answers) ----------

@test "#654 b': an Evidence platform: line equal to the artifact's passes - undeclared, attested or checked" {
    _art654 "$GIT_BASH"
    _mr654 "$GIT_BASH"
    _pe
    [ "$status" -eq 0 ]
    [ "$output" = "preship-evidence: PASS $D mr.md Evidence matches $(_art) (1/1 bats @ $(_head); files=1) [tree=checked] [upstream=no-origin] [platform=undeclared: $GIT_BASH]" ]
    _declare '["os=Linux fs=ext4"]'
    _pe --attest-platform "head=$(_head) platform=$GIT_BASH"             # the attested case, disclosed
    [ "$status" -eq 0 ]
    [[ "$output" == *"[platform=attested: head=$(_head) platform=$GIT_BASH $D acknowledged"* ]]
    _art654 "$WSL_EXT4"
    _mr654 "$WSL_EXT4"
    _pe
    [ "$status" -eq 0 ]
    [[ "$output" == *"[platform=checked: $WSL_EXT4 $D matches evidence_platforms 'os=Linux fs=ext4']" ]]
}

@test "#654 b': an Evidence platform: line one byte off the artifact's fails, naming the exact line to write, and writing it passes" {
    # The #466 suite: precedent: a mismatch names the exact correct line. The lines are
    # compared whole and raw, so a blank that the rung's own read strips still differs.
    _art654 "$WSL_EXT4"
    local v n=0
    local -a off=("platform: $WSL_EXT4 " "platform:  $WSL_EXT4" "platform: $WSL_MNTC" 'platform: os=Linux fs=ext4' 'platform:')
    for v in "${off[@]}"; do
        _mr654
        printf '%s\n' "$v" >> "$DEVDOC_DIR/Issue-1/mr.md"
        _pe
        [ "$status" -eq 1 ] || { echo "passed: [$v]"; return 1; }
        [[ "$output" == *"mr.md='$v' vs artifact='platform: $WSL_EXT4'"* ]] || { echo "unnamed: [$v]"; return 1; }
        [[ "$output" != *"preship-evidence: PASS"* ]] || { echo "PASS printed: [$v]"; return 1; }
        n=$((n + 1))
    done
    [ "$n" -eq 5 ]                                                   # subject COUNT (register Issue-151)
    # The printed remedy, executed (register Fork-132): write the artifact's line, as named.
    local line
    line="$(sed -n "s/.* vs artifact='\(platform: [^']*\)'.*/\1/p" <<<"$output")"
    [ "$line" = "platform: $WSL_EXT4" ]
    _mr654
    printf '%s\n' "$line" >> "$DEVDOC_DIR/Issue-1/mr.md"
    _pe
    [ "$status" -eq 0 ]
}

@test "#654 b' AC3: no declaration and no Evidence platform: line - unchecked, and the output is exactly the PASS line (pin)" {
    # AC3 stays literal under b': without a declaration, an Evidence block that lacks the
    # line (every mr.md drafted before #654) changes only the echo.
    _art654 "$GIT_BASH"
    _mr654
    _pe
    [ "$status" -eq 0 ]
    [ "$output" = "preship-evidence: PASS $D mr.md Evidence matches $(_art) (1/1 bats @ $(_head); files=1) [tree=checked] [upstream=no-origin] [platform=undeclared: $GIT_BASH]" ]
}

@test "#654 b': with a declaration, an Evidence block without the platform: line fails, naming the line to paste, which then passes" {
    _declare '["os=Linux fs=ext4"]'
    _art654 "$WSL_EXT4"                                              # a declared platform: the rung itself passes
    _mr654                                                           # suite: and files:, no platform:
    _pe
    [ "$status" -eq 1 ]
    [[ "$output" == *"Evidence platform line missing"* ]]
    [[ "$output" != *"PLATFORM UNATTESTED"* ]]
    [[ "$output" != *"no '## Evidence' block"* ]]                    # the arm reports it, never the #149 exit (D10)
    [ "$(grep -c 'Evidence platform line' <<<"$output")" -eq 1 ]     # reported once
    [[ "$output" != *"preship-evidence: PASS"* ]]
    local line
    line="$(sed -n 's/.*Add this line to the block: \(platform: .*\)$/\1/p' <<<"$output")"
    [ "$line" = "platform: $WSL_EXT4" ]                              # the artifact's line, exactly
    _mr654
    printf '%s\n' "$line" >> "$DEVDOC_DIR/Issue-1/mr.md"              # the remedy, run as printed (register Fork-132)
    _pe
    [ "$status" -eq 0 ]
    [[ "$output" == *"[platform=checked: $WSL_EXT4 "* ]]
    _art654 ""                                                       # unstamped: the rung fails, and the arm has no line to name
    _mr654
    _pe
    [ "$status" -eq 1 ]
    [[ "$output" == *"no 'platform:' line"* ]]
    [[ "$output" == *"Add this line to the block: the platform: line of an artifact re-run by run-suite"* ]]
}

@test "#654 b': with a declaration, an --attest-platform acknowledgment does not excuse a missing Evidence platform: line" {
    # b' (intent.md ## Answers): the attested, undeclared case is the one a maintainer most
    # needs to see, so it may not omit the disclosure.
    _declare '["os=Linux fs=ext4"]'
    _art654 "$GIT_BASH"
    _mr654
    local ack; ack="head=$(_head) platform=$GIT_BASH"
    _pe --attest-platform "$ack"
    [ "$status" -eq 1 ]
    [[ "$output" == *"Evidence platform line missing"* ]]
    [[ "$output" == *"Add this line to the block: platform: $GIT_BASH"* ]]
    [[ "$output" != *"PLATFORM UNATTESTED"* ]]                       # the rung itself was acknowledged
    [[ "$output" != *"--attest-platform ignored"* ]]
    _mr654 "$GIT_BASH"                                               # disclosed
    _pe --attest-platform "$ack"
    [ "$status" -eq 0 ]
    [[ "$output" == *"[platform=attested: $ack "* ]]
}

@test "#654 b': an Evidence platform: line with no artifact platform: line to back it fails, declared or not, and each printed remedy clears it" {
    _art654 ""                                                       # nothing declared: the rung says unstamped
    _mr654 "$WSL_EXT4"
    _pe
    [ "$status" -eq 1 ]
    [[ "$output" == *"Evidence platform line without an artifact line: mr.md has 'platform: $WSL_EXT4'"* ]]
    [[ "$output" != *"preship-evidence: PASS"* ]]
    [[ "$output" == *"deleting the Evidence line also clears this"* ]]
    _mr654                                                           # remedy: delete the line (nothing declared)
    _pe
    [ "$status" -eq 0 ]
    [[ "$output" == *"[platform=unstamped]"* ]]
    _declare '["os=Linux fs=ext4"]'
    _mr654 "$WSL_EXT4"
    _pe
    [ "$status" -eq 1 ]
    [[ "$output" == *"no 'platform:' line"* ]]                        # the rung's failure ...
    [[ "$output" == *"Evidence platform line without an artifact line"* ]]   # ... and the arm's
    # Remedy: re-run run-suite with this plugin's scripts (on a declared platform), then
    # copy the platform: line it writes (register Fork-132: every printed remedy, executed).
    _platform Linux 6.18.33.2-microsoft-standard-WSL2 ext4
    DEVAGENT_DATE_OVERRIDE=2099-01-01 _rs
    [ "$status" -eq 0 ]
    _mr654 "$(_line platform)"
    _pe
    [ "$status" -eq 0 ]
    [[ "$output" == *"[platform=checked: os=Linux kernel=6.18.33.2-microsoft-standard-WSL2 fs=ext4 modes="* ]]
}

@test "#654 b' AC4: the core-draft-mr rule copies platform: into the Evidence block and points at preship-evidence, not at a prose quote" {
    # AC4: the rule points at the mechanical check instead of prose. Whitespace-normalised,
    # because prose wraps mid-phrase (register Issue-612/465).
    local f="$DEVAGENT_ROOT/skills/core-draft-mr/SKILL.md" t
    local retired="quote the line under the body's testing notes"     # the #600 rule at 81bd632 :97-98
    t="$(tr -s '[:space:]' ' ' < "$f")"
    [[ "$t" == *"into the Evidence block whole and unchanged"* ]]
    [[ "$t" == *"preship-evidence.sh"* ]]
    [[ "$t" == *"compares it with the artifact byte for byte"* ]]
    [[ "$t" == *"evidence_platforms"* ]]
    [[ "$t" == *"modes=no-op"* ]]                                    # the #600 disclosure rides the checked line
    [ "$(printf 'a %s b\n' "$retired" | grep -cF "$retired")" -eq 1 ]   # planted control (lawfirm Issue-6)
    run grep -cF "$retired" <<<"$t"
    [ "$status" -eq 1 ]
}

@test "#654 b': mr_template carries one live platform: line, which fails unfilled naming the artifact's, and the verifier is told the rule" {
    local tpl="$DEVAGENT_ROOT/templates/mr_template.md" ev ph p
    ev="$(awk '/^## Evidence/{f=1;next} /^## /{f=0} f' "$tpl")"            # the checker's own extraction
    [ "$(grep -c '^platform:' <<<"$ev")" -eq 1 ]                          # one live line; no comment line starts platform: (U12)
    [ "$(grep -n '^platform:' <<<"$ev" | cut -d: -f1)" -gt "$(grep -n '^files:' <<<"$ev" | cut -d: -f1)" ]
    ph="$(grep '^platform:' <<<"$ev")"
    _art654 "$WSL_EXT4"
    _mr654
    printf '%s\n' "$ph" >> "$DEVDOC_DIR/Issue-1/mr.md"                     # the placeholder, left unfilled
    _pe
    [ "$status" -eq 1 ]
    [[ "$output" == *"artifact='platform: $WSL_EXT4'"* ]]                 # the exact line to write
    # Step 4 of the verifier, up to its first tag paragraph, names the line and its check.
    p="$(awk '/[*][*]Evidence cross-check[.][*][*]/{f=1} f && /[*][*]`TREE UNATTESTED`[*][*]/{exit} f' "$DEVAGENT_ROOT/agents/preship-verifier.md" | tr -s '[:space:]' ' ')"
    [ -n "$p" ]
    [[ "$p" == *"platform:"* ]]
    [[ "$p" == *"byte for byte"* ]]
    [[ "$p" == *"evidence_platforms"* ]]
}

@test "#654 b': two Evidence platform: lines fail as duplicated, naming both and the one to keep, which then passes" {
    # imPlan improve A2: exactly one Evidence platform: line may stand. A stale line left
    # beside a pasted one (a remedy applied by appending) is a duplicate, never judged by
    # whichever line comes first.
    _art654 "$WSL_EXT4"
    _mr654 "$WSL_MNTC"                                               # a stale line ...
    printf '%s\n' "platform: $WSL_EXT4" >> "$DEVDOC_DIR/Issue-1/mr.md"   # ... and the right one appended
    _pe
    [ "$status" -eq 1 ]
    [[ "$output" == *"Evidence platform line duplicated"* ]]
    [[ "$output" == *"'platform: $WSL_MNTC', 'platform: $WSL_EXT4'"* ]]
    [[ "$output" != *"Evidence platform line mismatch"* ]]
    local line
    line="$(sed -n 's/.*Keep only this line: \(platform: .*\)$/\1/p' <<<"$output")"
    [ "$line" = "platform: $WSL_EXT4" ]
    _mr654
    printf '%s\n' "$line" >> "$DEVDOC_DIR/Issue-1/mr.md"              # the remedy, run as printed (register Fork-132)
    _pe
    [ "$status" -eq 0 ]
    _mr654 "$WSL_EXT4"                                               # two EQUAL lines are still two
    printf '%s\n' "platform: $WSL_EXT4" >> "$DEVDOC_DIR/Issue-1/mr.md"
    _pe
    [ "$status" -eq 1 ]
    [[ "$output" == *"has 2 platform: lines"* ]]
}

# ---- documentation ----------------------------------------------------------------

@test "#654 sweep: every docs home names evidence_platforms, and every home naming TREE UNATTESTED names PLATFORM UNATTESTED" {
    # Homes DERIVED from the claims (register Issue-458/583): the AC4 homes plus the spec,
    # CHANGELOG and the script header name the key; every doc that names the tree rung's
    # tag names the platform rung's. Whitespace-normalised: prose wraps mid-tag (Issue-612/465).
    local f t n=0 tag
    tag="$(_tag platform_unattested preship-evidence.sh)"
    [ "$tag" = "PLATFORM UNATTESTED" ]
    local homes=(README.md CONTRIBUTING.md docs-site/configuration.md templates/config.toml.skel
                 docs/specs/2026-05-19-devagent-plugin-design.md CHANGELOG.md scripts/preship-evidence.sh)
    [ "${#homes[@]}" -eq 7 ]
    for f in "${homes[@]}"; do
        grep -qF 'evidence_platforms' "$DEVAGENT_ROOT/$f" || { echo "no evidence_platforms in $f"; return 1; }
    done
    [ "$(printf 'x TREE\n   UNATTESTED y\n' | tr -s '[:space:]' ' ' | grep -c 'TREE UNATTESTED')" -eq 1 ]   # planted control
    for f in "$DEVAGENT_ROOT"/README.md "$DEVAGENT_ROOT"/docs/specs/*.md "$DEVAGENT_ROOT"/docs-site/*.md \
             "$DEVAGENT_ROOT"/skills/*/SKILL.md "$DEVAGENT_ROOT"/agents/*.md; do
        t="$(tr -s '[:space:]' ' ' < "$f")"
        if [[ "$t" == *"TREE UNATTESTED"* ]]; then
            n=$((n + 1))
            [[ "$t" == *"$tag"* ]] || { echo "$f names TREE UNATTESTED but not $tag"; return 1; }
        fi
    done
    [ "$n" -ge 3 ]                                    # README, the spec, the verifier (census at 81bd632)
    grep -qF -- "$tag" "$DEVAGENT_ROOT/CHANGELOG.md"
    # improve SE4: the README's framing paragraph counts what the section covers, so it must
    # name the fourth, recorded-only fact too (register lectio Issue-10).
    local framing
    framing="$(awk '/^The suite has three environmental requirements/{f=1} f && /^$/{exit} f' "$DEVAGENT_ROOT/README.md" | tr -s '[:space:]' ' ')"
    [ -n "$framing" ]
    [[ "$framing" == *"A fourth fact is recorded but not required"* ]]
    [[ "$framing" == *"evidence_platforms"* ]]
}

@test "#654: the evidence_platforms example as written in config.toml.skel, README and docs-site pins modes=posix and is a declaration preship-evidence accepts" {
    # register Issue-461/583: a doc an operator copies is product behaviour; each home
    # carries an editor note naming this test. imPlan D12: the example pins modes=posix.
    local skel readme site d n=0 noop
    skel="$(sed -n 's/^# evidence_platforms = \(.*\)$/\1/p' "$DEVAGENT_ROOT/templates/config.toml.skel")"
    readme="$(sed -n 's/^evidence_platforms = \(.*\)$/\1/p' "$DEVAGENT_ROOT/README.md")"
    site="$(sed -n 's/^# evidence_platforms = \(\[[^]]*\]\).*$/\1/p' "$DEVAGENT_ROOT/docs-site/configuration.md")"
    _art654 "$WSL_EXT4"
    _mr654 "$WSL_EXT4"                                # b': declared, so the Evidence line is required
    for d in "$skel" "$readme" "$site"; do
        [ "$(printf '%s\n' "$d" | grep -c .)" -eq 1 ] || { echo "not one example: [$d]"; return 1; }
        [[ "$d" == *"modes=posix"* ]] || { echo "modes not pinned: $d"; return 1; }
        _declare "$d"
        _pe
        [ "$status" -eq 0 ] || { echo "refused: $d"; return 1; }
        [[ "$output" == *"[platform=checked: $WSL_EXT4 "* ]] || { echo "not checked: $d"; return 1; }
        n=$((n + 1))
    done
    [ "$n" -eq 3 ]
    # What the pin buys: an ext4 clone whose chmod probe found a no-op is refused.
    noop='os=Linux kernel=6.18.33.2-microsoft-standard-WSL2 fs=ext4 modes=no-op'
    _art654 "$noop"
    _mr654 "$noop"
    _pe
    [ "$status" -eq 1 ]
    [[ "$output" == *"PLATFORM UNATTESTED"* ]]
}
