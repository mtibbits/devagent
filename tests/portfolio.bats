#!/usr/bin/env bats
# tests/portfolio.bats — #726: the portfolio command (scripts/portfolio.sh)
# and the bash/Python agreement of its checklist reader.

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
  [ "$(_q "$T/one.json" 'sorted(d)')" = "['generated_at', 'parse_report', 'projects', 'schema', 'schema_version']" ]
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

@test "portfolio: usage errors exit 2" {
  local args
  for args in "--bogus" "--out" "--out|" "--out=" "positional"; do
    IFS='|' read -r -a argv <<< "$args"
    [[ "$args" == "--out|" ]] && argv=(--out "")
    run bash "$PORTFOLIO" "${argv[@]}"
    echo "[$args] -> $status: $output"
    [ "$status" -eq 2 ]
    [[ "$output" == *"usage: portfolio.sh [--out PATH]"* ]]
  done
  run bash "$PORTFOLIO" --help
  [ "$status" -eq 0 ]
  [[ "$output" == "usage: portfolio.sh [--out PATH]"* ]]
  [ ! -e "$DA_HOME/portfolio" ]
}
