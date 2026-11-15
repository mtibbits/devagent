#!/usr/bin/env bats
# bats file_tags=gitbash
# tests/backend-local.bats — #1016: the local code backend, scripts/code/local.sh.
# Every verb and every cell of its exit table (spec §9.2), over real git in a
# scratch repo per test. Run on its own or nested by tests/backend-contract.bats.
# The caller-level tests (ship, comments, mergemr, trust) are tests/local-callers.bats.
bats_require_minimum_version 1.5.0   # run --separate-stderr wherever stdout or stderr is pinned

load 'lib/bats-helpers'

setup() {
  setup_tmp_devagent_home
  export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com
  LOCAL="$PLUGIN_ROOT/scripts/code/local.sh"
  R="$BATS_TEST_TMPDIR/repo one"
  _mkrepo "$R"
  MARKER="$BATS_TEST_TMPDIR/git-called"
}

teardown() { teardown_tmp_devagent_home; }

is_git_bash() { case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) return 0 ;; esac; return 1; }

# _mkrepo <dir>: a repo on `main` with one commit and a branch `feat` one commit ahead.
_mkrepo() {
  mkdir -p "$1"
  git -C "$1" init -q -b main
  git -C "$1" commit -q --allow-empty -m init
  git -C "$1" checkout -q -b feat
  git -C "$1" commit -q --allow-empty -m feat
  git -C "$1" checkout -q main
}

# _git_shim: a DEVAGENT_GIT that records each call in $MARKER, then runs git.
_git_shim() {
  local s="$BATS_TEST_TMPDIR/gitshim"
  printf '#!/usr/bin/env bash\necho "$*" >> %q\nexec git "$@"\n' "$MARKER" > "$s"
  chmod +x "$s"
  echo "$s"
}

@test "local: the script is tracked with mode 100755" {
  run git -C "$PLUGIN_ROOT" ls-files -s scripts/code/local.sh
  [ "$status" -eq 0 ]
  [[ "$output" == 100755\ * ]]
}

@test "local: push-branch does nothing, exits 0 and prints the push line on stderr" {
  DEVAGENT_GIT="$(_git_shim)" run --separate-stderr "$LOCAL" push-branch origin feat
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ "$stderr" = "push: not applicable (local code backend)" ]
  [ ! -e "$MARKER" ]
}

@test "local: merge-mr, issue-mrs, mr-checks and mr-view exit 78" {
  local v n=0
  for v in merge-mr issue-mrs mr-checks mr-view; do
    run --separate-stderr "$LOCAL" "$v"
    [ "$status" -eq 78 ]; [ -z "$output" ]
    [ "$stderr" = "$v: not implemented by the local code backend" ]
    n=$((n + 1))
    run --separate-stderr "$LOCAL" "$v" "local:%2Fx#feat" --method squash 12
    [ "$status" -eq 78 ]; [ -z "$output" ]
    [ "$stderr" = "$v: not implemented by the local code backend" ]
    n=$((n + 1))
  done
  [ "$n" -eq 8 ]
}

@test "local: branch-exists answers 0, 1 and 2" {
  run --separate-stderr "$LOCAL" branch-exists "$R" feat
  [ "$status" -eq 0 ]; [ -z "$output" ]
  run --separate-stderr "$LOCAL" branch-exists "$R" nope
  [ "$status" -eq 1 ]; [ -z "$output" ]
  mkdir -p "$BATS_TEST_TMPDIR/plain"
  run --separate-stderr "$LOCAL" branch-exists "$BATS_TEST_TMPDIR/plain" feat
  [ "$status" -eq 2 ]; [ -z "$output" ]
}

# _verb_args <verb>: positional arguments for <verb> in $R.
_verb_args() {
  case "$1" in
    push-branch) echo origin; echo feat ;;
    branch-exists|merged-pr-head) echo "$R"; echo feat ;;
    create-mr) echo "$R"; echo t; echo /dev/null; echo feat; echo main ;;
    mr-state|mr-comments) "$LOCAL" create-mr "$R" t /dev/null feat main ;;
    *) ;;
  esac
}

