<!-- #443: Light-tier dimensions (1,3,5) + dim 16 Security (always-loaded: the _shared 'always check Security even on Light' rider references it on every tier, #443). Read with redteam_issue_shared. -->

### 1. Clarity
Can a stranger — someone with no shared context from this conversation —
parse the meaning unambiguously?

Watch for: jargon without definition, ambiguous pronouns ("it", "this"),
walls of text without structure, burying the lede, passive voice hiding
the actor.

### 3. Specificity
Is the scope exactly one addressable problem?

Watch for: compound issues ("X is broken and also Y"), scope creep within
the description, vague boundaries ("improve error handling"), moving targets
where the definition of the problem shifts mid-issue.

### 5. Verifiability
Can someone confirm a fix is correct and complete?

Watch for: no acceptance criteria, "it should work better" without
specifying what "better" means, no way to distinguish "fixed" from "masked",
missing test cases or verification steps.

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
