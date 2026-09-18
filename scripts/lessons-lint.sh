#!/usr/bin/env bash
# scripts/lessons-lint.sh — validate a lessonsLearned.md against the closed tag
# taxonomy (#232). NOT a strict mirror of reap.sh block 4 — deliberately
# STRICTER (#232): skip <!-- --> comment blocks; accept the structured
# '### claim' + '- Tags: [...]' form, the flat inline '- [tag] <claim>' form and
# (#588) the legacy bold-lead '- **[tag] <claim>.**' form (TOLERATED so Fable-era
# files do not false-flag — not a preferred shape); (#594) read a bracket that
# LEADS a '### [tag] claim' heading as that entry's tag (TOLERATED, same rule
# as the bullets: the bracket must lead; reap.sh does NOT read a heading bracket)
# and treat a '- [[wikilink]]' bullet or '### [[wikilink]]' heading as a link,
# never a tag;
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
  # Every entry opener and END run the same no-tag flush; the openers differ only
  # in the prefix stripped from the recorded claim. flat_open is the ONE opener
  # for column-0 bold-lead bullets (#525/#588): both flat rules call it and gate
  # on the same predicate, boldlead, so they cannot drift apart.
  function flush() {
    if (in_entry && !tagged) { printf "  line %d: entry has no tag: %s\n", eline, etext; bad=1 }
  }
  function open_entry(strip) { flush(); in_entry=1; tagged=0; eline=NR; etext=$0; sub(strip,"",etext) }
  function flat_open() { open_entry("^-[ \t]*") }
  # #594: the ONE tag predicate. The heading rule and the tag-bullet rule both
  # call it, so they cannot drift (Issue-565). It validates every token of the
  # FIRST bracket on the line and sets tagged only when a token exists: an
  # empty bracket "[]" carries no tag, so the missing-tag check still fires
  # (#232 review L1), and an off-taxonomy token is tagged-but-reported, one
  # honest finding, not two. i, n, toks, a, hastok are function-local.
  function tagcheck(   i, n, toks, a, hastok) {
    if (!match($0, /\[[^]]*\]/)) return
    toks=substr($0, RSTART+1, RLENGTH-2)
    n=split(toks, a, /[ ,]+/)
    hastok=0
    for (i=1;i<=n;i++) if (a[i] != "") {
      hastok=1
      if (!(a[i] in valid)) { printf "  line %d: off-taxonomy tag [%s]: %s\n", NR, a[i], $0; bad=1 }
    }
    if (hastok) tagged=1
  }
  /<!--/ { incomment=1 }
  incomment { if ($0 ~ /-->/) incomment=0; next }
  # #594: a bracket that LEADS the heading ("### [tag] claim") is that entry
  # tag. open_entry runs FIRST (it clears tagged), so a heading can never
  # retro-tag the entry above it. Leading only: a bracket mid-claim is prose
  # (#232 strictness). A heading that leads with a "[[wikilink]]" is a link, not
  # a tag: it stays an ordinary untagged heading, the same exemption as the
  # wikilink-bullet rule below.
  /^### / {
    open_entry("^### *"); seen_heading=1
    if ($0 ~ /^### *\[/ && $0 !~ /^### *\[\[/) tagcheck()
    next
  }
  # #594: a "- [[wikilink]]" bullet is a LINK. It opens no entry (it is not
  # bold-lead) and tags none, so it is consumed BEFORE the tag-bullet rule can
  # read its "[[page]" as a tag token.
  /^[ \t]*-[ \t]+(\*\*)?(Tags:[ \t]*)?\[\[/ { next }
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
    # the hastok gate in tagcheck, so "- **[] x.**" stays untagged and an
    # off-taxonomy "- **[bogus] x.**" is tagged-but-reported.
    if (!seen_heading && $0 ~ boldlead) flat_open()
    tagcheck()
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
    flush()
    if (bad) { printf "lessons-lint: FAIL %s (off-taxonomy or untagged entries above)\n", FILENAME > "/dev/stderr"; exit 1 }
  }
' "$file"