# _verb_want <verb>: the exit _verb_args' arguments give.
_verb_want() {
  case "$1" in
    merge-mr|issue-mrs|mr-checks|mr-view) echo 78 ;;
    merged-pr-head) echo 1 ;;
    *) echo 0 ;;
  esac
}

@test "local: every verb accepts and ignores --key <value>" {
  local v n=0 a1 a2 s1 o1
  for v in push-branch merge-mr issue-mrs mr-checks mr-view branch-exists create-mr mr-state mr-comments merged-pr-head; do
    mapfile -t args < <(_verb_args "$v")
    run "$LOCAL" "$v" "${args[@]}"
    s1="$status"; o1="$output"
    [ "$s1" -eq "$(_verb_want "$v")" ] || { echo "$v: status $s1" >&2; false; }
    run "$LOCAL" "$v" "${args[@]}" --key github/o/r
    [ "$status" -eq "$s1" ] || { echo "$v: $status vs $s1" >&2; false; }
    [ "$output" = "$o1" ]
    n=$((n + 1))
  done
  [ "$n" -eq 10 ]
}

@test "local: a bad --key, an unknown option, a wrong argument count and an unknown verb exit 2" {
  local n=0
  _two() { run --separate-stderr "$LOCAL" "$@"; [ "$status" -eq 2 ] || { echo "$*: $status" >&2; return 1; }; [ -z "$output" ]; n=$((n + 1)); }
  _two branch-exists "$R" feat --key                 # --key with no value
  _two branch-exists "$R" feat --key ''              # --key with an empty value
  _two branch-exists "$R" feat --key=x               # --key=<v>
  _two branch-exists "$R" feat --key a --key b       # a second --key
  _two branch-exists "$R" feat --draft               # any other argument there
  _two branch-exists "$R"                            # a wrong argument count
  _two frob                                          # an unknown verb
  _two                                               # no verb
  _two merge-mr --key                                # D-key first, even on a 78 verb
  _two mr-checks --key=x
  [ "$n" -eq 10 ]
  run --separate-stderr "$LOCAL" push-branch origin  # push-branch: 0 whatever its positionals
  [ "$status" -eq 0 ]
}

# --- create-mr, the reference and the record (Task 3) ------------------------

# _cdir <repo>: git's own common-dir line for <repo>, CR stripped.
_cdir() { git -C "$1" rev-parse --path-format=absolute --git-common-dir | tr -d '\r'; }

# _ref <repo> <branch>: the reference D-ref builds, by an independent encoder.
_ref() {
  python3 -X utf8 -c 'import sys,urllib.parse as u; q=lambda s: u.quote(s, safe="~"); print("local:" + q(sys.argv[1]) + "#" + q(sys.argv[2]))' "$(_cdir "$1")" "$2"
}

# _rec <repo> <branch>: the record's path.
_rec() {
  printf '%s/devagent/local-mr/%s' "$(_cdir "$1")" \
    "$(python3 -X utf8 -c 'import sys,urllib.parse as u; print(u.quote(sys.argv[1], safe="~"))' "$2")"
}

# _snap <repo>: refs, index and working tree as git reports them.
_snap() { git -C "$1" status --porcelain=v2 --branch; git -C "$1" for-each-ref; }

@test "local: create-mr writes the record and prints the reference" {
  local body="$BATS_TEST_TMPDIR/body.md"; echo body > "$body"
  run --separate-stderr "$LOCAL" create-mr "$R" "Add a thing" "$body" feat main
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 1 ]
  [ "$output" = "$(_ref "$R" feat)" ]
  local f; f="$(_rec "$R" feat)"
  [ -f "$f" ]
  local want
  want="$(printf '%s\n' 'version: 1' 'state: open' 'head: feat' 'base: main' \
    "head_sha: $(git -C "$R" rev-parse feat)" 'merge_commit: -' 'title: Add a thing')"
  [ "$(cat "$f")" = "$want" ]
  [ "$(wc -l < "$f")" -eq 7 ]
}

