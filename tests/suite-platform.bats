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
# artifact (b', Task 6). preship ignores that line before Task 6 and compares it from Task 6 on,
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
