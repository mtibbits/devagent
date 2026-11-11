#!/usr/bin/env bats
# #455: the commit-discipline PreToolUse guard. Drives hooks/commit-guard.sh with
# PreToolUse JSON on stdin (exit 2 = deny, exit 0 = allow). Opt-in default-off; fires
# only for a `git commit` missing -s when an issue is active for the resolved project
# AND cwd is under that project's source_dir.

. "${BATS_TEST_DIRNAME}/lib/hermetic-env.bash"

REPO="${BATS_TEST_DIRNAME}/.."
HOOK="$REPO/hooks/commit-guard.sh"

# #950: the six cwd spellings the issue's AC names, against source_dir c:/x/proj.
WIN_SPELLINGS=('C:\x\proj' 'c:\x\proj' '/c/x/proj' '/C/x/proj' 'C:/x/proj/sub/' 'c:\x\proj\sub')

setup() {
  DA="$BATS_TEST_TMPDIR/da"; mkdir -p "$DA/state"
  export DA_HOME="$DA"
  SRC="$BATS_TEST_TMPDIR/proj"; mkdir -p "$SRC"
  _src "$SRC"
  printf 'active_issue = "Issue-7"\n' > "$DA/state/acme.toml"
  export DEVAGENT_ACTIVE_PROJECT=acme
  unset DEVAGENT_COMMIT_GUARD_OVERRIDE
}
# _js <string> - the string's JSON literal (quotes included), no trailing newline.
# The string reaches python3 on stdin only: Git Bash rewrites a /c/... ARGUMENT to a
# native program, which would falsify the fixture (#950).
_js() { printf '%s' "$1" | python3 -c 'import json,sys; sys.stdout.write(json.dumps(sys.stdin.read()))'; }
_j()  { printf '{"tool_input":{"command":%s},"cwd":%s}' "$(_js "$1")" "$(_js "${2:-$SRC}")"; }
_feed() { run bash -c 'printf "%s" "$1" | bash "$2"' _ "$1" "$HOOK"; }

# _src <source_dir> [off] rewrites the config with that source_dir and commit_guard on;
# "off" leaves the commit_guard line out (the default-off gate).
# _deny / _allow <cwd> feed an unsigned commit from that cwd and return non-zero with
# a named reason, so a loop can collect every failing leg (#950).
_src() {
  { [ "${2:-}" = off ] || printf '[defaults]\ncommit_guard = true\n'
    printf '[project.acme]\nsource_dir = "%s"\n' "$1"; } > "$DA/config.toml"
}
_deny() {
  _feed "$(_j 'git commit -m fix' "$1")"
  [ "$status" -eq 2 ] || { echo "cwd '$1': want DENY (status 2), got status $status" >&2; return 1; }
  [[ "$output" == *DCO* ]] || { echo "cwd '$1': deny output lacks DCO: $output" >&2; return 1; }
  [[ "$output" == *Issue-7* ]] || { echo "cwd '$1': deny output lacks Issue-7: $output" >&2; return 1; }
  [[ "$output" == *"Override this single call: DEVAGENT_COMMIT_GUARD_OVERRIDE=1"* ]] ||
    { echo "cwd '$1': deny output lacks the override line: $output" >&2; return 1; }
}
_allow() {
  _feed "$(_j 'git commit -m fix' "$1")"
  [ "$status" -eq 0 ] || { echo "cwd '$1': want ALLOW (status 0), got status $status" >&2; return 1; }
  [ -z "$output" ] || { echo "cwd '$1': allow printed output: $output" >&2; return 1; }
}
# _expect_each <deny|allow> <expected-count> <cwd>... - every cwd must get that verdict;
# all failing cwds are named in one message (each leg already printed its reason), and
# the count guards against a silently empty list.
_expect_each() {
  local verb="$1" want="$2" sp n=0 bad=""; shift 2
  for sp in "$@"; do
    "_$verb" "$sp" || bad+="[$sp] "
    n=$((n + 1))
  done
  [ -z "$bad" ] || { echo "want $verb, did not get it: $bad" >&2; return 1; }
  [ "$n" -eq "$want" ] || { echo "ran $n legs, want $want" >&2; return 1; }
}
# _symlink_or_skip <target> <link> - make the link, or skip where ln -s copies.
_symlink_or_skip() {
  ln -s "$1" "$2" 2>/dev/null || true
  [ -L "$2" ] || skip "no real symlinks here (ln -s copies)"
}
# _case_insensitive_or_skip <dir> - skip unless <dir> is on a case-insensitive filesystem.
_case_insensitive_or_skip() {
  mkdir "$1/CaseProbe"
  [ -d "$1/caseprobe" ] || skip "the temp dir is on a case-sensitive filesystem"
}

