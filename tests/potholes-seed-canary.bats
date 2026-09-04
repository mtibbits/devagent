#!/usr/bin/env bats
# #611: the shipped seed must not carry private project names. Born RED at #611
# (104 citations at 54349ef), so the private-name and section-cap rows are gated by
# the `<!-- curated: ledger <sha> -->` marker on line 1; #613 curated the seed, so
# the gated rows run live and the sibling row asserts the marker instead of its
# absence. A planted control proves each predicate can fire. The #613 rows below
# (total cap, privacy sweep, file contract, headings) are gated the same way.
. "${BATS_TEST_DIRNAME}/lib/hermetic-env.bash"
REPO="${BATS_TEST_DIRNAME}/.."
SEED="$REPO/templates/potholes.md"
FX="$REPO/tests/fixtures/private-project-names.txt"

_lib()     { . "$REPO/scripts/lib/template_resolve.sh"; }
_names()   { _lib; potholes_fixture_private_names "$FX"; }     # the SAME parser doctor uses
_public()  { _lib; potholes_fixture_public "$FX"; }
# "<count> <heading>" per seed section over POTHOLES_SECTION_CAP (after _lib).
_over_cap() {
  local h n
  while read -r h; do
    n="$(potholes_section_count "$SEED" "$h")"; [ "$n" -le "$POTHOLES_SECTION_CAP" ] || echo "$n $h"
  done < <(grep '^## ' "$SEED")
}
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

@test "the seed IS curated (#613): line 1 is the '<!-- curated: ledger <sha> -->' marker, so every gated row above and below runs live" {
  _curated
  sha="$(head -1 "$SEED" | sed -E 's/^<!-- curated: ledger ([0-9a-f]+) -->$/\1/')"; [ "${#sha}" -ge 7 ]
}

@test "seed: no section exceeds POTHOLES_SECTION_CAP (gated: skipped until the seed is curated by the distribute issue)" {
  _curated || skip "seed line 1 lacks the '<!-- curated: ledger <sha> -->' marker — the distribute capture owns consolidating the backlog"
  _lib
  over="$(_over_cap)"
  [ -z "$over" ] || { printf '%s\n' "$over" >&2; false; }
}

@test "seed: total bullets <= POTHOLES_SEED_TOTAL_CAP (gated on the curated marker)" {
  _curated || skip "seed line 1 lacks the curated marker"
  _lib
  n="$(grep -c '^- ' "$SEED")"; [ "$n" -le "$POTHOLES_SEED_TOTAL_CAP" ] || { echo "seed holds $n bullets (cap $POTHOLES_SEED_TOTAL_CAP)" >&2; false; }
}

@test "seed: privacy sweep — no fork-tracker token, home path, host, e-mail or operator username (gated); the planted control fires" {
  _curated || skip "seed line 1 lacks the curated marker"
  _lib
  # the operator word is the git e-mail local part with a noreply numeric prefix stripped — never $USER
  # (a generic login such as "user" would match "user-facing"); empty in CI, where the four fixed kinds still run
  run potholes_seed_sweep "$SEED" "$(git config user.email 2>/dev/null | cut -d@ -f1 | sed 's/^[0-9]*+//')"
  [ "$status" -eq 0 ]; [ -z "$output" ]
  printf '%s\n' '- a (Issue-Fork-3).' '- b /home/zzquser/x (Issue-4).' > "$BATS_TEST_TMPDIR/p.md"
  run potholes_seed_sweep "$BATS_TEST_TMPDIR/p.md"; [ "$status" -eq 1 ]; [ "$(printf '%s\n' "$output" | wc -l)" -eq 2 ]
}

@test "seed passes the register file contract as the seed layer (gated) — bare devagent tokens only" {
  _curated || skip "seed line 1 lacks the curated marker"
  _lib
  run potholes_file_check seed "$SEED"; [ "$status" -eq 0 ]; [ -z "$output" ]
  run grep -cE '\([A-Za-z]+ Issue-' "$SEED"; [ "$status" -eq 1 ]     # no project-qualified token at all
}

@test "seed: every section heading of the pre-#613 register is still present (the union's --add targets live here)" {
  _lib
  for h in 'Bash exit-status & control flow' 'Test discipline (born-red / vacuous pass)' 'State / TOML / atomicity' 'Git / ambient checkout / forge state' 'Sweeps / fix-at-source / sibling sites' 'New gate / shared-fixture blast radius' 'Dispatched fresh-context checking' 'Premise freshness / contracts / classification' 'Docs / edit-neighborhood hygiene' 'Version / registry-string comparison'; do
    grep -qxF -- "## $h" "$SEED" || { echo "missing heading: ## $h" >&2; false; }
  done
}
