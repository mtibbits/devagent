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

# ---------------------------------------------------------------- Task 6: set and the first write

no_temp_left() { ! compgen -G "$1/.*.tmp-*" > /dev/null; }

@test "di: setting a key to its current value leaves bytes identical" {
  cp "$FIX/full.md" "$W/1.md"
  crlf "$FIX/full.md" "$W/2.md"
  bom "$FIX/full.md" "$W/3.md"
  for f in 1 2 3; do
    cp "$W/$f.md" "$W/$f.orig"
    run --separate-stderr di set "$W/$f.md" status=Done parent=#3
    [ "$status" -eq 0 ]
    cmp "$W/$f.md" "$W/$f.orig"
  done
  no_temp_left "$W"
}

@test "di: set on the CRLF minimal file ends every line in CRLF" {
  crlf "$FIX/minimal.md" "$W/1.md"
  run --separate-stderr di set "$W/1.md" state=closed
  [ "$status" -eq 0 ]
  run python3 -c 'import sys; d=open(sys.argv[1],"rb").read(); print(d.count(b"\n"), d.count(b"\r\n"), d.endswith(b"\r\n"))' "$W/1.md"
  [ "$output" = "6 6 True" ]
}

@test "di: three sets turn minimal.md into full.md's header and prompt" {
  cp "$FIX/minimal.md" "$W/1.md"
  di set "$W/1.md" state=closed
  di set "$W/1.md" status=Done
  di set "$W/1.md" parent=3
  head -n 8 "$FIX/full.md" > "$W/want"
  cmp "$W/1.md" "$W/want"
}

@test "di: the first write moves the prose byte for byte" {
  printf 'T\n\n\nline one  \nhas\rcr\nff\x0cx\n' > "$W/1.md"
  run --separate-stderr di set "$W/1.md" state=closed
  [ "$status" -eq 0 ]
  run python3 -c 'import sys; d=open(sys.argv[1],"rb").read(); print(d == b"# T\nstate: closed\n\n## Prompt\nline one  \nhas\rcr\nff\x0cx\n")' "$W/1.md"
  [ "$output" = "True" ]
}

@test "di: a full-form set changes only the named line" {
  cp "$FIX/full.md" "$W/1.md"
  run --separate-stderr di set "$W/1.md" status=Blocked
  [ "$status" -eq 0 ]
  run python3 -c '
import sys
a = open(sys.argv[1], "rb").read().split(b"\n"); b = open(sys.argv[2], "rb").read().split(b"\n")
print(len(a) == len(b), [i for i, (x, y) in enumerate(zip(a, b)) if x != y], b[2])' "$FIX/full.md" "$W/1.md"
  [ "$output" = "True [2] b'status: Blocked'" ]
}

@test "di: a new key goes in canonical order" {
  printf '# T\nstate: closed\nlabels: a\n\n## Prompt\nx\n' > "$W/1.md"
  run --separate-stderr di set "$W/1.md" parent=3 github=o/n#4 status=Open
  [ "$status" -eq 0 ]
  [ "$(cat "$W/1.md")" = "$(printf '# T\nstate: closed\nstatus: Open\nparent: 3\nlabels: a\ngithub: o/n#4\n\n## Prompt\nx')" ]
}

@test "di: state=open removes the line; --unset removes a key; unsetting an absent key writes nothing" {
  cp "$FIX/full.md" "$W/1.md"
  run --separate-stderr di set "$W/1.md" state=open --unset parent
  [ "$status" -eq 0 ]
  [ "$(head -n 3 "$W/1.md")" = "$(printf '# Add a dark-mode toggle to the settings page\nstatus: Done\n')" ]
  cp "$W/1.md" "$W/1.orig"
  run --separate-stderr di set "$W/1.md" --unset labels --unset parent
  [ "$status" -eq 0 ]
  cmp "$W/1.md" "$W/1.orig"
}

@test "di: a value with a line break exits 2 and leaves the file unchanged" {
  cp "$FIX/full.md" "$W/1.md"
  run --separate-stderr di set "$W/1.md" "status=a
b"
  [ "$status" -eq 2 ]
  [[ "$stderr" == *'"status" value contains a line break'* ]]
  cmp "$W/1.md" "$FIX/full.md"
}

@test "di: set refuses a bad value with exit 2" {
  cp "$FIX/full.md" "$W/1.md"
  run --separate-stderr di set "$W/1.md" state=Closed
  [ "$status" -eq 2 ]
  [[ "$stderr" == *'disk-issue: state must be "open" or "closed", got "Closed"' ]]
  cmp "$W/1.md" "$FIX/full.md"
}

