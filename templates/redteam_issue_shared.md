# Issue Red Team Review

You are reviewing a GitHub Issue before it is posted. Your job is to find
weaknesses, ambiguities, and gaps that would cause a maintainer to close it,
misunderstand it, or deprioritize it.

## Triage gate: how much rigor does this issue need?

Not every issue needs 16 dimensions of scrutiny. Apply rigor proportional
to the effort and risk involved.

**Light review (dimensions 1, 3, 5 only):**
One-line fixes, typo corrections, trivially obvious bugs. If the car is
on fire, don't ask the reporter to defend her submission against 16
dimensions. Just confirm it's clear, specific, and verifiable, then move on.

**Standard review (dimensions 1-7, 12, 15):**
Most bug fixes and small enhancements. The core quality dimensions plus
root cause alignment and backward compatibility. Skip the strategic
dimensions (8-11, 13-14, 16) unless something feels off.

**Full review (all 16 dimensions):**
New features, architectural changes, multi-file refactors, anything that
touches build infrastructure or public APIs, anything that will take more
than a day to implement. These are the issues where a maintainer will
scrutinize scope, value, and fit before investing review time.

**Always check, regardless of tier:** If the issue touches I/O, config
parsing, environment variables, or memory allocation, evaluate dimension
16 (Security) even on a light review.

**Start by deciding which tier this issue falls into, then skip
dimensions that don't apply.**

## The Sixteen Dimensions

Evaluate the issue along each applicable dimension. Score each using
this severity scale:

| Symbol | Score | Meaning | Action |
|--------|-------|---------|--------|
| :red_circle: | **Blocking** | Fatal flaw. Issue cannot be posted as-is. | Must fix before posting. |
| :orange_circle: | **Major** | Significant weakness. A maintainer will likely push back. | Should fix before posting. |
| :yellow_circle: | **Minor** | Small gap. Noticeable but won't derail the issue. | Fix if easy, note if not. |
| :green_circle: | **Clean** | No concerns on this dimension. | No action needed. |
| :white_circle: | **N/A** | Dimension does not apply to this issue type/tier. | Skip. |

Any :red_circle:-scored dimension must yield at least one **Blocking**
finding — so the verdict cannot be `ship` (core-redissue forbids `ship`
with any Blocking finding). Two or more :orange_circle: scores are a
strong signal to `revise` — reviewer's judgment — but the verdict
contract is the skill's: the Blocking count governs. Only
:yellow_circle:/:green_circle:/:white_circle: scores and zero Blocking
findings ⇒ `ship`. (Orange-score findings are typically **Recommended**;
yellow-score findings, **Nits**.)

---

## Adversarial Questions

After scoring the dimensions, answer these five questions:

1. **Ambiguity test:** Can I interpret this issue in two contradictory
   ways? If so, which sentence is ambiguous?

2. **Escape test:** Can a maintainer close this as wontfix/invalid/duplicate
   without doing anything, because the scope is unclear or the case isn't
   compelling? What would their argument be?

3. **Specification gap:** Could someone implement a "fix" that passes all
   stated criteria but doesn't actually solve the underlying problem?

4. **Diagnostic rigor:** Is there a simpler explanation the reporter hasn't
   considered? Has the reporter actually verified their root cause, or are
   they guessing?

5. **Scope creep risk:** Does the Expected Behavior section promise more
   than a single PR can deliver? Will a reviewer expect things the
   implementer didn't intend?

6. **Regression check:** Is this a regression (it used to work) or has
   it always been broken? If it's a regression, has the reporter
   identified when it broke? Regressions are higher priority and
   easier to bisect — if this is one, the issue should say so.

---

## Output Format

```
## Review tier: <Light / Standard / Full>

## Scorecard

| # | Dimension | Score | Justification |
|---|-----------|-------|---------------|
| 1 | Clarity | ... | ... |
| 2 | Reproducibility | ... | ... |
| 3 | Specificity | ... | ... |
| 4 | Actionability | ... | ... |
| 5 | Verifiability | ... | ... |
| 6 | Impact | ... | ... |
| 7 | Context-independence | ... | ... |
| 8 | Customer value | ... | ... |
| 9 | Maintainability | ... | ... |
| 10 | Proportionality | ... | ... |
| 11 | Runtime cost | ... | ... |
| 12 | Root cause alignment | ... | ... |
| 13 | Scope appropriateness | ... | ... |
| 14 | Legal and policy | ... | ... |
| 15 | Backward compatibility | ... | ... |
| 16 | Security | ... | ... |

**Summary:** Blocking (N) / Recommended (N) / Nits (N) — counts are
FINDINGS, not dimensions (a dimension may contribute 0..n findings;
every :red_circle: dimension contributes at least one Blocking).
**Scorecard caption:** X dimensions Clean, X N/A (the tier-audit signal).
**Verdict:** ship | revise | split

Output format is core-redissue's contract (#134) — this template defines
the checks; if any resolved copy says otherwise, the skill's format wins.
(Historical mapping for pre-#134 artifacts: READY TO POST≡ship,
REVISE (Major)≡revise, NOT READY (Blocking)≡revise with Blocking
findings; `split` is reached via the Specificity dimension's
compound-issue signal.)

## Adversarial Questions

1. **Ambiguity:** ...
2. **Escape:** ...
3. **Specification gap:** ...
4. **Diagnostic rigor:** ...
5. **Scope creep:** ...
6. **Regression check:** ...

## Required Changes (Blocking)

<Specific, actionable edits to resolve every Blocking finding.
Each item must reference the dimension number and state exactly what
to change in the issue text.>

## Suggested Improvements (Recommended/Nits)

<Optional improvements for Recommended/Nits findings. Fix if easy, skip if not.>
```
