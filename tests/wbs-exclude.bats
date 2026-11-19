#!/usr/bin/env bats
#
# #761: `wbs exclude [project] <issue-id>...` adds one `<!-- wbs-exclude: ... -->`
# line to WBS.md. It validates every id with no tracker call, writes nothing
# on any refusal, and proves the new line takes effect before writing. The
# backends here are tripwires: any call touches backend-called, and gh/glab/curl
# shims log to network.log; teardown asserts both absent.

. "$(dirname "$BATS_TEST_FILENAME")/lib/hermetic-env.bash"
bats_require_minimum_version 1.5.0   # run --separate-stderr

REPO="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
# stub issue backends + network shims (no real tracker call)
. "$(dirname "$BATS_TEST_FILENAME")/helpers/wbs-tracker.bash"
# #749: lock stubs (devdoc_lock_stub_holder)
. "$(dirname "$BATS_TEST_FILENAME")/helpers/devdoc-repo.bash"

BYTES="$REPO/tests/helpers/wbs_bytes.py"
L12='<!-- wbs-exclude: Issue-12 -->'
USAGE='usage: /devagent:wbs exclude [project] <issue-id>...'

setup() {
  TMPROOT="$(mktemp -d)"
  TMPDEV="$TMPROOT/devdoc"
  mkdir -p "$TMPDEV" "$TMPROOT/src"
  export TMPROOT
  export HOME="$TMPROOT/home"
  mkdir -p "$HOME/.claude/devagent/state" "$HOME/.claude/devagent/secrets"
  unset DEVAGENT_JIRA_PROJECT_KEY DEVAGENT_PROJECT
  _config github acme/testproj
  export DEVAGENT_ISSUE_BACKEND_DIR="$TMPROOT/backends"
  mkdir -p "$DEVAGENT_ISSUE_BACKEND_DIR"
  local b
  for b in github jira; do
    printf '#!/usr/bin/env bash\ntouch "%s/backend-called"\nexit 99\n' "$TMPROOT" \
      > "$DEVAGENT_ISSUE_BACKEND_DIR/$b.sh"
    chmod +x "$DEVAGENT_ISSUE_BACKEND_DIR/$b.sh"
  done
  wbs_tracker_install_shims "$TMPROOT/shims" "$TMPROOT/network.log"
  export PATH="$TMPROOT/shims:$PATH"
}

teardown() {
  [ ! -e "$TMPROOT/network.log" ]
  [ ! -e "$TMPROOT/backend-called" ]
  rm -rf "$TMPROOT"
}

# _config <backend> <repo> [noprefix]: testproj with one issue_source;
# noprefix omits its dir_prefix
_config() {
  {
    printf '%s\n' '[defaults]' 'checklist_template = "standard"' '' \
      '[project.testproj]' "source_dir = \"$TMPROOT/src\"" "devdoc_dir = \"$TMPDEV\"" '' \
      '[project.testproj.issue_source]' "backend = \"$1\"" "repo = \"$2\""
    [ "${3:-}" = noprefix ] || printf '%s\n' 'dir_prefix = "Issue-"'
  } > "$HOME/.claude/devagent/config.toml"
}

_ex() { run --separate-stderr bash "$REPO/scripts/wbs.sh" exclude testproj "$@"; }

# _only_inserts <old> <new>: rc 1 when diff's normal output has only `a`
# hunks (the filter keeps any other line), rc 0 otherwise
_only_inserts() {
  local rc=0
  diff "$1" "$2" > "$TMPROOT/hunks" || rc=$?
  [ "$rc" -eq 1 ] || return 2
  grep -vE '^([0-9]+a[0-9]+(,[0-9]+)?|> .*)$' "$TMPROOT/hunks"
}

