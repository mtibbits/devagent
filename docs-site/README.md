# docs-site — content-drift policy

This directory holds the devAgent onboarding site: six content pages, plain
markdown, no generator. This file is the site's maintenance policy, not one
of the pages. (The Pages deployment workflow may exclude it from the
published site; its content is public-safe either way.)

## Derivation rule

Every content page's **first line** is an HTML comment naming ALL the repo
sources it derives from:

```
<!-- derived-from: README.md scripts/ -->
```

A directory counts as measured provenance (install.md's `jq` prerequisite is
measured against `scripts/`).
**Edit the SOURCE first, then the page** — the site restates repo truth; it
never originates it.

## Numbers and versions

Counts and versions are restated minimally, with the sources' exact tokens:

- the slash-command count phrase — `index.md` is an enrolled home of the sweep
  in `tests/cmd_wrappers.bats`, alongside README, both plugin manifests, the
  CHANGELOG, and the spec.
- "24-step workflow" — the site-wide headline number; `workflow.md`'s
  Numbering section carries the reconciling sentence for the optional steps.
- the mandatory/optional step split — spec §6.3 is the authority, but the
  number is restated wherever a reader needs it (README, `workflow.md`'s
  Numbering section). Those restatements are kept honest by the sweep in
  `tests/checklist-numbering.bats`, which derives the expected count from
  `templates/checklist-standard.md` and finds its subjects by predicate — so a
  new home is covered the moment it is written, without editing the test.
- The verified Claude Code version — verbatim-shared between `install.md`
  and the repo README, pinned on both sides by the guard suite; on a bump,
  update README first, then the page and the test's expectation together,
  and sweep the old token repo-wide **including docs-site/**.

## Enforcement today

`tests/docs-site.bats` is the enforcement: it pins the pages against their
sources (drift on either side reddens), and its header comment — which lives
next to the assertions and is edited with them — enumerates the pinned
surface. Anything the suite does not pin is held only by the derivation rule
above and by review.

## Pending mechanism

The structural fix for documentation lag is a "spec-touch" question in the
red-team and preship review steps — "does this diff add, rename, or remove a
config key, command, hook, or top-level directory the spec must name?" —
tracked as **mtibbits/devagent#435**. Note its scope as filed is the
**spec**, not this site: when it lands it will not cover `docs-site/` unless
widened (or given a sibling check). Until then, this file is the strategy
record.
