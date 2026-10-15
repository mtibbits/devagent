#!/usr/bin/env bats
#
# #706: `wbs init --from-tracker` seeds a fresh WBS.md from the project's
# tracker history. The tracker data is the synthesized fixture set that
# tests/fixtures/wbs-import/make-fixtures.py generates (its header is the
# provenance block). Real backends run over it: the gh-stub on PATH for
# GitHub, the fixture server for GitLab and Jira; gh/glab/curl shims log any
# other call to network.log, which teardown asserts absent.

REPO="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
. "$(dirname "$BATS_TEST_FILENAME")/lib/hermetic-env.bash"
. "$(dirname "$BATS_TEST_FILENAME")/helpers/wbs-tracker.bash"
load lib/fixture-server.sh

GEN="$REPO/tests/fixtures/wbs-import/make-fixtures.py"

setup() {
  TMPROOT="$(mktemp -d)"
  export TMPROOT
}

teardown() {
  if declare -F fixture_stop >/dev/null 2>&1; then fixture_stop; fi
  [ ! -e "$TMPROOT/network.log" ]
  rm -rf "$TMPROOT"
}

@test "fixtures: regenerating reproduces the committed bytes" {
  python3 "$GEN" "$TMPROOT/regen"
  local n=0 p
  while IFS= read -r p; do
    cmp "$TMPROOT/regen/$p" "$REPO/tests/fixtures/$p"
    n=$((n + 1))
  done < <(python3 "$GEN" --manifest)
  [ "$n" -eq 11 ]
}

@test "fixtures: no private project name appears in the import fixtures" {
  . "$REPO/scripts/lib/template_resolve.sh"
  local names files=() p name rc
  names="$(potholes_fixture_private_names "$REPO/tests/fixtures/private-project-names.txt")"
  [ -n "$names" ]
  while IFS= read -r p; do files+=("$REPO/tests/fixtures/$p"); done < <(python3 "$GEN" --manifest)
  files+=("$GEN")
  # control: a planted name is found, so rc 1 below means "no match"
  name="$(printf '%s\n' "$names" | head -1)"
  printf 'x %s y\n' "$name" > "$TMPROOT/planted"
  rc=0; grep -liwF -- "$name" "$TMPROOT/planted" "${files[@]}" >/dev/null || rc=$?
  [ "$rc" -eq 0 ]
  while IFS= read -r name; do
    rc=0; grep -liwF -- "$name" "${files[@]}" || rc=$?
    [ "$rc" -eq 1 ]
  done <<< "$names"
}
