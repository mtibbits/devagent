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
measured against `scripts/`, which the repo README's toolchain line omits).
**Edit the SOURCE first, then the page** — the site restates repo truth; it
never originates it.

## Numbers and versions

Counts and versions are restated minimally, with the sources' exact tokens:

- "57 slash commands" — `index.md` is an enrolled home of the phrasing sweep
  in `tests/cmd_wrappers.bats`, alongside README, both plugin manifests, the
  CHANGELOG, and the spec.
- "22-step workflow" — the site-wide headline number; `workflow.md`'s
  Numbering section carries the reconciling sentence for the optional steps.
- Claude Code "2.1.211" — on a version bump, sweep every home:
  `grep -rn '2\.1\.211'` across the repo **including docs-site/**.

## Enforcement today

- `tests/docs-site.bats` — pins the page set, the derive headers (each named
  source must exist), per-page links, the install commands (asserted in BOTH
  `install.md` and README, so drift on either side reddens), the 24-row step
  table, the ten backend verbs, and a no-match canary for the audit's
  off-by-one step-count typo.
- The devAgent workflow's preship step re-verifies restated numbers at the
  ship SHA.

## Pending mechanism

The structural fix for documentation lag is a "documented-surface" question
in the red-team and preship review steps — "does this diff add, rename, or
remove a config key, command, hook, or top-level directory a documented
surface must name?" — tracked as **mtibbits/devagent#435**. Until it lands,
this file is the strategy record.
