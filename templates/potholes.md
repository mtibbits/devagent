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
- A post-test quality refactor moves the UNTESTED surface (diagnostic actionability, branch reachability) → re-derive what the tests do NOT pin after restructuring a guard; a still-green suite is not the whole answer (Issue-Fork-165).
- Two failure paths sharing one exit code fake a born-red assert → attribute the red to the INTENDED path (pin the message substring, not the bare code) and stage test forms to the feature's introduction (Issue-Fork-132).
- `! cmd | grep` negation in bats is vacuous → `run grep …; [ "$status" -ne 0 ]`; when a red step unexpectedly passes, find out WHY (Issue-31).
- A grep presence-canary asserts `-eq 1` (precise no-match), never `-ne 0` (which conflates clean with error) (Issue-337).
- A fix that unblocks a previously-unreachable path can expose an env/tooling prerequisite the born-red run never reached → derive run prerequisites from the mode's own docs/runner, not from the failing repro (Issue-Fork-221).
- Ad-hoc test runs in an env-pinned session inherit the pins → only a hermetic (`env -u`) or harness-owned run is admissible evidence; re-running the same contaminated command at baseline confirms nothing (Issue-458).
- A guard whose glob stops selecting its subjects passes SILENTLY — relocating a file can empty a canary without reddening anything → enumerate the globs that select a file before moving it, and assert the subject COUNT (Issue-439).
- An observability marker computed from the same predicate as the mechanism it claims to observe is vacuous → set the marker from INSIDE the mechanism's own code path, then mutation-prove by breaking the routing, not the marker (Issue-Fork-162).
- A detector with N verdict classes needs a planted control per class — controlling only the dramatic class (crash) leaves the quiet one (wrong-answer) mutable to a no-op (Issue-Fork-162).
- A before/after evidence pair is like-for-like only when every nondeterminism source (seed, env) is pinned identically in both runs → find the seed knob before promising a diff-based proof, and record the pin inside each artifact (Issue-Fork-191).

## State / TOML / atomicity
- `sed`-append into a state TOML creates duplicate keys tomllib rejects → sed-REPLACE or route through the canonical `_toml.py` layer; never hand-roll a sectioned-config writer (Issue-116).
- A function that reads state to decide what to write must decide inside the lock → prefer a locked primitive (`set-many-if`, `--print-old`) over a read-then-write pair (Issue-240).
- Atomicity ACs pin by observing transaction TRAFFIC (shim the writer, assert co-carried fields) + crash injection — a race-window test is flaky-green theatre (Issue-317).

## Git / ambient checkout / forge state

- A locally-scaffolded issue number is provisional until the tracker write succeeds — never bake it into branch names or MR close-references before filed.toml exists (Issue-94).
- Any step that commits/pushes/merges → assert `HEAD == state.branch` first; steps that MOVE the checkout set traps for later steps ("acts on ambient git state, not the named target" is a defect family) (Issue-69).
- "Is this ref still a valid base?" depends on merge state → ask the forge; git topology can't see it, don't add heuristics (Issue-154).
- Any clever git/plumbing technique → validate empirically on a scratch repo BEFORE planning around it (Issue-33).
- A per-issue override marker (baseline, tier) consumed by a chained scripted step must be written at scaffold/pull time → an auto-chain reaches the consuming step without pausing, and the mis-based artifact must then be rebuilt (Issue-Fork-132).
- A `git diff --exit-code` restoration guard is vacuous while related work sits uncommitted (HEAD-relative diff always fails) → stage or copy aside the known-good state first and diff against THAT base (Issue-Fork-191).

