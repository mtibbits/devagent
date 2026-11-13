# docs-site — content-drift policy

This directory holds the devAgent onboarding site: its content pages
(Markdown `*.md` pages, and hand-written `*.html` pages, which the build also
accepts), `moved.txt` (old page names and their new homes) and, when one
exists, an `assets/` folder. Nothing generated is committed.
`scripts/build-docs-site.sh` renders the pages at publish time. This file is
the site's maintenance policy, not one of the pages: the build leaves
`README.*` out of the published site (its content is public-safe either way).

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
- "25-step workflow" — the site-wide headline number; `workflow.md`'s
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

**A second suite reads these pages.** `tests/build-docs-site.bats` builds the
site and derives expectations from the markdown: each page's code-fence count
and `workflow.md`'s table rows must survive rendering, the two
`claude plugin …` lines in `install.md` must appear verbatim in the HTML,
`install.md`'s and `concurrency.md`'s H1s are pinned as page titles, and the
site's navigation order is read from `index.md`'s "Where to go next" bullet
list — which must stay a top-level `- [Title](./page.md)` list. If no bullet
is in that form the build refuses (exit 4); if a single bullet drifts, that
page silently moves to the end of the nav and the nav-order assertion in
`tests/build-docs-site.bats` reddens instead. That suite needs pandoc: the
`test suite` workflow installs it and runs the file un-skipped, and the
`publish docs site` workflow additionally refuses any skip in it. If it
reddens after a deliberate page edit, the expectation moves with the page.

## How the build reads this directory

`scripts/build-docs-site.sh`'s header is the reference (inputs, nav order,
exit codes); this section is the editor's view of it.

**Hand-written pages.** A `<name>.html` file here is a page body. The build
wraps it in the same template as a Markdown page, so it gets the same head,
nav and footer, and inserts its bytes unchanged between `<article>` and
`</article>`: neither of pandoc's readers touches it. (A build-time
placeholder hook runs over every page; it changes nothing until a later
child of #994 defines the placeholders.)

- Line 1 is the same `<!-- derived-from: ... -->` header a Markdown page
  carries. Without it, or with a UTF-8 byte-order mark before it, the build
  exits 4.
- The `<title>` and nav label come from the first `<h1>` that is not inside a
  comment or a `<pre>`, `<script>`, `<style>`, `<template>` or `<textarea>`.
  Text inside an inline `<code>` counts, a `<br>` reads as a space, other tags
  are stripped, and the entities `&amp;` `&lt;` `&gt;` `&quot;` `&#39;` are
  decoded once. Any other entity (`&mdash;`, `&nbsp;`) in the `<h1>` exits 5:
  write the character itself. A page with no `<h1>` exits 5.
- A `<!-- nav-label: Short name -->` line in the header block (the run of
  `<!-- ... -->` lines from line 1) sets the nav label instead; the title still
  comes from the `<h1>`. The label is plain text, not HTML: write `Q & A`, not
  `Q &amp; A`.
- `<name>.md` and `<name>.html` together exit 4: keep one. `README.*` is
  reserved for this file, so a `README.html` exits 4.

**Nav source.** The nav is the index page first, then the pages the index's
own top-level list names, in its order, then every page the list omits, in
alphabetical (`LC_ALL=C`) order of base name across both kinds.

- In `index.md` the list is `- [Title](./page.md)` bullets, or
  `- [Title](./page.html)` for a hand-written page. Bullets inside a backtick
  or tilde code fence are examples and are ignored.
- In an `index.html` each entry is one line holding `<li>` and then
  `<a ... href="page.html">`, with the `href` double-quoted (other attributes
  may come first). A `<li>` alone on a line followed by an `<a href="page.html">`
  on the next exits 4. Entries inside a comment or a `<pre>`, `<code>`, `<script>`,
  `<style>`, `<template>` or `<textarea>` are ignored.
- A list that names no page exits 4, rather than publish an alphabetical nav.

**Asset folders.** `docs-site/assets/` is copied to `assets/` and
`scripts/docs-site/static/` (the template's own files) to `static/`, byte for
byte; either may be absent. A Markdown page may show an image from
`./assets/<path>`; any other image target fails the build (exit 5). Every
`href`, `src` and `srcset` attribute of a tag in the rendered output must name
a file the build produced (exit 6); the same words written in code or prose
are text, not links, and so is a tag inside an HTML comment or inside the body
of a `<script>`, `<style>`, `<template>` or `<textarea>` (a `<script src>`
itself is still checked). A root-absolute path (`/x`) and a path with a `..` segment
are refused too, because the site is served under a subpath (`/devagent/`)
where both point somewhere else.

**Moved pages.** `moved.txt` lists old page names and their new homes, one
`<old-name> <new-home>` pair per line; its header documents the format. For
each line the build writes `<old-name>.html`, a static stub that says the page
moved and links to the new home: a content page of this site
(`<page>.html[#fragment]`) or an absolute `https://` URL. Stubs load nothing,
ask not to be indexed, appear in no nav and are not counted as pages. A line
whose old name is still a content page, is `README`, or repeats an old name,
exits 4; a new home that is not a content page this build produces (a missing
page, the stub itself, or another stub) exits 6.

**The fetch ban is still in force.** On the real build,
`tests/build-docs-site.bats` fails if any rendered file, assets included,
contains `<script`, `<link `, `<img `, `<iframe`, ` src=`, `@import` or
`url(`, or the words "private preview". So no tracked page or asset may carry
those strings until #1030 replaces the ban with an allowlist. Fixture builds
in that suite are not subject to it.

**Deploy hold.** The website 2.0 epic (#994) holds publishing: the repository
variable `DOCS_SITE_DEPLOY` is set to `false` before #995 merges, and stays
`false` until child 10 of that epic sets it back to `true`, after the operator
approves a full private preview. While it is off,
GitHub Pages keeps serving the last 1.0 deploy, and every push still builds
the site and uploads it as the `docs-site` review artifact
(`docs/pages-deployment.md` has the mechanism).

## Pending mechanism

The structural fix for documentation lag is a "spec-touch" question in the
red-team and preship review steps — "does this diff add, rename, or remove a
config key, command, hook, or top-level directory the spec must name?" —
tracked as **mtibbits/devagent#435**. Note its scope as filed is the
**spec**, not this site: when it lands it will not cover `docs-site/` unless
widened (or given a sibling check). Until then, this file is the strategy
record.