@test "di: any write to a file with two status: lines exits 4 and leaves it unchanged" {
  printf '# T\nstatus: a\nstatus: b\n' > "$W/1.md"
  cp "$W/1.md" "$W/1.orig"
  run --separate-stderr di set "$W/1.md" status=Done
  [ "$status" -eq 4 ]
  [[ "$stderr" == *"$W/1.md:3: duplicate key \"status\" (first at line 2)"* ]]
  cmp "$W/1.md" "$W/1.orig"
  run --separate-stderr di set "$W/1.md" --comment x
  [ "$status" -eq 4 ]
  cmp "$W/1.md" "$W/1.orig"
  no_temp_left "$W"
}

@test "di: set keeps the permission bits" {
  skip_on_git_bash "file modes"
  cp "$FIX/full.md" "$W/1.md"
  chmod 640 "$W/1.md"
  run --separate-stderr di set "$W/1.md" status=Blocked
  [ "$status" -eq 0 ]
  assert_file_mode "$W/1.md" 640
}

@test "di: set on a missing file exits 1" {
  run --separate-stderr di set "$W/1.md" status=x
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"$W/1.md: cannot read: "* ]]
  [ ! -e "$W/1.md" ]
}

@test "di: a title-only file with no final newline" {
  printf 'T' > "$W/1.md"
  run --separate-stderr di set "$W/1.md" state=closed
  [ "$status" -eq 0 ]
  run python3 -c 'import sys; print(open(sys.argv[1],"rb").read() == b"# T\nstate: closed\n")' "$W/1.md"
  [ "$output" = "True" ]
}

@test "di: values are written as given, after trimming" {
  cp "$FIX/minimal.md" "$W/1.md"
  run --separate-stderr di set "$W/1.md" "parent=  #3 "
  [ "$status" -eq 0 ]
  [ "$(sed -n 2p "$W/1.md")" = "parent: #3" ]
  [ "$(json_get "$(di parse "$W/1.md")" 'o["keys"]["parent"]')" = "3" ]
}

@test "di: set keeps a BOM and every-line CRLF on both example files" {
  for src in minimal full; do
    bom "$FIX/$src.md" "$W/1.md"
    crlf "$W/1.md" "$W/2.md"
    for f in 1 2; do
      run --separate-stderr di set "$W/$f.md" status=X
      [ "$status" -eq 0 ]
      [ "$(head -c 3 "$W/$f.md" | od -An -tx1 | tr -d ' ')" = "efbbbf" ]
      [ "$(json_get "$(di parse "$W/$f.md")" '[o["title"], o["keys"]["status"]]')" = '["Add a dark-mode toggle to the settings page", "X"]' ]
    done
    run python3 -c 'import sys; d=open(sys.argv[1],"rb").read(); print(d.count(b"\n") == d.count(b"\r\n"))' "$W/2.md"
    [ "$output" = "True" ]
  done
}

# ---------------------------------------------------------------- Task 7: --comment and --date

@test "di: --comment adds ## Comments and one entry dated by DEVAGENT_DATE_OVERRIDE" {
  head -n 8 "$FIX/full.md" > "$W/1.md"
  before="$(json_get "$(di parse "$W/1.md")" 'o["prompt"]')"
  DEVAGENT_DATE_OVERRIDE=2026-11-10 run --separate-stderr di set "$W/1.md" --comment hello
  [ "$status" -eq 0 ]
  run python3 -c 'import sys; print(open(sys.argv[1],"rb").read().endswith(b"reload.\n\n## Comments\n- 2026-11-10 hello\n"))' "$W/1.md"
  [ "$output" = "True" ]
  [ "$(json_get "$(di parse "$W/1.md")" 'o["prompt"]')" = "$before" ]
}

@test "di: a two-paragraph comment reads back as one entry" {
  head -n 8 "$FIX/full.md" > "$W/1.md"
  DEVAGENT_DATE_OVERRIDE=2026-11-10 run --separate-stderr di set "$W/1.md" --comment $'first\nline two\n\nsecond'
  [ "$status" -eq 0 ]
  run python3 -c 'import sys; print(open(sys.argv[1],"rb").read().endswith(b"- 2026-11-10 first\n  line two\n\n  second\n"))' "$W/1.md"
  [ "$output" = "True" ]
  [ "$(json_get "$(di parse "$W/1.md")" '[(c["date"], c["text"]) for c in o["comments"]]')" = '[["2026-11-10", "first\nline two\n\nsecond"]]' ]
}

