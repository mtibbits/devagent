#!/usr/bin/env bats
# tests/disk-issue.bats — #1008: the disk issue file format reader and writer
# (scripts/lib/disk-issue.py) and its reference page (docs/disk-issues.md).
bats_require_minimum_version 1.5.0   # run --separate-stderr wherever stdout or stderr is pinned

load 'lib/bats-helpers'

FIX="$BATS_TEST_DIRNAME/fixtures/disk-issue"

setup() {
  DI="$PLUGIN_ROOT/scripts/lib/disk-issue.py"
  INJ="$PLUGIN_ROOT/tests/helpers/disk_issue_inject.py"
  W="$BATS_TEST_TMPDIR/w"
  mkdir -p "$W"
}

# Git Bash on NTFS has no POSIX modes and no flock: chmod is a silent no-op there.
skip_on_git_bash() {
  case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*) skip "$1 (Git Bash: no POSIX file modes or flock)" ;;
  esac
}

di() { python3 "$DI" "$@"; }

# py_mod <code> [args...] — run python with the module loaded as `di`.
py_mod() {
  local code="$1"; shift
  python3 - "$DI" "$@" <<PY
import importlib.util, json, sys
spec = importlib.util.spec_from_file_location("disk_issue", sys.argv[1])
di = importlib.util.module_from_spec(spec); sys.modules["disk_issue"] = di
spec.loader.exec_module(di)
args = sys.argv[2:]
$code
PY
}

# crlf <src> <dst> — an every-line-CRLF copy; bom <src> <dst> — a BOM-prefixed copy.
crlf() { python3 -c 'import sys; d=open(sys.argv[1],"rb").read(); open(sys.argv[2],"wb").write(d.replace(b"\r\n",b"\n").replace(b"\n",b"\r\n"))' "$1" "$2"; }
bom() { { printf '\xef\xbb\xbf'; cat "$1"; } > "$2"; }

# jq-free JSON field read: json_get <json> <python-expression over `o`>
json_get() { python3 -c 'import json,sys; o=json.loads(sys.argv[1]); print(json.dumps(eval(sys.argv[2]), ensure_ascii=False))' "$1" "$2"; }

# ---------------------------------------------------------------- Task 1: CLI grammar

@test "di: no arguments prints usage" {
  run --separate-stderr di
  [ "$status" -eq 2 ]
  [[ "$stderr" == *"usage: disk-issue.py parse"* ]]
}

@test "di: unknown verb" {
  run --separate-stderr di frob x
  [ "$status" -eq 2 ]
  [[ "$stderr" == *'unknown verb "frob"'* ]]
}

@test "di: set unknown option" {
  cp "$FIX/full.md" "$W/1.md"
  run --separate-stderr di set "$W/1.md" status=Done --force
  [ "$status" -eq 2 ]
  [[ "$stderr" == *'unknown option "--force"'* ]]
  run --separate-stderr di set "$W/1.md" --comment=x
  [ "$status" -eq 2 ]
  [[ "$stderr" == *'unknown option "--comment=x"'* ]]
}

@test "di: set empty key=" {
  cp "$FIX/full.md" "$W/1.md"
  run --separate-stderr di set "$W/1.md" status=
  [ "$status" -eq 2 ]
  [[ "$stderr" == *'empty value for "status"'* ]]
  run --separate-stderr di set "$W/1.md" "status=  "
  [ "$status" -eq 2 ]
  [[ "$stderr" == *'empty value for "status"'* ]]
}

@test "di: set unknown key" {
  cp "$FIX/full.md" "$W/1.md"
  run --separate-stderr di set "$W/1.md" owner=me
  [ "$status" -eq 2 ]
  [[ "$stderr" == *'unknown key "owner"'* ]]
  run --separate-stderr di set "$W/1.md" --unset owner
  [ "$status" -eq 2 ]
  [[ "$stderr" == *'unknown key "owner"'* ]]
}