## Sweeps / fix-at-source / sibling sites
- A getter/pattern with N consumers → fix at the SOURCE, enumerate all N up front, one regression test per site (fixing one and missing the twin is the classic) (Issue-82).
- Scoping one accessor to a context → scope-asymmetry bugs travel in PAIRS; audit its siblings for the same need (Issue-76).
- A mechanical `sed` sweep undercounts on single-line grep (the dominant form is a continuation line) and a variable-path sed evades every `.toml`-string canary → anchored pattern + `-A1` count + balanced-diff + a semantic check (Issue-335).
- A contract enumerated in N files → ONE sweep test over all N homes, extended in the same change that adds a home; it ships divergent exactly when the sweep lags the homes (Issue-458).
- Claiming a CLASS is closed → derive its members mechanically (grep the predicate); fixing the instances a checker handed you and declaring the class shut publishes a count the next reader disproves in one command (Issue-439).
- A value that has been corrected twice is a design defect, not a typo → remove the dependency on it rather than updating it a third time (Issue-558).
- A comment policing an ordering invariant marks a fix one layer too shallow → accumulate the fact at the site that produces it; empty-by-construction beats a re-derived condition defended in prose (Issue-Fork-132).
- A checker's green result overclaims unless its blind-spot SHAPE is written into the checker itself → state what it cannot decide beside what it asserts (Issue-558).
- A mechanically-derived class membership inherits its enumerator's blind spot → state the enumeration boundary beside any class-closed claim, and probe for members outside the enumerator's reach (Issue-Fork-191).

## New gate / shared-fixture blast radius
- Adding a guard/gate that reads shared fixture state → grep the fixture and COUNT affected tests FIRST; the fixture edit is Step 0, not a later debugging session (Issue-242).
- A new `die` in a step script → trace its `--auto`-chain interaction in the plan; a die mid-chain is a different product than one on direct invocation, and warnings can't gate autonomous flows (Issue-242).
- Replacing a lookup or scan → enumerate BOTH branches of the new logic and test each; a rewrite that fixes one direction can turn a fail-closed error into a fail-open wrong write (Issue-558).
- A new fail-closed gate turns some ROUTINE user action into its trigger → name that action in the error message and the user-facing docs, not just the defect class the gate was built for (Issue-Fork-132).
- Probe whether a new fail-closed gate's trigger ALREADY fires live (CI logs, current state) before building it, and land a deliberately-red outcome only with the remediation FILED plus a failure-text discriminator that keeps new signal visible (Issue-Fork-165).
- A diagnostic's first-listed remedy can be the guard's own bypass → order remedies fix-first, label silencing paths as reviewed de-scoping, and state what the bypassed state's green means (Issue-Fork-165).
- Registering a hard-contract test enrolls every lane/build shape its registration point reaches → enumerate those shapes and probe the exotic ones (or gate to the validated set with a broadening follow-up filed) before landing (Issue-Fork-162).
- A guard keyed to a build-type NAME misses the same condition arriving via injected flags → key it on a capability probe, not the configuration name; the first new consumer of an old mode inherits its ungated holes (Issue-Fork-162).
- A single-cause label on a multi-cause counter becomes misinformation when a change arms the second cause → re-read every aggregate/summary label sharing a counter with the newly-reachable failure path (Issue-Fork-191).

## Dispatched fresh-context checking
- Keep review/redmr/improve in dispatched fresh-context subagents — highest value exactly where the change "looks trivial and the tests are green" (Issue-316).
- A dispatched checker returning 0 tool-uses / echoing an instruction fragment is a MISFIRE, not a clean pass → verify the artifact was written; re-dispatch with a "do the work with tools" nudge (Issue-315).
- A checklist item a dispatched checker never RECEIVES is a dead tripwire → add the input to the dispatch-packaging list in the same change (Issue-286).
- An artifact relayed through another model session is NOT verbatim → the producer/relay writes it to a FILE; a low body-line floor passes an elided report as valid (Issue-458).
- A checker finding is a SAMPLE of a class, not a coordinate → grep for its siblings before fixing the named site, or the next round returns the same shape (Issue-558).
- Evidence written only to session-scoped storage is invisible to fresh-context checkers → every verification claim gets a durable artifact in the issue's analysis dir with the SHA recorded inside the file (Issue-Fork-225).

