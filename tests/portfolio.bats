#!/usr/bin/env bats
# tests/portfolio.bats — #726: the portfolio command (scripts/portfolio.sh)
# and the bash/Python agreement of its checklist reader; #727: --ready.
bats_require_minimum_version 1.5.0   # #727: run --separate-stderr for --ready's stderr lines

load 'lib/bats-helpers'

FIX="$BATS_TEST_DIRNAME/fixtures/portfolio"

# The Python reader, printed in the bash form below.
PY_NEXT='
import importlib.util, sys
spec = importlib.util.spec_from_file_location("portfolio", sys.argv[1])
pf = importlib.util.module_from_spec(spec); sys.modules["portfolio"] = pf
spec.loader.exec_module(pf)
try:
    state, n, name = pf.checklist_next(sys.argv[2])
except pf.ChecklistError:
    print("error")
else:
    print("complete" if state == "complete" else f"open {n} {name}")
'

# The bash rule next.sh uses: checklist_current_step + checklist_step_name,
# a die mapped to `error`.
bash_next() {
  local f="$1" n
  n="$(checklist_current_step "$f" 2>/dev/null)" || { echo error; return 0; }
  if [[ "$n" == "done" ]]; then
    echo complete
  else
    echo "open $n $(checklist_step_name "$f" "$n")"
  fi
}