@test "di: set same key twice" {
  cp "$FIX/full.md" "$W/1.md"
  run --separate-stderr di set "$W/1.md" status=a status=b
  [ "$status" -eq 2 ]
  [[ "$stderr" == *'"status" given twice'* ]]
}

@test "di: set key both set and unset" {
  cp "$FIX/full.md" "$W/1.md"
  run --separate-stderr di set "$W/1.md" status=a --unset status
  [ "$status" -eq 2 ]
  [[ "$stderr" == *'"status" is both set and unset'* ]]
}

@test "di: --date without --comment" {
  cp "$FIX/full.md" "$W/1.md"
  run --separate-stderr di set "$W/1.md" status=a --date 2026-11-10
  [ "$status" -eq 2 ]
  [[ "$stderr" == *"--date needs --comment"* ]]
}

@test "di: set with no change" {
  cp "$FIX/full.md" "$W/1.md"
  run --separate-stderr di set "$W/1.md"
  [ "$status" -eq 2 ]
  [[ "$stderr" == *"nothing to change"* ]]
}

@test "di: --comment and --date at most once; their argument is taken verbatim" {
  cp "$FIX/full.md" "$W/1.md"
  run --separate-stderr di set "$W/1.md" --comment a --comment b
  [ "$status" -eq 2 ]
  [[ "$stderr" == *'"--comment" given twice'* ]]
  run --separate-stderr di set "$W/1.md" --comment a --date 2026-11-10 --date 2026-11-11
  [ "$status" -eq 2 ]
  [[ "$stderr" == *'"--date" given twice'* ]]
  run --separate-stderr di set "$W/1.md" --comment
  [ "$status" -eq 2 ]
  [[ "$stderr" == *"--comment needs a value"* ]]
}

@test "di: file name not <N>.md" {
  printf '# T\n' > "$W/x.md"
  printf '# T\n' > "$W/0.md"
  run --separate-stderr di parse "$W/x.md"
  [ "$status" -eq 2 ]
  [[ "$stderr" == *"file name must be <N>.md"* ]]
  run --separate-stderr di check "$W/0.md"
  [ "$status" -eq 2 ]
  [[ "$stderr" == *"file name must be <N>.md"* ]]
  run --separate-stderr di set "$W/0.md" status=a
  [ "$status" -eq 2 ]
  [[ "$stderr" == *"file name must be <N>.md"* ]]
}

# ---------------------------------------------------------------- Task 2: reader, parse, check

HINT='; if this line is prose, put a blank line above it'

@test "di: lines round-trip byte for byte" {
  run py_mod '
cases = [b"# T\r\nstate: closed\r\n", b"\xef\xbb\xbf# T\nx\n", b"# T\nno final newline",
         b"# T\na\rb\n", b"# T\nform\x0cfeed\n", "# T\nsep x\n".encode()]
for d in cases:
    assert b"".join(di._lines(d)) == d, d
print("ok", len(cases))'
  [ "$status" -eq 0 ]
  [ "$output" = "ok 6" ]
}

@test "di: no title line" {
  : > "$W/1.md"
  printf '\n  \n\t\n' > "$W/2.md"
  run --separate-stderr di check "$W/1.md"
  [ "$status" -eq 4 ]
  [ "$output" = "$W/1.md:1: no title line" ]
  run --separate-stderr di check "$W/2.md"
  [ "$status" -eq 4 ]
  [ "$output" = "$W/2.md:1: no title line" ]
}

@test "di: title drops a BOM and \"# \"" {
  bom "$FIX/full.md" "$W/1.md"
  run --separate-stderr di parse "$W/1.md"
  [ "$status" -eq 0 ]
  [ "$(json_get "$output" 'o["title"]')" = '"Add a dark-mode toggle to the settings page"' ]
}

@test "di: a BOM on its own line before the title is valid" {
  printf '\xef\xbb\xbf\n# T\n' > "$W/1.md"
  run --separate-stderr di parse "$W/1.md"
  [ "$status" -eq 0 ]
  [ "$(json_get "$output" 'o["title"]')" = '"T"' ]
}