@test "di: set status=Done state=closed --comment \"on_merge: status Done, closed\" makes all three changes" {
  printf '# T\nstatus: In Review\n\n## Prompt\nbody\n' > "$W/1.md"
  DEVAGENT_DATE_OVERRIDE=2026-11-11 run --separate-stderr di set "$W/1.md" status=Done state=closed --comment "on_merge: status Done, closed"
  [ "$status" -eq 0 ]
  [ "$(cat "$W/1.md")" = "$(printf '# T\nstate: closed\nstatus: Done\n\n## Prompt\nbody\n\n## Comments\n- 2026-11-11 on_merge: status Done, closed')" ]
}

@test "di: comments replay full.md" {
  cp "$FIX/minimal.md" "$W/1.md"
  di set "$W/1.md" state=closed
  di set "$W/1.md" status=Done
  di set "$W/1.md" parent=3
  di set "$W/1.md" --comment "on_draft_start: status In Progress" --date 2026-11-10
  di set "$W/1.md" --comment "on_ship: status In Review" --date 2026-11-10
  di set "$W/1.md" --comment "on_merge: status Done, closed" --date 2026-11-11
  cmp "$W/1.md" "$FIX/full.md"
}

@test "di: --date 2026-02-30 exits 2" {
  cp "$FIX/full.md" "$W/1.md"
  run --separate-stderr di set "$W/1.md" --comment x --date 2026-02-30
  [ "$status" -eq 2 ]
  [[ "$stderr" == *"--date must be a real YYYY-MM-DD date"* ]]
  cmp "$W/1.md" "$FIX/full.md"
}

@test "di: an empty --comment exits 2" {
  cp "$FIX/full.md" "$W/1.md"
  run --separate-stderr di set "$W/1.md" --comment $' \n\t\n'
  [ "$status" -eq 2 ]
  [[ "$stderr" == *"empty comment"* ]]
  cmp "$W/1.md" "$FIX/full.md"
}

@test "di: a bad DEVAGENT_DATE_OVERRIDE exits 2, and is not read when --date is given" {
  cp "$FIX/full.md" "$W/1.md"
  DEVAGENT_DATE_OVERRIDE=2026-13-01 run --separate-stderr di set "$W/1.md" --comment x
  [ "$status" -eq 2 ]
  [[ "$stderr" == *"DEVAGENT_DATE_OVERRIDE is not a YYYY-MM-DD date"* ]]
  cmp "$W/1.md" "$FIX/full.md"
  DEVAGENT_DATE_OVERRIDE=2026-13-01 run --separate-stderr di set "$W/1.md" --comment x --date 2026-11-12
  [ "$status" -eq 0 ]
  [ "$(tail -n 1 "$W/1.md")" = "- 2026-11-12 x" ]
}

@test "di: without the override the date equals date_tag" {
  local tz before after got
  for tz in Pacific/Kiritimati Pacific/Pago_Pago; do
    cp "$FIX/full.md" "$W/1.md"
    before="$(env -u DEVAGENT_DATE_OVERRIDE TZ="$tz" bash -c "source '$PLUGIN_ROOT/scripts/lib/io.sh'; date_tag")"
    env -u DEVAGENT_DATE_OVERRIDE TZ="$tz" python3 "$DI" set "$W/1.md" --comment x
    after="$(env -u DEVAGENT_DATE_OVERRIDE TZ="$tz" bash -c "source '$PLUGIN_ROOT/scripts/lib/io.sh'; date_tag")"
    got="$(tail -n 1 "$W/1.md")"
    [ "$got" = "- $before x" ] || [ "$got" = "- $after x" ]
  done
}

@test "di: a fence in an added comment cannot turn earlier text into code" {
  printf '# T\n\n## Prompt\n```\nopen\n' > "$W/1.md"
  DEVAGENT_DATE_OVERRIDE=2026-11-10 run --separate-stderr di set "$W/1.md" --comment $'see\n```\ncode'
  [ "$status" -eq 0 ]
  run python3 -c 'import sys; print(open(sys.argv[1],"rb").read().endswith(b"\n## Comments\n- 2026-11-10 see\n  ```\n  code\n"))' "$W/1.md"
  [ "$output" = "True" ]
  run --separate-stderr di parse "$W/1.md"
  [ "$(json_get "$output" '[o["prompt"], [c["text"] for c in o["comments"]]]')" = '["```\nopen", ["see\n```\ncode"]]' ]
  run --separate-stderr di check "$W/1.md"
  [ "$status" -eq 0 ]
}

@test "di: a comment keeps a BOM and every-line CRLF" {
  for src in minimal full; do
    bom "$FIX/$src.md" "$W/0"
    crlf "$W/0" "$W/1.md"
    DEVAGENT_DATE_OVERRIDE=2026-11-12 run --separate-stderr di set "$W/1.md" status=X --comment $'one\n\ntwo'
    [ "$status" -eq 0 ]
    [ "$(head -c 3 "$W/1.md" | od -An -tx1 | tr -d ' ')" = "efbbbf" ]
    run python3 -c 'import sys; d=open(sys.argv[1],"rb").read(); print(d.count(b"\n") == d.count(b"\r\n"), d.endswith(b"- 2026-11-12 one\r\n\r\n  two\r\n"))' "$W/1.md"
    [ "$output" = "True True" ]
  done
}

