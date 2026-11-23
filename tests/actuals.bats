#!/usr/bin/env bats
bats_require_minimum_version 1.5.0   # run --separate-stderr: the document and the WARNING stream apart
#
# #735: scripts/actuals.sh. Two projects (alpha, beta) with github issue
# sources served by the stub backend of tests/helpers/wbs-tracker.bash; an
# archive with hosts h1 and h2 (.jsonl.gz), one two-model session; a
# checklist per project. gh/glab/curl shims on PATH log to network.log,
# which teardown asserts absent.

REPO="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
. "$(dirname "$BATS_TEST_FILENAME")/lib/hermetic-env.bash"
. "$(dirname "$BATS_TEST_FILENAME")/helpers/wbs-tracker.bash"

FIX="$REPO/tests/fixtures/milestones"
USAGE="usage: actuals.sh [--archive DIR] [--project P] [--out PATH | --stdout] [--if-stale]"

setup() {
  TMPROOT="$(mktemp -d)"
  export TMPROOT
  export HOME="$TMPROOT/home"
  export DA_HOME="$HOME/.claude/devagent"
  export CLAUDE_CONFIG_DIR="$TMPROOT/claude"
  mkdir -p "$DA_HOME/state" "$DA_HOME/secrets" "$CLAUDE_CONFIG_DIR/projects" \
    "$TMPROOT/devdoc/alpha" "$TMPROOT/devdoc/beta" "$TMPROOT/tmp"
  export TMPDIR="$TMPROOT/tmp"
  {
    printf '%s\n' '[defaults]' 'checklist_template = "standard"' ''
    for p in alpha beta; do
      printf '%s\n' "[project.$p]" "source_dir = \"$TMPROOT/src/$p\"" \
        "devdoc_dir = \"$TMPROOT/devdoc/$p\"" '' "[project.$p.issue_source]" \
        'backend = "github"' "repo = \"acme/$p\"" 'dir_prefix = "Issue-"' ''
    done
  } > "$DA_HOME/config.toml"
  export DEVAGENT_ISSUE_BACKEND_DIR="$TMPROOT/backends"
  export DEVAGENT_CODE_BACKEND_DIR="$TMPROOT/code-backends"
  wbs_tracker_install_stub "$DEVAGENT_ISSUE_BACKEND_DIR"
  wbs_mr_install_stub "$DEVAGENT_CODE_BACKEND_DIR"
  wbs_tracker_install_shims "$TMPROOT/shims" "$TMPROOT/network.log"
  export PATH="$TMPROOT/shims:$PATH"
  unset DEVAGENT_PROJECT DEVAGENT_JIRA_PROJECT_KEY
  : > "$TMPROOT/issue-list.github.acme_alpha"
  : > "$TMPROOT/issue-list.github.acme_beta"
  cp -r "$FIX/shapes/Issue-700" "$TMPROOT/devdoc/alpha/"
  cp -r "$FIX/rev2/Issue-465" "$TMPROOT/devdoc/beta/"
  _archive
}

teardown() {
  [ ! -e "$TMPROOT/network.log" ]
  rm -rf "$TMPROOT"
}

# _archive: $TMPROOT/A/h1 (alpha/Issue-700 on two models) and h2 (beta/Issue-465).
_archive() {
  python3 - "$TMPROOT/A" <<'PY'
import gzip, json, sys
from pathlib import Path
root = Path(sys.argv[1])

def dispatch(project, issue, tid):
    return [{"type": "assistant", "message": {"id": "d" + tid, "content": [
                {"type": "tool_use", "id": tid, "name": "Bash",
                 "input": {"command": f'bash "x/scripts/next.sh" {project} --auto'}}]}},
            {"type": "user", "message": {"content": [{"type": "tool_result", "tool_use_id": tid,
                "content": f"dispatch: {project}/{issue} — step 9 (implement), skill-backed"}]}}]

def call(mid, model, **u):
    usage = {"input_tokens": u.get("inp", 0), "cache_read_input_tokens": u.get("read", 0),
             "cache_creation_input_tokens": 0, "output_tokens": u.get("out", 0)}
    return {"type": "assistant", "message": {"id": mid, "model": model, "usage": usage, "content": []}}

def gz(path, recs):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(gzip.compress("".join(json.dumps(r) + "\n" for r in recs).encode(), mtime=0))

gz(root / "h1" / "-work-alpha" / "S1.jsonl.gz",
   dispatch("alpha", "Issue-700", "n1") + [call("m1", "claude-a", inp=10, out=2), call("m2", "claude-b", read=100)])
gz(root / "h2" / "-work-beta" / "S2.jsonl.gz",
   dispatch("beta", "Issue-465", "n2") + [call("b1", "claude-a", inp=5)])
PY
}

