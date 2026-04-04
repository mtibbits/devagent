# PR Red Team Review Prompt

Red-team this PR from the maintainer's perspective. The maintainer is [name/context].

For each finding, rate severity as: **block** (must fix before merge), **request-changes** (should fix, would accept a follow-up), or **nit** (take it or leave it).

Review for:

**Scope & Focus**
- Does this PR do exactly one thing? Could any part be split out or deferred?
- Does it mix refactoring with behavior changes?
- Are there any "while I'm here" changes that inflate the diff without being in the PR title?

**Reviewer Burden**
- How many lines is the diff? Can a reviewer understand the "why" in under 2 minutes?
- Is the commit message doing the heavy lifting, or does the reviewer have to read every line?

**Style & Conventions**
- Does the code follow existing patterns (naming, imports, comments, test structure)?
- Does it introduce patterns the next contributor would need to learn, or does it follow existing conventions they'd already know?

**Unnecessary Additions**
- Any dead code, over-documented comments, unused imports, or defensive checks for impossible states?

**Test Coverage**
- Does the PR include tests proportional to the change?
- Are the tests verifying behavior or implementation details? Will they break on unrelated refactors?

**Error Paths**
- What happens when this fails? Are errors surfaced or swallowed?
- Does the failure mode match what the maintainer would expect?

**Hidden Coupling**
- Does this change make assumptions about other parts of the codebase that could silently break?
- Any implicit ordering, shared state, or undocumented contracts?

**Maintenance Burden**
- Am I adding something the maintainer now has to support? Is that burden proportional to the value?
- Does this introduce a new pattern where an existing one would work?

**Rollback Safety**
- If this breaks in prod, can the maintainer revert cleanly?
- Any migrations, config changes, or API contracts that make reverting painful?

**PR Description**
- Is it self-contained? Does it explain the problem, not just the solution?
- Would a maintainer who hasn't talked to me understand why this matters?

**Gut check**: If I were mass-reverting PRs during an incident, would I hesitate before reverting this one? Why?

For each issue found, phrase it as a review comment the maintainer would actually write.