# ---------------------------------------------------------------- Task 8: safe writes

teardown() {
  if [ -n "${HOLDER:-}" ]; then kill "$HOLDER" 2>/dev/null || true; wait "$HOLDER" 2>/dev/null || true; fi
}

inj() { python3 "$INJ" "$@"; }
safe_fixture() { printf '# T\n\n## Prompt\nbody\n' > "$W/1.md"; cp "$W/1.md" "$W/orig"; }

@test "di: a writer killed before the replace leaves the original intact" {
  safe_fixture
  run --separate-stderr inj kill-before-replace -- set "$W/1.md" status=Done
  [ "$status" -eq 137 ]
  cmp "$W/1.md" "$W/orig"
  run compgen -G "$W/.1.md.tmp-*"
  [ "${#lines[@]}" -eq 1 ]
  run --separate-stderr di list "$W"
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 1 ]
  [[ "${lines[0]}" == '{"n":1,'* ]]
}

@test "di: a change between read and replace is merged by one restart" {
  safe_fixture
  run --separate-stderr inj change-once -- set "$W/1.md" status=Done
  [ "$status" -eq 0 ]
  [ "$(cat "$W/1.md")" = "$(printf '# T\nstatus: Done\n\n## Prompt\nbody\nother session')" ]
  no_temp_left "$W"
}

@test "di: a file that keeps changing is not overwritten" {
  safe_fixture
  run --separate-stderr inj change-always -- set "$W/1.md" status=Done
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"$W/1.md: changed while being written; not overwritten"* ]]
  ! grep -q 'status: Done' "$W/1.md"
  [ "$(tail -n 2 "$W/1.md")" = "$(printf 'other session\nother session')" ]
  no_temp_left "$W"
}

@test "di: three changes are one write" {
  safe_fixture
  DEVAGENT_DATE_OVERRIDE=2026-11-11 run --separate-stderr inj count-replace -- set "$W/1.md" status=Done state=closed --comment "on_merge: status Done, closed"
  [ "$status" -eq 0 ]
  [ "$stderr" = "replaces=1" ]
  [ "$(cat "$W/1.md")" = "$(printf '# T\nstate: closed\nstatus: Done\n\n## Prompt\nbody\n\n## Comments\n- 2026-11-11 on_merge: status Done, closed')" ]
}

@test "di: a no-op set never replaces" {
  safe_fixture
  run --separate-stderr inj count-replace -- set "$W/1.md" state=open --unset status
  [ "$status" -eq 0 ]
  [ "$stderr" = "replaces=0" ]
  cmp "$W/1.md" "$W/orig"
  no_temp_left "$W"
}

@test "di: a Windows sharing violation is retried" {
  safe_fixture
  run --separate-stderr inj win-share 3 -- set "$W/1.md" status=Done
  [ "$status" -eq 0 ]
  grep -q '^status: Done$' "$W/1.md"
  no_temp_left "$W"
}

@test "di: a held file fails after about one second" {
  safe_fixture
  local t0 t1 ms
  t0="$(date +%s%N)"
  run --separate-stderr inj win-share always -- set "$W/1.md" status=Done
  t1="$(date +%s%N)"
  ms=$(( (t1 - t0) / 1000000 ))
  [ "$status" -eq 1 ]
  [ "$ms" -ge 900 ]
  [ "$ms" -le 3000 ]
  cmp "$W/1.md" "$W/orig"
  no_temp_left "$W"
}

@test "di: a writer waits for the folder lock, then gives up" {
  skip_on_git_bash "flock"
  safe_fixture
  python3 -c '
import fcntl, sys, time
fh = open(sys.argv[1], "a"); fcntl.flock(fh.fileno(), fcntl.LOCK_EX)
open(sys.argv[2], "w").close(); time.sleep(3)' "$W/.disk-issue.lock" "$BATS_TEST_TMPDIR/holding" 3>&- &
  HOLDER=$!
  local n=0
  until [ -e "$BATS_TEST_TMPDIR/holding" ]; do
    n=$((n + 1)); [ "$n" -lt 100 ] || false
    sleep 0.05
  done
  run --separate-stderr inj lock-wait 0.3 -- set "$W/1.md" status=Done
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"$W: another writer holds the lock"* ]]
  cmp "$W/1.md" "$W/orig"
}
