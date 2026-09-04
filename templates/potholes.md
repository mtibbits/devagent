<!-- curated: ledger 25fd3e7a47aa75428ee4c4dcea605bd962703949 -->
<!-- POTHOLE REGISTER — public SEED (#286, curated #613). Highest-generality [pattern]
     lessons fed FORWARD into the draft step. This file is a curated EXCERPT: the full
     register lives in private layers (a shared workflow layer citing `(<project> Issue-N)`
     and one per-project layer citing `(Issue-N)`), read together as a UNION by
     `template.sh show potholes` (#611). Format contract (potholes_file_check, #613):
       - one line per entry, keyed by a DOMAIN TRIGGER (the situation that fires it);
       - each entry ends with its citation `(Issue-N[; Issue-M]).` — devagent issue numbers only;
       - at most 25 entries per section and 100 in the file (tests/potholes-seed-canary.bats);
       - line 1 names the migration ledger commit that says where every pre-#613 line went.
     The workflow never writes this file: step 22 stages lessons into the private layers
     (scripts/promote-potholes.sh --add --layer); the seed changes only by PR. Keep EVERY
     section heading, even one with no entries here — `--add` validates its section against
     the union of headings, and this file is the one every project has; an empty heading
     means the section's lessons live in the private layers, not that it has none.
     A reader with no private layers (a fresh install) sees this excerpt alone.
     Resolved via the §12 registry (project paths -> devdoc override -> plugin default). -->

# Pothole register

Known potholes plans keep being written into. Before drafting, check which triggers
match this issue and dispose of each match in `## Potholes considered`.

## Bash exit-status & control flow
- Pipe/`< <()`/loop-tail `&&`/`|| true` hide a non-zero exit as "found nothing" under `set -euo pipefail` → capture into a var with explicit `|| die`, THEN test emptiness (Issue-314).
- `cmd 2>/dev/null || true` on a maybe-undefined function returns empty (127 swallowed) and drives the wrong branch → `type <fn>` in the script's own source-set before relying on the fallback (Issue-316).
- A lib function returning >1 value → side-channel vars die inside `$(...)` subshells; choose setter-globals vs stdout-token BEFORE writing code, and grep call sites for `$(` (Issue-282).
- A resolver/setter that `die`-exits cannot live inside `$(...)` → the echo-wrapper-in-command-substitution is the non-fatal resolve shape (Issue-120).
- Two same-exit-code states that some caller must distinguish → mint distinct exit codes at the SOURCE; caller-side stderr-prose parsing is unguardable (a phrase-grep pins words, not behavior) (Issue-458).
- `cd "$(cmd)"` with an empty substitution SUCCEEDS in place, silently disarming a derived-path failure branch → capture the result and test non-empty before the cd (Issue-571).
- A tool that documents status exit codes is judged by THEM — deriving ran/failed/could-not-run by parsing its summary prose breaks on field ordering and vocabulary (a two-state summary matched a one-state prefix and recorded a clean false green) (Issue-466).
- `${s%%"$m"*}` yields the prefix of the FIRST match → per-occurrence attribution over `grep -o` output needs a per-line cursor, and a same-text-twice-on-one-line fixture (Issue-583).
- A helper that prints its diagnostic to stdout AND returns non-zero inside a `$(...)` capture under `set -e` is silent — the caller aborts at the assignment before printing what it captured → route the diagnostic to stderr (Issue-583).
- A script that writes then commits must snapshot before the write and restore on any post-write failure, dying with the staging record still pending — otherwise the retry defers on its own dirt forever (Issue-586).

## Test discipline (born-red / vacuous pass)
- A guard whose subject set can silently EMPTY passes vacuously — a floor/presence guard on a test that filters-after-discovering, a canary whose glob stops selecting its subjects when a file is relocated → count what the assertions actually run against (after the filter), assert the subject COUNT, enumerate the globs that select a file before moving it, and mutation-test the guard itself (Issue-151; Issue-439).
- A born-red test whose fixture pre-seeds the asserted marker proves nothing → assert a delta/count, not mere presence (Issue-318).
- A NEGATIVE assertion is vacuously satisfied by the wrong failure — `grep` returning 2 (could not run) reads as 'no match' under `-ne 0`, and a MISSING function's 127 satisfies rc != 0 and stderr non-empty → assert `-eq 1` (precise no-match), never `-ne 0`, and precede born-red negative tests with a `type <fn>` probe or pin the specific failure token, so absence and error redden instead of greening (Issue-337; Issue-572).
- Evidence is environment-bound — an ad-hoc run in an env-pinned session inherits the pins (re-running the same contaminated command at baseline confirms nothing), and a check green YESTERDAY and red TODAY at the same SHA is a question about WHICH ENVIRONMENT produced each run, not about drift → only a hermetic (`env -u`) or harness-owned run is admissible evidence, and an A/B across SHAs is valid only same-environment (Issue-458; Issue-559).
- A hand probe that asserts MEMBERSHIP is blind to a suite's EQUALITY pin — extending a single-source list passes `contains` and fails `equals`; when substituting probes for a suite, match the assertion SHAPE (Issue-561).
- Absence from a SUBSET result means NOT RUN, not PASSED — assert the name->file mapping is TOTAL before diffing a subset against a known failure set, because an unmapped name is silent and silence reads as success (Issue-561).
- A fast tier that never EXECUTES a real call path cannot see a control-flow regression → put the cheapest real end-to-end run first in the slow tier; five author regressions passed a full fast tier here (Issue-106).
- A guard that iterates the WHOLE tree is a cost you must measure before shipping it — time it against a normal test in the same suite; a per-file process pipeline over every tracked file can eat a fifth of a CI budget for one assertion, and a bare-token prefilter usually removes ~98% of it (Issue-566).
- A guard set that measures only SAFETY lets a half-built feature ship green -> every enabling task needs a positive-capability probe, because "clean" is also satisfied by "wrote nothing" (Issue-107).
- A multi-assertion guard reddens only at its FIRST failing assert — born-red evidence for the later legs requires probing each leg independently against the unfixed tree (Issue-123).
- Evidence generated in an environment where the suite is known never to be green produces an authoritative-looking artifact that fails the gate it feeds → generate gate inputs in the supported environment first, rather than building a case around a red number (Issue-550).
- A guard that passes only because two independently-derived quantities COINCIDE today is armed to mislead when they diverge → compare against the field that names the subject under test, never a lookalike value that happens to equal it at HEAD (Issue-118).
- When the defect makes the suite THINNER, the suite's own total is identical on both sides and cannot be the guard → assert the enabling CONDITION in a self-describing test that names the remedy (Issue-565).
- A test that greps the implementation's SOURCE passes on disabled code (`if false; then … fi`) and reddens on innocuous reflow → drive the entry point and stub the environment so the negative branch runs everywhere, not just where it is already impossible (Issue-565).
- A test-only ENV seam is answered from the environment by whichever production caller forgets to scrub it, and a fixture that EXPORTS the seam can make a planned test unable to pass in either direction → pass the seam as an ARGUMENT that REPLACES the ambient probes (an appended seam isolates nothing), read a fixture's exports before writing a test against an env-seamed branch, and scrub with `env -u` to reach the branch under test (Issue-565; Issue-578).
- Two concurrent runs sharing one worktree void each other: a checkout in one changes the tree under the other, and the victim's output is not a weaker result but NO result — one worktree per run, or serialise them (Issue-578).
- A fix that silences a false-positive diagnostic can disarm the loss-direction guard it shares state with — in a warn-only channel a false negative is strictly the worse trade → re-run the loss-direction fixtures before committing any "stop warning here" change, and add the "still warns there" negative in the same commit (Issue-582).
- A mutation row that goes inert after a later fix has found dead code → remove the code, retire the row with its reason recorded, and confirm its guard is still pinned by another row (Issue-582).
- When the operative call is silent on success, an ALLOW read is only the ABSENCE of the deny string → pair the stream read with a side-effect check so a no-op cannot false-pass (Issue-584).
- A LIMITS list is itself a set of claims: for every "surfaces as a miss, never as a pass" sentence, construct the input it describes and run the guard on it before shipping the sentence — the first such list shipped was wrong in the fail-open direction (Issue-583).
- A change to a manifest/config that clients CACHE is unmeasured by a fresh install — the population carrying the bug is the one holding the stale artifact → run two probes (fresh + upgrade-from-broken) and ship the recovery command in the user-facing doc (Issue-541).
- A negative-state token that CONTAINS the positive one as a substring makes a bare grep pass on the failing state → pin the exact marker and scope the match to the record, not to a line window (Issue-541).
- A guard and its own probe must share ONE predicate — a probe that re-spells the matcher tests a copy, so mutating the real one leaves every test green and the "pinned" property is unpinned (Issue-585).
- A source-grep guard that accepts an INDENTED match accepts a disabled one → anchor to column 0, then re-count the class; anchoring exposed a file passing the check on a line inside its own test body (Issue-585).
- An independent second count catches a silently-empty work list → verify a batch edit with an instrument that does not read the same list the loop consumed (Issue-585).

## State / TOML / atomicity
- Atomicity ACs pin by observing transaction TRAFFIC (shim the writer, assert co-carried fields) + crash injection — a race-window test is flaky-green theatre (Issue-317).

## Git / ambient checkout / forge state
- Merge state is not visible in git topology — 'is this ref still a valid base' depends on the forge, and a sibling's branch tip failing `merge-base --is-ancestor` does NOT mean its content is absent, because squash-merge rewrites identity → ask the forge for merge state (do not add heuristics), and verify a landed prerequisite by file state at the baseline, never by branch-tip ancestry (Issue-154; Issue-571).
- A whole-file `git add` during a long implementation sweeps CONCURRENT working-tree edits into the task's commit unrecorded → diff the staged hunks against the task's intent before committing, and treat a file reported as externally modified mid-session as a pending merge, not noise (Issue-572).
- An evidence run whose checkout FAILS, whose clone cannot reach the forge, or whose local ref never moved silently measures the OLD tree and records it under the new claim, and a green run on it reads as proof of the change → hard-abort on checkout failure, assert the sha actually materialised before measuring, and stamp the resolved SHA as the artifact's first data line (Issue-572; Issue-578).
- A deferral needs an ADDRESSEE that exists — a `Closes #N` keyword silently discharges acceptance criteria a scope split moved elsewhere, an obligation recorded only in a code comment or MR body has no owner, and naming a follow-up owner from memory calls a filed issue 'unfiled' → look the addressee up on the tracker, file the receiving issue and amend the closing one BEFORE ship (never as a merge-time promise), and carry the obligation in a committed, guard-asserted register the change itself carries (Issue-106; Issue-107).
- A forge executes its own closing-link set, not the PR body's prose — a sidebar-linked issue auto-closes even when the body disclaims it → for an MR that must NOT close its issue, query the PR's closing-issue references BEFORE merge, and re-check every related issue's state on the forge AFTER any merge; disclaiming the keyword in prose guarantees nothing (Issue-122; Issue-21).
- Untracked components (interpreter dirs, dependency caches, data dirs) never travel into a linked worktree → any tree-derived resolution must state its fallback for the worktree-without-the-component case before that mode ships (Issue-466).
- A rebase, squash or replay invalidates every SHA the workflow pinned — baseline, evidence head, prose commit refs — as a SET, and a replayed branch leaves artifacts citing commits that are no longer ancestors → after any history rewrite re-derive them all, re-verify each recorded SHA is still reachable (`git merge-base --is-ancestor <sha> HEAD`), and re-run the evidence validator, or the checker lies in both directions (Issue-466; Issue-561).
- A write into the shared source tree that no workflow step commits is a loss, not a delay: name the committing step, or stage to a per-issue file and drain it from the step that owns the base branch (Issue-586).
- Path-containment rails must canonicalise both sides (cd && pwd -P) before comparing — Git Bash /c/… never equals c:/… — and an unresolvable side must die, not degenerate the glob to /* (Issue-586).
- A DEFAULT git pathspec lets `*` cross `/` → use `:(glob)` magic wherever the wildcard is meant to stop at a directory boundary, or the enumeration silently reaches into subdirectories (Issue-585).

## Sweeps / fix-at-source / sibling sites
- A defect found at one site is a SAMPLE of a class — a getter/pattern with N consumers, a checker's named line, the instances a checker handed you — and 'the class is closed' is a count the next reader disproves in one command → fix at the SOURCE, derive the members mechanically (grep the predicate) before fixing the first, one regression test per site, and never declare the class shut from the instances you were handed; fixing one and missing the twin is the classic (Issue-82; Issue-558; Issue-439).
- Scoping one accessor to a context → scope-asymmetry bugs travel in PAIRS; audit its siblings for the same need (Issue-76).
- A mechanical `sed` sweep undercounts on single-line grep (the dominant form is a continuation line) and a variable-path sed evades every `.toml`-string canary → anchored pattern + `-A1` count + balanced-diff + a semantic check (Issue-335).
- A contract or claim enumerated in N homes needs ONE sweep whose subject list grows with N in the same change — a diff that ADDS a top-level surface must update the documents that enumerate surfaces (spec layout tree, changelog, readme pointer), and a change that enrols a NEW home in an 'all N homes state X' claim must grow the guard's asserted-home list to N → derive the pin list from the claim, not from the pre-change test; being new is exactly what makes a home invisible, and the sweep ships divergent exactly when it lags the homes (Issue-458; Issue-461; Issue-583).
- A value that has been corrected twice is a design defect, not a typo → remove the dependency on it rather than updating it a third time (Issue-558).
- A programmatic edit (`sed`, string-replace) that silently NO-OPS leaves a false record when you verify a proxy instead of the edited file → grep the edited file for the new text before booking the fix (Issue-106).
- A repo-wide sweep must DECLARE its universe and prove the edge: enumerate from the tracked set (not the filesystem, which carries ignored mutable junk), pass the NUL-delimited form so unusual filenames survive quoting, and probe it with a subject whose NAME exercises the edge rather than only its contents (Issue-566).
- A re-value/re-baseline sweep misses pins living behind gated or slow tiers (env-flag, archive-dependent, subprocess) → enumerate subjects by grepping the LITERAL across ALL tiers and run every gated tier once before declaring the sweep complete; the miss surfaces as a red at the next issue's least convenient moment (Issue-122).
- An honesty fix that documents a guarded token's history is itself a new match for the token census — write deliberate-reference buckets into the census contract up front, and re-derive the count at the final SHA after EVERY fix wave, never carry it forward (Issue-119).
- A def-time parameter default freezes an import-time value and defeats runtime redirection -> pass a None sentinel and resolve inside the function when the value can vary per run (Issue-107).
- Before adding a probe/helper, grep for the QUESTION it decides, not the name you would give it — two implementations that can disagree about one question is the defect, and a fresh file's self-justifying rationale is unaudited (Issue-565).
- A swept CLASS derived by a PHRASING regex is walk-past-able — a differently-worded member slips through while the canary greens on the safe change → derive the class from the minimal invariant token plus a commented allow-list of legitimate non-members (Issue-541).
- "Widening" a matcher is a claim to MEASURE: run old and new over a fixture list and diff the match sets — a replacement committed as a widening lost the shapes the original caught and shipped as a coverage regression (Issue-585).

## New gate / shared-fixture blast radius
- Adding a guard/gate that reads shared fixture state → grep the fixture and COUNT affected tests FIRST; the fixture edit is Step 0, not a later debugging session (Issue-242).
- Replacing a lookup or scan → enumerate BOTH branches of the new logic and test each; a rewrite that fixes one direction can turn a fail-closed error into a fail-open wrong write (Issue-558).
- Changing a serialized format can invalidate a certificate that hashes the FILE rather than its contents → grep for file-level hashers first, and pin the container's key set in the same change; content hashes cannot see a key appear (Issue-106).
- A no-override refusal with no operator seam converts every configuration outside the validated set from "unsupported" into "unshippable" → pair the fail-closed verdict with an explicit escape seam and record the seam's use in the artifact (Issue-466).
- The repo's CI gates and a diff-scoped local analyzer scan DISJOINT surfaces → before ship, run each CI gate's command verbatim over its own scope; a green analyze step predicts nothing about a gate keyed to a different file set or rule class (Issue-466).
- A hermetic harness that isolates only the tool's CONFIG dir still resolves the tool's STATE home → give the ladder a scratch state root with a fixture positioned at the step under test, restore it between runs, and record it in every stream artifact (Issue-584).
- Read a step's EXIT CODE before recording it done — a step marked done while its script exited non-zero publishes a false record the next reader inherits (Issue-585).
- When evidence needs a capability ABSENT, look for an invocation-scoped switch before mutating global state: a per-invocation settings override removed exactly the target and left everything else, with nothing to restore and no crashed-run failure mode (Issue-585).

## Dispatched fresh-context checking
- A headless (`-p`) transcript captures final TEXT, not tool calls, so an agent can narrate the expected output of a call that was actually DENIED — plausible fabricated success prose over zero execution → every headless probe asserts an unforgeable token (a nonce in stdout) or reads the tool result from the machine event stream; a prose claim of execution is inadmissible and is withdrawn rather than left standing (Issue-548; Issue-585).
- A check that was not RUN is an open risk, not coverage — a checker's prediction you cannot execute, a test line added but never run, a gate that WARNS it cannot verify something and passes on the remaining rungs → record it as an open risk or execute the skipped check by hand and record that, and treat the pass as provisional until it runs (Issue-550; Issue-561).
- Keep review/redmr/improve in dispatched fresh-context subagents — highest value exactly where the change "looks trivial and the tests are green" (Issue-316).
- A mechanical evidence gate and an adversarial reader catch DISJOINT classes — the gate reads two lines and misses false prose; the reader misses arithmetic. A green gate is not evidence the body is true (Issue-561).
- Several findings in one round often share ONE structural cause → look for it before fixing them individually; reverting the decision can close all of them, where fixing each spawns the next round's defects (Issue-106).
- A guard cited as what makes a trade acceptable must be quoted with its FULL state table — summarising a tri-state guard as two-state hides the branch the reader will land on, and the omitted branch is often already documented in your own evidence artifact (Issue-578).

## Premise freshness / contracts / classification
- A permission/pattern matcher compares LITERAL emitted forms — a rule silently never matches an emission differing only in quoting, bracing, case or argument presence, and refuses a MULTI-LINE command whose first line prefix-matches the grant → capture the exact emitted strings mechanically, treat the emission shape (prefix, quoting AND line count) as part of the grant contract, and probe each call shape (backslash-continued forms included) before sweeping grants or rules (Issue-584; Issue-548).
- A plan built on a version-gated NEGATIVE ("measured NO at version V") must re-measure that negative at the CURRENT version as its FIRST cell, with an explicit STOP wired for the flip — a vendor can silently land the capability and convert every planned branch at once (Issue-548).
- An issue's named input can be wrong → verify it exists with the assumed content in scope/improve; surface the mismatch rather than building an inert fix (Issue-274).
- A premise-freshness ✗ on a named file can be the issue's own DELIVERABLE → classify input-vs-output before treating absence as a falsified premise (Issue-458).
- Two components that must agree on a format → test by feeding one's REAL produced artifact through the other, not a prose promise or a format check (Issue-232).
- A status ambiguous between "absent" and "can't-determine" → fail closed; a tri-state classifier makes the fail-safe un-violatable by construction (Issue-243).
- A cost measurement is machine- and input-vintage-bound — "smaller input, so the prior number is an upper bound" is a hypothesis to measure, not a bound to book; when measurement falsifies it, push the correction to whoever booked the number (Issue-123).
- An evidence artifact saved under a non-canonical filename silently drops out of its mechanized checker's glob — the checker validates the wrong file and the mismatch reads as staleness; canonical names are part of the evidence contract (Issue-559).
- Match rigor to risk; tier the model to the FAILURE MODE, not the diff size (a 90-line interleaving diff earns opus; a proven-dead deletion earns one coupling sweep) (Issue-122).
- An artifact pinned to a gitignored, mutable input goes stale SILENTLY → record a provenance block for that input inside the artifact, and expect siblings elsewhere in the repo (Issue-106).
- A suite that is green only in CI hides UNDECLARED PREREQUISITES, not local quirks — chase the delta and declare it; a bare `python3` with no version bound is how a stdlib-version break ships (Issue-561).
- Before requesting an override on a failing quality gate, ask whether the GATE is right and the ENVIRONMENT is wrong — an override is a permanent record of a compromise (Issue-561).
- A portability constraint a plan asserts ("POSIX only", "works on the minimal implementation") is a claim until the constrained implementation runs it → shim it into PATH, run every fixture, record the transcript in the evidence artifact, and repeat after each change to the constrained code (Issue-582).
- A per-file tool allow-list can be ADDITIVE, not a ceiling → prove it with a grant-less control before adding tools to "restore" a ceiling; a listed tool is a widening (Issue-584).
- A "mechanical sweep" premise is only as good as a census taken at HEAD → make the census the first plan task and route every falsified premise through question-return, not a guessed fix (Issue-584).
- An operator approval is pinned to the ARTIFACT VERSION it was given on, and the identity that ties rounds together ('same URL/ID as last round') is unfalsifiable when logged only as a parenthetical inside another step's line → one log line per round carrying the round label and the equality it asserts (an unlogged round is an unauditable round), and on any redeploy to the same URL, even a presentation-only one, record the delta and re-invite review before the irreversible act the approval gates (Issue-462).
- An evidence/verification script older than the fix that scopes it cannot honour that scope no matter which input you set → grep the TOOL for the fix's function before debugging its inputs; a stale clone runs the pre-fix resolver (Issue-570).
- A detector over historical prose is designed from the live corpus, not the imagined one: grep every line it will run on and pin a must-trip and a must-not-trip case from real entries (Issue-586).

## Docs / edit-neighborhood hygiene
- The maintainer-facing MR body and its checklist boxes are falsifiable claims about the branch at the FINAL SHA — the body is REGENERATED at ship, not authored once, so every post-draftmr commit silently ages its evidence SHA, counts, and any claim a later review corrected elsewhere → derive each box from a command at the final SHA (trailer sweep, tip equality, count re-run) and re-stamp the body LAST, never leave it the first one forgotten; a box checked from memory ships a false certification the verifier will catch (Issue-553; Issue-119).
- An audience-facing page inherits claims from its issue/source prose → verify every support/prerequisite/platform claim against the CODE and CI matrix; premise-rederive must cover ALL inherited claims, not just the ones that look stale (Issue-461).
- Docs an agent or a test EXECUTES are product behaviour — every command a doc presents as pasteable is checked for arity against the command's own usage, with the guard's subject set derived from the doc (all fenced commands) rather than from the found instances; 'deferred in the prose, decided in the instructions' is a real behaviour change held to code-review standards; and an executed-doc test couples every doc it extracts from, so announce the coupling INSIDE each coupled doc (an editor note beside the fence), not only in the test's failure message (Issue-461; Issue-561; Issue-583).
- Write each claim to the width of the diff → run the one command that would disprove it; if the output is narrower than the sentence, narrow the sentence (Issue-558).
- Pin the CLAIM, not one phrasing of it — a guard that fails when the text it guards is IMPROVED trains people to weaken guards (Issue-561).
- Running a VARIANT of a published command is not running it — a regex published in one dialect and executed in another returns a different count under an identical-looking claim; run every command in the exact form it will appear (Issue-106).
- A comment beside an assertion can claim more than the assertion buys → for each claim, name the input that makes THAT line fail first; if a neighbouring assertion always catches it first, say belt-and-braces (Issue-550).
- A doc line is classified by the SECTION that frames it, not by when it was written — a historical note under a "current state" heading is a live false claim → read the enclosing heading before granting append-only immunity (Issue-541).
- A fix that removes a mutable global input can RELOCATE the staleness rather than close it (a guard that fires only on unset still reuses a stale non-empty value) → ask where the staleness moves to and say so, or the same wrong-destination class returns wearing a new source (Issue-570).

## Version / registry-string comparison