## Premise freshness / contracts / classification
- Re-derive an audit-issue's premises at HEAD before planning — it may be half-done, the A-vs-B menu may have changed, or the prerequisite may already have landed (Issue-116).
- An issue's named input can be wrong → verify it exists with the assumed content in scope/improve; surface the mismatch rather than building an inert fix (Issue-274).
- Building on an external tool/harness parameter → probe the CONSUMER's accepted-value contract live (closed enums reject values docs imply legal); split probe findings CONFIRMED vs ASSERTED by provenance — the read-not-measured rung is the one that breaks (Issue-458).
- A premise-freshness ✗ on a named file can be the issue's own DELIVERABLE → classify input-vs-output before treating absence as a falsified premise (Issue-458).
- Correcting or restating a prior record's claim → re-derive it from the PRIMARY artifact at execution time; the record's conclusion AND its inherited qualifiers are leads, not sources — if the artifact is gone, withhold rather than assert (Issue-Fork-138).
- A documented verified-non-fix gets re-proposed by every fresh reviewer → record the refutation at the code site itself, not only in the issue/plan (Issue-Fork-221).
- An issue's prescribed fix is an untrusted hypothesis, not a spec → verify it at HEAD before building on it (Issue-Fork-149's `## Fix` would have hung); and "which impl/path does this ACTUALLY run by default?" is a source question — read the dispatch/fallback logic, don't assume the measured or common case is the default (Issue-Fork-149).
- Two components that must agree on a format → test by feeding one's REAL produced artifact through the other, not a prose promise or a format check (Issue-232).
- A status ambiguous between "absent" and "can't-determine" → fail closed; a tri-state classifier makes the fail-safe un-violatable by construction (Issue-243).
- Match rigor to risk; tier the model to the FAILURE MODE, not the diff size (a 90-line interleaving diff earns opus; a proven-dead deletion earns one coupling sweep) (Issue-122).
- A verification claim is only true at the SHA it RAN at → re-run every claimed check at the final SHA before ship; fixing X silently invalidates each count derived from X being broken (Issue-439).
- A multiplier or figure inherited from an issue body is a MODEL, not a measurement → measure it before quoting a saving that is linear in it; the whole estimate rides on the factor nobody checked (Issue-439).
- When a change alters a contract the workflow itself consumes, run the workflow THROUGH it before ship — one live self-hosted dispatch falsifies premises that six review gates pass (Issue-439).
- A hypothesis about another platform/toolchain is often locally falsifiable (cross-compile, emulate, inspect the format) → run that probe before designing around the claimed behavior; ABI-level facts don't need the platform (Issue-Fork-225).
- A diagnostic that asserts a CAUSE it cannot verify misdirects every future diagnosis → report the observation plus discriminating evidence (what WAS found), never an unverified cause (Issue-Fork-225).

## Docs / edit-neighborhood hygiene
- Changing one claim/line → re-read its unchanged neighbours for a newly-created contradiction, and pin every parallel surface (command doc + script `usage()`) or they drift (Issue-321).
- Evidence/count numbers must come from a run at THIS HEAD — stale counts copy forward silently; brand numbers need ONE derived source, not N hand-edits (Issue-284).
- Mixing measurement bases (whole-file before minus stripped-body after) inflates a headline while every individual number stays true → state the basis beside the number and subtract like from like (Issue-439).
- An audience-facing page inherits claims from its issue/source prose → verify every support/prerequisite/platform claim against the CODE and CI matrix; premise-rederive must cover ALL inherited claims, not just the ones that look stale (Issue-461).
- Every command a doc presents as pasteable → check arity against the command's own usage, and derive the guard's subject set from the doc (all fenced commands), never from the found instances (Issue-461).
- A diff that ADDS a top-level surface → update the documents that enumerate surfaces (spec layout tree, changelog, readme pointer) in the same change; being new is exactly what makes it invisible (Issue-461).
- Write each claim to the width of the diff → run the one command that would disprove it; if the output is narrower than the sentence, narrow the sentence (Issue-558).
- A surface added while remediating a checker's finding postdates that checker's enumeration pass → re-ask spec-touch/enumeration questions at the final SHA, not the SHA the checker saw (Issue-Fork-221).
- A fix that retires a framing/standard mid-change re-opens every surface earlier judged fine under the old standard → re-run the parallel-surface enumeration against the NEW standard at the final SHA (Issue-Fork-225).