# _block_end <file> <needle>: the 1-based last line of the block of the first
# node line holding <needle>, by wbs-parser.py's one block rule
_block_end() {
  python3 -c '
import importlib.util, sys
spec = importlib.util.spec_from_file_location("wbs_parser", sys.argv[1])
p = importlib.util.module_from_spec(spec)
spec.loader.exec_module(p)
lines = open(sys.argv[2], "rb").read().decode("utf-8").splitlines(keepends=True)
kinds, bodies, _u = p._classify_lines(lines)
i = next(i for i, (k, _m) in enumerate(kinds) if k == "node" and sys.argv[3] in bodies[i])
print(p._block_end(kinds, bodies, i) + 1)
' "$REPO/scripts/lib/wbs-parser.py" "$1" "$2"
}

# _refused <line>...: stderr is exactly these lines, each prefixed `wbs exclude: `
_refused() {
  local want="" l
  for l in "$@"; do want="${want:+$want$'\n'}wbs exclude: $l"; done
  [ "$stderr" = "$want" ] || { printf 'want:\n%s\ngot:\n%s\n' "$want" "$stderr"; false; }
}

_t1_base() {
  printf '%s\n' '# testproj WBS' '' '```text' '<!-- wbs-exclude: Issue-13 -->' '```' '' \
    '<!-- wbs-exclude: Issue-40 -->' '<!-- WBS-Exclude: Issue-7 -->' \
    '- [ ] Leaf {issue: Issue-3}' '' 'Last prose line.' > "$TMPROOT/t1.md"
}

@test "exclude inserts one line after the last exclusion line on LF, CRLF and no-final-newline bases (#761)" {
  local kind eol rc
  _t1_base
  for kind in lf crlf lf-nofinal crlf-nofinal; do
    python3 "$BYTES" variant "$TMPROOT/t1.md" "$kind" "$TMPDEV/WBS.md"
    cp "$TMPDEV/WBS.md" "$TMPROOT/old"
    eol=lf; [[ "$kind" == crlf* ]] && eol=crlf
    python3 "$BYTES" insert-after "$TMPROOT/old" "$TMPROOT/want" \
      '<!-- wbs-exclude: Issue-40 -->' "$eol" "$L12"
    _ex Issue-12
    [ "$status" -eq 0 ] || { echo "$kind: $stderr"; false; }
    [ "$stderr" = "wbs exclude: excluded Issue-12 in $TMPDEV/WBS.md" ]
    [ -z "$output" ]
    cmp "$TMPROOT/want" "$TMPDEV/WBS.md"
    [ "$(grep -c '' "$TMPDEV/WBS.md")" -eq "$(( $(grep -c '' "$TMPROOT/old") + 1 ))" ]
    rc=0; _only_inserts "$TMPROOT/old" "$TMPDEV/WBS.md" || rc=$?
    [ "$rc" -eq 1 ] || { echo "$kind: not inserts only"; cat "$TMPROOT/hunks"; false; }
  done
  # control: a changed line is a `c` hunk, which the filter keeps
  sed 's/^Last prose line\./Last prose line!/' "$TMPDEV/WBS.md" > "$TMPROOT/changed"
  rc=0; _only_inserts "$TMPROOT/old" "$TMPROOT/changed" >/dev/null || rc=$?
  [ "$rc" -eq 0 ]
}

