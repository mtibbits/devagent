#!/usr/bin/env bash
# skill-fixture-check.sh — structural validator for devAgent SKILL.md files.
# Usage: skill-fixture-check.sh <skill-dir> <fixture-dir>
# Exit 0 if SKILL.md passes all structural checks; non-zero otherwise.

set -euo pipefail

skill_dir="${1:-}"
fixture_dir="${2:-}"

if [[ -z "$skill_dir" || -z "$fixture_dir" ]]; then
  echo "usage: $0 <skill-dir> <fixture-dir>" >&2
  exit 64
fi

skill_md="$skill_dir/SKILL.md"

if [[ ! -f "$skill_md" ]]; then
  echo "SKILL.md not found at $skill_md" >&2
  exit 1
fi

# Extract frontmatter (between leading --- markers).
fm="$(awk '/^---$/{c++; next} c==1{print} c==2{exit}' "$skill_md")"

for field in name description; do
  if ! grep -qE "^${field}:[[:space:]]+\S" <<<"$fm"; then
    echo "frontmatter missing: ${field}" >&2
    exit 1
  fi
done

if ! grep -qE "^##[[:space:]]+Checklist" "$skill_md"; then
  echo "Checklist section missing" >&2
  exit 1
fi

if ! grep -qE "^##[[:space:]]+Halt" "$skill_md"; then
  echo "Halt section missing (no-auto-skip rule required)" >&2
  exit 1
fi

if ! grep -q "checklist-log.sh" "$skill_md"; then
  echo "missing checklist-log invocation" >&2
  exit 1
fi

if [[ -d "$fixture_dir" ]]; then
  : # caller-specific fixture checks run in the bats test, not here
fi

exit 0