@test "local: a head feat/12-a#b%c.d in a repo path with a space round-trips through the reference (AC 3)" {
  local b='feat/12-a#b%c.d' r2 dir n=0
  r2="$BATS_TEST_TMPDIR/caf""é repo"
  _mkrepo "$r2"
  for dir in "$R" "$r2"; do
    local tip; tip="$(git -C "$dir" rev-parse feat)"
    git -C "$dir" branch -q -D feat           # refs/heads/feat would block feat/…
    git -C "$dir" branch "$b" "$tip"
    run --separate-stderr "$LOCAL" create-mr "$dir" "t" /dev/null "$b" main
    [ "$status" -eq 0 ]
    [ "${output##*#}" = 'feat%2F12-a%23b%25c.d' ]
    local half="${output#local:}"; half="${half%#*}"
    [ "$(python3 -X utf8 -c 'import sys,urllib.parse as u; print(u.unquote(sys.argv[1]))' "$half" | tr -d '\r')" = "$(_cdir "$dir")" ]
    [ "$output" = "$(_ref "$dir" "$b")" ]
    grep -qxF "head: $b" "$(_rec "$dir" "$b")"
    n=$((n + 1))
  done
  [ "$n" -eq 2 ]
  [[ "$(_ref "$r2" "$b")" == *%C3%A9* ]]
}

@test "local: the root, a subdirectory, a linked worktree and a symlink give one reference" {
  local want n=0
  mkdir -p "$R/sub/dir"
  git -C "$R" worktree add -q "$BATS_TEST_TMPDIR/wt" -b other main
  want="$(_ref "$R" feat)"
  for spelling in "$R" "$R/sub/dir" "$BATS_TEST_TMPDIR/wt"; do
    run --separate-stderr "$LOCAL" create-mr "$spelling" t /dev/null feat main
    [ "$status" -eq 0 ]; [ "$output" = "$want" ] || { echo "$spelling: $output" >&2; false; }
    n=$((n + 1))
  done
  [ "$n" -eq 3 ]
  is_git_bash && skip "Git Bash: ln -s copies instead of linking by default"
  ln -s "$R" "$BATS_TEST_TMPDIR/link"
  run --separate-stderr "$LOCAL" create-mr "$BATS_TEST_TMPDIR/link" t /dev/null feat main
  [ "$status" -eq 0 ]; [ "$output" = "$want" ]
}

@test "local: Git Bash slash, mixed and backslash spellings of one repo give the same reference (AC 3)" {
  is_git_bash || skip "Git Bash only (drive-letter forms are relative paths elsewhere)"
  local posix mixed win lower want n=0
  posix="$(cd "$R" && pwd)"
  mixed="$(cygpath -m "$R")"
  win="$(cygpath -w "$R")"
  lower="$(printf '%s' "${mixed:0:1}" | tr 'A-Z' 'a-z')${mixed:1}"
  run --separate-stderr "$LOCAL" create-mr "$posix" t /dev/null feat main
  [ "$status" -eq 0 ]
  want="$output"
  [[ "$want" == local:[A-Z]%3A%2F* ]]
  for spelling in "$mixed" "$win" "$lower"; do
    run --separate-stderr "$LOCAL" create-mr "$spelling" t /dev/null feat main
    [ "$status" -eq 0 ]; [ "$output" = "$want" ] || { echo "$spelling: $output" >&2; false; }
    n=$((n + 1))
  done
  [ "$n" -eq 3 ]
}

@test "local: create-mr ignores the cwd and an exported GIT_DIR, and records the named head, not HEAD" {
  local other="$BATS_TEST_TMPDIR/other"
  _mkrepo "$other"
  git -C "$R" checkout -q main
  cd "$other"
  GIT_DIR="$other/.git" run --separate-stderr "$LOCAL" create-mr "$R" t /dev/null feat main
  [ "$status" -eq 0 ]
  [ "$output" = "$(_ref "$R" feat)" ]
  grep -qxF "head_sha: $(git -C "$R" rev-parse feat)" "$(_rec "$R" feat)"
  [ "$(git -C "$R" rev-parse feat)" != "$(git -C "$R" rev-parse HEAD)" ]
  [ ! -e "$other/.git/devagent" ]
}

@test "local: create-mr --draft records open and prints the draft line" {
  run --separate-stderr "$LOCAL" create-mr "$R" t /dev/null feat main --draft
  [ "$status" -eq 0 ]
  [ "$output" = "$(_ref "$R" feat)" ]
  [ "$stderr" = "draft: not applicable (local code backend)" ]
  grep -qxF "state: open" "$(_rec "$R" feat)"
  run --separate-stderr "$LOCAL" create-mr "$R" t /dev/null feat main --key k --draft
  [ "$status" -eq 0 ]
}