@test "exclude appends at column 0 at the end when no exclusion line exists, keeping the final-newline state (#761)" {
  local kind eol rc
  printf '%s\n' '# testproj WBS' '' '- [ ] Epic {issue: Issue-1}' '  - [ ] Task {issue: Issue-2}' \
    '  Note under Epic.' > "$TMPROOT/t2.md"
  for kind in lf crlf lf-nofinal crlf-nofinal; do
    python3 "$BYTES" variant "$TMPROOT/t2.md" "$kind" "$TMPDEV/WBS.md"
    cp "$TMPDEV/WBS.md" "$TMPROOT/old"
    eol=lf; [[ "$kind" == crlf* ]] && eol=crlf
    python3 "$BYTES" append "$TMPROOT/old" "$TMPROOT/want" "$eol" "$L12"
    _ex Issue-12
    [ "$status" -eq 0 ] || { echo "$kind: $stderr"; false; }
    [ "$stderr" = "wbs exclude: excluded Issue-12 in $TMPDEV/WBS.md" ]
    cmp "$TMPROOT/want" "$TMPDEV/WBS.md"
    [ "$(grep -c '' "$TMPDEV/WBS.md")" -eq "$(( $(grep -c '' "$TMPROOT/old") + 1 ))" ]
    if [[ "$kind" == *-nofinal ]]; then
      # #701's exception: the old last line gains the EOL, so old is a byte prefix of new
      cmp -n "$(wc -c < "$TMPROOT/old")" "$TMPROOT/old" "$TMPDEV/WBS.md"
    else
      rc=0; _only_inserts "$TMPROOT/old" "$TMPDEV/WBS.md" || rc=$?
      [ "$rc" -eq 1 ] || { echo "$kind: not inserts only"; cat "$TMPROOT/hunks"; false; }
    fi
    [ "$(_block_end "$TMPDEV/WBS.md" Epic)" = "$(_block_end "$TMPROOT/old" Epic)" ]
  done
}

@test "an indented exclusion line is followed with its indentation and its node's block keeps it (#761)" {
  printf '%s\n' '- [ ] Epic {issue: Issue-1}' '  - [ ] Task {issue: Issue-2}' \
    '  <!-- wbs-exclude: Issue-40 -->' '  Note under Epic.' '- [ ] Next {issue: Issue-3}' \
    > "$TMPDEV/WBS.md"
  cp "$TMPDEV/WBS.md" "$TMPROOT/old"
  python3 "$BYTES" insert-after "$TMPROOT/old" "$TMPROOT/want" \
    '<!-- wbs-exclude: Issue-40 -->' lf "  $L12"
  _ex Issue-12
  [ "$status" -eq 0 ] || { echo "$stderr"; false; }
  cmp "$TMPROOT/want" "$TMPDEV/WBS.md"
  [ "$(_block_end "$TMPROOT/old" Epic)" = 4 ]
  [ "$(_block_end "$TMPDEV/WBS.md" Epic)" = 5 ]
  [ "$(sed -n 6p "$TMPDEV/WBS.md")" = '- [ ] Next {issue: Issue-3}' ]
  # planted control: a column-0 copy would end Epic's block at the anchor line
  python3 "$BYTES" insert-after "$TMPROOT/old" "$TMPROOT/col0" \
    '<!-- wbs-exclude: Issue-40 -->' lf "$L12"
  [ "$(_block_end "$TMPROOT/col0" Epic)" = 3 ]
}

@test "a second run writes nothing and says nothing to exclude; a repeated id is written once (#761)" {
  printf '%s\n' '# testproj WBS' '' 'Some prose.' > "$TMPROOT/base"
  cp "$TMPROOT/base" "$TMPDEV/WBS.md"
  _ex Issue-12
  [ "$status" -eq 0 ] || { echo "$stderr"; false; }
  cp "$TMPDEV/WBS.md" "$TMPROOT/first"
  _ex Issue-12
  [ "$status" -eq 0 ]
  _refused 'nothing to exclude; Issue-12 already listed'
  cmp "$TMPROOT/first" "$TMPDEV/WBS.md"
  # a repeated id: one line, one id
  cp "$TMPROOT/base" "$TMPDEV/WBS.md"
  _ex Issue-12 Issue-12
  [ "$status" -eq 0 ]
  _refused "excluded Issue-12 in $TMPDEV/WBS.md"
  cmp "$TMPROOT/first" "$TMPDEV/WBS.md"
  # a listed id beside a new one: only the new one is written
  _ex Issue-12 Issue-41
  [ "$status" -eq 0 ]
  _refused "excluded Issue-41 in $TMPDEV/WBS.md; Issue-12 already listed"
  printf '%s\n' "$L12" '<!-- wbs-exclude: Issue-41 -->' > "$TMPROOT/tail"
  cat "$TMPROOT/base" "$TMPROOT/tail" | cmp - "$TMPDEV/WBS.md"
}

