---
description: "Step 23: restore tree, commit devdoc, clear active_issue."
allowed-tools: Bash(bash "${CLAUDE_PLUGIN_ROOT}/scripts/*"), Bash(bash "${CLAUDE_PLUGIN_ROOT}/scripts/*" *)
argument-hint: "[project] [issue-dir]"
---

# /devagent:cleanup

Invokes `scripts/cleanup.sh` with the parsed arguments per spec §6.1.

The script honors all permission gates from `[project.<name>.permissions]`.
With `--auto`, the chaining layer suppresses the inter-step prompt but does
**not** suppress permission gates (spec §7.2).

## Precondition (#242, generalizes #231)

`cleanup.sh` refuses to complete while ANY closeout step — `updatewbs`,
`impact`, or `lessonslearned` (each resolved by name) — is in a non-terminal
glyph (`[ ]`, `[~]`, `[!]`, `[?]`, `[P]`). The die names every offender at once.
Finish each step, or mark it `[-]` (skip) if genuinely empty — the per-step
skip is the escape hatch and stays auditable in the checklist.
`lessonslearned` is the highest-stakes gate (producer of the `[actionable]` →
`/devagent:reap` pipeline; an out-of-order close silently drops follow-ups — and
every entry must carry a tag in a `lessons-lint`-recognized shape, or reap and the
register never see it, #525);
updatewbs/impact are recoverable bookkeeping, but they are exactly the steps
skipped when "the code is merged, I'm done" (Issue-78/79/80). Steps absent
from the issue's checklist are not gated (research/docs-only templates).

## Precondition (#594) — the lessons file lints clean

Right after the #242 check and BEFORE any side effect, `cleanup.sh` runs
`scripts/lessons-lint-corpus.sh <issue-dir>/lessonsLearned.md` and refuses a
file that does not lint clean, quoting the offenders. Step 22 writes that file
and this step commits it, so this is the one scripted point every new lessons
file passes through — the lint is enforced here, not merely available. The gate
is keyed on the FILE, not on the step's glyph:

- file present → linted, whatever the `lessonslearned` glyph says;
- `lessonslearned` `[x]` and no file → refused (a missing input is a failure,
  not a pass);
- `lessonslearned` `[-]`, or no such row in the checklist, and no file → no
  subject, cleanup proceeds.

A lint that could not RUN (the walker's rc 2) refuses too. Remedies, fix first:
give every entry a tag from the closed taxonomy `actionable reference norm
pattern` in a shape `templates/lessonsLearned_template.md` documents, check with
`bash "${CLAUDE_PLUGIN_ROOT}/scripts/lessons-lint.sh" <issue-dir>/lessonsLearned.md`,
and re-run. Marking `lessonslearned` `[-]` with no file written is the reviewed
de-scoping: auditable in the checklist, and it leaves the issue out of the
`/devagent:reap` pipeline. A refusal leaves the tree exactly where it was.

## Precondition (#586/#611) — pothole-register promotions

`cleanup.sh` runs `promote-potholes.sh <project> <issue-dir> --check`
BEFORE the tree restore and refuses while a `lessonslearned:` log line CLAIMS
a register promotion (`… promoted to the potholes register`) that no register
layer carries — the check reads the UNION of the plugin seed and every
configured layer file (Retired sections included), so a pre-split citation in
the seed and a line that landed in the shared workflow layer both satisfy a
cleanup re-run. A pending `<issue-dir>/potholes-promotion.md` satisfies the
claim — it is the mechanism's own promise. The remedy is to stage the lines
(`promote-potholes.sh … --add --layer project|workflow "<section>" "- … (<citation>)."`)
or to reword the log line as a deferral/skip with its reason. A `--check` die
leaves the tree exactly where it was.

Immediately AFTER the tree restore, cleanup DRAINS that pending file with
`--apply`. Rails, in order, all evaluated before any register file is written (the lock directory and the target's parent directory are created during the rail phase; both are invisible to git while empty): the project's raw
`permissions.commit_devdoc` must be `true` (false → DEFER before any gate, so
`DA_YES=1` cannot stand in for the operator's flag); each staged layer's file
must be inside the git repo that holds `devdoc_dir` (containment — a workflow
file at the devDoc repo root is in-bounds for every project whose devdoc_dir
is inside that repo, a mistyped absolute path is not); that repo must not be
mid-merge; the target path must be clean and tracked-or-absent; a `mkdir`
lock `<file>.lock` beside the file must be free (a held lock is named in the
DEFER — `rmdir` a stale one from a killed run). Then, per layer: an absent
file is bootstrapped; then every op (`add`, `retire`, `amend`, #612) is
validated SEQUENTIALLY against a temp copy of every target file — hit counts,
the per-line rails re-run against the CURRENT config (single line, `- `
prefix, the multi-token citation grammar, and — workflow layer — the
project-name and `potholes_domain_nouns` rails, so a noun configured after
staging DEFERs the drain with the line quoted), the register FILE contract
(`potholes_file_check`, #613 — over the WHOLE temp copy, so a pre-existing
register-contract violation in the layer file DEFERs too, quoting
`<file>:<line>: <reason>` against the real path: fix that line by hand, then
re-run `--apply`) and the citation postcondition — and only then is each file
written: adds append at the END of their named section (a union-valid heading
the file lacks is added), a
retire rewrites its line as `- [<section>] <text> — mechanised by <mechanism>
(<tokens>).` under `## Retired (mechanised)` at the file's end, an amend
replaces its line in place. Two failure classes: a staging file `--apply`
cannot PARSE (a hand-edit — a block without `layer:`, an unknown `op:`, two
bullets in one block) is rc 1 and cleanup DIES, fix the file and re-run; a
failed VALIDATION is rc 3 with the op and line quoted and cleanup warns and
continues. Rolling the plugin back below #612 while an op-only (retire/amend)
staging file is pending stamps it `applied` with nothing written — the
pre-#612 parser sees no `- ` line — so re-stage or `mv` such a file aside
before a rollback. A zero-hit whose exact result is already present is
ALREADY APPLIED (a partial run converges on re-run); a STALE op names its two
closes, `promote-potholes.sh … --drop <op>` or `status: applied by-hand
<sha>`. The file is `git add`ed if new and committed with the operator's
identity (`-s`) as
`chore: promote pothole-register entries from #N`, scoped to that ONE path —
never through cleanup's own `git add -A` devdoc commit, which is itself scoped
to `devdoc_dir`. The staging file flips to `status: applied <sha>[,<sha>]`
(one sha per layer file committed). Nothing is pushed.

rc 3 is a DEFERRAL: cleanup warns, completes, and the file stays
`status: pending` — `promote-potholes.sh <project> --list-pending` lists the
backlog and `--apply` can be re-run by hand once the cause is fixed. Any
other non-zero rc dies AFTER the restore (tree on the base branch, step 23
unmarked, no devdoc commit; the failing layer is restored — a bootstrapped
file is removed outright — while an earlier layer's commit stands);
re-running cleanup is safe — `--check` passes on a pending file and
`--apply` is idempotent.

## Precondition (#595) — the oneshot no-repo-diff boundary

On a **oneshot**-tier issue only — `cleanup.sh` reads the `Template:` header
itself, so every other tier pays one header read and never spawns the checker —
`${CLAUDE_PLUGIN_ROOT}/scripts/oneshot-zerodiff.sh <project> <issue>` runs
BEFORE the tree restore and refuses on two verdicts: `violated` (the tree
carries commits beyond `default_baseline`, and/or uncommitted paths) and
`indeterminate` (the tree is on another branch, the baseline does not resolve,
or the tree is unreadable — an unprovable invariant must not authorize
completion). The check measures whether the tree carries UNPUBLISHED CHANGE; it
cannot attribute that change to the issue, because the source tree is shared,
so the refusal lists what it found and asks the operator to judge. The routine
`indeterminate` is a shared tree left on a sibling issue's branch: check out
the base branch and re-run. The fix for `violated` is the escalation valve the
tier's own boundary paragraph names:
`revise.sh <project> <issue> --retier standard`, which appends the standard
rows and restarts the issue at draft (step 2). The escape seam is
`echo "<reason>" > <issue-dir>/.devagent-oneshot-ack`: that verdict
(`acknowledged`) completes, warns loudly, and leaves the reason in the issue dir
— a reviewed de-scoping, not a fix. The ack is per-issue and persistent: it is
only read on the oneshot path, so it silences every future revision of this
issue while it stays `oneshot` and is inert after a retier. An empty ack file
does not silence the check. Two documented limits: the measured tree is the
recorded `worktree_path` when one exists (the #571 contract every evidence
step shares), else `source_dir` — a linked worktree is `indeterminate` with a
remedy that names the tier, since the base branch cannot be checked out there;
and a checklist with no `Template:` header (pre-#537) reads as not-oneshot, so
the gate does not run — fail-open by decision, for backward compatibility.

!`bash "${CLAUDE_PLUGIN_ROOT}/scripts/cleanup.sh" $ARGUMENTS`
