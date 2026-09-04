#!/usr/bin/env bats
# #613: the register FILE contract (potholes_file_check), the ledger key
# (potholes_line_sha1) and the seed privacy sweep (potholes_seed_sweep) — the
# reusable half of the Issue-613 migration, factored into scripts/lib/potholes.sh
# and called by promote-potholes.sh --apply on every temp copy (one predicate,
# Issue-585). Fixture: tests/fixtures/potholes-migration-register.md.
. "${BATS_TEST_DIRNAME}/lib/hermetic-env.bash"
REPO="${BATS_TEST_DIRNAME}/.."
FX="$REPO/tests/fixtures/potholes-migration-register.md"
setup() { . "$REPO/scripts/lib/template_resolve.sh"; T="$BATS_TEST_TMPDIR"; }
_file() { printf '%s\n' "$@" > "$T/f.md"; }

@test "floor: the three functions and the two constants exist in the lib (anti-vacuous, #572)" {
  type potholes_file_check potholes_line_sha1 potholes_seed_sweep >/dev/null
  [ "$POTHOLES_SEED_TOTAL_CAP" = 100 ]; [ -n "$POTHOLES_RETIRED_LINE_RE" ]
  [ "$(grep -c '^POTHOLES_SEED_TOTAL_CAP=' "$REPO/scripts/lib/potholes.sh")" -eq 1 ]   # defined once, column 0
}

@test "file_check: clean project and workflow layers pass silently (rc 0); fork tokens obey the same form rule" {
  _file '# R' '' '## A' '- x (Issue-1).' '- y (Issue-2; Issue-Fork-3).' '' '## B' '- z (Issue-4).'
  run potholes_file_check project "$T/f.md"; [ "$status" -eq 0 ]; [ -z "$output" ]
  run potholes_file_check seed "$T/f.md";    [ "$status" -eq 0 ]
  _file '# R' '' '## A' '- x (zzqp Issue-1; zzqq Issue-Fork-3).'
  run potholes_file_check workflow "$T/f.md"; [ "$status" -eq 0 ]; [ -z "$output" ]
}

@test "file_check: bullet immediately before a heading — line number + the phrase --apply's test pins" {
  _file '# R' '' '## A' '- x (Issue-1).' '## B' '- z (Issue-4).'
  run potholes_file_check project "$T/f.md"; [ "$status" -eq 1 ]
  [[ "$output" == *":5: bullet immediately before a ## heading"* ]]
}

@test "file_check: a citation-less bullet and the seed's mis-tokened shape are reported; the retokened form passes" {
  _file '# R' '' '## A' '- no citation here' '- (two sites: a and b — Issue-11).'
  run potholes_file_check project "$T/f.md"; [ "$status" -eq 1 ]
  [[ "$output" == *":4: bullet does not end in the citation grammar"* ]]
  [[ "$output" == *":5: bullet does not end in the citation grammar"* ]]
  _file '# R' '' '## A' '- (two sites: a and b) (Issue-11).'
  run potholes_file_check project "$T/f.md"; [ "$status" -eq 0 ]
}

