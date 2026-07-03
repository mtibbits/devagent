# Issue Red Team Review

You are reviewing a GitHub Issue before it is posted. Your job is to find
weaknesses, ambiguities, and gaps that would cause a maintainer to close it,
misunderstand it, or deprioritize it.

## Triage gate: how much rigor does this issue need?

Not every issue needs 14 dimensions of scrutiny. Apply rigor proportional
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

### 1. Clarity
Can a stranger — someone with no shared context from this conversation —
parse the meaning unambiguously?

Watch for: jargon without definition, ambiguous pronouns ("it", "this"),
walls of text without structure, burying the lede, passive voice hiding
the actor.

### 2. Reproducibility
Can someone else observe the same behavior by following what's written?

Watch for: missing environment details, "it crashes" without steps, implicit
assumptions about build configuration, platform-specific behavior not called
out, non-deterministic bugs described as deterministic.

### 3. Specificity
Is the scope exactly one addressable problem?

Watch for: compound issues ("X is broken and also Y"), scope creep within
the description, vague boundaries ("improve error handling"), moving targets
where the definition of the problem shifts mid-issue.

### 4. Actionability
Can an implementer start work without a round-trip conversation?
**We don't want the issue prescribing a solution.**

Two distinct failure modes, both Major:

**Problem under-described**: the issue states the bug but doesn't give the
implementer enough surrounding context to start. Missing root cause when the
reporter clearly knows it, insufficient context about the surrounding code,
blocking dependencies not mentioned, ambiguous scope.

**Solution prescribed**: the issue body contains an "Implementation sketch",
"Proposed approach", "The fix", "Why X not Y", "Suggested fix direction",
"Test plan", or "Alternatives considered" section that commits the
implementer to one specific path before they've started. **Issues describe
problems; PRs and implementation plans describe solutions.** Solution-
prescriptive issues close off better fixes the implementer might propose,
create an issue/PR contradiction if the eventual fix differs from what the
issue said, and read as "please rubber-stamp my answer" rather than "here's
a problem worth solving."

