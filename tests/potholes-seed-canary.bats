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

_lib()     { . "$REPO/scripts/lib/template_resolve.sh"; }
_names()   { _lib; potholes_fixture_private_names "$FX"; }     # the SAME parser doctor uses
_public()  { _lib; potholes_fixture_public "$FX"; }
_curated() { head -1 "$SEED" | grep -qE '^<!-- curated: ledger [0-9a-f]{7,40} -->'; }

@test "fixture list is well-formed: a public allowlist and at least one private name" {
  [ -n "$(_public)" ]
  [ "$(_names | wc -l)" -ge 1 ]
  [[ " $(_public) " == *" devagent "* ]]
}

@test "every listed private name already appeared in the repo BEFORE this change — the list is never a first disclosure (#611 red-team r2)" {
  # Measured at the merge base with the default branch, never at HEAD: a name
  # introduced by the same change cannot vouch for itself, and this file's own
  # literals never count as prior art.
  # A shallow or master-less clone (CI fetch-depth:1 on a PR ref) has no
  # origin/master: skip WITH the reason rather than die at status 128 — the
  # workflow checks out full history so this row is live there, not skipped.
  git -C "$REPO" rev-parse --verify -q 'origin/master^{commit}' >/dev/null \
    || skip "origin/master is not resolvable in this clone (shallow / no default-branch ref) — the disclosure guard needs the merge base"
  base="$(cd "$REPO" && git merge-base HEAD origin/master 2>/dev/null)" || base="$(git -C "$REPO" rev-parse origin/master)"
  mapfile -t names < <(_names)
  for n in "${names[@]}"; do
    hits="$(cd "$REPO" && git grep -Iliw -- "$n" "$base" -- . ':(exclude)tests/fixtures/private-project-names.txt' ':(exclude)tests/potholes-seed-canary.bats' | wc -l)"
    [ "$hits" -ge 1 ] || { echo "'$n' is absent from the repo at merge-base $base — it would be a first disclosure; remove it" >&2; return 1; }
  done
}

@test "predicate FAILS (rc 2), never 'clean', on an unreadable seed" {
  _lib
  run potholes_private_name_hits "$BATS_TEST_TMPDIR/does-not-exist.md" zzqAcme
  [ "$status" -eq 2 ]
}

@test "control: the predicate FIRES on a planted private citation and a bare word; the public allowlist is enforced by the caller" {
  _lib
  planted="$BATS_TEST_TMPDIR/seed.md"
  # Synthesised names: the control must not spell a real private name (this
  # file would then be prior art for the disclosure guard above).
  printf '%s\n' '- x (ZzqAcme Issue-3).' '- a zzqarmada of ships (Issue-4).' '- y (devagent Issue-5).' > "$planted"
  run potholes_private_name_hits "$planted" zzqAcme zzqarmada
  [ "$status" -eq 1 ]
  [[ "$output" == *"zzqAcme citations=1"* ]]
  [[ "$output" == *"zzqarmada citations=0 words=1"* ]]
  run potholes_private_name_hits "$planted" zzqnowhere    # silent on a name the file does not carry
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

@test "seed: no section exceeds POTHOLES_SECTION_CAP (gated: skipped until the seed is curated by the distribute issue)" {
  _curated || skip "seed line 1 lacks the '<!-- curated: ledger <sha> -->' marker — the distribute capture owns consolidating the backlog"
  _lib
  over=(); while read -r h; do
    n="$(potholes_section_count "$SEED" "$h")"; [ "$n" -le "$POTHOLES_SECTION_CAP" ] || over+=("$n $h")
  done < <(grep '^## ' "$SEED")
  [ "${#over[@]}" -eq 0 ] || { printf '%s\n' "${over[@]}" >&2; false; }
}

@test "gate condition is still true for the cap row: seed uncurated AND at least one section is over the cap today (flip both when distribute lands)" {
  run _curated
  [ "$status" -ne 0 ]
  _lib
  over=0; while read -r h; do
    [ "$(potholes_section_count "$SEED" "$h")" -le "$POTHOLES_SECTION_CAP" ] || over=1
  done < <(grep '^## ' "$SEED")
  [ "$over" -eq 1 ]                                       # the gated row WOULD fail today — it is not vacuous
}
