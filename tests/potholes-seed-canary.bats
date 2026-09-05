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
# The gated rows: skip (never fail) on a pre-#613 seed so the marker row alone names the cause.
_gate()    { _curated || skip "seed line 1 lacks the '<!-- curated: ledger <sha> -->' marker (a pre-#613 seed)"; _lib; }

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

@test "seed carries no private project name (gated on the curated marker)" {
  _gate
  mapfile -t names < <(_names)
  run potholes_private_name_hits "$SEED" "${names[@]}"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "the seed IS curated (#613): line 1 is the '<!-- curated: ledger <sha> -->' marker, so every gated row above and below runs live" {
  _curated
}

@test "seed: no section exceeds POTHOLES_SECTION_CAP (gated on the curated marker)" {
  _gate
  over="$(_over_cap)"
  [ -z "$over" ] || { printf '%s\n' "$over" >&2; false; }
}

@test "seed: total bullets <= POTHOLES_SEED_TOTAL_CAP (gated on the curated marker)" {
  _gate
  n="$(grep -c '^- ' "$SEED")"; [ "$n" -le "$POTHOLES_SEED_TOTAL_CAP" ] || { echo "seed holds $n bullets (cap $POTHOLES_SEED_TOTAL_CAP)" >&2; false; }
}

@test "seed: privacy sweep — no fork-tracker token, home path, host or e-mail (gated); the planted control fires" {
  _gate
  run potholes_seed_sweep "$SEED"
  [ "$status" -eq 0 ]; [ -z "$output" ]
  printf '%s\n' '- a (Issue-Fork-3).' '- b /home/zzquser/x (Issue-4).' > "$BATS_TEST_TMPDIR/p.md"
  run potholes_seed_sweep "$BATS_TEST_TMPDIR/p.md"; [ "$status" -eq 1 ]; [ "${#lines[@]}" -eq 2 ]
}

# The operator's forge handles, DECLARED: the owner half of every code_source.fork /
# issue_source_fork.repo in the LIVE config — a property of who runs this box, stable
# across commits. Never $USER (a generic login such as "user" matches "user-facing"),
# never `git config user.email` (hermetic-env.bash nulls it — the limb was silently
# word-less, Issue-613 review I1), and never commit metadata (%ae drifts with every
# commit and a role local part — ci@, docs@, test@ — is ordinary seed prose, so the
# row reddened for a reason unrelated to the seed, Issue-613 redmr). No config (CI)
# ⇒ no words ⇒ the handle row skips WITH the reason; the fixed kinds run regardless.
_operator_words() {
  local cfg p f
  cfg="$(config_path 2>/dev/null)" && [ -f "$cfg" ] || return 0
  while IFS= read -r p; do
    for f in "$(config_get_project_field "$p" code_source.fork 2>/dev/null || true)" \
             "$(config_get_project_field "$p" issue_source_fork.repo 2>/dev/null || true)"; do
      [ -n "$f" ] && printf '%s\n' "${f%%/*}"
    done
  done < <(config_list_projects 2>/dev/null || true) | sort -u
}

@test "seed: privacy sweep — no operator forge handle (the fork owners the live config declares; gated); the planted control fires" {
  _gate
  mapfile -t words < <(_operator_words)
  [ "${#words[@]}" -gt 0 ] || skip "no fork owner declared in a live config (none here, e.g. CI) — the operator-handle limb has no word"
  run potholes_seed_sweep "$SEED" "${words[@]}"
  [ "$status" -eq 0 ]; [ -z "$output" ]
  printf '%s\n' "- a lesson by ${words[0]} about x (Issue-4)." > "$BATS_TEST_TMPDIR/p.md"
  run potholes_seed_sweep "$BATS_TEST_TMPDIR/p.md" "${words[@]}"; [ "$status" -eq 1 ]; [[ "$output" == *"word:${words[0]}:"* ]]
}

@test "seed passes the register file contract as the seed layer (gated) — bare devagent tokens only" {
  _gate
  run potholes_file_check seed "$SEED"; [ "$status" -eq 0 ]; [ -z "$output" ]
  # belt-and-braces over the CITATION TAIL only — a body parenthetical such as "(the Issue-586 rule)" is prose, not a token (Issue-613 redmr)
  run grep -cE "\\(([^)]*; )?${POTHOLES_PROJ_RE} ${POTHOLES_ISSUE_RE}(; [^)]*)?\\)\\.\$" "$SEED"; [ "$status" -eq 1 ]
}

@test "seed: every section heading of the pre-#613 register is still present (the union's --add targets live here)" {
  for h in 'Bash exit-status & control flow' 'Test discipline (born-red / vacuous pass)' 'State / TOML / atomicity' 'Git / ambient checkout / forge state' 'Sweeps / fix-at-source / sibling sites' 'New gate / shared-fixture blast radius' 'Dispatched fresh-context checking' 'Premise freshness / contracts / classification' 'Docs / edit-neighborhood hygiene' 'Version / registry-string comparison'; do
    grep -qxF -- "## $h" "$SEED" || { echo "missing heading: ## $h" >&2; false; }
  done
}
