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
# dropped every flag, regressing #537's shipped `tier:`); AND, while no key has been
# seen yet, it ends at the first non-blank line that is not a col-1 key (#553: an EMPTY
# flags heading followed by prose otherwise left the block open, so a later col-1
# `key: value` prose line still parsed as a live flag — die-class since #561's model
# keys, so a hard pull failure rather than a warning). That last clause is deliberately
# warn-LESS: a block whose first in-block non-blank line is a mis-cased or indented key
# (`Tier: oneshot`) closes there, silently dropping every key below it, so "a typo is
# not silently inert" does not hold for that shape — accepted, with a warn-on-close
# follow-up in #553's future-enhancements. Why the two rules #553 proposed cannot work
# (both keyed on a blank; the conventional and defective shapes share their first three
# lines, so the discriminator is the THIRD): CHANGELOG #553.
# (This comment DESCRIBES the third clause rather than quoting it: a guard in
# tests/lib_flags.bats counts that rule's occurrences in this file, and spelling its
# matching form here would make the count wrong — #561.)
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
#
# DUPLICATE KEYS ARE FIRST-MATCH-WINS (#561 AC10, documenting existing
# behavior): the awk action `exit`s on the first match, so a body carrying
# `tier: opus-checking` above `tier: oneshot` yields `opus-checking` and the
# second line is dead. To combine a template tier with a model annotation use
# `tier:` + `checking-model:`, one line each. Note this is deliberately the
# OPPOSITE of the per-issue marker's duplicate rule (config.sh's
# step_models_tier dies on two lines for one class): the flags block is remote
# content whose forward-compat contract is "ignore what you don't understand",
# while the marker is local operator-authored state where ambiguity is a bug.
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
    inblock && !seen && $0 !~ /^[[:space:]]*$/ && $0 !~ /^[a-z][a-z-]*:/ { inblock=0 }
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
flags_known_keys() { printf 'tier research spike implementation-model checking-model'; }

# --- #561: per-issue model steering ------------------------------------------
#
# Two keys, orthogonal to `tier:` (which stays the checklist-template
# selector). Both are SCAFFOLD-TIME only — pull.sh writes them into the
# per-issue `.devagent-step-models` marker at first pull; the post-scaffold
# path is hand-editing that file.
#
#   implementation-model: <token>  → the THINKING class, canonical steps
#                                    2 draft, 9 implement, 10 quality,
#                                    11 document, 14 draftmr
#   checking-model: <token>        → the CHECKING class, canonical steps
#                                    5 improve, 15 review, 16 redmr,
#                                    17 preship
#
# ENFORCEMENT DIFFERS BY STEP and the names under-promise their coverage:
# `checking-model` is fully enforced (all four steps dispatch, and consume the
# resolved tier as the Agent-tool `model:` override per
# docs/checking-dispatch-contract.md). `implementation-model` is enforced for
# step 2 only (draft's dispatched planner, via step-model.sh <project> 2) and
# ADVISORY for 9/10/11/14 — those run inline and a session cannot swap its own
# model, so the tier surfaces only as the next/catchup hint.

# model_token_allowlist — single source of the legal model tokens, shared by
# both keys, the `tier: <model>-checking` shim, and the label channel. The
# Agent tool's closed model enum plus #291's reserved `inherit`.
model_token_allowlist() { printf 'sonnet opus haiku fable inherit'; }

# model_token_is_legal <value> — legal values are space-free by construction,
# so a value carrying trailing inline prose fails (fail-closed, matching
# tier_is_legal's semantics).
model_token_is_legal() { [[ " $(model_token_allowlist) " == *" ${1:-} "* ]]; }

# model_token_require_legal <value> [context] — die with the single-sourced
# legal-tokens message. Uses whatever die() the caller has in scope (the
# tier_require_legal contract), so it MUST be called as a statement and never
# inside $(...) — a die inside command substitution kills only the subshell.
model_token_require_legal() {
  model_token_is_legal "${1:-}" \
    || die "unknown model token '${1:-}'${2:-} — legal tokens: $(model_token_allowlist)"
}

