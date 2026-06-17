#!/usr/bin/env bats
# core-draft-mr vs mr_template reconciliation (#128).
#
# The core-draft-mr skill's fill checklist must only instruct filling sections
# that actually exist in templates/mr_template.md, and it must mention the
# template's Related-issues / `Closes #NNN` auto-close mechanism (or shipped MRs
# never auto-close their issue). Pre-fix the skill told models to fill
# Motivation / Evidence / Reviewer notes (none in the template) and never
# mentioned Related issues.

REPO="${BATS_TEST_DIRNAME}/.."
SKILL="${REPO}/skills/core-draft-mr/SKILL.md"
TEMPLATE="${REPO}/templates/mr_template.md"

@test "every 'Fill <X> section' step names a section that exists in mr_template (#128)" {
  # Extract the section names the skill instructs filling.
  mapfile -t names < <(grep -oE '\*\*Fill [A-Za-z ]+ section' "$SKILL" \
    | sed -E 's/^\*\*Fill //; s/ section$//')
  [ "${#names[@]}" -ge 3 ]   # at least Summary / Related issues / Testing / Checklist
  local n
  for n in "${names[@]}"; do
    # Each filled section must be a real ## heading in the template.
    grep -qiE "^## ${n}\$" "$TEMPLATE"
  done
}

@test "skill mentions the Related-issues auto-close mechanism (#128)" {
  grep -q 'Related issues' "$SKILL"
  grep -q 'Closes #' "$SKILL"
}