@test "portfolio: checklist_next agrees with checklist_current_step + checklist_step_name" {
  source "$PLUGIN_ROOT/scripts/lib/paths.sh"
  source "$PLUGIN_ROOT/scripts/lib/io.sh"
  source "$PLUGIN_ROOT/scripts/lib/checklist.sh"
  local work subjects=() f b p count=0
  work="$(mktemp -d)"
  cp "$FIX"/checklists/*.md "$work/"
  sed 's/$/\r/' "$FIX/checklists/rev2-open.md" > "$work/rev2-open-crlf.md"
  for f in "$work"/*.md; do subjects+=("$f"); done
  for f in "${subjects[@]}"; do
    b="$(bash_next "$f")"
    p="$(python3 -c "$PY_NEXT" "$PLUGIN_ROOT/scripts/lib/portfolio.py" "$f" | tr -d '\r')"
    echo "$(basename "$f"): bash=[$b] python=[$p]"
    [[ "$b" == "$p" ]]
    count=$((count + 1))
  done
  rm -rf "$work"
  [[ "$count" -eq 9 ]]
}

# --- the command ---------------------------------------------------------------

PORTFOLIO="$PLUGIN_ROOT/scripts/portfolio.sh"
NAMES="alpha beta gamma delta epsilon zeta eta theta iota"

setup() {
  setup_tmp_devagent_home
  T="$BATS_TEST_TMPDIR/w"
  D="$T/devdocs"
  mkdir -p "$T/src/alpha" "$T/wt"
  cp -R "$FIX/multi" "$D"
  # Generated here, not committed: eol- and binary-unsafe shapes.
  mkdir -p "$D/epsilon" "$D/zeta/WBS.md" "$D/alpha/Issue-5"
  printf '# epsilon\n- [ ] bad \xff byte\n' > "$D/epsilon/WBS.md"
  printf 'Step: 9 implement\n\xfe\xff\n' > "$D/alpha/Issue-5/STUCK"
  cat > "$DA_HOME/config.toml" <<EOF
[project.alpha]
devdoc_dir = "$D/alpha"
source_dir = "$T/src/alpha"
worktree_root = "$T/wt"

[project.beta]
devdoc_dir = "$D/beta"

[project.gamma]
devdoc_dir = "$D/gamma"

[project.delta]
source_dir = "$T/src/delta"

[project.epsilon]
devdoc_dir = "$D/epsilon"

[project.zeta]
devdoc_dir = "$D/zeta"

[project.eta]
devdoc_dir = "$D/eta"

[project.theta]
devdoc_dir = "$D/theta"

[project.iota]
devdoc_dir = ""
EOF
}

teardown() {
  teardown_tmp_devagent_home
}

# _q <doc> <python expression over `d`>: print one value from a document.
_q() {
  python3 -c 'import json, sys; d = json.load(open(sys.argv[1], encoding="utf-8")); print(eval(sys.argv[2]))' "$1" "$2"
}

# _strip <doc> <out>: the document without generated_at, canonical bytes.
_strip() {
  python3 -c 'import json, sys; d = json.load(open(sys.argv[1], encoding="utf-8")); d.pop("generated_at"); open(sys.argv[2], "w", encoding="utf-8").write(json.dumps(d, sort_keys=True))' "$1" "$2"
}

_hashes() {
  (cd "$1" && find . -type f | LC_ALL=C sort | xargs -d '\n' sha256sum)
}

@test "portfolio: writes a checker-valid document listing every configured project" {
  run bash "$PORTFOLIO"
  echo "$output"
  [ "$status" -eq 0 ]
  out="$DA_HOME/portfolio/portfolio.json"
  [ -f "$out" ]
  [[ "$output" == "portfolio: wrote $out (9 projects, "*" report entries)" ]]
  run python3 "$PLUGIN_ROOT/scripts/lib/portfolio-check.py" "$out"
  [ "$status" -eq 0 ]
  [ "$(_q "$out" '" ".join(p["project"] for p in d["projects"])')" = "$NAMES" ]
}

@test "portfolio: default output lands under devagent_home only" {
  before="$(cd "$T" && find . | LC_ALL=C sort)"
  run bash "$PORTFOLIO"
  [ "$status" -eq 0 ]
  [ "$(cd "$T" && find . | LC_ALL=C sort)" = "$before" ]
  [ "$(cd "$DA_HOME" && find portfolio -type f)" = "portfolio/portfolio.json" ]
}

@test "portfolio: no devdoc file changes during a run" {
  before="$(_hashes "$D")"
  [ -n "$before" ]
  run bash "$PORTFOLIO"
  [ "$status" -eq 0 ]
  [ "$(_hashes "$D")" = "$before" ]
  # control: the comparison sees a one-byte change.
  printf 'x' >> "$D/theta/WBS.md"
  [ "$(_hashes "$D")" != "$before" ]
}

@test "portfolio: an unset devdoc_dir is a status and the others still read" {
  run bash "$PORTFOLIO"
  [ "$status" -eq 0 ]
  out="$DA_HOME/portfolio/portfolio.json"
  [ "$(_q "$out" '[(p["status"], p["status_reason"]) for p in d["projects"] if p["project"] == "delta"]')" \
    = "[('no_devdoc_dir', 'no devdoc dir is configured')]" ]
  [ "$(_q "$out" '[p["project"] for p in d["projects"] if p["status"] == "read"]')" \
    = "['alpha', 'beta', 'theta']" ]
}

@test "portfolio: an inherited PORTFOLIO_* var does not fill a manifest gap" {
  # delta (index 3) has no devdoc_dir; a stale export must not give it beta's.
  PORTFOLIO_DEVDOC_3="$D/beta" PORTFOLIO_PROJECT_COUNT=1 run bash "$PORTFOLIO"
  [ "$status" -eq 0 ]
  out="$DA_HOME/portfolio/portfolio.json"
  [ "$(_q "$out" 'len(d["projects"])')" = "9" ]
  [ "$(_q "$out" '[p["status"] for p in d["projects"] if p["project"] == "delta"]')"     = "['no_devdoc_dir']" ]
}

@test "portfolio: DEVAGENT_TEST_DEVDOC does not collapse projects" {
  run bash "$PORTFOLIO" --out "$T/plain.json"
  [ "$status" -eq 0 ]
  DEVAGENT_TEST_DEVDOC="$D/alpha" run bash "$PORTFOLIO" --out "$T/seam.json"
  [ "$status" -eq 0 ]
  texts() { _q "$1" "[n['text'] for p in d['projects'] if p['project'] == '$2' for n in p['nodes']]"; }
  [ "$(texts "$T/seam.json" alpha)" != "$(texts "$T/seam.json" beta)" ]
  [[ "$(texts "$T/seam.json" beta)" == *"plant-beta-issue1"* ]]
  _strip "$T/plain.json" "$T/plain.s"
  _strip "$T/seam.json" "$T/seam.s"
  cmp "$T/plain.s" "$T/seam.s"
}

@test "portfolio: two runs are identical apart from generated_at" {
  run bash "$PORTFOLIO" --out "$T/one.json"
  [ "$status" -eq 0 ]
  run bash "$PORTFOLIO" --out "$T/two.json"
  [ "$status" -eq 0 ]
  _strip "$T/one.json" "$T/one.s"
  _strip "$T/two.json" "$T/two.s"
  cmp "$T/one.s" "$T/two.s"
  # control: generated_at is the only field dropped, and it is present.
  [ "$(_q "$T/one.json" 'sorted(d)')" = "['actuals', 'generated_at', 'parse_report', 'projects', 'schema', 'schema_version']" ]
}

@test "portfolio: output file is 600 and its new dirs 700" {
  run bash "$PORTFOLIO" --out "$T/new1/new2/p.json"
  [ "$status" -eq 0 ]
  [ "$(stat -c %a "$T/new1/new2/p.json")" = 600 ]
  [ "$(stat -c %a "$T/new1/new2")" = 700 ]
  [ "$(stat -c %a "$T/new1")" = 700 ]
  [ -z "$(find "$T/new1/new2" -name '*.tmp')" ]
}

@test "portfolio: missing config exits 1" {
  rm "$DA_HOME/config.toml"
  run bash "$PORTFOLIO"
  [ "$status" -eq 1 ]
  [[ "$output" == *"config not found"* ]]
  [ ! -e "$DA_HOME/portfolio" ]
}

@test "portfolio: unparseable config exits 1" {
  printf '[project.alpha\ndevdoc_dir = \n' > "$DA_HOME/config.toml"
  run bash "$PORTFOLIO"
  [ "$status" -eq 1 ]
  [[ "$output" == *"not valid TOML"* ]]
  [ ! -e "$DA_HOME/portfolio" ]
}

@test "portfolio: unwritable --out exits 2" {
  : > "$T/afile"
  run bash "$PORTFOLIO" --out "$T/afile/p.json"
  [ "$status" -eq 2 ]
  [[ "$output" == "portfolio: cannot write $T/afile/p.json: "* ]]
  [ -f "$T/afile" ] && [ ! -s "$T/afile" ]
}

@test "portfolio: --out inside a git work tree is refused, nothing written (#735)" {
  git init -q "$T/repo"
  run bash "$PORTFOLIO" --out "$T/repo/new/p.json"
  [ "$status" -eq 2 ]
  [[ "$output" == "portfolio: --out is inside a git work tree ($T/repo); the document lists session ids and working directories"* ]]
  [ ! -e "$T/repo/new" ]
}

@test "portfolio: --out under a devdoc, source_dir or worktree_root is refused" {
  local role path
  for role in devdoc_dir source_dir worktree_root; do
    case "$role" in
      devdoc_dir) path="$D/alpha/sub/p.json" ;;
      source_dir) path="$T/src/alpha/p.json" ;;
      worktree_root) path="$T/wt/x/p.json" ;;
    esac
    run bash "$PORTFOLIO" --out "$path"
    echo "$role: $output"
    [ "$status" -eq 2 ]
    [[ "$output" == "portfolio: refusing to write under the $role of project 'alpha' ("* ]]
    [ ! -e "$path" ]
  done
  [ ! -e "$D/alpha/sub" ]
}

@test "portfolio: --out under the default worktree root (source_dir-wt) is refused" {
  # #1050 item 6: with worktree_root unset or empty, <source_dir>-wt is railed.
  cat >> "$DA_HOME/config.toml" <<TOML

[project.kappa]
source_dir = "$T/src/kappa"
worktree_root = ""
TOML
  run bash "$PORTFOLIO" --out "$T/src/delta-wt/p.json"
  echo "delta: $output"
  [ "$status" -eq 2 ]
  [ "$output" = "portfolio: refusing to write under the worktree_root of project 'delta' ($T/src/delta-wt); choose an --out outside every devdoc_dir, source_dir and worktree_root" ]
  [ ! -e "$T/src/delta-wt" ]
  run bash "$PORTFOLIO" --out "$T/src/kappa-wt/p.json"
  echo "kappa: $output"
  [ "$status" -eq 2 ]
  [ "$output" = "portfolio: refusing to write under the worktree_root of project 'kappa' ($T/src/kappa-wt); choose an --out outside every devdoc_dir, source_dir and worktree_root" ]
  [ ! -e "$T/src/kappa-wt" ]
  # Control: alpha sets worktree_root, so its <source_dir>-wt is not a root.
  run bash "$PORTFOLIO" --out "$T/src/alpha-wt/p.json"
  echo "alpha-wt: $output"
  [ "$status" -eq 0 ]
  [ -f "$T/src/alpha-wt/p.json" ]
}

@test "portfolio: usage errors exit 2" {
  local args
  for args in "--bogus" "--out" "--out|" "--out=" "positional"; do
    IFS='|' read -r -a argv <<< "$args"
    [[ "$args" == "--out|" ]] && argv=(--out "")
    run bash "$PORTFOLIO" "${argv[@]}"
    echo "[$args] -> $status: $output"
    [ "$status" -eq 2 ]
    [[ "$output" == *"usage: portfolio.sh [--out PATH | --ready]"* ]]
  done
  run bash "$PORTFOLIO" --help
  [ "$status" -eq 0 ]
  [[ "$output" == "usage: portfolio.sh [--out PATH | --ready]"* ]]
  [ ! -e "$DA_HOME/portfolio" ]
}

# --- --ready (#727) --------------------------------------------------------------

# _ready_config: config.toml naming rho then sigma over a tmp copy of the
# readiness fixture, in $R.
_ready_config() {
  R="$T/ready"
  cp -R "$FIX/ready" "$R"
  cat > "$DA_HOME/config.toml" <<EOF
[project.rho]
devdoc_dir = "$R/rho"

[project.sigma]
devdoc_dir = "$R/sigma"
EOF
}

@test "portfolio: --ready prints ready leaves in config then source order" {
  _ready_config
  run bash "$PORTFOLIO" --ready
  echo "$output"
  [ "$status" -eq 0 ]
  [ "$output" == "$(cat "$FIX/ready-expected.tsv")" ]
}

@test "portfolio: --ready twice gives identical output" {
  _ready_config
  run bash "$PORTFOLIO" --ready
  [ "$status" -eq 0 ]
  first="$output"
  [ -n "$first" ]
  run bash "$PORTFOLIO" --ready
  [ "$status" -eq 0 ]
  [ "$output" == "$first" ]
}

@test "portfolio: --ready writes nothing" {
  _ready_config
  before="$(_hashes "$R")"
  [ -n "$before" ]
  run bash "$PORTFOLIO" --ready
  [ "$status" -eq 0 ]
  [ ! -e "$DA_HOME/portfolio" ]
  [ "$(_hashes "$R")" = "$before" ]
}

@test "portfolio: --ready with --out is a usage error" {
  _ready_config
  run bash "$PORTFOLIO" --ready --out "$T/x.json"
  [ "$status" -eq 2 ]
  [[ "$output" == *"--ready writes no document; drop --out"* ]]
  run bash "$PORTFOLIO" --out "$T/x.json" --ready
  [ "$status" -eq 2 ]
  [[ "$output" == *"--ready writes no document; drop --out"* ]]
  [ ! -e "$T/x.json" ]
  [ ! -e "$DA_HOME/portfolio" ]
}

@test "portfolio: --ready=1 is an unknown flag" {
  run bash "$PORTFOLIO" --ready=1
  [ "$status" -eq 2 ]
  [[ "$output" == *"unknown flag '--ready=1'"* ]]
}

@test "portfolio: --ready over the multi fixture lists its ready leaves" {
  local p
  run --separate-stderr bash "$PORTFOLIO" --ready
  echo "$output"
  echo "stderr: $stderr"
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | wc -l)" -eq 13 ]   # #963: plant-issue5 (unreadable STUCK) is not ready
  [[ "$output" == *$'\n'"beta"$'\t'"Issue-1"$'\t'"3h"$'\t'"Adopt the schema plant-beta-issue1"* ]]
  [[ "$output" != *"rdy-"* ]]
  for p in gamma delta epsilon zeta eta iota; do
    [[ "$stderr" == *"portfolio: $p: not read ("* ]]
  done
  [[ "$stderr" != *"portfolio: alpha:"* ]]
}

@test "portfolio: --ready empty fields split with cut" {
  _ready_config
  run bash "$PORTFOLIO" --ready
  [ "$status" -eq 0 ]
  line="$(printf '%s\n' "$output" | grep 'rdy-noissue')"
  [ -n "$line" ]
  [ "$(printf '%s\n' "$line" | cut -f1)" = "rho" ]
  [ -z "$(printf '%s\n' "$line" | cut -f2)" ]
  [ "$(printf '%s\n' "$line" | cut -f3)" = "?w" ]
  [ "$(printf '%s\n' "$line" | cut -f4)" = "No issue rdy-noissue" ]
}

# --- models (#890) ---------------------------------------------------------------

_models_config() {
  M="$T/models"
  cp -R "$FIX/models" "$M"
  cat > "$DA_HOME/config.toml" <<EOF
[project.nu]
devdoc_dir = "$M/nu"

[project.nu.step_models]
thinking = "sonnet"
"9" = "fable"

[project.xi]
devdoc_dir = "$M/xi"

[project.xi.step_models]
default = "haiku"

[project.omicron]
devdoc_dir = "$M/omicron"

[project.omicron.step_models]
thinking = "gpt"
default = "opus"
EOF
}

# _bare <project>: a _q expression for that project's Bare leaf's models.
_bare() {
  printf 'next(n for p in d["projects"] if p["project"] == "%s" for n in p["nodes"] if n["text"] == "Bare")["models"]' "$1"
}

@test "portfolio: step_models reach the models field through config.sh (#890)" {
  _models_config
  local out="$T/p.json"
  run bash "$PORTFOLIO" --out "$out"
  echo "$output"
  [ "$status" -eq 0 ]
  run python3 "$PLUGIN_ROOT/scripts/lib/portfolio-check.py" "$out"
  [ "$status" -eq 0 ]
  [ "$(_q "$out" "$(_bare nu)"'["thinking"] == {"value": "sonnet", "source": "project"}')" = True ]
  [ "$(_q "$out" "$(_bare nu)"'["checking"] is None')" = True ]
  [ "$(_q "$out" "$(_bare xi)"' == {c: {"value": "haiku", "source": "project"} for c in ("thinking", "checking")}')" = True ]
  [ "$(_q "$out" "$(_bare omicron)"'["thinking"] is None')" = True ]
  [ "$(_q "$out" 'sum(1 for r in d["parse_report"] if r["project"] == "omicron" and r["kind"] == "bad_model")')" = 1 ]
}

@test "portfolio: a table-valued step_models key gives null and one bad_model, silently (#890)" {
  _models_config
  local value out="$T/p.json" count=0
  # a table, then an array of tables: _toml.py get exits 1 on both
  for value in '{model = "opus"}' '[{model = "opus"}]'; do
    printf '[project.nu]\ndevdoc_dir = "%s"\n\n[project.nu.step_models]\nthinking = %s\ndefault = "sonnet"\n' \
      "$M/nu" "$value" > "$DA_HOME/config.toml"
    run --separate-stderr bash "$PORTFOLIO" --out "$out"
    [ "$status" -eq 0 ]
    [ -z "$stderr" ]
    [ "$(_q "$out" "$(_bare nu)"'["thinking"] is None')" = True ]
    [ "$(_q "$out" "$(_bare nu)"'["checking"] == {"value": "sonnet", "source": "project"}')" = True ]
    [ "$(_q "$out" '[r["message"].split(" is ")[0] for r in d["parse_report"] if r["kind"] == "bad_model"]')" = "['step_models.thinking \"<unreadable>\"']" ]
    count=$((count + 1))
  done
  [ "$count" -eq 2 ]
}

# _tier_value <project> <step>: step_models_tier's answer as a value:
# rc 0 its stdout, rc 2 inherit, rc 3 none.
_tier_value() {
  local v rc
  v="$(step_models_tier "$1" "$2" 2>/dev/null)" && rc=0 || rc=$?
  case "$rc" in
    0) printf '%s\n' "$v" ;;
    2) echo inherit ;;
    3) echo none ;;
    *) echo "rc$rc" ;;
  esac
}

# _model_value <doc> <project index> <class>: that project's one leaf's
# models.<class> value, or none.
_model_value() {
  _q "$1" "(lambda m: 'none' if m is None else m['value'])(next(n for n in d['projects'][$2]['nodes'] if n['leaf'])['models']['$3'])" | tr -d '\r'
}

@test "portfolio: the models project rung agrees with step_models_tier (#890)" {
  source "$PLUGIN_ROOT/scripts/lib/paths.sh"
  source "$PLUGIN_ROOT/scripts/lib/io.sh"
  source "$PLUGIN_ROOT/scripts/lib/config.sh"
  local tables=('' 'thinking = "sonnet"' 'default = "haiku"'
                $'thinking = ""\ndefault = "opus"' $'checking = "fable"\ndefault = "haiku"'
                'thinking = "inherit"' $'"9" = "fable"\nthinking = "sonnet"')
  local i out="$T/p.json" count=0 want_t want_c got_t got_c
  mkdir -p "$T/one"
  printf '%s\n' '# p WBS' '' '- [ ] L {issue: Issue-1}' > "$T/one/WBS.md"
  # One project per table, so a single portfolio run covers every table.
  : > "$DA_HOME/config.toml"
  for i in "${!tables[@]}"; do
    printf '[project.p%s]\ndevdoc_dir = "%s"\n\n' "$i" "$T/one" >> "$DA_HOME/config.toml"
    [[ -z "${tables[i]}" ]] || printf '[project.p%s.step_models]\n%s\n\n' "$i" "${tables[i]}" >> "$DA_HOME/config.toml"
  done
  bash "$PORTFOLIO" --out "$out" > /dev/null
  for i in "${!tables[@]}"; do
    want_t="$(_tier_value "p$i" 2)"
    want_c="$(_tier_value "p$i" 5)"
    got_t="$(_model_value "$out" "$i" thinking)"
    got_c="$(_model_value "$out" "$i" checking)"
    echo "[${tables[i]}]: tier thinking=$want_t checking=$want_c; portfolio thinking=$got_t checking=$got_c"
    [ "$got_t" = "$want_t" ]
    [ "$got_c" = "$want_c" ]
    count=$((count + 1))
  done
  [ "$count" -eq 7 ]
}

# --- #735: actuals.json ------------------------------------------------------------

@test "portfolio: a missing actuals.json still writes, exit 0, one actuals_unavailable per project" {
  run bash "$PORTFOLIO" --out "$T/p.json"
  [ "$status" -eq 0 ]
  [ "$(_q "$T/p.json" 'sum(1 for r in d["parse_report"] if r["kind"] == "actuals_unavailable")')" -eq 9 ]
  [ "$(_q "$T/p.json" '[r["project"] for r in d["parse_report"] if r["kind"] == "actuals_unavailable"]')" = "['alpha', 'beta', 'gamma', 'delta', 'epsilon', 'zeta', 'eta', 'theta', 'iota']" ]
  [ "$(_q "$T/p.json" 'd["actuals"]')" = None ]
  [ "$(_q "$T/p.json" 'set(e["actuals"] for p in d["projects"] for e in p["issues"]) | set(p["actuals"] for p in d["projects"])')" = "{None}" ]
}

@test "portfolio: carries actuals built by actuals.sh" {
  export CLAUDE_CONFIG_DIR="$T/claude"
  mkdir -p "$CLAUDE_CONFIG_DIR/projects"
  python3 - "$T/A" <<'PY'
import gzip, json, sys
from pathlib import Path
p = Path(sys.argv[1]) / "h1" / "-w-alpha" / "S1.jsonl.gz"
p.parent.mkdir(parents=True)
recs = [{"type": "assistant", "message": {"id": "d1", "content": [{"type": "tool_use", "id": "n1", "name": "Bash",
         "input": {"command": 'bash "x/scripts/next.sh" alpha --auto'}}]}},
        {"type": "user", "message": {"content": [{"type": "tool_result", "tool_use_id": "n1",
         "content": "dispatch: alpha/Issue-1 \u2014 step 9 (implement), skill-backed"}]}},
        {"type": "assistant", "message": {"id": "m1", "model": "claude-a", "content": [],
         "usage": {"input_tokens": 7, "output_tokens": 1}}}]
p.write_bytes(gzip.compress("".join(json.dumps(r) + "\n" for r in recs).encode(), mtime=0))
PY
  run bash "$PLUGIN_ROOT/scripts/actuals.sh" --archive "$T/A"
  [ "$status" -eq 0 ]
  [[ "$output" == *"actuals: wrote $DA_HOME/actuals.json ("* ]]
  run bash "$PORTFOLIO" --out "$T/p.json"
  [ "$status" -eq 0 ]
  local slot row
  slot="$(_q "$T/p.json" 'json.dumps(next(e for p in d["projects"] if p["project"] == "alpha" for e in p["issues"] if e["issue"] == "Issue-1")["actuals"], sort_keys=True)')"
  row="$(_q "$DA_HOME/actuals.json" 'json.dumps(next(r for r in d["issues"] if (r["project"], r["issue"]) == ("alpha", "Issue-1"))["actuals"], sort_keys=True)')"
  [ "$slot" = "$row" ]
  [[ "$slot" == *'"total": 12.0'* ]]
  [ "$(_q "$T/p.json" 'sum(1 for r in d["parse_report"] if r["kind"] == "actuals_unavailable")')" -eq 0 ]
  [ "$(_q "$T/p.json" 'd["actuals"]["actuals_version"]')" = "1.0" ]
}

# --- #963: devagent state, parked and stuck.kind ---------------------------------

# _state_config: one project `p` whose WBS has Held (Issue-1, a question
# STUCK), Parked (Issue-2), Plain (Issue-3, a STUCK with no Kind:), Free
# (Issue-4), Also (Issue-5) and Loose (no issue). Sets P and SF (its state).
_state_config() {
  P="$T/st/p"
  mkdir -p "$P"/Issue-{1,2,3,4,5}
  printf '%s\n' '# p' '' '- [ ] Held {issue: Issue-1}' '- [ ] Parked {issue: Issue-2}' \
    '- [ ] Plain {issue: Issue-3}' '- [ ] Free {issue: Issue-4}' '- [ ] Also {issue: Issue-5}' \
    '- [ ] Loose' > "$P/WBS.md"
  printf '%s\n' 'Kind:        question' 'Step:        5 improve' '' '## Question' '' 'q?' > "$P/Issue-1/STUCK"
  printf '%s\n' 'Step:        5 improve' 'Reason:      r' > "$P/Issue-3/STUCK"
  printf '[project.p]\ndevdoc_dir = "%s"\n' "$P" > "$DA_HOME/config.toml"
  SF="$DA_HOME/state/p.toml"
  mkdir -p "$DA_HOME/state"
}

# _entries <doc>: `issue parked kind` per IssueEntry.
_entries() {
  python3 -c 'import json, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
for e in d["projects"][0]["issues"]:
    k = None if e["stuck"] is None else e["stuck"]["kind"]
    print(e["issue"], json.dumps(e["parked"]), json.dumps(k))' "$1"
}

# _lines_of <issue> <text> ...: the --ready lines of project p.
_lines_of() { printf 'p\t%s\t\t%s\n' "$@"; }

@test "portfolio: --ready leaves out a held, a parked and a stuck issue and still lists the free one" {
  _state_config
  printf '%s\n' 'active_issue = "Issue-9"' '' '[parked]' 'Issue-2 = "operator"' 'Issue-5 = "waiting on #1"' > "$SF"
  run --separate-stderr bash "$PORTFOLIO" --ready
  [ "$status" -eq 0 ] || { echo "rc=$status err=$stderr" >&2; return 1; }
  [ "$output" = "$(_lines_of Issue-4 Free '' Loose)" ]
  [ -z "$stderr" ]
  run bash "$PORTFOLIO" --out "$T/doc.json"
  [ "$status" -eq 0 ]
  [ "$(_entries "$T/doc.json")" = "$(printf '%s\n' 'Issue-1 false "question"' 'Issue-2 true null' \
      'Issue-3 false "stuck"' 'Issue-4 false null' 'Issue-5 true null')" ]
  run python3 "$PLUGIN_ROOT/scripts/lib/portfolio-check.py" "$T/doc.json"
  [ "$status" -eq 0 ]
}

@test "portfolio: a state file with no [parked] table offers its ready leaves with parked false" {
  _state_config
  rm "$P/Issue-1/STUCK" "$P/Issue-3/STUCK"
  printf '%s\n' 'active_issue = "Issue-9"' > "$SF"
  run --separate-stderr bash "$PORTFOLIO" --ready
  [ "$status" -eq 0 ]
  [ "$output" = "$(_lines_of Issue-1 Held Issue-2 Parked Issue-3 Plain Issue-4 Free Issue-5 Also '' Loose)" ]
  run bash "$PORTFOLIO" --out "$T/doc.json"
  [ "$status" -eq 0 ]
  [ "$(_entries "$T/doc.json" | awk '{print $2}' | sort -u)" = false ]
}

@test "portfolio: a project with no state file behaves like one with no parked issues" {
  _state_config
  rm "$P/Issue-1/STUCK" "$P/Issue-3/STUCK"
  [ ! -e "$SF" ]
  run --separate-stderr bash "$PORTFOLIO" --ready
  [ "$status" -eq 0 ]
  [ "$output" = "$(_lines_of Issue-1 Held Issue-2 Parked Issue-3 Plain Issue-4 Free Issue-5 Also '' Loose)" ]
  [ -z "$stderr" ]
  run bash "$PORTFOLIO" --out "$T/doc.json"
  [ "$status" -eq 0 ]
  [ "$(_entries "$T/doc.json" | awk '{print $2}' | sort -u)" = false ]
  [ "$(_q "$T/doc.json" 'len([r for r in d["parse_report"] if r["kind"] == "state_unreadable"])')" = 0 ]
}

# _fails_closed: the unreadable-state verdict on _state_config's project.
_fails_closed() {
  run --separate-stderr bash "$PORTFOLIO" --ready
  [ "$status" -eq 0 ] || { echo "rc=$status err=$stderr" >&2; return 1; }
  [ "$output" = "$(_lines_of '' Loose)" ]
  [ "$stderr" = "portfolio: p: devagent state could not be read; leaves with an issue are not listed" ]
  run bash "$PORTFOLIO" --out "$T/doc.json"
  [ "$status" -eq 0 ]
  [ "$(_entries "$T/doc.json" | awk '{print $2}' | sort -u)" = null ]
  [ "$(_q "$T/doc.json" '[(r["source_line"], r["message"]) for r in d["parse_report"] if r["kind"] == "state_unreadable"]')" \
    = "[(None, 'devagent state could not be read; its issues have parked: null and its leaves with an issue are not ready')]" ]
  ! grep -qF "$SF" "$T/doc.json" || false
  ! grep -qF '.toml' "$T/doc.json"
}

@test "portfolio: an unparseable state file fails closed" {
  _state_config
  printf 'x = [\n' > "$SF"
  _fails_closed
}

@test "portfolio: a parked that is not a table fails closed" {
  _state_config
  printf 'parked = true\n' > "$SF"
  _fails_closed
}

# The Python kind, through the document's own reader (read_stuck); null when
# the STUCK could not be read, as the document records it.
PY_KIND='
import importlib.util, sys
spec = importlib.util.spec_from_file_location("portfolio", sys.argv[1])
pf = importlib.util.module_from_spec(spec); sys.modules["portfolio"] = pf
spec.loader.exec_module(pf)
try:
    print(pf.read_stuck(sys.argv[2])["kind"])
except pf.StuckError:
    print("null")
'

@test "portfolio: stuck kind agrees with stuck_kind on the shared fixtures" {
  source "$PLUGIN_ROOT/scripts/lib/paths.sh"
  source "$PLUGIN_ROOT/scripts/lib/io.sh"
  source "$PLUGIN_ROOT/scripts/lib/checklist.sh"
  local w="$BATS_TEST_TMPDIR/kinds" bad="$BATS_TEST_TMPDIR/bad" d b p count=0
  mkdir -p "$w"/{none,body,crlf,lf,unknown,empty,h2,held} "$bad"
  printf 'Step: 5 improve\nReason: r\n' > "$w/none/STUCK"
  printf 'Step: 5 improve\n\n## Note\n\nKind: question\n' > "$w/body/STUCK"
  printf 'Kind: question\r\nStep: 5 improve\r\n\r\nKind: x\r\n' > "$w/crlf/STUCK"
  printf 'Kind: question\nStep: 5 improve\n\nKind: x\n' > "$w/lf/STUCK"
  printf 'Kind: brand-new\nStep: 5 improve\n' > "$w/unknown/STUCK"
  printf 'Kind:\nStep: 5 improve\n' > "$w/empty/STUCK"
  printf 'Step: 5 improve\n## Question\nKind: question\n' > "$w/h2/STUCK"
  [[ "$(od -c "$w/crlf/STUCK" | tr -s ' ')" == *'\r \n'* ]]
  # The eighth: a STUCK written by a real hold (#962).
  ( source "$BATS_TEST_DIRNAME/lib/hold-fixture.bash"
    _toy
    _q "$BATS_TEST_TMPDIR/q.md"
    DEVAGENT_UNATTENDED=1 "$PLUGIN_ROOT/scripts/hold.sh" toy Issue-7 --step improve --reason r \
      --question-file "$BATS_TEST_TMPDIR/q.md" >/dev/null 2>&1
    cp "$D/STUCK" "$w/held/STUCK" )
  [ "$(head -1 "$w/held/STUCK")" = "Kind:        question" ]
  for d in "$w"/*/; do
    d="${d%/}"
    b="$(stuck_kind "$d")"
    p="$(python3 -c "$PY_KIND" "$PLUGIN_ROOT/scripts/lib/portfolio.py" "$d/STUCK" | tr -d '\r')"
    echo "${d##*/}: bash=[$b] python=[$p]"
    [[ "$b" == "$p" ]]
    count=$((count + 1))
  done
  [ "$count" -eq 8 ]
  [ "$(stuck_kind "$w/crlf")" = "$(stuck_kind "$w/lf")" ]
  [ "$(stuck_kind "$w/crlf")" = question ]
  [ "$(stuck_kind "$w/body")" = stuck ]
  # Stated difference: a STUCK that is not valid UTF-8 reads a kind in bash and
  # `kind: null` in the document ("could not be read").
  printf 'Kind: question\n\xff\n' > "$bad/STUCK"
  [ "$(stuck_kind "$bad")" = question ]
  [ "$(python3 -c "$PY_KIND" "$PLUGIN_ROOT/scripts/lib/portfolio.py" "$bad/STUCK")" = null ]
}
