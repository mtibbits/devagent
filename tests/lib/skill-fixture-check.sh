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

skill_kind="procedure"
# #458: a `context: fork` skill is a FORK PROMPT, not a procedure. The harness
# runs its body inside the bound agent, whose system prompt owns the checklist
# and whose invoking command owns the halt rules and logging — so the
# procedure-shaped requirements below do not apply to it. The exemption is not
# a hole: a fork prompt must name a bound agent that actually EXISTS and
# declares the matching name, which is the failure this class can suffer that a
# procedure skill cannot (a typo'd `agent:` silently falls back to
# general-purpose — no system prompt, no tool denial, no isolation).
if grep -qE '^context:[[:space:]]+fork[[:space:]]*$' <<<"$fm"; then
  agent_ref="$(grep -E '^agent:[[:space:]]+\S' <<<"$fm" | head -1 | sed -E 's/^agent:[[:space:]]+//; s/[[:space:]]+$//')"
  if [[ -z "$agent_ref" ]]; then
    echo "context: fork requires an 'agent:' binding (else it forks to general-purpose: no system prompt, no tool denial)" >&2
    exit 1
  fi
  # Plugin-scoped form `<plugin>:<agent>`; the leaf is the agent's name.
  agent_name="${agent_ref##*:}"
  agent_file="$skill_dir/../../agents/${agent_name}.md"
  if [[ ! -f "$agent_file" ]]; then
    echo "agent: ${agent_ref} names no agent file (looked for agents/${agent_name}.md)" >&2
    exit 1
  fi
  if ! grep -qE "^name:[[:space:]]+${agent_name}[[:space:]]*$" "$agent_file"; then
    echo "agents/${agent_name}.md does not declare 'name: ${agent_name}' (identity comes from frontmatter, not filename)" >&2
    exit 1
  fi
  skill_kind="fork"
fi

# Procedure-shaped requirements: a fork prompt has none of these — its checklist
# is the bound agent's system prompt, and the halt rules and logging belong to
# the invoking command. Everything AFTER this block is universal and applies to
# both kinds (the exemption is for the requirements that don't fit the kind, not
# a blanket pass).
if [[ "$skill_kind" != "fork" ]]; then
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
fi

# #131 (universal — applies to fork prompts too, which DO invoke scripts:
# core-redmr calls template.sh, core-preship calls state.sh): the cwd at
# invocation is the target project, so a bare relative scripts/<x>.sh misses.
# Every invocation must be plugin-root-prefixed.
# #131 (universal — both kinds): the cwd at invocation is the target project,
# so a bare relative scripts/… path misses. Two complementary guards:
#
# (a) checklist-log.sh in ANY form — the original guard, kept verbatim in scope.
if grep -nE 'scripts/checklist-log\.sh' "$skill_md" \
    | grep -vqE '\$\{CLAUDE_PLUGIN_ROOT\}/scripts/checklist-log\.sh'; then
  echo "checklist-log.sh invocation not prefixed with \${CLAUDE_PLUGIN_ROOT} (#131)" >&2
  exit 1
fi
#
# (b) any OTHER script INVOKED via bash. #458 fork prompts genuinely invoke
# scripts (core-redmr calls template.sh, core-preship calls state.sh), and the
# old guard only covered checklist-log — so the files most likely to grow new
# script calls were the ones it did not watch. Keyed on `bash …` so that prose
# merely NAMING a script (core-lessons-learned mentions `scripts/lessons-lint.sh`
# in a sentence) is not a false positive.
if grep -nE '\bbash[[:space:]]+"?[^"[:space:]]*scripts/[a-z0-9_-]+\.sh' "$skill_md" \
    | grep -vqE '\$\{CLAUDE_PLUGIN_ROOT\}/scripts/'; then
  echo "a scripts/*.sh invocation is not prefixed with \${CLAUDE_PLUGIN_ROOT} (#131)" >&2
  grep -nE '\bbash[[:space:]]+"?[^"[:space:]]*scripts/[a-z0-9_-]+\.sh' "$skill_md" \
    | grep -vE '\$\{CLAUDE_PLUGIN_ROOT\}/scripts/' >&2
  exit 1
fi

if [[ -d "$fixture_dir" ]]; then
  : # caller-specific fixture checks run in the bats test, not here
fi

exit 0
