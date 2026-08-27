#!/usr/bin/env bats
# #572: the resolver-scope triage table is a CONTRACT enumerated in two homes —
# the doc and the scripts. One sweep test over both (register: Issue-458).

. "${BATS_TEST_DIRNAME}/lib/hermetic-env.bash"

REPO="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
DOC="$REPO/docs/resolver-scope-triage.md"

_universe() {
  ( cd "$REPO" && grep -rln 'active_resolve_project' scripts/ \
      | grep -v '^scripts/lib/active.sh$' \
      | grep -v '^scripts/wbs.sh$' \
      | sed 's|^scripts/||' | sort )
}
_rows() {
  # rows look like: | `born-red.sh` | PROTECTED | ... | validates | ... |
  sed -n 's/^| *`\([a-z0-9-]*\.sh\)` *|.*/\1/p' "$DOC" | sort
}

@test "triage table lists exactly the 18 resolving scripts (#572 AC1)" {
  [ -f "$DOC" ]
  [ "$(_universe | wc -l)" -eq 18 ]
  diff <(_universe) <(_rows)
}

@test "every PROTECTED row's script calls active_guard_scope; no EXEMPT row does (#572)" {
  [ -f "$DOC" ]
  local checked=0
  while IFS='|' read -r _ script class _rest; do
    script="$(echo "$script" | tr -d ' \`')"
    class="$(echo "$class" | tr -d ' ')"
    [ -n "$script" ] || continue
    case "$class" in
      PROTECTED) run grep -c 'active_guard_scope' "$REPO/scripts/$script"
                 [ "$status" -eq 0 ]
                 [ "$output" -ge 1 ]
                 checked=$((checked + 1)) ;;
      EXEMPT)    run grep -c 'active_guard_scope' "$REPO/scripts/$script"
                 [ "$status" -ne 0 ]
                 checked=$((checked + 1)) ;;
    esac
  done < <(sed -n '/^| *`[a-z0-9-]*\.sh` *|/p' "$DOC")
  # floor guard (register: Issue-151 — count what the assertions ran against)
  [ "$checked" -eq 18 ]
}

@test "every row records a config_is_project validation status (#572 AC1)" {
  [ -f "$DOC" ]
  run bash -c "sed -n '/^| *\`[a-z0-9-]*\.sh\` *|/p' '$DOC' | grep -cE 'validates|no-validation'"
  [ "$output" -eq 18 ]
}