@test "local: create-mr changes no ref, no index and no working-tree file" {
  echo x > "$R/untracked"
  local before; before="$(_snap "$R")"
  run --separate-stderr "$LOCAL" create-mr "$R" t /dev/null feat main
  [ "$status" -eq 0 ]
  [ "$(_snap "$R")" = "$before" ]
}

@test "local: create-mr refuses a non-repository, a missing head or base and an old git, and writes nothing" {
  local plain="$BATS_TEST_TMPDIR/plain" n=0 old="$BATS_TEST_TMPDIR/oldgit"
  mkdir -p "$plain"
  run --separate-stderr "$LOCAL" create-mr "$plain" t /dev/null feat main
  [ "$status" -eq 1 ]; [ -z "$output" ]
  [ "${stderr##*$'\n'}" = "not a git repository: $plain" ]; n=$((n + 1))
  run --separate-stderr "$LOCAL" create-mr "$R" t /dev/null nope main
  [ "$status" -eq 1 ]; [ -z "$output" ]
  [ "${stderr##*$'\n'}" = "not a local branch: nope" ]; n=$((n + 1))
  run --separate-stderr "$LOCAL" create-mr "$R" t /dev/null feat nobase
  [ "$status" -eq 1 ]; [ -z "$output" ]
  [ "${stderr##*$'\n'}" = "not a local branch: nobase" ]; n=$((n + 1))
  # An old git echoes the unknown option back: two lines, the first not a path.
  printf '#!/usr/bin/env bash\nfor a; do [ "$a" = --path-format=absolute ] && { echo "$a"; echo .git; exit 0; }; done\nexec git "$@"\n' > "$old"
  chmod +x "$old"
  DEVAGENT_GIT="$old" run --separate-stderr "$LOCAL" create-mr "$R" t /dev/null feat main
  [ "$status" -eq 1 ]; [ -z "$output" ]
  [ "${stderr##*$'\n'}" = "git 2.31 or newer is needed (rev-parse --path-format)" ]; n=$((n + 1))
  [ "$n" -eq 4 ]
  [ ! -e "$(_cdir "$R")/devagent" ]
}

# --- mr-state, mr-comments and the record reader (Task 4) --------------------

# _mk <repo> [branch]: create-mr for <branch> (default feat) onto main; REF is the reference.
_mk() {
  REF="$("$LOCAL" create-mr "$1" t /dev/null "${2:-feat}" main)"
}

# _state <ref>: mr-state's output, which must exit 0.
_state_is() {
  run --separate-stderr "$LOCAL" mr-state "$1"
  [ "$status" -eq 0 ] || { echo "mr-state: $status $stderr" >&2; return 1; }
  [ "$output" = "$2" ] || { echo "mr-state: $output, want $2" >&2; return 1; }
}

# _hand_rec <repo> <branch> <state> <head_sha>: write a D-rec record by hand.
_hand_rec() {
  local f; f="$(_rec "$1" "$2")"
  mkdir -p "${f%/*}"
  printf '%s\n' 'version: 1' "state: $3" "head: $2" 'base: main' "head_sha: $4" 'merge_commit: -' 'title: t' > "$f"
}

@test "local: mr-state is open after create-mr (AC 4)" {
  _mk "$R"
  _state_is "$REF" open
}

@test "local: mr-state is merged after git merge --no-ff, after a fast-forward, and for a stored merged record (AC 4)" {
  local n=0
  _mk "$R"
  git -C "$R" merge -q --no-ff -m m feat
  _state_is "$REF" merged; n=$((n + 1))
  local r2="$BATS_TEST_TMPDIR/r2"
  _mkrepo "$r2"; _mk "$r2"
  git -C "$r2" merge -q --ff-only feat
  _state_is "$REF" merged; n=$((n + 1))
  local r3="$BATS_TEST_TMPDIR/r3"
  _mkrepo "$r3"; _mk "$r3"
  _hand_rec "$r3" feat merged "$(git -C "$r3" rev-parse feat)"
  run git -C "$r3" merge-base --is-ancestor feat main
  [ "$status" -eq 1 ]
  _state_is "$REF" merged; n=$((n + 1))
  [ "$n" -eq 3 ]
}