@test "on a Jira base, Issue-PROJ-12 already lists Issue-12 (#761)" {
  _config jira PROJ
  printf '%s\n' '# testproj WBS' '' '<!-- wbs-exclude: Issue-PROJ-12 -->' > "$TMPDEV/WBS.md"
  cp "$TMPDEV/WBS.md" "$TMPROOT/old"
  _ex Issue-12
  [ "$status" -eq 0 ] || { echo "$stderr"; false; }
  _refused 'nothing to exclude; Issue-12 already listed'
  cmp "$TMPROOT/old" "$TMPDEV/WBS.md"
  # control: another key is written
  _ex Issue-13
  [ "$status" -eq 0 ]
  _refused "excluded Issue-13 in $TMPDEV/WBS.md"
  [ "$(tail -n 1 "$TMPDEV/WBS.md")" = '<!-- wbs-exclude: Issue-13 -->' ]
}

@test "bad ids exit 2 and leave WBS.md byte-identical (#761)" {
  printf '%s\n' '# testproj WBS' '' '<!-- wbs-exclude: Issue-40 -->' > "$TMPDEV/WBS.md"
  cp "$TMPDEV/WBS.md" "$TMPROOT/old"
  local id
  for id in 'Issue 12' 'Issue-1,Issue-2' 'Issue-x-->'; do
    _ex "$id"
    [ "$status" -eq 2 ]
    _refused "'$id' is not an issue id" 'nothing written'
    cmp "$TMPROOT/old" "$TMPDEV/WBS.md"
  done
  _ex $'Issue-1\nIssue-2'
  [ "$status" -eq 2 ]
  _refused "'Issue-1\\nIssue-2' is not an issue id" 'nothing written'
  cmp "$TMPROOT/old" "$TMPDEV/WBS.md"
  _ex Foo-12
  [ "$status" -eq 2 ]
  _refused "'Foo-12' names no configured issue source" 'nothing written'
  cmp "$TMPROOT/old" "$TMPDEV/WBS.md"
  # a valid id beside a bad one: neither is written
  _ex Issue-12 'Issue 13'
  [ "$status" -eq 2 ]
  _refused "'Issue 13' is not an issue id" 'nothing written'
  cmp "$TMPROOT/old" "$TMPDEV/WBS.md"
  # no ids, and the flags: usage errors
  _ex
  [ "$status" -eq 2 ]
  [ "$stderr" = "wbs exclude: no issue id given"$'\n'"$USAGE" ]
  _ex --bogus
  [ "$status" -eq 2 ]
  [ "$stderr" = "wbs exclude: unknown flag '--bogus'"$'\n'"$USAGE" ]
  _ex --
  [ "$status" -eq 2 ]
  [ "$stderr" = "wbs exclude: unknown flag '--'"$'\n'"$USAGE" ]
  cmp "$TMPROOT/old" "$TMPDEV/WBS.md"
  # a config gap is not a bad id
  _config github acme/testproj noprefix
  _ex Issue-12
  [ "$status" -eq 2 ]
  _refused 'no issue source of testproj has backend, repo and dir_prefix set' 'nothing written'
  cmp "$TMPROOT/old" "$TMPDEV/WBS.md"
}