@test "di: status: broken directly under the title is a header" {
  printf 'T\nstatus: broken since Tuesday\n\nprose\n' > "$W/1.md"
  run --separate-stderr di parse "$W/1.md"
  [ "$status" -eq 0 ]
  [ "$(json_get "$output" 'o["keys"]')" = '{"state": "open", "status": "broken since Tuesday"}' ]
  [ "$(json_get "$output" 'o["prompt"]')" = '"prose"' ]
}

@test "di: a repeated status: fails check with that line's number" {
  printf '# T\nstatus: a\nstatus: b\n' > "$W/1.md"
  run --separate-stderr di check "$W/1.md"
  [ "$status" -eq 4 ]
  [ "$output" = "$W/1.md:3: duplicate key \"status\" (first at line 2)" ]
}

@test "di: state: maybe and state: Closed fail check" {
  printf 'T\nstate: maybe\n' > "$W/1.md"
  printf 'T\nstate: Closed\n' > "$W/2.md"
  run --separate-stderr di check "$W/1.md" "$W/2.md"
  [ "$status" -eq 4 ]
  [ "${lines[0]}" = "$W/1.md:2: state must be \"open\" or \"closed\", got \"maybe\"$HINT" ]
  [ "${lines[1]}" = "$W/2.md:2: state must be \"open\" or \"closed\", got \"Closed\"$HINT" ]
  [ "${#lines[@]}" -eq 2 ]
}

@test "di: state: the form loses state under the title fails with the blank-line hint" {
  printf 'Fix the form\nstate: the form loses state\n' > "$W/1.md"
  run --separate-stderr di check "$W/1.md"
  [ "$status" -eq 4 ]
  [[ "$output" == "$W/1.md:2: state must be"*"put a blank line above it" ]]
}

@test "di: a bad header value below the first header line has no blank-line hint" {
  printf '# T\nstatus: x\nstate: maybe\n' > "$W/1.md"
  run --separate-stderr di check "$W/1.md"
  [ "$status" -eq 4 ]
  [ "$output" = "$W/1.md:3: state must be \"open\" or \"closed\", got \"maybe\"" ]
}

@test "di: state: closed after a blank line warns" {
  printf '# T\n\nstate: closed\n' > "$W/1.md"
  run --separate-stderr di check "$W/1.md"
  [ "$status" -eq 0 ]
  [ "$output" = "$W/1.md:3: warning: \"state: closed\" is read as prose because a blank line is above it; delete the blank line if it is a header line" ]
}

