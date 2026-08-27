#!/usr/bin/env bats
# #531 size canary for the PER-INVOCATION prompt files — the agent definitions
# (agents/*.md), the checking-command wrappers (commands/{preship,redmr,improve}),
# and the converted user-facing skills (skills/{capture,ship}). Sibling of
# tests/skill-next-size-canary.bats, which guards skills/next/SKILL.md on the SAME
# frontmatter-stripped-body measure — that canary's 2,000/800 pins are NOT touched
# here (they carry next.md's proven-doubler history; see that file).
#
# Measure: frontmatter-stripped body chars, the EXACT next-canary idiom
#   awk '/^---$/{c++; next} c>=2{print}' | wc -c
# (the `;next` matters — without it the closing `---` falls through and every
# count is +4; #439 "state the basis, subtract like from like").
#
# Ceilings ≈ current + ~25% headroom; floors ≈ half of current (anti-hollowing).
# The headroom is deliberately LOOSER than the next canary's tight ~4% (2000 on a
# 1916 body): next.md is the proven-doubler with a known regrowth driver, so it
# earns a tight pin; these are stabler prompt bodies where a ~25% ceiling still
# catches doubling without flapping on ordinary edits. Numbers documented per
# file below (measured at baseline 090d1a5; tests-only, so identical at HEAD).
#
#   file                          body   floor  ceiling
#   agents/preship-verifier.md    5342   2600   6800
#   agents/redteam-reviewer.md    5407   2600   6800
#   agents/plan-improver.md       6130   3000   7700
#   commands/preship.md           5989   2900   7600
#   commands/redmr.md             6039   2900   7600
#   commands/improve.md           6228   3000   7800
#   skills/capture/SKILL.md       2553   1200   3300
#   skills/ship/SKILL.md          2249   1000   3000

. "${BATS_TEST_DIRNAME}/lib/hermetic-env.bash"

REPO="${BATS_TEST_DIRNAME}/.."

# file:floor:ceiling — the curated per-invocation list. agents/ entries are also
# completeness-guarded below (a NEW agent must join this list); commands/ and
# skills/ entries are curated (only the heavy per-invocation files qualify — most
# commands are thin, most skills are not per-invocation prompts).
_ROWS=(
  "agents/preship-verifier.md:2600:6800"
  "agents/redteam-reviewer.md:2600:6800"
  "agents/plan-improver.md:3000:7700"
  "commands/preship.md:2900:7600"
  "commands/redmr.md:2900:7600"
  "commands/improve.md:3000:7800"
  "skills/capture/SKILL.md:1200:3300"
  "skills/ship/SKILL.md:1000:3000"
)

_body_chars() { awk '/^---$/{c++; next} c>=2{print}' "$1" | wc -c; }

@test "every guarded per-invocation file exists (anti-vacuous, #439)" {
  for row in "${_ROWS[@]}"; do
    local f="${row%%:*}"
    [ -f "$REPO/$f" ] || { echo "missing guarded file: $f" >&2; return 1; }
  done
}

@test "each per-invocation body is within [floor, ceiling] chars (#531)" {
  local fail=0
  for row in "${_ROWS[@]}"; do
    local f="${row%%:*}"; local rest="${row#*:}"
    local floor="${rest%%:*}"; local ceiling="${rest#*:}"
    local n; n="$(_body_chars "$REPO/$f")"
    if [ "$n" -lt "$floor" ]; then
      echo "FLOOR: $f body=$n < $floor (hollowed out — did a section get lost?)" >&2; fail=1
    fi
    if [ "$n" -gt "$ceiling" ]; then
      echo "CEILING: $f body=$n > $ceiling (regrowth — thin it or raise the pin deliberately)" >&2; fail=1
    fi
  done
  [ "$fail" -eq 0 ]
}

@test "agents/*.md completeness: every agent is size-guarded (a NEW agent REDs, #439)" {
  # The enumerable subset: EVERY agents/*.md is a per-invocation prompt by
  # definition, so the list must cover all of them. A 4th agent that lands
  # without a row reds here — closing the silent-add hole (#448/#449/#450 class).
  local guarded=""
  for row in "${_ROWS[@]}"; do
    case "${row%%:*}" in agents/*) guarded="$guarded ${row%%:*}";; esac
  done
  local n_guarded; n_guarded="$(echo $guarded | wc -w)"
  local n_actual; n_actual="$(find "$REPO/agents" -maxdepth 1 -name '*.md' | wc -l)"
  [ "$n_actual" -eq "$n_guarded" ] || {
    echo "agents/*.md count=$n_actual but $n_guarded are size-guarded — add the new agent to _ROWS" >&2
    find "$REPO/agents" -maxdepth 1 -name '*.md' -printf '  %f\n' >&2; return 1; }
  local rel
  for a in "$REPO"/agents/*.md; do
    rel="agents/$(basename "$a")"
    [[ " $guarded " == *" $rel "* ]] || { echo "unguarded agent: $rel" >&2; return 1; }
  done
}