@test "#749: a held lock exits 1 with nothing written, and a bad id still exits 2 (#761)" {
  printf '%s\n' '# testproj WBS' '' 'Some prose.' > "$TMPDEV/WBS.md"
  cp "$TMPDEV/WBS.md" "$TMPROOT/old"
  local lp
  lp="$(devdoc_lock_stub_holder "$TMPDEV" Issue-5)"
  export DEVAGENT_DEVDOC_LOCK_TIMEOUT=1
  _ex Issue-12
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"devdoc lock $lp is held"* ]]
  cmp "$TMPROOT/old" "$TMPDEV/WBS.md"
  # validation runs before the lock: no wait, exit 2
  _ex 'Issue 12'
  [ "$status" -eq 2 ]
  _refused "'Issue 12' is not an issue id" 'nothing written'
  [[ "$stderr" != *"waiting for devdoc lock"* ]]
  rm -f "$lp/holder" && rmdir "$lp"
  _ex Issue-12
  [ "$status" -eq 0 ] || { echo "$stderr"; false; }
  [ ! -e "$lp" ]
  [ "$(tail -n 1 "$TMPDEV/WBS.md")" = "$L12" ]
}

@test "a failed write under the lock exits 1, keeps the bytes and frees the lock (#761)" {
  printf '%s\n' '# testproj WBS' '' 'Some prose.' > "$TMPDEV/WBS.md"
  cp "$TMPDEV/WBS.md" "$TMPROOT/old"
  export DEVAGENT_TEST_WBS_REPLACE_FAILS=20 DEVAGENT_DEVDOC_LOCK_TIMEOUT=1
  _ex Issue-12
  [ "$status" -eq 1 ]
  [[ "$stderr" == "wbs exclude: cannot write $TMPDEV/WBS.md: "* ]] || { echo "$stderr"; false; }
  cmp "$TMPROOT/old" "$TMPDEV/WBS.md"
  [ "$(ls -A "$TMPDEV")" = WBS.md ]
  # the EXIT trap freed the lock: a leaked one would fail this run within 1 s
  unset DEVAGENT_TEST_WBS_REPLACE_FAILS
  _ex Issue-12
  [ "$status" -eq 0 ] || { echo "$stderr"; false; }
  [ "$(tail -n 1 "$TMPDEV/WBS.md")" = "$L12" ]
}

@test "a missing WBS.md exits 1 and creates nothing (#761)" {
  _ex Issue-12
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"wbs exclude: $TMPDEV/WBS.md missing"* ]]
  [ -z "$(ls -A "$TMPDEV")" ]
}

# _readme_names_exclude <readme>: the README's `wbs` row names `exclude`
_readme_names_exclude() { grep -E '^\| `wbs` \|' "$1" | grep -qF '`exclude`'; }

@test "docs: every wbs exclude home names it (#761)" {
  local cmd="$REPO/commands/wbs.md" spec="$REPO/docs/specs/2026-05-19-devagent-plugin-design.md"
  grep -qE '^description: .*exclude' "$cmd"
  grep -qE '^argument-hint: .*exclude' "$cmd"
  grep -qE '^- `exclude ' "$cmd"
  grep -F 'To keep a deliberately deleted issue out' "$cmd" | grep -qF '`exclude'
  sed -n '/^### 13\.2 /,/^### 13\.3 /p' "$spec" | grep -qF '/devagent:wbs exclude'
  sed -n '/^A directive is/,/^$/p' "$spec" | grep -qF 'wbs exclude'
  _readme_names_exclude "$REPO/README.md"
  grep -qF 'wbs exclude' "$REPO/changelog.d/761.md"
  # planted control: a README copy without the token fails the same predicate
  sed 's/ \/ `exclude`//' "$REPO/README.md" > "$TMPROOT/README.md"
  run cmp -s "$REPO/README.md" "$TMPROOT/README.md"
  [ "$status" -ne 0 ]
  run _readme_names_exclude "$TMPROOT/README.md"
  [ "$status" -ne 0 ]
}

@test "wbs usage names exclude (#761)" {
  run --separate-stderr bash "$REPO/scripts/wbs.sh"
  [ "$status" -eq 2 ]
  grep -qxF 'usage: /devagent:wbs <init|update|order|exclude|show> [project] [args]' <<< "$stderr"
  grep -q '^  exclude <issue-id>\.\.\. ' <<< "$stderr"
}