Score :orange_circle: Major on either failure mode. The over-prescription
failure is the harder one to self-diagnose because a solution-bearing issue
still reads as "well thought out" — that's the failure mode itself, not a
quality indicator. If the issue body contains any of the section names listed
above, the answer is "yes, this is over-prescribed" regardless of how good
those sections are individually. For trivially obvious fixes ("this should be
`true`, not `false`"), note the Major, accept it as acknowledged, and post
the issue anyway — a meaningful bug report is more valuable than a clean
scorecard.

### 5. Verifiability
Can someone confirm a fix is correct and complete?

Watch for: no acceptance criteria, "it should work better" without
specifying what "better" means, no way to distinguish "fixed" from "masked",
missing test cases or verification steps.

### 6. Impact
Is the priority, urgency, and value evident?

Watch for: no severity signal, no indication of who is affected or how
often, no context on why this matters now, theoretical bugs with no
practical consequence presented as urgent.

### 7. Context-independence
Does the issue stand alone without tribal knowledge?

Watch for: references to conversations not linked, assumed familiarity
with project history, unexplained abbreviations, "as discussed" without
saying where, related issues referenced by number without explaining the
relationship.

### 8. Customer value
If we spend engineering effort on this, what does the user concretely gain?

This is the ROI lens — distinct from Impact (#6), which measures severity.
Impact says "this crashes." Customer value says "and therefore users can't
reliably profile kernels, which means they ship suboptimal configurations
to production." A high-impact bug with no real-world user consequence is
low customer value.

Watch for: fixes to code paths no user exercises, theoretical correctness
with no practical effect, gold-plating that adds complexity without user
benefit, missing "who cares and why" framing.

### 9. Maintainability
Will the fix make the codebase easier or harder to maintain long-term?

Watch for: fixes that add complexity (new abstractions, special cases,
compatibility shims) without reducing it elsewhere. Also watch for
missed opportunities — does the issue describe a fix that would *reduce*
technical debt (replace unsafe patterns, remove dead code, establish
reusable conventions) without calling that out? A maintainer deciding
whether to accept a PR wants to know: does this leave the codebase
better or worse than before?

Consider: code clarity, pattern consistency (does the fix follow or
establish conventions other code can follow?), dead code removal,
surface area for future bugs, cognitive load on future contributors.

### 10. Proportionality
Is the solution's complexity proportional to the problem's importance?

This is the Lincoln lens: "I didn't have time to write a short letter,
so I wrote a long one." A 200-line refactor for a 5-line bug fix is
disproportionate. A new abstraction layer for a one-time operation is
over-engineering. Conversely, a one-line band-aid on a systemic problem
is under-engineering.

Watch for: solutions more complex than the problem warrants, abstractions
built for hypothetical future requirements, defensive code for scenarios
that cannot occur, verbose implementations when a simple one suffices,
touching 10 files when 1 would do. Also watch for the inverse: dismissing
a real problem as "just add a check" when the underlying pattern is
broken and will produce the same class of bug again.

The test: if you described this fix to a colleague in one sentence, would
they nod or would they ask "why so complicated?" If the issue itself
needs more than two paragraphs of Expected Behavior, the scope may be
disproportionate to the defect.

### 11. Runtime cost
Will the fix degrade performance or increase resource consumption?

For a performance-sensitive library, hot code may run at enormous
scale — a branch added to the hot path matters, and a static allocation
that persists for the process lifetime matters on embedded targets.

Watch for: validation added to hot paths (should be at initialization,
not per-call), allocations that grow with input size without bounds,
template instantiation bloat from new ISA tiers, synchronization
primitives where none existed before.

Consider separately:
- **CPU cost:** Does this add work to the critical path? A 2% regression
  may be acceptable for correctness. A 200% regression is not.
- **Memory footprint:** Does this increase static or dynamic memory
  usage? On embedded targets (Raspberry Pi, resource-constrained SDR
  hardware), memory is scarce.
- **Binary size:** Does this add significant code (new ISA tiers,
  template expansion) that inflates the shared library?

For non-hot-path code (argument parsing, config file reading, one-time
initialization), runtime cost is usually not a concern — note this
explicitly so the reviewer doesn't waste time analyzing it.

### 12. Root cause alignment
Is the problem in the architecture or in the current implementation?
And is the issue honest about which one it's asking you to fix?

A segfault in the argument parser can be fixed with a bounds check
(implementation: the parser is missing a guard) or by replacing the
hand-rolled parser with CLI11 (architecture: the parser has no
validation framework). Both are valid — but the issue must be explicit
about which layer it's targeting and why.

An implementation fix is appropriate when the architecture is sound and
the bug is a local defect. An architecture fix is appropriate when the
same class of bug keeps recurring because the design can't prevent it.
Most issues should target the implementation; the few that target the
architecture need to justify the larger scope.

Watch for: issues that correctly identify an architectural weakness but
only ask for an implementation patch (the bug will recur). Issues that
propose an architectural change when an implementation fix is sufficient
(over-engineering, see dimension 10). Issues where the Root Cause and
Expected Behavior point at different layers of the stack — a signal that
the issue is confused about what it's actually asking for.

The test: if Root Cause says "the parser uses `atoi` which can't report
errors" but Expected Behavior says "reject negative vlen", those are
different layers — the parser doesn't know what vlen means. That
mismatch means the issue needs to be split or refocused.

### 13. Scope appropriateness
Does this belong in this project?

A perfectly written issue for a feature that doesn't fit the project's
charter will be rejected regardless of quality. Bug fixes almost always
belong where the bug lives. Enhancements and new features are where
this dimension matters most.

Watch for: feature requests that drift outside the project's mission
(vectorized SHA-256 in a DSP library), fixes that belong in a
dependency or a consumer rather than this library, enhancements that
duplicate functionality available in a sibling project, changes that
would make this library responsible for concerns it currently delegates.

Anchor scope to the project's stated domain: features should serve
that domain, infrastructure changes should serve the existing feature
set, and tooling should serve the project's developers and integrators.
Anything outside that scope — however well-implemented — is a better
fit for a different project.

The test: would the project's maintainers say "yes, we should own
this" or "that's interesting, but it belongs in [other project]"?

### 14. Legal and policy
Are there any licensing, copyright, or policy concerns?

Watch for: proposed implementations that copy code from incompatibly
licensed projects (e.g. copyleft code into a permissively-licensed one), algorithms covered
by patents, features that require adding new dependencies with
license implications, changes that affect SPDX headers or copyright
notices, contributions that need CLA/DCO sign-off the reporter may
not be aware of.

Check the project's own license and contribution policy: an
incompatibly-licensed import (e.g. copyleft code into a
permissively-licensed project) or an unsigned commit where a DCO/CLA is
required is a non-starter regardless of technical merit.

### 15. Backward compatibility
Will this break existing users?

A change can be correct, well-scoped, and high-value and still be
rejected because it breaks downstream code. A shared library is
consumed by other projects — an API change, a behavioral change in a
function's output, a renamed symbol, or a changed default can silently
break every program linked against it.

Watch for: changes to function signatures or return types, changes to
kernel numerical output (even "more correct" results break users who
calibrated against the old behavior), changes to default values (warmup
time, tolerance, vector length), removal of deprecated functions without
a deprecation period, changes to config file format or path that
orphan existing configs, changes to build system defaults that break
existing build scripts.

The test: if a user upgrades this library without reading the
changelog, does their existing code still compile, link, and produce
the same results?
If not, the issue must explicitly acknowledge the compatibility break
and justify why it's worth the cost. Most breaking changes require a
major version bump or a deprecation period — the issue should state
which approach it expects.

### 16. Security
Does this fix, introduce, or ignore a security concern?

Many issues in a compute library have no security implications — it
processes caller-provided buffers. But code that reads from environment
variables, config files, or network input is attack surface.

Watch for: buffer overflows from unsanitized external input (environment
variables, config files, command-line arguments), format string
vulnerabilities, integer overflows that lead to undersized allocations,
use of attacker-controllable paths without validation, `sscanf`/`sprintf`
without width limits on data from external sources.

Also consider the inverse: does *not* fixing this issue leave a security
hole? For example, a `strncpy`/`strcat` buffer overflow reading a
config path from an environment variable a local attacker on a shared
system could set. Not exploitable in most deployments, but a
static analysis tool or distro security audit would flag it.

For most kernel-level issues (SIMD implementations, algorithm fixes),
score this N/A and move on. For anything touching I/O, config parsing,
environment variables, or memory allocation, evaluate seriously.

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