@test "active tree: signed 'git commit -s' PASSES (#455)" {
  _feed "$(_j 'git commit -s -m fix')"; [ "$status" -eq 0 ]
  _feed "$(_j 'git commit -sm fix')";   [ "$status" -eq 0 ]
  _feed "$(_j 'git commit --signoff -m fix')"; [ "$status" -eq 0 ]
}

@test "active tree: unsigned 'git commit' is DENIED, message names -s (#455)" {
  _feed "$(_j 'git commit -m fix')"
  [ "$status" -eq 2 ]
  [[ "$output" == *"-s"* ]]
}

@test "active tree: 'git commit --amend' without -s is DENIED (sign-off drop) (#455)" {
  _feed "$(_j 'git commit --amend --no-edit')"; [ "$status" -eq 2 ]
  _feed "$(_j 'git commit --amend -s')";        [ "$status" -eq 0 ]
}

@test "'-S' (gpg-sign) is NOT a DCO sign-off → unsigned commit DENIED (#455)" {
  _feed "$(_j 'git commit -S -m fix')"; [ "$status" -eq 2 ]
}

@test "fused DCO+gpg cluster '-sS'/'-Ss' IS signed → PASSES (#455 redmr)" {
  # -s (DCO sign-off) + -S (gpg-sign) in one cluster is a genuinely SIGNED commit;
  # the mandatory lowercase `s` is present, so it must not be wrongly denied.
  _feed "$(_j 'git commit -sS -m fix')"; [ "$status" -eq 0 ]
  _feed "$(_j 'git commit -Ss -m fix')"; [ "$status" -eq 0 ]
  # but -S alone (no lowercase s) is still UNSIGNED → denied (guard against widening).
  _feed "$(_j 'git commit -Sm fix')"; [ "$status" -eq 2 ]
}

@test "'commit' as a ref/other subcommand is NOT a git commit (#455)" {
  for c in 'git log commit' 'git commit-tree abc' 'echo commit' 'git show commit'; do
    _feed "$(_j "$c")"
    [ "$status" -eq 0 ] || { echo "false-positive on: $c (status $status)" >&2; false; }
  done
}

@test "out of scope: commit in a repo OUTSIDE the active source_dir PASSES (#455)" {
  _feed "$(_j 'git commit -m fix' '/some/other/repo')"; [ "$status" -eq 0 ]
}

@test "out of scope: no active_issue ⇒ unsigned commit PASSES (#455)" {
  printf 'active_issue = ""\n' > "$DA/state/acme.toml"
  _feed "$(_j 'git commit -m fix')"; [ "$status" -eq 0 ]
}

@test "opt-in default-off: gate off ⇒ unsigned commit PASSES (#455)" {
  _src "$SRC" off
  _feed "$(_j 'git commit -m fix')"; [ "$status" -eq 0 ]
}

@test "per-call override + fail-open: override / malformed input PASS (#455)" {
  export DEVAGENT_COMMIT_GUARD_OVERRIDE=1
  _feed "$(_j 'git commit -m fix')"; [ "$status" -eq 0 ]
  unset DEVAGENT_COMMIT_GUARD_OVERRIDE
  _feed 'not json'; [ "$status" -eq 0 ]
}

@test "per-call override as a command prefix PASSES, as the deny message says (#950 redmr)" {
  _feed "$(_j 'DEVAGENT_COMMIT_GUARD_OVERRIDE=1 git commit -m fix')"; [ "$status" -eq 0 ]
  _feed "$(_j 'DEVAGENT_COMMIT_GUARD_OVERRIDE=0 git commit -m fix')"; [ "$status" -eq 2 ]
}

@test "-C global option: 'git -C <dir> commit' unsigned is DENIED (#455)" {
  _feed "$(_j "git -C $SRC commit -m fix")"; [ "$status" -eq 2 ]
}

@test "fixture: _j escapes cwd and the hook reads each Windows spelling back (#950)" {
  # shellcheck source=/dev/null
  source "$REPO/hooks/lib/hook-common.sh"
  local sp got n=0 bad=""
  for sp in "${WIN_SPELLINGS[@]}"; do
    got="$(hook_json_field "$(_j 'git commit -m x' "$sp")" cwd 2>/dev/null || true)"
    [ "$got" = "$sp" ] || bad+="[$sp read back as '$got'] "
    n=$((n + 1))
  done
  [ -z "$bad" ] || { echo "cwd did not round-trip: $bad" >&2; false; }
  [ "$n" -eq 6 ]
}

# --- #950: cwd under source_dir, string fallback (the directories do not exist) ---

@test "string fallback: each Windows spelling of cwd is DENIED (#950)" {
  [ ! -e c:/x ] || skip "c:/x exists on this host"
  _src c:/x/proj
  _expect_each deny 6 "${WIN_SPELLINGS[@]}"
}

