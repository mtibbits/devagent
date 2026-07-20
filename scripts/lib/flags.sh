#!/usr/bin/env bash
# scripts/lib/flags.sh — `## Workflow flags` body-block parsing (#537).
#
# Grammar (pinned by the #535 research-step capture; this file is the first
# consumer and #535/#536 EXTEND it): one `key: value` pair per line; keys
# lowercase [a-z-]+; the block is CONTIGUOUS — it ends at the next `#` heading, or at a
# blank line ONCE AT LEAST ONE KEY HAS BEEN SEEN, so col-1 prose further down the body
# can never be read as a flag (#535 review: a blank line + a col-1 `key: value` prose line
# otherwise MIS-FLIPPED) while the markdown-conventional `## Workflow flags` + blank line +
# keys form still parses (#535 redmr BLOCKING: terminating on the FIRST blank silently
# dropped every flag, regressing #537's shipped `tier:`);
# unknown keys are ignored by each consumer (forward
# compatibility); legal values are per-key. Value lines are BARE: trailing
# inline prose is part of the value and fails per-key validation downstream
# (fail-closed). Parses ONLY the body segment of a fetched issue.md —
# everything before the `^## Comments (` heading — so a flags block quoted
# in a tracker comment can never flip behavior. HTML-comment spans
# (`<!-- … -->`) are skipped entirely (the reap.sh/lessons-lint.sh
# incomment idiom): template boilerplate that quotes a flags block inside a
# comment is invisible in rendered markdown and must never parse as live
# config (#537 redmr BLOCKING).
#
# Source-only file: do not execute directly.

# flags_get <issue-md-path> <key> — print <key>'s value from the body's
# `## Workflow flags` block; empty + rc 1 when file/block/key is absent.
flags_get() {
  local file="$1" key="$2"
  [[ -f "$file" ]] || return 1
  awk -v key="$key" '
    /^## Comments \(/ { exit }
    /<!--/ { incomment = 1 }
    incomment { if ($0 ~ /-->/) incomment = 0; next }
    /^## Workflow flags[[:space:]]*$/ { inblock=1; seen=0; next }
    inblock && /^#/ { inblock=0 }
    inblock && seen && /^[[:space:]]*$/ { inblock=0 }
    inblock && /^[a-z][a-z-]*:/ { seen=1 }
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

# tier_is_legal <value> — values are space-free by construction.
tier_is_legal() { [[ " $(tier_allowlist) " == *" ${1:-} "* ]]; }

# tier_require_legal <value> [context] — die with the single-sourced
# legal-names message; <context> is optional prose after the tier name
# (e.g. " in ## Workflow flags"). Uses whatever die() the caller has in
# scope, so per-script message prefixes are preserved.
tier_require_legal() {
  tier_is_legal "${1:-}" \
    || die "unknown tier '${1:-}'${2:-} — legal tiers: $(tier_allowlist)"
}

# flags_known_keys — single source of the recognized `## Workflow flags` keys.
# Consumers EXTEND this (tier #537, research #535; #536 spike adds its own).
# Unknown keys are warn-and-ignored by flags_validate (forward compatibility).
flags_known_keys() { printf 'tier research'; }

# flags_validate <issue-md-path> — enumerate the body `## Workflow flags` block's
# COL-1 keys (the flags_get idiom: body segment only via the `^## Comments (`
# guard, HTML-comment spans skipped, block ends at the next `^#` heading) and WARN
# on stderr — non-fatal, forward-compat — for any key not in flags_known_keys.
# Silent when the block is absent or carries only known keys. Value-continuation,
# indented, and blank lines are not keys (col-1 `^[a-z][a-z-]*:` only).
# CONSUMPTION NOTE: pull.sh calls this only in the scaffold branch, so a key added
# after first scaffold is never validated. CAVEAT (inherited #537 grammar): an inline
# `<!--` on a key line starts a comment span and silently drops that key.
flags_validate() {
  local file="$1"
  [[ -f "$file" ]] || return 0
  awk -v known=" $(flags_known_keys) " '
    /^## Comments \(/ { exit }
    /<!--/ { incomment = 1 }
    incomment { if ($0 ~ /-->/) incomment = 0; next }
    /^## Workflow flags[[:space:]]*$/ { inblock = 1; seen = 0; next }
    inblock && /^#/ { inblock = 0 }
    inblock && seen && /^[[:space:]]*$/ { inblock = 0 }
    inblock && /^[a-z][a-z-]*:/ { seen = 1 }
    inblock && /^[a-z][a-z-]*:/ {
      key = $0; sub(/:.*/, "", key)
      if (index(known, " " key " ") == 0)
        print "flags.sh: warn: unknown ## Workflow flags key '\''" key "'\'' — ignored (forward-compat)" > "/dev/stderr"
    }
  ' "$file"
}
