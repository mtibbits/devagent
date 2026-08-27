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

## Precondition (#586) — pothole-register promotions

`cleanup.sh` runs `scripts/promote-potholes.sh <project> <issue-dir> --check`
BEFORE the tree restore and refuses while a `lessonslearned:` log line CLAIMS
a register promotion (`… promoted to the potholes register`) that the resolved
register does not carry (no `(Issue-N)` citation). A pending
`<issue-dir>/potholes-promotion.md` satisfies the claim — it is the mechanism's
own promise. The remedy is to stage the lines
(`promote-potholes.sh … --add "<section>" "- … (Issue-N)."`) or to reword the
log line as a deferral/skip with its reason. A `--check` die leaves the tree
exactly where it was.

Immediately AFTER the tree restore, cleanup DRAINS that pending file with
`--apply`: the lines are appended at the end of their named sections and
committed on the base branch as `chore: promote pothole-register entries from
#N`, scoped to the register path only (a concurrent session's staged files are
left alone). The commit is NOT pushed. rc 3 (register dirty in git, source repo
not on the base branch, or the register resolving outside the project's own
repos) is a DEFERRAL: cleanup warns, completes, and the file stays
`status: pending` — `promote-potholes.sh <project> --list-pending` lists the
backlog and `--apply` can be re-run by hand once the register is clean. Any
other non-zero rc dies AFTER the restore (tree on the base branch, step 23
unmarked, no devdoc commit); re-running cleanup is safe — `--check` passes on a
pending file and `--apply` is idempotent.

!`bash "${CLAUDE_PLUGIN_ROOT}/scripts/cleanup.sh" $ARGUMENTS`
