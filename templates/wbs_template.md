# {{PROJECT}} WBS

> Source-of-truth for work-breakdown structure. Edited by hand and by
> `/devagent:wbs update`. Each bullet is a WBS node; inline
> `{key: value, ...}` block carries metadata.
>
> Recognized keys (v1): issue, est, cost, owner, milestone, start, due, depends_on
> Unrecognized keys are preserved verbatim.

- [ ] Top-level milestone or epic {est: 0w, milestone: M1, owner: @you, cost: 0}
  - [ ] First leaf {issue: Issue-1, est: 1w}
  - [ ] Second leaf {issue: Issue-2, est: 1w, depends_on: Issue-1}
