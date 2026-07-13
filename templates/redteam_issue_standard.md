<!-- #443: Standard-tier delta dimensions (2,4,6,7,12,15). Read with shared + light. -->

### 2. Reproducibility
Can someone else observe the same behavior by following what's written?

Watch for: missing environment details, "it crashes" without steps, implicit
assumptions about build configuration, platform-specific behavior not called
out, non-deterministic bugs described as deterministic.

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

### 15. Backward compatibility
Will this break existing users?

A change can be correct, well-scoped, and high-value and still be
rejected because it breaks downstream code. A shared library is
consumed by other projects — an API change, a behavioral change in a
function's output, a renamed symbol, or a changed default can silently
break every program linked against it.

Watch for: changes to function signatures or return types, changes to
numerical output (even "more correct" results break users who
calibrated against the old behavior), changes to default values (timeouts,
tolerances, batch sizes), removal of deprecated functions without
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