@test "file_check: layer FORM — qualified token in a project/seed layer, bare token in the workflow layer; the reason is potholes_line_cite_ok's own string (one predicate)" {
  _file '# R' '' '## A' '- x (zzqp Issue-1).' '- f (Issue-Fork-2).'
  run potholes_file_check project "$T/f.md"; [ "$status" -eq 1 ]
  [[ "$output" == *":4: project-layer token 'zzqp Issue-1' must be bare 'Issue-N'"* ]]; [[ "$output" != *":5:"* ]]
  run potholes_file_check seed "$T/f.md"; [ "$status" -eq 1 ]; [[ "$output" == *"seed-layer token 'zzqp Issue-1' must be bare"* ]]
  run potholes_file_check workflow "$T/f.md"; [ "$status" -eq 1 ]
  [[ "$output" != *":4:"* ]]; [[ "$output" == *":5: workflow-layer token 'Issue-Fork-2' must be '<project> Issue-N'"* ]]
  # the same string from the other consumer, so a rewording reddens here instead of diverging (improve B2)
  run potholes_line_cite_ok zzqp Issue-1 workflow '- x (zzqp Issue-1; Issue-Fork-2).'; [ "$status" -eq 1 ]
  [[ "$output" == *"workflow-layer token 'Issue-Fork-2' must be '<project> Issue-N'"* ]]
  [ "$(potholes_layer_form workflow)" = "^${POTHOLES_PROJ_RE} ${POTHOLES_ISSUE_RE}\$" ]
  [ "$(grep -c 'form="^\${POTHOLES' "$REPO/scripts/lib/potholes.sh")" -eq 0 ]     # the case-statement copy is gone
}

@test "grammar alphabet (improve B3): N is [0-9]+ or Fork-[0-9]+, stated once in POTHOLES_ISSUE_RE — Issue-typoo and Issue-Fork-abc are not citations" {
  [ "$POTHOLES_ISSUE_RE" = 'Issue-(Fork-)?[0-9]+' ]
  _file '# R' '' '## A' '- a (Issue-typoo).' '- b (Issue-Fork-abc).' '- c (Issue--).' '- d (Issue-7).' '- e (Issue-Fork-7).'
  run potholes_file_check project "$T/f.md"; [ "$status" -eq 1 ]
  for n in 4 5 6; do [[ "$output" == *":$n: bullet does not end in the citation grammar"* ]]; done
  [[ "$output" != *":7:"* ]]; [[ "$output" != *":8:"* ]]
  run potholes_cite_tokens '- a (Issue-typoo).'; [ "$status" -eq 1 ]
}

@test "file_check: Retired region — a retired-shaped line outside it and a plain bullet inside it are both reported" {
  _file '# R' '' '## A' '- [A] r — mechanised by t (Issue-1; Issue-9).' '' '## Retired (mechanised)' '- plain (Issue-2).' '- [A] ok — mechanised by t (Issue-3; Issue-9).'
  run potholes_file_check project "$T/f.md"; [ "$status" -eq 1 ]
  [[ "$output" == *":4: retired-shaped line outside the Retired section"* ]]
  [[ "$output" == *":7: non-retired line inside the Retired section"* ]]; [[ "$output" != *":8:"* ]]
}

@test "file_check + line_sha1: a CRLF bullet is REFUSED (LF only); its LF-normalised sha1 equals the LF line's and sha1sum's" {
  printf '# R\n\n## A\n- x (Issue-1).\r\n' > "$T/f.md"
  run potholes_file_check project "$T/f.md"; [ "$status" -eq 1 ]; [[ "$output" == *":4: CR byte"* ]]
  [ "$(potholes_line_sha1 $'- x (Issue-1).\r')" = "$(potholes_line_sha1 '- x (Issue-1).')" ]
  [ "$(potholes_line_sha1 '- x (Issue-1).')" = "$(printf '%s' '- x (Issue-1).' | sha1sum | cut -d' ' -f1)" ]
}

@test "file_check: rc 2 — never 'clean' — on an unreadable file or an unknown layer (Issue-316)" {
  run potholes_file_check project "$T/nope.md"; [ "$status" -eq 2 ]
  _file '# R'; run potholes_file_check devdoc "$T/f.md"; [ "$status" -eq 2 ]
}

@test "file_check over the fixture register reports the mis-tokened line by number (the Issue-553 shape at scale)" {
  n="$(grep -n ' — Issue-11)\.$' "$FX" | cut -d: -f1)"; [ -n "$n" ]
  run potholes_file_check project "$FX"; [ "$status" -eq 1 ]
  [[ "$output" == *":$n: bullet does not end in the citation grammar"* ]]
}

@test "seed_sweep: silent on a clean file; fires once per kind on planted controls; rc 2 on an unreadable file" {
  _file '- fine, mentions a drive form /c/x and c:/y which are outside the universe (Issue-1).'
  run potholes_seed_sweep "$T/f.md" zzquser; [ "$status" -eq 0 ]; [ -z "$output" ]
  _file '- a (Issue-Fork-3).' '- b /home/zzquser/x (Issue-4).' '- c see https://x.example (Issue-5).' \
        '- d mail zzq@example.com (Issue-6).' '- e by ZZQUSER (Issue-7).' '- f box01.local (Issue-8).'
  run potholes_seed_sweep "$T/f.md" zzquser; [ "$status" -eq 1 ]
  [[ "$output" == *"1: fork:"* ]]; [[ "$output" == *"2: path:"* ]]; [[ "$output" == *"3: host:"* ]]
  [[ "$output" == *"4: email:"* ]]; [[ "$output" == *"5: word:zzquser:"* ]]; [[ "$output" == *"6: host:"* ]]
  run potholes_seed_sweep "$T/nope.md"; [ "$status" -eq 2 ]
}