@test "string fallback: source_dir spelled C:/, /c/ or with a trailing slash still DENIES (#950)" {
  [ ! -e c:/x ] || skip "c:/x exists on this host"
  local r
  for r in C:/x/proj c:/x/proj/ /c/x/proj; do
    _src "$r"
    _expect_each deny 6 "${WIN_SPELLINGS[@]}" || { echo "source_dir '$r'" >&2; return 1; }
  done
}

@test "string fallback: proj2, another drive and a later-component case are ALLOWED (#950)" {
  [ ! -e c:/x ] || skip "c:/x exists on this host"
  _src c:/x/proj
  _deny c:/x/proj
  _expect_each allow 5 c:/x/proj2 'C:\x\proj2' /d/x/proj c:/x/Proj /some/other/repo
}

@test "POSIX source_dir keeps its answers (#950)" {
  [ ! -e /home/u ] || skip "/home/u exists on this host"
  _src /home/u/proj
  _deny /home/u/proj
  _deny /home/u/proj/sub
  _allow /home/u/proj2
}

@test "gate off: a Windows-spelled cwd gives exit 0 and no output (#950)" {
  _src c:/x/proj off
  _allow 'C:\x\proj'
}

# --- #950: cwd under source_dir, identity (real directories) ---

@test "identity: real directories, each Windows spelling is DENIED (#950)" {
  # The string fallback gives these same answers, so this test pins the real-directory
  # spellings end to end, not the identity limb; the later-component-case and `..`
  # identity tests below pin the limb.
  local M d l U rest bs
  M="$(cygpath -m "$BATS_TEST_TMPDIR" 2>/dev/null || true)"
  [[ "$M" =~ ^[A-Za-z]:/ ]] || skip "the temp dir has no <letter>:/ spelling here (not Git Bash)"
  _case_insensitive_or_skip "$M"
  mkdir -p "$M/x/proj/sub"
  d="${M:0:1}"; l="${d,,}"; U="${d^^}"
  rest="${M:2}"; rest="${rest%/}"      # /Users/.../N  (leading /, no trailing /)
  bs="${rest//\//\\}"                  # the same with \ separators
  _src "$l:$rest/x/proj"
  _expect_each deny 6 \
    "$U:$bs\\x\\proj" \
    "$l:$bs\\x\\proj" \
    "/$l$rest/x/proj" \
    "/$U$rest/x/proj" \
    "$U:$rest/x/proj/sub/" \
    "$l:$bs\\x\\proj\\sub"
}

@test "identity: a later component in another case is DENIED on a case-insensitive filesystem (#950)" {
  local T="$BATS_TEST_TMPDIR"
  _case_insensitive_or_skip "$T"
  mkdir -p "$T/x/proj/sub"
  _src "$T/x/proj"
  _deny "$T/x/Proj/sub"
}

@test "identity: a cwd through a symlink to source_dir is DENIED (#950)" {
  local T="$BATS_TEST_TMPDIR"
  mkdir -p "$T/x/proj/sub"
  _symlink_or_skip "$T/x/proj" "$T/link"
  _src "$T/x/proj"
  _deny "$T/link"
  _deny "$T/link/sub"
}

@test "identity decides when both exist: a .. segment leaving source_dir is ALLOWED (#950)" {
  local T="$BATS_TEST_TMPDIR"
  mkdir -p "$T/x/proj" "$T/x/other"
  _src "$T/x/proj"
  _deny "$T/x/proj"
  _allow "$T/x/proj/../other"
}

@test "identity: a symlinked subdir of source_dir pointing outside is ALLOWED (#950)" {
  local T="$BATS_TEST_TMPDIR"
  mkdir -p "$T/x/proj" "$T/x/out"
  _symlink_or_skip ../out "$T/x/proj/lnk"
  [ "$T/x/proj/lnk/.." -ef "$T/x" ] || skip ".. is lexical here, not the physical parent"
  _src "$T/x/proj"
  _deny "$T/x/proj"
  _allow "$T/x/proj/lnk"
}

@test "identity: the walk reaches a deep source_dir through a symlinked cwd (#950)" {
  local T="$BATS_TEST_TMPDIR"
  mkdir -p "$T/x/proj/a/b/c/d/e"
  _symlink_or_skip "$T/x/proj/a/b/c/d/e" "$T/w"
  _src "$T/x/proj"
  _deny "$T/w"
}

@test "identity: source_dir configured through a symlink, physical cwd is DENIED (#950)" {
  local T="$BATS_TEST_TMPDIR"
  mkdir -p "$T/x/proj/sub"
  _symlink_or_skip "$T/x/proj" "$T/plink"
  _src "$T/plink"
  _deny "$T/x/proj/sub"
}
