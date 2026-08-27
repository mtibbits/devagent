#!/usr/bin/env bats
# #530 Part A: dispatch-lint.sh rejects the ELISION shape class — a checker
# report relayed through another model session (not file-carried, #458) comes
# back truncated. Two named deterministic shapes: (1) an elision/omission MARKER
# line outside a code fence; (2) a body padded to clear a line count with < 5
# DISTINCT substantive lines. The archived #458 specimen is the ground-truth
# member. Born-red was proven at implementation: the origin/master (ead26c1)
# lint ACCEPTS all three reject fixtures (recorded in actualWork.md); the shipped
# suite asserts the fixed behavior below, and includes the ACCEPT regression that
# guards against false-positives on legitimate terse artifacts (the floor is
# UNCONDITIONAL — it gates every carrier, including improve/review/redmr).

. "${BATS_TEST_DIRNAME}/lib/hermetic-env.bash"

REPO="${BATS_TEST_DIRNAME}/.."
LINT="$REPO/scripts/dispatch-lint.sh"
FX="$REPO/tests/fixtures/dispatch-lint"

# Hermetic: never inherit an env pin (Issue-458 — ad-hoc runs in a pinned
# session are inadmissible; a bats run under run-suite is already clean, this is
# belt-and-suspenders for a direct invocation).
_lint() { run env -u DEVAGENT_ACTIVE_ISSUE DEVAGENT_ROOT="$REPO" bash "$LINT" "$@"; }

# --- REJECT: Shape 1 (elision-marker line) ---

@test "rejects the archived #458 relay-elided specimen (Shape 1) (#530)" {
  _lint "$FX/reject-specimen.md" subagent --class preship
  [ "$status" -ne 0 ]
  [[ "$output" == *"elision/relay marker"* ]]
}

@test "rejects a synthetic elision-marker member ([truncated] line) (#530)" {
  _lint "$FX/reject-synthetic-marker.md" subagent --class preship
  [ "$status" -ne 0 ]
  [[ "$output" == *"elision/relay marker"* ]]
}

# --- REJECT: Shape 2 (low distinct substance) ---

@test "rejects a synthetic low-distinct-substance member (padded) (#530)" {
  _lint "$FX/reject-synthetic-low-distinct.md" subagent --class preship
  [ "$status" -ne 0 ]
  [[ "$output" == *"distinct substantive lines"* ]]
}

# --- ACCEPT regression: legitimate artifacts must still pass (every carrier) ---

@test "accepts a legitimate multi-line preship report (#530)" {
  _lint "$FX/accept-preship.md" subagent --class preship
  [ "$status" -eq 0 ]
}

@test "accepts a terse improve-class artifact (no --class) (#530)" {
  _lint "$FX/accept-improve.md" subagent
  [ "$status" -eq 0 ]
}

@test "accepts a terse redmr-class artifact (house count line) (#530)" {
  _lint "$FX/accept-redmr.md" subagent --class redmr
  [ "$status" -eq 0 ]
}

@test "accepts a report with a standalone ellipsis INSIDE a code fence (#530)" {
  # The checker's own quotation of an elided hunk — not a relay truncation.
  _lint "$FX/accept-fenced-ellipsis.md" subagent --class review
  [ "$status" -eq 0 ]
}

# --- Guard the shape discrimination directly (not just via fixtures) ---

@test "a bare '...' line outside a fence is rejected; the same inside a fence is not (#530)" {
  fenced="$(mktemp)"; bare="$(mktemp)"
  printf 'context: subagent\nmodel: opus\n\nalpha\nbeta\ngamma\ndelta\nepsilon\n```\n...\n```\nVerdict: PASS\n' > "$fenced"
  printf 'context: subagent\nmodel: opus\n\nalpha\nbeta\ngamma\ndelta\nepsilon\n...\nVerdict: PASS\n' > "$bare"
  run env -u DEVAGENT_ACTIVE_ISSUE DEVAGENT_ROOT="$REPO" bash "$LINT" "$fenced" subagent --class preship
  local fenced_status="$status"
  run env -u DEVAGENT_ACTIVE_ISSUE DEVAGENT_ROOT="$REPO" bash "$LINT" "$bare" subagent --class preship
  local bare_status="$status"
  rm -f "$fenced" "$bare"
  [ "$fenced_status" -eq 0 ]      # fenced ellipsis: accepted
  [ "$bare_status" -ne 0 ]        # bare ellipsis: rejected
}

# --- mawk portability (#526): the awk pass must behave identically on mawk ---

@test "elision detection is mawk-safe (literal … + no regex backrefs) (#530/#526)" {
  command -v mawk >/dev/null || skip "mawk not installed"
  local tmpbin; tmpbin="$(mktemp -d)"; ln -sf "$(command -v mawk)" "$tmpbin/awk"
  # Rule-heavy body: 4 content lines + three horizontal rules. Rules must NOT
  # count as substance under mawk (the backref-free rule match), so a body with
  # < 5 distinct content lines rejects identically on gawk and mawk.
  local f; f="$(mktemp)"
  printf 'context: subagent\nmodel: opus\n\nalpha\n---\nbeta\n***\ngamma\n___\ndelta\n' > "$f"
  run env -u DEVAGENT_ACTIVE_ISSUE PATH="$tmpbin:$PATH" DEVAGENT_ROOT="$REPO" bash "$LINT" "$f" subagent --class preship
  local mawk_status="$status"
  run env -u DEVAGENT_ACTIVE_ISSUE DEVAGENT_ROOT="$REPO" bash "$LINT" "$f" subagent --class preship
  local gawk_status="$status"
  rm -rf "$f" "$tmpbin"
  [ "$mawk_status" -ne 0 ]                 # rejected (distinct=4 < 5)
  [ "$mawk_status" -eq "$gawk_status" ]    # and both awks agree
}
