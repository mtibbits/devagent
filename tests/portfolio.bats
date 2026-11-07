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
  if [[ "$n" == done ]]; then
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
