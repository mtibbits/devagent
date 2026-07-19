#!/usr/bin/env bash
# scripts/lessons-lint.sh — validate a lessonsLearned.md against the closed tag
# taxonomy (#232). NOT a strict mirror of reap.sh block 4 — deliberately
# STRICTER (#232): skip <!-- --> comment blocks; accept the structured
# '### claim' + '- Tags: [...]' form and the flat inline '- [tag] <claim>' form;
# and (#525) FAIL a wholly flat-bullet, zero-tag entry (the batch-11 shape) that
# the '### '-only floor used to pass vacuously. Exit 0 if clean; 1 listing
# offenders (naming the file); 2 on usage.
set -euo pipefail

file="${1:-}"
[ -n "$file" ] || { echo "usage: lessons-lint.sh <lessonsLearned.md>" >&2; exit 2; }
[ -f "$file" ] || { echo "lessons-lint: no such file: $file" >&2; exit 2; }

awk '
  BEGIN { split("actionable reference norm pattern", v, " "); for (i in v) valid[v[i]]=1; bad=0 }
  /<!--/ { incomment=1 }
  incomment { if ($0 ~ /-->/) incomment=0; next }
  /^### / {
    if (in_entry && !tagged) { printf "  line %d: entry has no tag: %s\n", eline, etext; bad=1 }
    in_entry=1; tagged=0; eline=NR; etext=$0; sub(/^### */,"",etext); seen_heading=1; next
  }
  # A tag-bearing bullet: "- Tags: [..]", "- [tag] ..", or "- [..]". The bracket
  # must LEAD the bullet (after an optional "Tags:") — intentionally STRICTER
  # than reap.sh block 4 (which matches a bare [actionable] anywhere on the line),
  # to force the canonical leading-bracket form. #232.
  /^[ \t]*-[ \t]+(Tags:[ \t]*)?\[[^]]*\]/ {
    if (match($0, /\[[^]]*\]/)) {
      toks=substr($0, RSTART+1, RLENGTH-2)
      n=split(toks, a, /[ ,]+/)
      hastok=0
      for (i=1;i<=n;i++) if (a[i] != "") {
        hastok=1
        if (!(a[i] in valid)) { printf "  line %d: off-taxonomy tag [%s]: %s\n", NR, a[i], $0; bad=1 }
      }
      # An empty bracket "[]" carries no tag — leave the entry untagged so the
      # missing-tag check fires rather than silently passing (#232 review L1).
      if (hastok) tagged=1
    }
    next
  }
  # #525: a flat-bullet entry — a column-0 BOLD-lead "- **" bullet (the batch-11
  # entry shape) that the tag-bullet rule above did NOT consume (it runs first and
  # "next"s tag bullets), opening an entry only OUTSIDE a "### " structured file:
  # once a heading is seen the file is structured and body bullets belong to their
  # heading. Bold-lead only, so a prose/context bullet before the first heading is
  # not mistaken for an entry (#525 redmr). Closes the vacuous pass over wholly
  # flat bold-bullet, zero-tag files (the batch-11 shape).
  /^-[ \t]+\*\*/ {
    if (!seen_heading) {
      if (in_entry && !tagged) { printf "  line %d: entry has no tag: %s\n", eline, etext; bad=1 }
      in_entry=1; tagged=0; eline=NR; etext=$0; sub(/^-[ \t]*/,"",etext)
    }
    next
  }
  END {
    if (in_entry && !tagged) { printf "  line %d: entry has no tag: %s\n", eline, etext; bad=1 }
    if (bad) { printf "lessons-lint: FAIL %s (off-taxonomy or untagged entries above)\n", FILENAME > "/dev/stderr"; exit 1 }
  }
' "$file"
