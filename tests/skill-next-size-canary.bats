#!/usr/bin/env bats
# #439 size canary: next.md doubled in three weeks (2,961 → 5,659 chars,
# 06-18 → 07-10) before the thinning; the operative body of its successor
# (skills/next/SKILL.md) reloads on ~14 steps per --auto traversal, so silent
# regrowth is a per-issue token tax. Ceiling per #439's target. The floor is an
# ANTI-VACUOUS guard, not a contract guard: it catches a missing/emptied file
# (0 chars would otherwise satisfy the ceiling), but at a 1916-char body it only
# fires once ~58% of the text is gone. The contracts themselves are pinned by the
# #125/#116 literal greps in tests/command-usage-docs.bats.

REPO="${BATS_TEST_DIRNAME}/.."
SKILL="$REPO/skills/next/SKILL.md"

@test "skills/next/SKILL.md exists (#439 canary is not vacuous)" {
  [ -f "$SKILL" ]
}

@test "operative body (frontmatter-stripped) is 800..2000 chars (#439)" {
  # Body-side complement of the frontmatter extractor idiom in
  # tests/lib/skill-fixture-check.sh (`next` skips the --- delimiters).
  body_chars="$(awk '/^---$/{c++; next} c>=2{print}' "$SKILL" | wc -c)"
  echo "body_chars=$body_chars" >&2
  [ "$body_chars" -le 2000 ]
  [ "$body_chars" -ge 800 ]
}
