# {{PROJECT}} WBS

> Source-of-truth for work-breakdown structure. Edited by hand and by
> `/devagent:wbs update`. Each `- [ ]` bullet outside a code fence is a
> WBS node; inline `{key: value, ...}` block carries metadata.
>
> Recognized keys (v1): issue, est, cost, owner, milestone, start, due, depends_on, status_src
> Unrecognized keys are preserved verbatim.
> `wbs update` sets a leaf's glyph from its issue's tracker state, else its checklist,
> and records which in `status_src`. It changes only that glyph and value and adds
> newly active issues; every other line, this note included, is kept byte-for-byte.

- [ ] Top-level milestone or epic {est: 0w, milestone: M1, owner: @you, cost: 0}
  - [ ] First leaf {issue: Issue-1, est: 1w}
  - [ ] Second leaf {issue: Issue-2, est: 1w, depends_on: Issue-1}