@test "local: mr-state is closed once the head branch is deleted unmerged (AC 4)" {
  _mk "$R"
  git -C "$R" branch -q -D feat
  _state_is "$REF" closed
  [ -f "$(_rec "$R" feat)" ]
}

@test "local: mr-state stays open after git merge --squash" {
  _mk "$R"
  git -C "$R" merge -q --squash feat
  git -C "$R" commit -q --allow-empty -m squash
  _state_is "$REF" open
}

@test "local: mr-state reads closed after git merge --squash and branch -D" {
  _mk "$R"
  git -C "$R" merge -q --squash feat
  git -C "$R" commit -q --allow-empty -m squash
  git -C "$R" branch -q -D feat
  _state_is "$REF" closed
}

@test "local: a missing base branch reads as not merged" {
  _mk "$R"
  git -C "$R" checkout -q feat
  git -C "$R" branch -q -D main
  _state_is "$REF" open
  git -C "$R" checkout -q --detach
  git -C "$R" branch -q -D feat
  _state_is "$REF" closed
}

@test "local: a reference with no record exits 1 and names the record path (AC 4)" {
  local ref; ref="$(_ref "$R" feat)"
  run --separate-stderr "$LOCAL" mr-state "$ref"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  [ "${stderr##*$'\n'}" = "no local MR record at $(_rec "$R" feat)" ]
}

@test "local: malformed references exit 1" {
  local d n=0 ref
  d="$(python3 -c 'import sys,urllib.parse as u; print(u.quote(sys.argv[1], safe="~"))' "$(_cdir "$R")")"
  _mk "$R"
  for ref in "$d#feat" "local:$d" "local:$d#feat#x" "local:#feat" "local:$d#" \
             "local:$d#a%2fb" "local:$d#%ZZ" "local:$d#a%2" "local:$d#a%00" \
             "local:$d#%41" "local:$d#.." "local:$d#." \
             "local:.git#feat" "local:repo%2F.git#feat"; do
    run --separate-stderr "$LOCAL" mr-state "$ref"
    [ "$status" -eq 1 ] || { echo "$ref: $status" >&2; false; }
    [ -z "$output" ]
    [ "${stderr##*$'\n'}" = "not a local MR reference: $ref" ] || { echo "$ref: $stderr" >&2; false; }
    n=$((n + 1))
  done
  [ "$n" -eq 14 ]
}

@test "local: malformed records exit 5" {
  local f good n=0 sha
  _mk "$R"
  f="$(_rec "$R" feat)"; good="$(cat "$f")"
  sha="$(git -C "$R" rev-parse feat)"
  _bad() {
    printf '%s\n' "$@" > "$f"
    run --separate-stderr "$LOCAL" mr-state "$REF"
    [ "$status" -eq 5 ] || { echo "$*: $status $output" >&2; return 1; }
    [ -z "$output" ]
    [[ "${stderr##*$'\n'}" == "malformed local MR record at $f: "* ]]
    n=$((n + 1))
  }
  _bad 'version: 1' 'state: open' 'head: feat' 'base: main' "head_sha: $sha" 'merge_commit: -'                       # missing key
  _bad 'version: 1' 'state: open' 'head: feat' 'base: main' "head_sha: $sha" 'merge_commit: -' 'title: t' 'title: u'  # repeated
  _bad 'version: 1' 'state: open' 'head: feat' 'base: main' "head_sha: $sha" 'merge_commit: -' 'title: t' 'x: y'      # unknown key
  _bad 'version: 1' 'state: shut' 'head: feat' 'base: main' "head_sha: $sha" 'merge_commit: -' 'title: t'             # bad state
  _bad 'version: 1' 'state: open' 'head: feat' 'base: main' "head_sha: ${sha^^}" 'merge_commit: -' 'title: t'         # bad head_sha
  _bad 'version: 1' 'state: open' 'head: other' 'base: main' "head_sha: $sha" 'merge_commit: -' 'title: t'            # head unlike the file
  _bad 'version: 2' 'state: open' 'head: feat' 'base: main' "head_sha: $sha" 'merge_commit: -' 'title: t'             # version 2
  [ "$n" -eq 7 ]
  printf '%s\n' "$good" | sed 's/$/\r/' > "$f"
  _state_is "$REF" open
}