@test "di: later status: green on CI never warns" {
  printf '# T\n\nThe build.\nstatus: green on CI\n' > "$W/1.md"
  run --separate-stderr di check "$W/1.md"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "di: text above ## Prompt fails check" {
  printf '# T\n\nstray\n\n## Prompt\nbody\n' > "$W/1.md"
  run --separate-stderr di check "$W/1.md"
  [ "$status" -eq 4 ]
  [ "$output" = "$W/1.md:3: text between the header and ## Prompt" ]
}

@test "di: a second ## Prompt fails check" {
  printf '# T\n\n## Prompt\nbody\n## Prompt  \nmore\n' > "$W/1.md"
  run --separate-stderr di check "$W/1.md"
  [ "$status" -eq 4 ]
  [ "$output" = "$W/1.md:5: second ## Prompt (first at line 3)" ]
}

@test "di: key values normalise" {
  printf '# T\nparent: #3\nlabels: a , b\ngithub: o/n#7\n' > "$W/1.md"
  run --separate-stderr di parse "$W/1.md"
  [ "$status" -eq 0 ]
  [ "$(json_get "$output" 'o["keys"]')" = '{"state": "open", "parent": 3, "labels": ["a", "b"], "github": "o/n#7"}' ]
}

@test "di: bad values fail" {
  printf '# T\nstatus:\n' > "$W/1.md"
  printf '# T\nparent: 0\n' > "$W/2.md"
  printf '# T\nparent: 1234567890123456789\n' > "$W/3.md"
  printf '# T\nlabels: a,,b\n' > "$W/4.md"
  printf '# T\ngithub: x#1\n' > "$W/5.md"
  run --separate-stderr di check "$W/1.md" "$W/2.md" "$W/3.md" "$W/4.md" "$W/5.md"
  [ "$status" -eq 4 ]
  [ "${lines[0]}" = "$W/1.md:2: empty value for \"status\"$HINT" ]
  [ "${lines[1]}" = "$W/2.md:2: parent must be an issue number such as 3 or #3, got \"0\"$HINT" ]
  [ "${lines[2]}" = "$W/3.md:2: parent must be an issue number such as 3 or #3, got \"1234567890123456789\"$HINT" ]
  [ "${lines[3]}" = "$W/4.md:2: labels must be a comma-separated list with no empty label, got \"a,,b\"$HINT" ]
  [ "${lines[4]}" = "$W/5.md:2: github must be owner/name#N, got \"x#1\"$HINT" ]
  [ "${#lines[@]}" -eq 5 ]
}

@test "di: invalid UTF-8 is a fault" {
  printf '# T\n\nok\nbad \xff byte\n' > "$W/1.md"
  run --separate-stderr di check "$W/1.md"
  [ "$status" -eq 4 ]
  [ "$output" = "$W/1.md:4: not valid UTF-8" ]
}

@test "di: 1234567890123456789.md is a fault" {
  printf '# T\n' > "$W/1234567890123456789.md"
  run --separate-stderr di check "$W/1234567890123456789.md"
  [ "$status" -eq 4 ]
  [ "$output" = "$W/1234567890123456789.md:1: issue number has more than 18 digits" ]
}

@test "di: parse on an unreadable file prints to stderr only and exits 1" {
  run --separate-stderr di parse "$W/9.md"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  [[ "$stderr" == "$W/9.md: cannot read: "* ]]
}

@test "di: parse on a faulty file prints the faults line and exits 4" {
  printf '# T\nstatus: a\nstatus: b\n' > "$W/1.md"
  run --separate-stderr di parse "$W/1.md"
  [ "$status" -eq 4 ]
  [ "$output" = '{"n":1,"faults":[{"line":3,"message":"duplicate key \"status\" (first at line 2)"}],"warnings":[]}' ]
}

# ---------------------------------------------------------------- Task 3: code fences

@test "di: a ## Workflow flags block is prompt text, unchanged" {
  printf '# T\n\n## Prompt\nIntro\n\n## Workflow flags\n- skip: research\n' > "$W/1.md"
  run --separate-stderr di parse "$W/1.md"
  [ "$status" -eq 0 ]
  [ "$(json_get "$output" 'o["prompt"]')" = '"Intro\n\n## Workflow flags\n- skip: research"' ]
}

@test "di: ## Comments inside a backtick fence is prompt text" {
  printf '# T\n\n## Prompt\n```text\n## Comments\n- 2026-11-10 x\n```\nafter\n' > "$W/1.md"
  run --separate-stderr di parse "$W/1.md"
  [ "$status" -eq 0 ]
  [ "$(json_get "$output" 'o["comments"]')" = '[]' ]
  [ "$(json_get "$output" 'o["prompt"]')" = '"```text\n## Comments\n- 2026-11-10 x\n```\nafter"' ]
}

@test "di: ## Comments inside a tilde fence is prompt text" {
  printf '# T\n\n## Prompt\n~~~\n## Comments\n~~~\n' > "$W/1.md"
  run --separate-stderr di parse "$W/1.md"
  [ "$status" -eq 0 ]
  [ "$(json_get "$output" 'o["comments"]')" = '[]' ]
  [ "$(json_get "$output" 'o["prompt"]')" = '"~~~\n## Comments\n~~~"' ]
}

@test "di: ## Comments after an unclosed opener starts the comments section" {
  printf '# T\n\n## Prompt\n```\nx\n\n## Comments\n- 2026-11-10 entry\n' > "$W/1.md"
  run --separate-stderr di parse "$W/1.md"
  [ "$status" -eq 0 ]
  [ "$(json_get "$output" 'o["prompt"]')" = '"```\nx"' ]
  [ "$(json_get "$output" 'o["comments"]')" = '[{"date": "2026-11-10", "text": "entry", "line": 8}]' ]
}

@test "di: ## Prompt inside a fence is not a second ## Prompt" {
  printf '# T\n\n## Prompt\n````\n## Prompt\n````\n' > "$W/1.md"
  run --separate-stderr di check "$W/1.md"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "di: fence predicate edges" {
  run py_mod '
def code(text):
    b = text.split("\n")
    return [i for i, c in enumerate(di.classify_fences(b, 0)[0]) if c]
assert code("```a`b\nx\n```") == [], code("```a`b\nx\n```")        # backtick in info: not an opener
assert code("```\nx\n~~~\ny") == []                                  # ~~~ does not close ```
assert code("````\nx\n```\ny") == []                                 # shorter run does not close
assert code("````\nx\n`````\ny") == [0, 1, 2]                        # a longer run closes
assert code("  ```\nx\n\t```  \ny") == [0, 1, 2]                     # indented opener and closer
assert code("```\nx\n```py\n```") == [0, 1, 2, 3]                    # a closer has no info
print("ok")'
  [ "$status" -eq 0 ]
  [ "$output" = "ok" ]
}

@test "di: 1000 unclosed openers pass, 1001 fail" {
  { printf '# T\n'; for i in $(seq 1000); do printf '```py\n'; done; } > "$W/1.md"
  { cat "$W/1.md"; printf '```py\n'; } > "$W/2.md"
  run --separate-stderr di check "$W/1.md"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  run --separate-stderr di check "$W/2.md"
  [ "$status" -eq 4 ]
  [ "$output" = "$W/2.md:1002: more than 1000 unclosed code fence openers (1001 found)" ]
}

@test "di: a closer indented under ## Comments does not close a prompt fence" {
  printf '# T\n\n## Prompt\n```\nx\n\n## Comments\n- 2026-11-10 see\n  ```\n' > "$W/1.md"
  run --separate-stderr di parse "$W/1.md"
  [ "$status" -eq 0 ]
  [ "$(json_get "$output" 'o["prompt"]')" = '"```\nx"' ]
  [ "$(json_get "$output" 'o["comments"]')" = '[{"date": "2026-11-10", "text": "see\n```", "line": 8}]' ]
}

@test "di: a column-0 closer after a fenced ## Comments still pairs" {
  printf '# T\n\n## Prompt\n```text\n## Comments\n- 2026-11-10 x\n```\n' > "$W/1.md"
  run --separate-stderr di parse "$W/1.md"
  [ "$status" -eq 0 ]
  [ "$(json_get "$output" 'o["comments"]')" = '[]' ]
  [ "$(json_get "$output" 'o["prompt"]')" = '"```text\n## Comments\n- 2026-11-10 x\n```"' ]
}

# ---------------------------------------------------------------- Task 4: comments section

@test "di: the two example files parse to the same title and prompt" {
  cp "$FIX/minimal.md" "$W/1.md"
  cp "$FIX/full.md" "$W/2.md"
  run --separate-stderr di parse "$W/1.md"
  [ "$status" -eq 0 ]
  local min="$output"
  run --separate-stderr di parse "$W/2.md"
  [ "$status" -eq 0 ]
  local full="$output"
  [ "$(json_get "$min" 'o["title"]')" = "$(json_get "$full" 'o["title"]')" ]
  [ "$(json_get "$min" 'o["prompt"]')" = "$(json_get "$full" 'o["prompt"]')" ]
  [ "$(json_get "$min" 'o["prompt"]')" = '"The settings page should have a switch that flips the site between light and dark.\nDone when the choice survives a page reload."' ]
  [ "$(json_get "$min" 'o["keys"]')" = '{"state": "open"}' ]
  [ "$(json_get "$min" 'o["comments"]')" = '[]' ]
  [ "$(json_get "$full" 'o["keys"]')" = '{"state": "closed", "status": "Done", "parent": 3}' ]
  [ "$(json_get "$full" 'o["comments"]')" = '[{"date": "2026-11-10", "text": "on_draft_start: status In Progress", "line": 11}, {"date": "2026-11-10", "text": "on_ship: status In Review", "line": 12}, {"date": "2026-11-11", "text": "on_merge: status Done, closed", "line": 13}]' ]
}

@test "di: check passes both example files" {
  cp "$FIX/minimal.md" "$W/1.md"
  cp "$FIX/full.md" "$W/2.md"
  run --separate-stderr di check "$W/1.md" "$W/2.md"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "di: blank lines between entries are allowed" {
  printf '# T\n\n## Comments\n- 2026-11-10 a\n\n\n- 2026-11-11 b\n  more\n\n  para\n\n' > "$W/1.md"
  run --separate-stderr di parse "$W/1.md"
  [ "$status" -eq 0 ]
  [ "$(json_get "$output" 'o["comments"]')" = '[{"date": "2026-11-10", "text": "a", "line": 4}, {"date": "2026-11-11", "text": "b\nmore\n\npara", "line": 7}]' ]
}

@test "di: a second ## Comments fails check" {
  printf '# T\n\n## Comments\n- 2026-11-10 a\n## Comments\n' > "$W/1.md"
  run --separate-stderr di check "$W/1.md"
  [ "$status" -eq 4 ]
  [ "$output" = "$W/1.md:5: second ## Comments (first at line 3)" ]
}

@test "di: ## Prompt after ## Comments fails check" {
  printf '# T\n\n## Comments\n- 2026-11-10 a\n## Prompt\n' > "$W/1.md"
  run --separate-stderr di check "$W/1.md"
  [ "$status" -eq 4 ]
  [ "$output" = "$W/1.md:5: ## Prompt after ## Comments" ]
}

@test "di: text between ## Comments and the first entry fails check" {
  printf '# T\n\n## Comments\nstray\n- 2026-11-10 a\n' > "$W/1.md"
  run --separate-stderr di check "$W/1.md"
  [ "$status" -eq 4 ]
  [ "$output" = "$W/1.md:4: text between ## Comments and the first entry" ]
}

@test "di: a comment date that is not a real date fails check" {
  printf '# T\n\n## Comments\n- 2026-02-30 a\n' > "$W/1.md"
  run --separate-stderr di check "$W/1.md"
  [ "$status" -eq 4 ]
  [ "$output" = "$W/1.md:4: comment date 2026-02-30 is not a real date" ]
}

@test "di: a heading inside ## Comments fails check" {
  printf '# T\n\n## Comments\n- 2026-11-10 a\n## Notes\n' > "$W/1.md"
  run --separate-stderr di check "$W/1.md"
  [ "$status" -eq 4 ]
  [ "$output" = "$W/1.md:5: heading inside ## Comments" ]
}

@test "di: an unexpected line inside ## Comments fails check" {
  printf '# T\n\n## Comments\n- 2026-11-10 a\n one space\n' > "$W/1.md"
  run --separate-stderr di check "$W/1.md"
  [ "$status" -eq 4 ]
  [ "$output" = "$W/1.md:5: unexpected line in ## Comments: an entry starts with \"- YYYY-MM-DD \" and continues on lines indented two spaces" ]
}

@test "di: a comment entry with no text fails check" {
  printf '# T\n\n## Comments\n- 2026-11-10 \n- 2026-11-11 b\n' > "$W/1.md"
  run --separate-stderr di check "$W/1.md"
  [ "$status" -eq 4 ]
  [ "$output" = "$W/1.md:4: comment entry has no text" ]
}

# ---------------------------------------------------------------- Task 5: list and the JSON shape

PROMPT_JSON='"The settings page should have a switch that flips the site between light and dark.\nDone when the choice survives a page reload."'
TITLE_JSON='"Add a dark-mode toggle to the settings page"'

@test "di: parse prints the pinned JSON line for both example files" {
  cp "$FIX/minimal.md" "$W/1.md"
  cp "$FIX/full.md" "$W/2.md"
  run --separate-stderr di parse "$W/1.md"
  [ "$status" -eq 0 ]
  [ "$output" = '{"n":1,"title":'"$TITLE_JSON"',"keys":{"state":"open"},"prompt":'"$PROMPT_JSON"',"comments":[],"warnings":[]}' ]
  run --separate-stderr di parse "$W/2.md"
  [ "$status" -eq 0 ]
  [ "$output" = '{"n":2,"title":'"$TITLE_JSON"',"keys":{"state":"closed","status":"Done","parent":3},"prompt":'"$PROMPT_JSON"',"comments":[{"date":"2026-11-10","text":"on_draft_start: status In Progress","line":11},{"date":"2026-11-10","text":"on_ship: status In Review","line":12},{"date":"2026-11-11","text":"on_merge: status Done, closed","line":13}],"warnings":[]}' ]
}

@test "di: list of an empty folder prints nothing and exits 0" {
  run --separate-stderr di list "$W"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "di: list sorts by N and ignores non-issue names" {
  for f in 10.md 2.md 1.md .1.md.tmp-x 0.md 01.md README.md; do printf '# T %s\n' "$f" > "$W/$f"; done
  mkdir "$W/sub" "$W/4.md"
  printf '# T\n' > "$W/sub/3.md"
  run --separate-stderr di list "$W"
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 3 ]
  [ "$(json_get "${lines[0]}" '[o["n"], o["title"]]')" = '[1, "T 1.md"]' ]
  [ "$(json_get "${lines[1]}" '[o["n"], o["title"]]')" = '[2, "T 2.md"]' ]
  [ "$(json_get "${lines[2]}" '[o["n"], o["title"]]')" = '[10, "T 10.md"]' ]
}

@test "di: list prints every line, then exits 4 when one file is faulty" {
  printf '# A\n' > "$W/1.md"
  printf '# B\nstate: maybe\n' > "$W/2.md"
  printf '# C\n' > "$W/3.md"
  run --separate-stderr di list "$W"
  [ "$status" -eq 4 ]
  [ "${#lines[@]}" -eq 3 ]
  [ "${lines[1]}" = '{"n":2,"faults":[{"line":2,"message":"state must be \"open\" or \"closed\", got \"maybe\"; if this line is prose, put a blank line above it"}],"warnings":[]}' ]
  [ "$(json_get "${lines[2]}" 'o["title"]')" = '"C"' ]
}

@test "di: list on a missing folder exits 1" {
  run --separate-stderr di list "$W/nope"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  [[ "$stderr" == *"$W/nope: cannot read folder"* ]]
}

@test "di: an unreadable file gives exit 1 and a cannot-read fault" {
  skip_on_git_bash "chmod 000"
  [ "$(id -u)" -ne 0 ] || skip "root reads a mode-000 file"
  printf '# A\n' > "$W/1.md"
  printf '# B\nstate: maybe\n' > "$W/2.md"
  printf '# C\n' > "$W/3.md"
  chmod 000 "$W/3.md"
  run --separate-stderr di list "$W"
  chmod 600 "$W/3.md"
  [ "$status" -eq 1 ]
  [ "${#lines[@]}" -eq 3 ]
  [ "${lines[2]}" = '{"n":3,"faults":[{"line":1,"message":"cannot read: Permission denied"}],"warnings":[]}' ]
}

@test "di: JSON output is UTF-8 with LF only" {
  printf '# Caf\xc3\xa9 \xe2\x80\x94 \xe6\x97\xa5\xe6\x9c\xac\r\n\r\nl\xc3\xa9\r\n' > "$W/1.md"
  di parse "$W/1.md" > "$W/out"
  di list "$W" >> "$W/out"
  ! grep -q $'\r' "$W/out"
  [ "$(grep -c 'Café — 日本' "$W/out")" -eq 2 ]
  [ "$(grep -c '"prompt":"lé"' "$W/out")" -eq 2 ]
}