# tier_shim_model <value> — the #561 compat shim. Echo <model> with rc 0 iff
# <value> is `<model>-checking` and <model> is a legal model token; rc 1
# otherwise, so the caller falls through to tier_require_legal and genuinely
# unknown tiers still die listing the legal tier names.
#
# Why it exists: koopman-gnn used `tier: opus-checking` / `tier: fable-checking`
# as a MODEL annotation before #537 claimed the `tier:` key for template
# selection, so pull.sh started hard-dying on already-drafted bodies
# (koopman-gnn#106). The shim is PERMANENT grammar and warns every time: the
# warning IS the migration nudge, and a removal date would orphan capture
# drafts that are not yet filed.
#
# Non-fatal by design — never calls die(), so it is safe inside $(...).
tier_shim_model() {
  local v="${1:-}" model
  [[ "$v" == *-checking ]] || return 1
  model="${v%-checking}"
  [[ -n "$model" ]] || return 1
  model_token_is_legal "$model" || return 1
  printf '%s\n' "$model"
}

# issue_labels <issue-md-path> — print one forge label per line, read from the
# HEADER segment's `- Labels: <csv>` line.
#
# This IS the backend payload as pull.sh sees it (#561 operator answer A1):
# the five-verb backend contract defines `fetch` as markdown-to-stdout and
# pull.sh writes that stdout verbatim, so no JSON crosses the process
# boundary — the `- Labels:` line the backends render
# (scripts/issue/github.sh, scripts/lib/backend-common.sh) is the structured
# surface available here.
#
# HEADER SEGMENT ONLY: awk exits at the first `^---`, and only the FIRST
# `- Labels:` line is consumed. This is the same segment-scoping discipline
# flags_get has, for the same reason — a `- Labels:` line sitting in body
# prose or quoted inside a tracker comment must never steer model selection.
#
# KNOWN LOSSY, accepted: forge label names may legally contain commas, and all
# three backends join this line on `,` / `, ` (scripts/issue/github.sh,
# scripts/issue/gitlab.sh, scripts/issue/jira.sh) while this function
# re-splits on `,`. A comma inside a non-`tier:` label merely sheds harmless
# fragments; a pathological `tier:check-opus, tier:check-fable` authored as ONE
# forge label would parse as two and hit pull.sh's same-class conflict die.
# Fixing it needs a structured backend channel (a sixth verb) — considered and
# rejected as out of scope; see the issue's future-enhancements file.
#
# SCOPE DEPENDENCY (#561 review F3): the header segment is delimited by the FIRST
# `^---`, which spec §9.3 requires every backend to emit
# (scripts/lib/backend-common.sh, scripts/issue/*.sh). Unlike flags_get this
# function has no `^## Comments (` guard and does not skip HTML-comment spans, so
# a non-compliant custom backend that omitted the separator would let a
# body-authored `- Labels:` line steer. Compliant backends make that unreachable;
# a stricter reader is not worth the complexity while §9.3 holds.
#
# rc is always 0: "no `- Labels:` line" and "an empty label set" are the same
# thing to every caller (no labels to steer with), so they are not
# distinguished.
issue_labels() {
  local file="$1"
  [[ -f "$file" ]] || return 0
  awk '
    /^---[[:space:]]*$/ { exit }
    /^- Labels:/ {
      val = $0
      sub(/^- Labels:[[:space:]]*/, "", val)
      n = split(val, parts, ",")
      for (i = 1; i <= n; i++) {
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", parts[i])
        if (parts[i] != "") print parts[i]
      }
      exit
    }
  ' "$file"
}

# flags_validate <issue-md-path> — enumerate the body `## Workflow flags` block's
# COL-1 keys (the flags_get idiom: body segment only via the `^## Comments (`
# guard, HTML-comment spans skipped, block ends at the next `^#` heading) and WARN
# on stderr — non-fatal, forward-compat — for any key not in flags_known_keys.
# Silent when the block is absent or carries only known keys. Value-continuation,
# indented, and blank lines are not keys (col-1 `^[a-z][a-z-]*:` only) — and, AFTER the
# first key, they do not end the block either; BEFORE the first key an indented or prose
# line ENDS it (#553), so such a line is not merely skipped, it closes the block. This
# machine is the deliberate twin of flags_get's; the grammar and its rationale are
# stated once at the top of this file.
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
    inblock && !seen && $0 !~ /^[[:space:]]*$/ && $0 !~ /^[a-z][a-z-]*:/ { inblock = 0 }
    inblock && /^[a-z][a-z-]*:/ { seen = 1 }
    inblock && /^[a-z][a-z-]*:/ {
      key = $0; sub(/:.*/, "", key)
      if (index(known, " " key " ") == 0)
        print "flags.sh: warn: unknown ## Workflow flags key '\''" key "'\'' — ignored (forward-compat)" > "/dev/stderr"
    }
  ' "$file"
}
