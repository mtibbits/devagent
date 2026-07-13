<!-- #443: Full-tier delta dimensions (8,9,10,11,13,14,16). Read with shared + light + standard. -->

### 8. Customer value
If we spend engineering effort on this, what does the user concretely gain?

This is the ROI lens — distinct from Impact (#6), which measures severity.
Impact says "this crashes." Customer value says "and therefore users can't
reliably profile the workload, which means they ship suboptimal configurations
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
  usage? On embedded / resource-constrained targets, memory is scarce.
- **Binary size:** Does this add significant code (new ISA tiers,
  template expansion) that inflates the shared library?

For non-hot-path code (argument parsing, config file reading, one-time
initialization), runtime cost is usually not a concern — note this
explicitly so the reviewer doesn't waste time analyzing it.

### 13. Scope appropriateness
Does this belong in this project?

A perfectly written issue for a feature that doesn't fit the project's
charter will be rejected regardless of quality. Bug fixes almost always
belong where the bug lives. Enhancements and new features are where
this dimension matters most.

Watch for: feature requests that drift outside the project's mission
(a cryptographic routine in a numeric-compute library), fixes that belong in a
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

Check the project's own license and contribution policy: such an
import, or an unsigned commit where a DCO/CLA is required, is a
non-starter regardless of technical merit.

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

For most numeric or algorithmic changes (compute routines, algorithm fixes),
score this N/A and move on. For anything touching I/O, config parsing,
environment variables, or memory allocation, evaluate seriously.
