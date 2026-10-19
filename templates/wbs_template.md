# {{PROJECT}} WBS

> Source-of-truth for work-breakdown structure. Edited by hand and by
> `/devagent:wbs update`. Each `- [ ]` bullet outside a code fence is a
> WBS node; inline `{key: value, ...}` block carries metadata.
>
> Recognized keys (v1): issue, est, cost, owner, milestone, start, due, depends_on, status_src, mr, priority
> Unrecognized keys are preserved verbatim.
> `wbs update` sets a leaf's glyph from its issue's tracker state, linked MRs, else its
> checklist, records which in `status_src`, and writes `mr` (open, draft or merged) for an
> open issue an MR closes. It changes only that glyph and those values, adds newly
> active issues, then sorts each parent's children by depends_on, then priority (P1-P4),
> moving whole lines; every line, this note included, keeps its bytes byte-for-byte.
> `/devagent:wbs init --from-tracker` builds a new file from the tracker's issue history instead.

- [ ] Top-level milestone or epic {est: 0w, milestone: M1, owner: @you, cost: 0}
  - [ ] First leaf {issue: Issue-1, est: 1w}
  - [ ] Second leaf {issue: Issue-2, est: 1w, depends_on: Issue-1}
