#!/usr/bin/env bash
# scripts/lib/flags.sh — `## Workflow flags` body-block parsing (#537).
#
# Grammar (pinned by the #535 research-step capture; this file is the first
# consumer and #535/#536 EXTEND it): one `key: value` pair per line; keys
# lowercase [a-z-]+; unknown keys are ignored by each consumer (forward
# compatibility); legal values are per-key. Parses ONLY the body segment of a
# fetched issue.md — everything before the `^## Comments (` heading — so a
# flags block quoted in a comment can never flip behavior.
#
# Source-only file: do not execute directly.

# flags_get <issue-md-path> <key> — print <key>'s value from the body's
# `## Workflow flags` block; empty + rc 1 when file/block/key is absent.
flags_get() {
  local file="$1" key="$2"
  [[ -f "$file" ]] || return 1
  awk -v key="$key" '
    /^## Comments \(/ { exit }
    /^## Workflow flags[[:space:]]*$/ { inblock=1; next }
    inblock && /^#/ { inblock=0 }
    inblock && index($0, key ":") == 1 {
      val = substr($0, length(key) + 2)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", val)
      print val; found = 1; exit
    }
    END { exit found ? 0 : 1 }
  ' "$file"
}

# tier_allowlist — the single source of legal `tier:` values (§6.3 tier
# table). simple/ultra are RESERVED names and deliberately absent.
# Note (#537 improve): flags_get is key-scoped and never enumerates the
# block, so the grammar's unknown-key WARN pass is deliberately deferred to
# #535's block-level validator — recorded, not reinterpreted.
tier_allowlist() { printf 'oneshot standard perf docs-only research'; }

# tier_is_legal <value>
tier_is_legal() {
  local t
  for t in $(tier_allowlist); do
    [[ "${1:-}" == "$t" ]] && return 0
  done
  return 1
}
