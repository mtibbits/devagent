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

## Test discipline (born-red / vacuous pass)
- Born-red is a claim to VERIFY per test against the UNFIXED tree — a green suite over unfixed code is the compound failure (Issue-282).
- A floor/presence guard on a test that filters-after-discovering is vacuous → count what the assertions run against (after the filter) and mutation-test the guard itself (Issue-151).
- "did it run / processes all X" features → assert COUNT/coverage or an observable per-item effect, never just rc or the log (Issue-32).
- A born-red test whose fixture pre-seeds the asserted marker proves nothing → assert a delta/count, not mere presence (Issue-318).
- `! cmd | grep` negation in bats is vacuous → `run grep …; [ "$status" -ne 0 ]`; when a red step unexpectedly passes, find out WHY (Issue-31).
- A grep presence-canary asserts `-eq 1` (precise no-match), never `-ne 0` (which conflates clean with error) (Issue-337).
- A guard whose glob stops selecting its subjects passes SILENTLY — relocating a file can empty a canary without reddening anything → enumerate the globs that select a file before moving it, and assert the subject COUNT (Issue-439).

## State / TOML / atomicity
- `sed`-append into a state TOML creates duplicate keys tomllib rejects → sed-REPLACE or route through the canonical `_toml.py` layer; never hand-roll a sectioned-config writer (Issue-116).
- A function that reads state to decide what to write must decide inside the lock → prefer a locked primitive (`set-many-if`, `--print-old`) over a read-then-write pair (Issue-240).
- Atomicity ACs pin by observing transaction TRAFFIC (shim the writer, assert co-carried fields) + crash injection — a race-window test is flaky-green theatre (Issue-317).

## Git / ambient checkout / forge state
- Any step that commits/pushes/merges → assert `HEAD == state.branch` first; steps that MOVE the checkout set traps for later steps ("acts on ambient git state, not the named target" is a defect family) (Issue-69).
- "Is this ref still a valid base?" depends on merge state → ask the forge; git topology can't see it, don't add heuristics (Issue-154).
- Any clever git/plumbing technique → validate empirically on a scratch repo BEFORE planning around it (Issue-33).

## Sweeps / fix-at-source / sibling sites
- A getter/pattern with N consumers → fix at the SOURCE, enumerate all N up front, one regression test per site (fixing one and missing the twin is the classic) (Issue-82).
- Scoping one accessor to a context → scope-asymmetry bugs travel in PAIRS; audit its siblings for the same need (Issue-76).
- A mechanical `sed` sweep undercounts on single-line grep (the dominant form is a continuation line) and a variable-path sed evades every `.toml`-string canary → anchored pattern + `-A1` count + balanced-diff + a semantic check (Issue-335).
- Claiming a CLASS is closed → derive its members mechanically (grep the predicate); fixing the instances a checker handed you and declaring the class shut publishes a count the next reader disproves in one command (Issue-439).

## New gate / shared-fixture blast radius
- Adding a guard/gate that reads shared fixture state → grep the fixture and COUNT affected tests FIRST; the fixture edit is Step 0, not a later debugging session (Issue-242).
- A new `die` in a step script → trace its `--auto`-chain interaction in the plan; a die mid-chain is a different product than one on direct invocation, and warnings can't gate autonomous flows (Issue-242).

## Dispatched fresh-context checking
- Keep review/redmr/improve in dispatched fresh-context subagents — highest value exactly where the change "looks trivial and the tests are green" (Issue-316).
- A dispatched checker returning 0 tool-uses / echoing an instruction fragment is a MISFIRE, not a clean pass → verify the artifact was written; re-dispatch with a "do the work with tools" nudge (Issue-315).
- A checklist item a dispatched checker never RECEIVES is a dead tripwire → add the input to the dispatch-packaging list in the same change (Issue-286).

## Premise freshness / contracts / classification
- Re-derive an audit-issue's premises at HEAD before planning — it may be half-done, the A-vs-B menu may have changed, or the prerequisite may already have landed (Issue-116).
- An issue's named input can be wrong → verify it exists with the assumed content in scope/improve; surface the mismatch rather than building an inert fix (Issue-274).
- Two components that must agree on a format → test by feeding one's REAL produced artifact through the other, not a prose promise or a format check (Issue-232).
- A status ambiguous between "absent" and "can't-determine" → fail closed; a tri-state classifier makes the fail-safe un-violatable by construction (Issue-243).
- Match rigor to risk; tier the model to the FAILURE MODE, not the diff size (a 90-line interleaving diff earns opus; a proven-dead deletion earns one coupling sweep) (Issue-122).
- A verification claim is only true at the SHA it RAN at → re-run every claimed check at the final SHA before ship; fixing X silently invalidates each count derived from X being broken (Issue-439).
- A multiplier or figure inherited from an issue body is a MODEL, not a measurement → measure it before quoting a saving that is linear in it; the whole estimate rides on the factor nobody checked (Issue-439).
- When a change alters a contract the workflow itself consumes, run the workflow THROUGH it before ship — one live self-hosted dispatch falsifies premises that six review gates pass (Issue-439).

## Docs / edit-neighborhood hygiene
- Changing one claim/line → re-read its unchanged neighbours for a newly-created contradiction, and pin every parallel surface (command doc + script `usage()`) or they drift (Issue-321).
- Evidence/count numbers must come from a run at THIS HEAD — stale counts copy forward silently; brand numbers need ONE derived source, not N hand-edits (Issue-284).
- Mixing measurement bases (whole-file before minus stripped-body after) inflates a headline while every individual number stays true → state the basis beside the number and subtract like from like (Issue-439).