@test "local: a git failure is exit 1, never open or closed" {
  local shim="$BATS_TEST_TMPDIR/failgit"
  _mk "$R"
  printf '#!/usr/bin/env bash\nfor a; do [ "$a" = merge-base ] && exit 128; done\nexec git "$@"\n' > "$shim"
  chmod +x "$shim"
  DEVAGENT_GIT="$shim" run --separate-stderr "$LOCAL" mr-state "$REF"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  [ "${stderr##*$'\n'}" = "git could not answer for $(_cdir "$R") (exit 128)" ]
}

# _sums <git-dir>: a checksum listing of every file under <git-dir>.
_sums() { (cd "$1" && find . -type f -print0 | LC_ALL=C sort -z | xargs -0 sha256sum); }

@test "local: the read verbs leave the git dir byte-identical" {
  local g before ref n=0
  g="$(_cdir "$R")"
  ref="$(_ref "$R" feat)"
  before="$(_sums "$g")"
  for v in "mr-state $ref" "mr-comments $ref" "branch-exists $R feat" "merged-pr-head $R feat"; do
    read -r verb a b <<<"$v"
    if [ "$verb" = branch-exists ] || [ "$verb" = merged-pr-head ]; then
      run "$LOCAL" "$verb" "$R" feat
    else
      run "$LOCAL" "$verb" "$ref"
    fi
    n=$((n + 1))
  done
  [ ! -e "$g/devagent" ]
  [ "$(_sums "$g")" = "$before" ]
  _mk "$R"
  before="$(_sums "$g")"
  for verb in mr-state mr-comments; do run "$LOCAL" "$verb" "$REF"; n=$((n + 1)); done
  run "$LOCAL" branch-exists "$R" feat; run "$LOCAL" merged-pr-head "$R" feat; n=$((n + 2))
  [ "$(_sums "$g")" = "$before" ]
  [ "$n" -eq 8 ]
}