_act() {
  run --separate-stderr bash "$REPO/scripts/actuals.sh" "$@"
}

# _py <script> [args]: python over the document on stdin.
_py() {
  python3 -c "$1" "${@:2}"
}

# _check_rows: every issue/project object passes the schema's slot definition; prints "<issues> <projects>".
_check_rows() {
  python3 -c "$(cat <<'PY'
import importlib.util, json, sys
spec = importlib.util.spec_from_file_location("pc", sys.argv[1]); pc = importlib.util.module_from_spec(spec)
sys.modules["pc"] = pc; spec.loader.exec_module(pc)
doc = json.load(open(0, encoding="utf-8"))
bad = [r for r in doc["issues"] if pc.check_at(r["actuals"], "projects[].issues[].actuals")]
bad += [r for r in doc["projects"] if pc.check_at(r["actuals"], "projects[].actuals")]
assert not bad, bad
print(len(doc["issues"]), len(doc["projects"]))
PY
)" "$REPO/scripts/lib/portfolio-check.py"
}

# _strip: the document with generated_at popped, keys sorted.
_strip() {
  python3 -c 'import json,sys; d=json.load(sys.stdin); d.pop("generated_at"); print(json.dumps(d, sort_keys=True))'
}

@test "AC1: --archive --stdout prints a document whose rows pass the slot definition" {
  _act --archive "$TMPROOT/A" --stdout
  [ "$status" -eq 0 ] || { echo "$stderr"; false; }
  [ "$(_check_rows <<<"$output")" = "2 2" ]
  [ "$(_py 'import json,sys; d=json.load(sys.stdin); print(next(r for r in d["issues"] if r["issue"] == "Issue-700")["actuals"]["tokens"]["total"])' <<<"$output")" = "30.0" ]
  [ "$(_py 'import json,sys; d=json.load(sys.stdin); print(len(next(r for r in d["issues"] if r["issue"] == "Issue-465")["actuals"]["milestones"]))' <<<"$output")" -gt 0 ]
}

@test "AC3: --archive reads no live dir: the same bytes after the live root is deleted" {
  mkdir -p "$CLAUDE_CONFIG_DIR/projects/-work-alpha"
  python3 -c 'import json,sys; print(json.dumps({"type":"assistant","message":{"id":"L1","usage":{"input_tokens":9},"content":[]}}))' \
    > "$CLAUDE_CONFIG_DIR/projects/-work-alpha/L.jsonl"
  _act --archive "$TMPROOT/A" --stdout
  [ "$status" -eq 0 ]
  local before
  before="$(_strip <<<"$output")"
  rm -rf "$CLAUDE_CONFIG_DIR/projects"
  _act --archive "$TMPROOT/A" --stdout
  [ "$status" -eq 0 ]
  [ "$(_strip <<<"$output")" = "$before" ]
}

@test "AC5: two runs give the same bytes apart from generated_at" {
  _act --archive "$TMPROOT/A" --stdout
  local one="$output"
  _act --archive "$TMPROOT/A" --stdout
  [ "$(grep -v '"generated_at"' <<<"$output")" = "$(grep -v '"generated_at"' <<<"$one")" ]
  [ "$(grep -c '"generated_at"' <<<"$output")" -eq 1 ]
}

@test "AC7: with no output flag the file is \$DA_HOME/actuals.json, mode 600" {
  _act --archive "$TMPROOT/A"
  [ "$status" -eq 0 ] || { echo "$stderr"; false; }
  [ "$output" = "actuals: wrote $DA_HOME/actuals.json (2 issues, 2 projects, 2 missing sources)" ]
  [ "$(stat -c %a "$DA_HOME/actuals.json")" = 600 ]
  [ "$(_check_rows < "$DA_HOME/actuals.json")" = "2 2" ]
}

@test "AC7: --out inside a git work tree is exit 2 and writes nothing" {
  git init -q "$TMPROOT/repo"
  _act --archive "$TMPROOT/A" --out "$TMPROOT/repo/x/actuals.json"
  [ "$status" -eq 2 ]
  [ "$stderr" = "actuals: --out is inside a git work tree ($TMPROOT/repo/x/actuals.json); the document lists project names, session ids and cwd paths" ]
  [ ! -e "$TMPROOT/repo/x" ]
  [ ! -e "$TMPROOT/backend.log" ]   # refused before any milestones call
}

