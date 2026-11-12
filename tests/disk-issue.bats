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
