# {{PROJECT}} WBS

> Source-of-truth for work-breakdown structure. Edited by hand and by
> `/devagent:wbs update`. Each `- [ ]` bullet outside a code fence is a
> WBS node; inline `{key: value, ...}` block carries metadata.
>
> Recognized keys (v1): issue, est, tok, cost, owner, milestone, start, due, depends_on, status_src, mr, priority, satisfies, objective, h, thinking, checking
> satisfies, objective: `<namespace>:<id>` or a [list] of them; h: 0-4 (operator attention); wbs show warns on other shapes.
> depends_on: an issue here, or <project>:<issue> for another configured project's issue (orders nothing here); wbs show warns on a malformed prefix.
> thinking, checking: one model token (model_token_allowlist in scripts/lib/flags.sh); a plan, not a setting; wbs show warns on other values.
> est: agent time, the agent wall time cost-report (scripts/lib/cost-report.py) reports for the issue, not operator
> or calendar time. Units match exactly: `h` = 1, `d` = 8, `w` = 40 agent hours (fixed multiples, not calendar days).
> tok: the token estimate, in cost-report's price-weighted input-token equivalents, written with `k` = 1000 or
> `M` = 1000000 (tok: 500k); a bare number is not a value. Either key takes a single value or a range low-high with
> one trailing unit (est: 2-4d, tok: 1-3M), low not above high. Zero is a legal estimate.
> est classes: `absent` (no key), `placeholder` (? or ?w), `time` (h, d or w), `non-time` (any other unit, as in
> 48pr: not an estimate), `unparseable` (anything else). tok classes: `absent` (no key), `placeholder` (? or ?M),
> `tokens` (k or M, whole tokens), `unparseable` (anything else, a bare number included).
> Only time and tokens count as estimates. On a parent node, est or tok is the operator's own roll-up: leaf
> readers ignore it, and it is never summed.
> cost: operator-defined and uninterpreted. It is not an actual; actuals belong in the planned actuals ledger (#729), never in WBS.md.
> Unrecognized keys are preserved verbatim.
> `wbs update` sets a leaf's glyph from its issue's tracker state, linked MRs, else its
> checklist, records which in `status_src`, and writes `mr` (open, draft or merged) for an
> open issue an MR closes. It changes only that glyph and those values, adds newly
> active issues, then sorts each parent's children by depends_on, then priority (P0-P4),
> moving whole lines; every line, this note included, keeps its bytes byte-for-byte.
> `/devagent:wbs init --from-tracker` builds a new file from the tracker's issue history instead.

- [ ] Top-level milestone or epic {est: ?w, milestone: M1, owner: @you, cost: 0}
  - [ ] First leaf {issue: Issue-1, est: 2-4d, tok: 1-3M}
  - [ ] Second leaf {issue: Issue-2, est: 1w, depends_on: Issue-1}