@test "refused flag forms are exit 2 with the usage line, before any work" {
  local args
  for args in "--archive" "--archive=" "--out" "--out=" "--project" "--project=" "--bogus" "positional" \
      "--out x --stdout" "--if-stale --stdout" "--if-stale --out x" "--if-stale --project alpha --stdout"; do
    # shellcheck disable=SC2086  # each case is a word list
    _act $args
    [ "$status" -eq 2 ] || { echo "args: $args -> $status" >&2; false; }
    [ "${stderr##*$'\n'}" = "$USAGE" ] || { echo "args: $args -> $stderr" >&2; false; }
  done
  _act --project alpha
  [ "$status" -eq 2 ]
  [ "$stderr" = "actuals: --project builds a one-project document; pass --out PATH or --stdout"$'\n'"$USAGE" ]
  [ ! -e "$TMPROOT/backend.log" ]
  [ ! -e "$DA_HOME/actuals.json" ]
}

@test "an unknown --project is exit 1" {
  _act --project nobody --stdout
  [ "$status" -eq 1 ]
  [ "$stderr" = "actuals: unknown project 'nobody'" ]
}

@test "a failing tracker is a header missing row: exit 0, no WARNING, both projects' checklist rows" {
  printf '%s\n' 1 > "$TMPROOT/issue-list.github.acme_alpha.rc"
  printf '%s\n' 'gh: HTTP 502: Bad Gateway' > "$TMPROOT/issue-list.github.acme_alpha.err"
  _act --archive "$TMPROOT/A" --stdout
  [ "$status" -eq 0 ]
  [ "$(grep -c '^actuals: WARNING:' <<<"$stderr")" -eq 0 ]
  [[ "$stderr" == *"actuals: milestones alpha: milestones: WARNING: tracker: github "* ]]
  [ "$(_py 'import json,sys; d=json.load(sys.stdin); print(sum(1 for s in d["sources"] if (s["source"], s["project"], s["status"]) == ("tracker", "alpha", "missing")))' <<<"$output")" -eq 1 ]
  [ "$(_py 'import json,sys; d=json.load(sys.stdin); print(sorted(r["project"] for r in d["issues"] if r["actuals"]["milestones"]))' <<<"$output")" = "['alpha', 'beta']" ]
}

@test "a failing milestones run is one WARNING and a missing row; the other project's rows stay" {
  rm -rf "$TMPROOT/devdoc/beta"
  _act --archive "$TMPROOT/A" --stdout
  [ "$status" -eq 0 ]
  [ "$(grep -c '^actuals: WARNING:' <<<"$stderr")" -eq 1 ]
  grep -qx "actuals: WARNING: milestones beta: exit 1: milestones.sh: milestones: devdoc_dir $TMPROOT/devdoc/beta does not exist; other sources still reported" <<<"$stderr"
  [ "$(_py 'import json,sys; d=json.load(sys.stdin); print([s["detail"] for s in d["sources"] if (s["source"], s["project"]) == ("milestones", "beta")])' <<<"$output")" = "['exit 1: milestones.sh: milestones: devdoc_dir $TMPROOT/devdoc/beta does not exist']" ]
  [ "$(_py 'import json,sys; d=json.load(sys.stdin); a={r["project"]: r["actuals"]["milestones"] for r in d["issues"]}; print(a["beta"], len(a["alpha"]) > 0)' <<<"$output")" = "None True" ]
}

@test "--if-stale leaves a fresh file byte-identical, silently, and replaces a 25 h old one" {
  _act
  [ "$status" -eq 0 ]
  local sum
  sum="$(sha256sum "$DA_HOME/actuals.json")"
  : > "$TMPROOT/backend.log"
  _act --if-stale
  [ "$status" -eq 0 ]
  [ "$output" = "" ] && [ "$stderr" = "" ]
  [ "$(sha256sum "$DA_HOME/actuals.json")" = "$sum" ]
  [ ! -s "$TMPROOT/backend.log" ]   # fresh: no milestones call
  python3 - "$DA_HOME/actuals.json" <<'PY'
import json, sys
from datetime import datetime, timedelta, timezone
p = sys.argv[1]; d = json.load(open(p))
d["generated_at"] = (datetime.now(timezone.utc) - timedelta(hours=25)).strftime("%Y-%m-%dT%H:%M:%SZ")
open(p, "w").write(json.dumps(d))
PY
  _act --if-stale
  [ "$status" -eq 0 ]
  [ "$output" = "actuals: wrote $DA_HOME/actuals.json (2 issues, 2 projects, 3 missing sources)" ]
  [ "$(sha256sum "$DA_HOME/actuals.json")" != "$sum" ]
}

@test "no temporary directory remains after a run" {
  _act --archive "$TMPROOT/A" --stdout
  [ "$status" -eq 0 ]
  [ -z "$(ls -A "$TMPDIR")" ]
  rm -rf "$TMPROOT/devdoc/beta"
  _act --archive "$TMPROOT/A" --out "$TMPROOT/out.json"
  [ "$status" -eq 0 ]
  [ -z "$(ls -A "$TMPDIR")" ]
}
