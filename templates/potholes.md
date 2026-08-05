<!-- POTHOLE REGISTER (#286). Curated, highest-generality [pattern] lessons fed
     FORWARD into the draft step. Format contract:
       - one line per entry, keyed by a DOMAIN TRIGGER (the situation that fires it);
       - each entry ends with its source citation `(Issue-N)`;
       - draft reads this file and produces a `## Potholes considered` plan section;
       - lessonslearned APPENDS new generalizing [pattern] lessons here, deduping by
         citation (skip if a line already cites that issue for that rule);
       - keep it curated — one line per distinct trigger, highest generality wins.
         Wholesale backfill is out of scope; the register earns entries via the
         lessonslearned promote, not by dumping the corpus.
     Resolved via the §12 registry (project paths -> devdoc override -> plugin default). -->

# Pothole register

Known potholes plans keep being written into. Before drafting, check which triggers
match this issue and dispose of each match in `## Potholes considered`.

## Bash exit-status & control flow
- Pipe/`< <()`/loop-tail `&&`/`|| true` hide a non-zero exit as "found nothing" under `set -euo pipefail` → capture into a var with explicit `|| die`, THEN test emptiness (Issue-314).
- `cmd 2>/dev/null || true` on a maybe-undefined function returns empty (127 swallowed) and drives the wrong branch → `type <fn>` in the script's own source-set before relying on the fallback (Issue-316).
- A lib function returning >1 value → side-channel vars die inside `$(...)` subshells; choose setter-globals vs stdout-token BEFORE writing code, and grep call sites for `$(` (Issue-282).
- A resolver/setter that `die`-exits cannot live inside `$(...)` → the echo-wrapper-in-command-substitution is the non-fatal resolve shape (Issue-120).
- `|| true` + a HEAD/default fallback on a load-bearing value hides a mis-base → make degradations loud; distinguish "genuinely absent" from "should-exist-but-didn't" first (Issue-72).
- Two same-exit-code states that some caller must distinguish → mint distinct exit codes at the SOURCE; caller-side stderr-prose parsing is unguardable (a phrase-grep pins words, not behavior) (Issue-458).

## Test discipline (born-red / vacuous pass)

- When an acceptance criterion demands bit-for-bit equivalence with an existing path, implement by delegating to that path — equivalence by construction beats equivalence maintained by test (Issue-94).
- Born-red is a claim to VERIFY per test against the UNFIXED tree — a green suite over unfixed code is the compound failure (Issue-282).
- A floor/presence guard on a test that filters-after-discovering is vacuous → count what the assertions run against (after the filter) and mutation-test the guard itself (Issue-151).
- "did it run / processes all X" features → assert COUNT/coverage or an observable per-item effect, never just rc or the log (Issue-32).
- A clean analyzer/test run over code the tool cannot parse or never built is VACUOUS, not a pass → verify the tool actually saw the changed lines (arch-gated sources, generated files, non-C asm) before trusting "0 findings" (Issue-Fork-149).
- A defect whose symptom depends on uninitialized caller/register/heap state → the test must CONTROL that state (poison it), or a benign ambient value shows a passing green over broken code (Issue-Fork-149).
- A born-red test whose fixture pre-seeds the asserted marker proves nothing → assert a delta/count, not mere presence (Issue-318).
- A mutation matrix that only DELETES the rule proves it is PRESENT, not that it is RIGHT — a rule narrowed to half its documented predicate can pass every guard and reproduce every mutation split → mutate each CLAUSE the docs claim, and ask which guard fails if that clause alone is wrong (Issue-553).
- `! cmd | grep` negation in bats is vacuous → `run grep …; [ "$status" -ne 0 ]`; when a red step unexpectedly passes, find out WHY (Issue-31).
- A grep presence-canary asserts `-eq 1` (precise no-match), never `-ne 0` (which conflates clean with error) (Issue-337).
- Ad-hoc test runs in an env-pinned session inherit the pins → only a hermetic (`env -u`) or harness-owned run is admissible evidence; re-running the same contaminated command at baseline confirms nothing (Issue-458).
- A guard whose glob stops selecting its subjects passes SILENTLY — relocating a file can empty a canary without reddening anything → enumerate the globs that select a file before moving it, and assert the subject COUNT (Issue-439).
- A born-red claim printed unconditionally is narration, not evidence — a later re-run makes the log contradict it → gate the claim on an actual existence/state check, or state the STRUCTURAL fact (this module imports only X, so it cannot depend on Y) instead (Issue-85).
- Before pinning a statistical probe, derive what it measures when the code is CORRECT → a probe whose estimator degenerates (support fixed by construction, error O(sd/sqrt(K)) not O(sd/sqrt(n))) hard-fails on a correct implementation (Issue-85).
- A hand probe that asserts MEMBERSHIP is blind to a suite's EQUALITY pin — extending a single-source list passes `contains` and fails `equals`; when substituting probes for a suite, match the assertion SHAPE (Issue-561).
- Absence from a SUBSET result means NOT RUN, not PASSED — assert the name->file mapping is TOTAL before diffing a subset against a known failure set, because an unmapped name is silent and silence reads as success (Issue-561).
- A locale-empty shell can make a test runner silently SKIP tests whose names carry non-ASCII characters while still printing a full plan — pin the harness locale and treat executed<plan as failure, not warning (Issue-559).
- Every number in an evidence artifact must be mechanically derived from the run log it cites — a prose summary is where hand-carried counts resurface after the mechanized path is fixed (Issue-559).
- A fast tier that never EXECUTES a real call path cannot see a control-flow regression → put the cheapest real end-to-end run first in the slow tier; five author regressions passed a full fast tier here (Issue-106).
- A guard that greps a message LITERAL dies silently when the message is reworded → export the string as a module constant and assert on it from both sides, so a rename reddens instead of disarming (Issue-106).
- A guard that iterates the WHOLE tree is a cost you must measure before shipping it — time it against a normal test in the same suite; a per-file process pipeline over every tracked file can eat a fifth of a CI budget for one assertion, and a bare-token prefilter usually removes ~98% of it (Issue-566).
- A run that never EXECUTED the code reads exactly like a passing one — a non-login shell without the test binary on PATH reports "0 failing" for a mutation that deletes the code under test → make the harness prove it ran: print the resolved binary path, assert ok+notok == plan, and refuse to summarize a run that produced no plan line (Issue-553).

## State / TOML / atomicity
- `sed`-append into a state TOML creates duplicate keys tomllib rejects → sed-REPLACE or route through the canonical `_toml.py` layer; never hand-roll a sectioned-config writer (Issue-116).
- A function that reads state to decide what to write must decide inside the lock → prefer a locked primitive (`set-many-if`, `--print-old`) over a read-then-write pair (Issue-240).
- Atomicity ACs pin by observing transaction TRAFFIC (shim the writer, assert co-carried fields) + crash injection — a race-window test is flaky-green theatre (Issue-317).

## Git / ambient checkout / forge state

- A locally-scaffolded issue number is provisional until the tracker write succeeds — never bake it into branch names or MR close-references before filed.toml exists (Issue-94).
- Any step that commits/pushes/merges → assert `HEAD == state.branch` first; steps that MOVE the checkout set traps for later steps ("acts on ambient git state, not the named target" is a defect family) (Issue-69).
- "Is this ref still a valid base?" depends on merge state → ask the forge; git topology can't see it, don't add heuristics (Issue-154).
- Any clever git/plumbing technique → validate empirically on a scratch repo BEFORE planning around it (Issue-33).
- A chain-continuation command emitted without its scoping argument re-resolves GLOBAL state at fire time — a concurrent session's pointer hijacks the chain; bake the resolved scope into the emitted command (Issue-559).
- A `Closes #N` keyword silently DELETES acceptance criteria that a scope split moved elsewhere → file the receiving issue and amend the tracker before ship, never as a merge-time promise (Issue-106).
- A deferral recorded only in a code comment or MR body has no addressee → put the obligation on the receiving issue AND in a committed, guard-asserted register the change itself carries (Issue-106).
- A command that resolves the active scope from GLOBAL state does it at FIRE time, so an unscoped invocation can silently WRITE its artifact into another scope's directory, not merely act on the wrong one — pass the scope explicitly to anything that produces a file (Issue-566).
- The same fire-time global-scope defect on the EVIDENCE path is worse than on the write path: an unscoped verifier measures a DIFFERENT tree and reports green, so the artifact is true about something nobody asked about → stamp the resolved SHA/tree in the artifact and compare it to the branch before trusting any number (three sites hit in one issue: suite runner, evidence checker, WBS updater — Issue-553).

## Sweeps / fix-at-source / sibling sites
- A getter/pattern with N consumers → fix at the SOURCE, enumerate all N up front, one regression test per site (fixing one and missing the twin is the classic) (Issue-82).
- Scoping one accessor to a context → scope-asymmetry bugs travel in PAIRS; audit its siblings for the same need (Issue-76).
- A mechanical `sed` sweep undercounts on single-line grep (the dominant form is a continuation line) and a variable-path sed evades every `.toml`-string canary → anchored pattern + `-A1` count + balanced-diff + a semantic check (Issue-335).
- A contract enumerated in N files → ONE sweep test over all N homes, extended in the same change that adds a home; it ships divergent exactly when the sweep lags the homes (Issue-458).
- Claiming a CLASS is closed → derive its members mechanically (grep the predicate); fixing the instances a checker handed you and declaring the class shut publishes a count the next reader disproves in one command (Issue-439).
- A value that has been corrected twice is a design defect, not a typo → remove the dependency on it rather than updating it a third time (Issue-558).
- A checker's green result overclaims unless its blind-spot SHAPE is written into the checker itself → state what it cannot decide beside what it asserts (Issue-558).
- A programmatic edit (`sed`, string-replace) that silently NO-OPS leaves a false record when you verify a proxy instead of the edited file → grep the edited file for the new text before booking the fix (Issue-106).
- After fixing a defect, grep the FIX ITSELF for the defect's own class → a phase-mixing bug was reintroduced inside the renderer added to fix it; prefer a COUNTED denominator over one derived from a loop bound, which silently re-mixes when a caller changes (Issue-85).
- A repo-wide sweep must DECLARE its universe and prove the edge: enumerate from the tracked set (not the filesystem, which carries ignored mutable junk), pass the NUL-delimited form so unusual filenames survive quoting, and probe it with a subject whose NAME exercises the edge rather than only its contents (Issue-566).

## New gate / shared-fixture blast radius
- Adding a guard/gate that reads shared fixture state → grep the fixture and COUNT affected tests FIRST; the fixture edit is Step 0, not a later debugging session (Issue-242).
- A new `die` in a step script → trace its `--auto`-chain interaction in the plan; a die mid-chain is a different product than one on direct invocation, and warnings can't gate autonomous flows (Issue-242).
- Replacing a lookup or scan → enumerate BOTH branches of the new logic and test each; a rewrite that fixes one direction can turn a fail-closed error into a fail-open wrong write (Issue-558).
- Changing a serialized format can invalidate a certificate that hashes the FILE rather than its contents → grep for file-level hashers first, and pin the container's key set in the same change; content hashes cannot see a key appear (Issue-106).

## Dispatched fresh-context checking
- Keep review/redmr/improve in dispatched fresh-context subagents — highest value exactly where the change "looks trivial and the tests are green" (Issue-316).
- A dispatched checker returning 0 tool-uses / echoing an instruction fragment is a MISFIRE, not a clean pass → verify the artifact was written; re-dispatch with a "do the work with tools" nudge (Issue-315).
- A checklist item a dispatched checker never RECEIVES is a dead tripwire → add the input to the dispatch-packaging list in the same change (Issue-286).
- An artifact relayed through another model session is NOT verbatim → the producer/relay writes it to a FILE; a low body-line floor passes an elided report as valid (Issue-458).
- A checker finding is a SAMPLE of a class, not a coordinate → grep for its siblings before fixing the named site, or the next round returns the same shape (Issue-558).
- A mechanical evidence gate and an adversarial reader catch DISJOINT classes — the gate reads two lines and misses false prose; the reader misses arithmetic. A green gate is not evidence the body is true (Issue-561).
- Several findings in one round often share ONE structural cause → look for it before fixing them individually; reverting the decision can close all of them, where fixing each spawns the next round's defects (Issue-106).
- Write each dispatched checker's returned body to disk on RECEIPT, before acting on it — act-then-summarize leaves an audit trail one round deep and second-hand (Issue-106).
- A checker's prediction you cannot EXECUTE is still a finding — record it as an open risk, not as covered; a test line added but never run is not coverage (Issue-561).

## Premise freshness / contracts / classification
- Re-derive an audit-issue's premises at HEAD before planning — it may be half-done, the A-vs-B menu may have changed, or the prerequisite may already have landed (Issue-116).
- An issue's named input can be wrong → verify it exists with the assumed content in scope/improve; surface the mismatch rather than building an inert fix (Issue-274).
- Building on an external tool/harness parameter → probe the CONSUMER's accepted-value contract live (closed enums reject values docs imply legal); split probe findings CONFIRMED vs ASSERTED by provenance — the read-not-measured rung is the one that breaks (Issue-458).
- A premise-freshness ✗ on a named file can be the issue's own DELIVERABLE → classify input-vs-output before treating absence as a falsified premise (Issue-458).
- An issue's prescribed fix is an untrusted hypothesis, not a spec → verify it at HEAD before building on it (Issue-Fork-149's `## Fix` would have hung); and "which impl/path does this ACTUALLY run by default?" is a source question — read the dispatch/fallback logic, don't assume the measured or common case is the default (Issue-Fork-149).
- An issue's MENU of candidate fixes can be wholly falsified, not just partly — execute every candidate against the real cases before picking one; when the working and broken inputs share a prefix, no rule keyed on that prefix can discriminate them, so the whole menu is unfixable and the discriminator lies further along (Issue-553).
- Two components that must agree on a format → test by feeding one's REAL produced artifact through the other, not a prose promise or a format check (Issue-232).
- A status ambiguous between "absent" and "can't-determine" → fail closed; a tri-state classifier makes the fail-safe un-violatable by construction (Issue-243).
- A check green YESTERDAY and red TODAY at the same SHA → establish WHICH ENVIRONMENT produced each run before diagnosing drift; an A/B across SHAs is valid only same-environment (Issue-559).
- An evidence artifact saved under a non-canonical filename silently drops out of its mechanized checker's glob — the checker validates the wrong file and the mismatch reads as staleness; canonical names are part of the evidence contract (Issue-559).
- A cited doc's exact commands are unverified until something RUNS them (wrapper/entrypoint, permissions, a step that consumes a file no step creates) → execute them during draft/scope instead of treating the citation as validation (fleet Issue-3).
- Match rigor to risk; tier the model to the FAILURE MODE, not the diff size (a 90-line interleaving diff earns opus; a proven-dead deletion earns one coupling sweep) (Issue-122).
- A verification claim is only true at the SHA it RAN at → re-run every claimed check at the final SHA before ship; fixing X silently invalidates each count derived from X being broken (Issue-439).
- A multiplier or figure inherited from an issue body is a MODEL, not a measurement → measure it before quoting a saving that is linear in it; the whole estimate rides on the factor nobody checked (Issue-439).
- When a change alters a contract the workflow itself consumes, run the workflow THROUGH it before ship — one live self-hosted dispatch falsifies premises that six review gates pass (Issue-439).
- A premise-freshness prober that checks named FILES cannot see a stale remote-tracking gap → compare the working checkout against the configured default_baseline itself (`rev-list --count main..origin/main`) before drafting; a 35-commit gap cost a whole plan revision (Issue-85).
- An artifact pinned to a gitignored, mutable input goes stale SILENTLY → record a provenance block for that input inside the artifact, and expect siblings elsewhere in the repo (Issue-106).
- When an inherited figure falsifies under measurement, correct it on the TRACKER where downstream readers look — fixing it only on the branch leaves every sibling issue quoting the wrong number (Issue-106).
- A suite that is green only in CI hides UNDECLARED PREREQUISITES, not local quirks — chase the delta and declare it; a bare `python3` with no version bound is how a stdlib-version break ships (Issue-561).
- After any history rewrite, re-verify every artifact's recorded SHA is still reachable (`git merge-base --is-ancestor <sha> HEAD`) — a replayed branch leaves artifacts citing commits that are no longer ancestors (Issue-561).
- Before requesting an override on a failing quality gate, ask whether the GATE is right and the ENVIRONMENT is wrong — an override is a permanent record of a compromise (Issue-561).

