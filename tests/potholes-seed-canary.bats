#!/usr/bin/env bats
# #611: the shipped seed must not carry private project names. Born RED today
# (104 citations at 54349ef), so the canary is gated by the `<!-- curated: ledger
# <sha> -->` marker the distribute capture will write on line 1; the sibling test
# asserts the gate condition is still true, so the row is never a permanently
# skipped vacuous one, and a planted control proves the predicate can fire.
. "${BATS_TEST_DIRNAME}/lib/hermetic-env.bash"
REPO="${BATS_TEST_DIRNAME}/.."
SEED="$REPO/templates/potholes.md"
FX="$REPO/tests/fixtures/private-project-names.txt"

_names()   { grep -v '^#' "$FX" | sed '/^[[:space:]]*$/d'; }
_public()  { sed -n 's/^# public: *//p' "$FX"; }
_curated() { head -1 "$SEED" | grep -qE '^<!-- curated: ledger [0-9a-f]{7,40} -->'; }
_lib()     { . "$REPO/scripts/lib/template_resolve.sh"; }

@test "fixture list is well-formed: a public allowlist and at least one private name" {
  [ -n "$(_public)" ]
  [ "$(_names | wc -l)" -ge 1 ]
  [[ " $(_public) " == *" devagent "* ]]
}

@test "control: the predicate FIRES on a planted private citation and a bare word; the public allowlist is enforced by the caller" {
  _lib
  planted="$BATS_TEST_TMPDIR/seed.md"
  printf '%s\n' '- x (LawFirm Issue-3).' '- a fleet of ships (Issue-4).' '- y (devagent Issue-5).' > "$planted"
  run potholes_private_name_hits "$planted" lawFirm fleet
  [ "$status" -eq 1 ]
  [[ "$output" == *"lawFirm citations=1"* ]]
  [[ "$output" == *"fleet citations=0 words=1"* ]]
  run potholes_private_name_hits "$planted" lectio         # silent on a name the file does not carry
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  # the PUBLIC allowlist is the CALLER's filter, not the predicate's: _names never yields a public name
  for pub in $(_public); do run grep -qixF -- "$pub" <(_names); [ "$status" -eq 1 ]; done
}

@test "seed carries no private project name (gated: skipped until the seed is curated)" {
  _curated || skip "seed line 1 lacks the '<!-- curated: ledger <sha> -->' marker — the distribute capture owns moving the private citations"
  _lib
  mapfile -t names < <(_names)
  run potholes_private_name_hits "$SEED" "${names[@]}"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "gate condition is still true: the seed is NOT yet curated and still carries private citations (flip both when distribute lands)" {
  run _curated
  [ "$status" -ne 0 ]
  _lib
  mapfile -t names < <(_names)
  run potholes_private_name_hits "$SEED" "${names[@]}"
  [ "$status" -eq 1 ]
}
