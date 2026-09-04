#!/usr/bin/env bash
# scripts/lessons-lint.sh — validate a lessonsLearned.md against the closed tag
# taxonomy (#232). NOT a strict mirror of reap.sh block 4 — deliberately
# STRICTER (#232): skip <!-- --> comment blocks; accept the structured
# '### claim' + '- Tags: [...]' form, the flat inline '- [tag] <claim>' form and
# (#588) the legacy bold-lead '- **[tag] <claim>.**' form (TOLERATED so Fable-era
# files do not false-flag — not a preferred shape);
# and (#525) FAIL a wholly flat-bullet, zero-tag entry (the batch-11 shape) that
# the '### '-only floor used to pass vacuously. Exit 0 if clean; 1 listing
# offenders (naming the file); 2 on usage.
# NOTE: the awk program below is ONE single-quoted bash string — no apostrophe may
# appear anywhere inside it, comments included (#588).
set -euo pipefail

file="${1:-}"
[ -n "$file" ] || { echo "usage: lessons-lint.sh <lessonsLearned.md>" >&2; exit 2; }
[ -f "$file" ] || { echo "lessons-lint: no such file: $file" >&2; exit 2; }

awk '
  BEGIN { split("actionable reference norm pattern", v, " "); for (i in v) valid[v[i]]=1; bad=0
          boldlead="^-[ \t]+\\*\\*" }
  # #525/#588: the ONE flat-entry opener shared by the tag rule and the flat-bullet
  # rule below — flush the open entry (its no-tag check) and open a new entry on
  # the current line. Both callers gate on the same column-0 predicate, boldlead,
  # so the two rules cannot drift apart.
  function flat_open() {
    if (in_entry && !tagged) { printf "  line %d: entry has no tag: %s\n", eline, etext; bad=1 }
    in_entry=1; tagged=0; eline=NR; etext=$0; sub(/^-[ \t]*/,"",etext)
  }
  /<!--/ { incomment=1 }
  incomment { if ($0 ~ /-->/) incomment=0; next }
  /^### / {
    if (in_entry && !tagged) { printf "  line %d: entry has no tag: %s\n", eline, etext; bad=1 }
    in_entry=1; tagged=0; eline=NR; etext=$0; sub(/^### */,"",etext); seen_heading=1; next
  }
  # A tag-bearing bullet: "- Tags: [..]", "- [tag] ..", "- [..]", or (#588) the
  # bold-lead "- **[tag] ..". The bracket must LEAD the bullet (after an optional
  # "**" and/or "Tags:") — intentionally STRICTER than reap.sh block 4 (which
  # matches a bare [actionable] anywhere on the line), to force the canonical
  # leading-bracket form. #232.
  /^[ \t]*-[ \t]+(\*\*)?(Tags:[ \t]*)?\[[^]]*\]/ {
    # #588: a column-0 BOLD-lead tag bullet "- **[tag] claim.**" is BOTH an entry
    # opener AND its own tag while no "### " heading has been seen (a flat file,
    # or the run-in before the first heading). Open the NEW entry BEFORE the
    # bracket is validated, so an untagged bold bullet above it cannot inherit
    # the tag. Column-0 only (boldlead): an INDENTED bold-tag sub-bullet tags the
    # OPEN entry, like an indented "- Tags: [..]". After a heading the bullet
    # tags that heading, like the plain "- [tag]" line. tagged is set only by
    # the hastok gate below, so "- **[] x.**" stays untagged and an off-taxonomy
    # "- **[bogus] x.**" is tagged-but-reported: one honest finding, not two.
    if (!seen_heading && $0 ~ boldlead) flat_open()
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
  # "next"s tag bullets — since #588 that includes bold-lead TAG bullets, which it
  # also opens via flat_open, so this rule sees only bold bullets with no leading
  # bracket), opening an entry only OUTSIDE a "### " structured file: once a
  # heading is seen the file is structured and body bullets belong to their
  # heading. Bold-lead only, so a prose/context bullet before the first heading is
  # not mistaken for an entry (#525 redmr). Closes the vacuous pass over wholly
  # flat bold-bullet, zero-tag files (the batch-11 shape).
  $0 ~ boldlead {
    if (!seen_heading) flat_open()
    next
  }
  END {
    if (in_entry && !tagged) { printf "  line %d: entry has no tag: %s\n", eline, etext; bad=1 }
    if (bad) { printf "lessons-lint: FAIL %s (off-taxonomy or untagged entries above)\n", FILENAME > "/dev/stderr"; exit 1 }
  }
' "$file"