## Docs / edit-neighborhood hygiene
- Changing one claim/line → re-read its unchanged neighbours for a newly-created contradiction, and pin every parallel surface (command doc + script `usage()`) or they drift (Issue-321).
- A late "trivial" fix-commit that exceeds the scope a review authorized invalidates the evidence the MR cites → re-run the evidence at the new HEAD before ship (fleet Issue-3).
- The MR body is REGENERATED at ship, not authored once — every post-draftmr commit silently ages its evidence SHA, counts, and any claim a later review corrected elsewhere; the maintainer-facing document is the one home consumed alone, so it must be the LAST one re-stamped, never the first one forgotten (Issue-553).
- Evidence/count numbers must come from a run at THIS HEAD — stale counts copy forward silently; brand numbers need ONE derived source, not N hand-edits (Issue-284).
- Mixing measurement bases (whole-file before minus stripped-body after) inflates a headline while every individual number stays true → state the basis beside the number and subtract like from like (Issue-439).
- An audience-facing page inherits claims from its issue/source prose → verify every support/prerequisite/platform claim against the CODE and CI matrix; premise-rederive must cover ALL inherited claims, not just the ones that look stale (Issue-461).
- Every command a doc presents as pasteable → check arity against the command's own usage, and derive the guard's subject set from the doc (all fenced commands), never from the found instances (Issue-461).
- A diff that ADDS a top-level surface → update the documents that enumerate surfaces (spec layout tree, changelog, readme pointer) in the same change; being new is exactly what makes it invisible (Issue-461).
- Write each claim to the width of the diff → run the one command that would disprove it; if the output is narrower than the sentence, narrow the sentence (Issue-558).
- A fix that lands in code and the work log but not in the NORMATIVE doc downstream consumers implement from ships the bug to them → enumerate every home of the contract in the same edit (Issue-85).
- Docs that an agent EXECUTES are product behavior — 'deferred in the prose, decided in the instructions' is a real behavior change, just later; hold them to code-review standards (Issue-561).
- State SHA/version anchoring ONCE and refer to it by ROLE elsewhere — the same literal repeated in N paragraphs goes stale N times on every move (Issue-561).
- Pin the CLAIM, not one phrasing of it — a guard that fails when the text it guards is IMPROVED trains people to weaken guards (Issue-561).
- Running a VARIANT of a published command is not running it — a regex published in one dialect and executed in another returns a different count under an identical-looking claim; run every command in the exact form it will appear (Issue-106).
- A comment explaining a grep-based guard must DESCRIBE the token without spelling it, and say why — quoting the literal re-triggers the guard the comment is warning about (Issue-561).
- Recording a command VERBATIM into an artifact passes through layers that each re-interpret backslash escapes — a regex escape can land as a control byte and read as a mere variant; write it as explicit bytes and diff byte-for-byte against the published form (Issue-566).

## Version / registry-string comparison
- Version strings from heterogeneous sources (registry DisplayVersion, package managers) pad components differently (`26.02` vs `26.02.00.0`) and `[version]`/semver treats missing parts as lower → normalize component count before any behind/at-max comparison (fleet Issue-4).
