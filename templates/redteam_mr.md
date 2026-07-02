# PR Red Team Review Prompt

Red-team this PR from the maintainer's perspective. The maintainer is [name/context].

This template defines WHAT to attack. Severity taxonomy, summary counts,
verdict vocabulary, and the checklist log line are the invoking skill's
contract (core-redmr: `[BLOCKING]` / `[MAJOR]` / `[MINOR]` / `[INFO]`) — if
any resolved copy of this template says otherwise, the skill's format wins.
(Historical mapping for pre-#134 artifacts: block≡BLOCKING,
request-changes≡MAJOR, nit≡MINOR.)

## Review order

1. Read the PR description — can you understand the "why" in under 2 minutes?
2. Check scope (Section A below).
3. Architecture pass — trace data flow, identify trust boundaries.
4. Line-by-line pass through Sections B–H.
5. Chain-analysis pass (Section I) — look across findings.

---

## A. Scope & Focus
- Does this PR do exactly one thing? Could any part be split out or deferred?
- Does it mix refactoring with behavior changes?
- Are there any "while I'm here" changes that inflate the diff without being in the PR title?

## B. Reviewer Burden
- How many lines is the diff? Can a reviewer understand the "why" in under 2 minutes?
- Is the commit message doing the heavy lifting, or does the reviewer have to read every line?

## C. Style & Conventions
- Does the code follow existing patterns (naming, imports, comments, test structure)?
- Does it introduce patterns the next contributor would need to learn, or does it follow existing conventions they'd already know?

## D. Unnecessary Additions
- Any dead code, over-documented comments, unused imports, or defensive checks for impossible states?

## E. Memory & Type Safety (C/C++ specific)
- **Buffer bounds**: Do loops processing arrays stop at array bounds? Do SIMD kernels handle tail elements safely when `num_points` is not a multiple of the vector width?
- **Integer overflow in size calculations**: Can `n * sizeof(T)` or similar expressions wrap? Are allocations checked?
- **Pointer lifetime & ownership**: Are bare pointers justified? Is nullptr handled at boundaries? Is ownership documented?
- **Const correctness**: Could more arguments, locals, or methods be `const`?
- **Initialization**: Are all plain-old-data fields initialized (use `{}` to avoid undefined values)?
- **Dangerous functions**: Grep the diff for `alloca`, `gets`, `sprintf`, `strcpy`, `atoi`, `system()`, `reinterpret_cast`. Each needs justification.
- **Alignment & portability**: Does the change assume a specific alignment, endianness, or SIMD register width that could break on another architecture?

## F. Build System & Supply Chain
- Do any new `FetchContent`, `ExternalProject`, or submodule additions pin versions and verify integrity (checksums or signatures)?
- Are compiler hardening flags preserved (`-fstack-protector-strong`, `-D_FORTIFY_SOURCE=2`, etc.)?
- Does the change affect CI runtime? PR checks should stay fast; slow checks get disabled by contributors.

## G. Test Coverage
- Does the PR include tests proportional to the change?
- Are the tests verifying behavior or implementation details? Will they break on unrelated refactors?
- For kernel changes: are edge cases tested (num_points=0, num_points=1, unaligned buffers, max values)?

## H. Error Paths
- What happens when this fails? Are errors surfaced or swallowed?
- Do error paths fail **closed** (deny/stop), not **open** (allow/continue)?
- Do error messages avoid leaking internal state (file paths, stack traces, config values)?

## I. Hidden Coupling
- Does this change make assumptions about other parts of the codebase that could silently break?
- Any implicit ordering, shared state, or undocumented contracts?
- **Chain analysis**: Review all findings together. Could two `[MINOR]` findings (e.g., an integer truncation + an unchecked return value) combine into a real vulnerability?

## J. Maintenance Burden
- Am I adding something the maintainer now has to support? Is that burden proportional to the value?
- Does this introduce a new pattern where an existing one would work?

## K. Rollback Safety
- If this breaks in prod, can the maintainer revert cleanly?
- Any migrations, config changes, or API/ABI contracts that make reverting painful?

## L. PR Description
- Is it self-contained? Does it explain the problem, not just the solution?
- Would a maintainer who hasn't talked to me understand why this matters?

---

**Gut check**: If I were mass-reverting PRs during an incident, would I hesitate before reverting this one? Why?

**Threat model the diff**: What could an adversary do if they controlled the inputs to this code path?

For each issue found, phrase it as a review comment the maintainer would actually write.