@test "local: mr-comments prints ## Comments (0)" {
  _mk "$R"
  run --separate-stderr "$LOCAL" mr-comments "$REF"
  [ "$status" -eq 0 ]
  [ "$output" = "## Comments (0)" ]
  rm -f "$(_rec "$R" feat)"
  run --separate-stderr "$LOCAL" mr-comments "$REF"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

# --- a second create-mr, merged-pr-head (Task 5) -----------------------------

@test "local: a second create-mr on an open record updates it (AC 5)" {
  _mk "$R"
  local first="$REF" f; f="$(_rec "$R" feat)"
  git -C "$R" branch dev main
  git -C "$R" checkout -q feat; git -C "$R" commit -q --allow-empty -m more; git -C "$R" checkout -q main
  run --separate-stderr "$LOCAL" create-mr "$R" "Second title" /dev/null feat dev
  [ "$status" -eq 0 ]
  [ "$output" = "$first" ]
  local want
  want="$(printf '%s\n' 'version: 1' 'state: open' 'head: feat' 'base: dev' \
    "head_sha: $(git -C "$R" rev-parse feat)" 'merge_commit: -' 'title: Second title')"
  [ "$(cat "$f")" = "$want" ]
}

@test "local: a second create-mr on a merged or closed record exits 1 and leaves it byte-identical (AC 5)" {
  local f n=0 sha
  _mk "$R"; f="$(_rec "$R" feat)"; sha="$(git -C "$R" rev-parse feat)"
  _refused() {
    cp "$f" "$BATS_TEST_TMPDIR/copy"
    run --separate-stderr "$LOCAL" create-mr "$R" t /dev/null feat main
    [ "$status" -eq 1 ] || { echo "status $status" >&2; return 1; }
    [ -z "$output" ]
    [ "${stderr##*$'\n'}" = "a merged or closed local MR exists for this branch; ship from a new branch" ]
    cmp "$f" "$BATS_TEST_TMPDIR/copy"
    n=$((n + 1))
  }
  _hand_rec "$R" feat merged "$sha"; _refused
  _hand_rec "$R" feat closed "$sha"; _refused
  _hand_rec "$R" feat open "$sha"
  git -C "$R" merge -q --no-ff -m m feat; _refused
  [ "$n" -eq 3 ]
}

@test "local: a second create-mr on a closed record whose head is gone gives the new-branch line" {
  _mk "$R"
  git -C "$R" branch -q -D feat
  run --separate-stderr "$LOCAL" create-mr "$R" t /dev/null feat main
  [ "$status" -eq 1 ]
  [ "${stderr##*$'\n'}" = "a merged or closed local MR exists for this branch; ship from a new branch" ]
}

@test "local: a second create-mr on an unreadable record exits 5 and leaves it byte-identical" {
  local f; _mk "$R"; f="$(_rec "$R" feat)"
  printf 'version: 2\n' > "$f"; cp "$f" "$BATS_TEST_TMPDIR/copy"
  run --separate-stderr "$LOCAL" create-mr "$R" t /dev/null feat main
  [ "$status" -eq 5 ]
  [ -z "$output" ]
  [[ "${stderr##*$'\n'}" == "malformed local MR record at $f: "* ]]
  cmp "$f" "$BATS_TEST_TMPDIR/copy"
}

@test "local: a failed record replace leaves the old record byte-identical" {
  local f bin="$BATS_TEST_TMPDIR/bin"; _mk "$R"; f="$(_rec "$R" feat)"
  cp "$f" "$BATS_TEST_TMPDIR/copy"
  mkdir -p "$bin"; printf '#!/usr/bin/env bash\nexit 1\n' > "$bin/mv"; chmod +x "$bin/mv"
  PATH="$bin:$PATH" run --separate-stderr "$LOCAL" create-mr "$R" other /dev/null feat main
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  [ "${stderr##*$'\n'}" = "cannot write the local MR record at $f" ]
  cmp "$f" "$BATS_TEST_TMPDIR/copy"
  [ "$(ls -A "${f%/*}")" = "${f##*/}" ]
}

@test "local: merged-pr-head answers 0, 1 and 2" {
  local sha n=0 plain="$BATS_TEST_TMPDIR/plain"
  _mhead() { run --separate-stderr "$LOCAL" merged-pr-head "$@"; [ -z "$output" ]; n=$((n + 1)); }
  _mhead "$R" feat; [ "$status" -eq 1 ]                       # no record
  _mk "$R"; sha="$(git -C "$R" rev-parse feat)"
  _mhead "$R" feat; [ "$status" -eq 1 ]                       # open
  _hand_rec "$R" feat merged "$sha"
  _mhead "$R" feat; [ "$status" -eq 0 ]                       # stored merged
  _hand_rec "$R" feat open "$sha"
  git -C "$R" merge -q --no-ff -m m feat
  _mhead "$R" feat; [ "$status" -eq 0 ]                       # merged by hand
  mkdir -p "$plain"
  _mhead "$plain" feat; [ "$status" -eq 2 ]                   # not a repository
  printf 'version: 2\n' > "$(_rec "$R" feat)"
  _mhead "$R" feat; [ "$status" -eq 2 ]                       # unreadable record: cannot tell
  [ "$n" -eq 6 ]
}

# --- a head rewritten after create-mr (review: Important 2) --------------------

@test "local: an amended head merged by hand reads open until create-mr runs again" {
  _mk "$R"
  git -C "$R" checkout -q feat
  git -C "$R" commit -q --amend --allow-empty -m "feat, amended"
  git -C "$R" checkout -q main
  git -C "$R" merge -q --no-ff -m m feat
  _state_is "$REF" open
  run --separate-stderr "$LOCAL" create-mr "$R" t /dev/null feat main
  [ "$status" -eq 0 ]
  _state_is "$REF" merged
}

@test "local: a rebased head fast-forwarded and deleted reads closed" {
  _mk "$R"
  git -C "$R" commit -q --allow-empty -m "main moves"
  git -C "$R" rebase -q main feat
  git -C "$R" checkout -q main
  git -C "$R" merge -q --ff-only feat
  _state_is "$REF" open
  git -C "$R" branch -q -d feat
  _state_is "$REF" closed
}
