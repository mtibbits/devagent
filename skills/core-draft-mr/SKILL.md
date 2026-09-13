---
name: core-draft-mr
description: "Step 14: draft the merge-request body from imPlan, actualWork, and analyzer output"
when_to_use: After /devagent:analyze and before /devagent:review. Run as part of /devagent:draftmr.
user-invocable: false
allowed-tools: Bash(bash "${CLAUDE_PLUGIN_ROOT}/scripts/*"), Bash(bash "${CLAUDE_PLUGIN_ROOT}/scripts/*" *)
---

# devagent-draft-mr

Step 14 of the devAgent 24-step workflow. Fills in
the resolved `mr_template.md` (§12 registry: project paths → devdoc → plugin default) from the issue's plan, actualWork, and
analyzer findings, writing the result to `<issue-dir>/mr.md`. The
ship step later uses `mr.md` verbatim as the MR body.

## Overview

The MR body is the only artifact a reviewer reads first. Filling the
template's sections, it must convey: what changed and why now
(**Summary**), which issue it closes (**Related issues** —
`Closes #NNN`), and what evidence exists it works (**Testing**). The
skill fills the template from existing artifacts so nothing is
re-typed.

## Inputs

- `$ISSUE_DIR`, `$NOTE`.
- Reads:
  - `<issue-dir>/issue.md` (for the problem statement and original
    motivation).
  - `<issue-dir>/imPlan.md` (for what was promised).
  - `<issue-dir>/actualWork.md` (for what was delivered + deviations).
  - `<issue-dir>/analysis/*.txt` (for static-analyzer / sanitizer
    summary).
  - Resolved `mr_template.md` (per spec §12 registry: project paths →
    `<devdoc>/templates/` → plugin default).
- Writes: `<issue-dir>/mr.md`.

## Checklist

1. **Resolve template.** Walk the §12 artifact registry to find
   `mr_template.md`. Halt if unresolvable.
2. **Fill Summary section.** One paragraph: what changed **and why now**
   (the template's Summary is literally "What changed and why?"), from
   the issue's problem statement + the actualWork's outcome + any
   operator $NOTE. Note any deviations from actualWork's
   `## Deviations from plan`. No marketing.
3. **Fill Related issues section.** Add `Closes #<issue-number>` (taken
   from `issue.md`) so the issue **auto-closes on merge** — this is the
   load-bearing line; without it the MR merges but the issue stays open.
   Use `Related: #NNN` for context-only links that should not close.
4. **Fill Testing section.** How the change was verified — bullet list:
   - Tests added (from actualWork).
   - Analyzer results (one line per tool with finding counts from
     `analysis/*.txt`).
   - Benchmarks if performance issue (path to the project's
     evidence-plot output if it has one).
5. **Fill Checklist section** (DCO, surgical-diff confirmation, etc.)
   from the template. Pre-check items that are verifiable from
   artifacts; leave others unchecked.
6. **Fill the `## Evidence` block** (#359), if the resolved template has one.
   Generate a fresh suite-count artifact and fill the two machine-checked
   lines from it — never by hand (hand-written counts shipped wrong 8×;
   #120/#85/#284):

   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/run-suite.sh" <project>   # writes analysis/<date>-suite-count.txt
   ```

   (`<project>` = the resolved project; pass it explicitly — #572 guards the
   bare form against wrong-scope resolution.)

   From the newest `analysis/<date>-suite-count.txt`, write the `suite:` line naming
   ONLY the frameworks the artifact reports present (#466). A framework whose line reads
   `(none)` is ABSENT from the tree and must not appear in the Evidence at all. The
   framework line is the one that starts `bats:`; the artifact's `bats_jobs:` line
   is the run MODE (#593 — how many test files ran at a time), never a count, and never
   appears in the Evidence:

   | artifact | `suite:` line |
   |---|---|
   | `bats: <ok>/<plan>` + `pytest: <n> passed` | `<ok>/<plan> bats, <n> pytest @ <head-sha>` |
   | `bats: <ok>/<plan>` + `pytest: (none)` | `<ok>/<plan> bats @ <head-sha>` |
   | `bats: (none)` + `pytest: <n> passed` | `<n> pytest @ <head-sha>` |
   | `bats: (none)` + `pytest: (none)` | `none @ <head-sha>` (#411) |

   Never write `, 0 pytest` for a `pytest: (none)` artifact — a measured zero and an
   absent framework are different facts, and the first is a false green (#572 MINOR-5).
   An artifact reading `pytest: (error)` means `tests/test_*.py` exist but produced no
   counts: the suite was NOT measured, preship fails on it, and no Evidence line is
   writable — fix the interpreter and re-run run-suite before continuing.
   Also write `files: <n> changed`
   (n = `git diff --name-only <baseline_sha>..HEAD | wc -l`).
   If an `analysis/<date>-born-red.txt` exists, add
   `born-red: <its verdict>`. preship's verification #4 (#359) hard-checks
   these against the artifact + git, so they must be exact. (No Evidence block
   in the template ⇒ skip — the checker warns and passes for back-compat.)
7. **Write `<issue-dir>/mr.md`.**

## Halt and ask if

- `mr_template.md` cannot be resolved from any registry layer.
- `actualWork.md` is missing — operator must run document first.
- Any `analysis/*.txt` reports unaddressed findings — surface them
  before filing the MR. (The analyze step is N/A when its step is
  absent from the issue's checklist, e.g. docs-only, or when step 13
  is marked `[-]` — the `analyze = "none"` self-skip, #55 — then there
  is no `analysis/` and that is expected, not a halt.)
- `<issue-dir>/mr.md` already exists with substantive content —
  ask whether to overwrite, append a revision section, or abort.

## Skipping policy

Never auto-skip. Filing an MR with no body is bad-faith. If the issue
is docs-only and the template is overkill, surface "trivial change;
fill template stub only?" rather than skipping outright.

## Logging

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/checklist-log.sh" "$ISSUE_DIR" draftmr "mr.md drafted from mr_template.md (template source: $TEMPLATE_PATH); note: $NOTE"
```

## Templates referenced

- the resolved `mr_template.md` (§12 registry: project paths → devdoc → plugin default) — the canonical structure being filled.
