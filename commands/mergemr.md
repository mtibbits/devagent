---
description: "Step 20: merge the issue's PR at the verified head when permissions.merge_mr = true (a head preship-verified-head.sh forward re-recorded merges only on green CI); otherwise mark the step waiting [?] until the PR is merged."
allowed-tools: Bash(bash "${CLAUDE_PLUGIN_ROOT}/scripts/*"), Bash(bash "${CLAUDE_PLUGIN_ROOT}/scripts/*" *)
argument-hint: "[project] [issue]"
---

# /devagent:mergemr

Invokes `scripts/mergemr.sh` with the parsed arguments per spec §6.1:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/mergemr.sh" <project> [issue]
```

The step after mergetoall and before updatewbs (#885). It reads the PR that
ship recorded (`mr_url`) and decides at once; nothing waits. It merges only
when `permissions.merge_mr` is exactly `true`, and only at the head the last
passing `/devagent:preship` recorded as `verified_head`, or that
`preship-verified-head.sh forward` re-recorded after a merge-forward git made
itself (#1125; merged only on green CI, rule 17). With `required_checks` set
(#1097) it merges only when each of those CI checks is `success` at that head,
and only when the PR's own diff cannot change what they measure or the
operator has acknowledged that diff for that head (rule 21). On a code
backend that cannot report checks it stops `[!]` `CI NOT CHECKED` (rule 20).
It never uses the permission gate, so `DA_YES=1` and an interactive terminal
cannot open it.
With `merge_mr` false or unset it never merges by any route: it marks `[?]`
until the PR is merged elsewhere, and stops `[!]` only where a rule that
applies whatever `merge_mr` says stops (rules 4 and 20). Rule 21 does not
stop it then: the `[?]` line names the self-certifying paths instead.

## How a run ends

The step marks its own row by name and exits:

- `[x]` merged, or `[-]` ship was skipped: exit 0. `/devagent:next` continues.
- `[?]` waiting: exit 0. It prints `mergemr: waiting (<rule>): <reason>` and
  logs `waiting (<rule>): <reason>` only when that differs from the last
  `mergemr:` log line, so repeated runs do not fill the log. Run
  `/devagent:next` again later to re-check; do not poll.
- `[!]` a stop: exit 1. It writes `STUCK` (via `checklist-stuck.sh --name
  mergemr`) with the reason `mergemr rule <N>: <text>`.

Every run that reads the PR also prints the `CI …:` line and logs it under
`ci:` (deduplicated, as #782 does).

## Decision order (first match wins)

`<rule>` is the number below, or `read` for a read that decided nothing.
Rules 1-8 apply whatever `merge_mr` says; rules 9-19 only when the step would
merge; rules 20-21 are operator-only stops; each row states where it sits in the order.

| # | condition | mark — text |
|---|---|---|
| 1 | ship `[-]` | `[-]`, log `skipped: ship was skipped (no PR)` |
| 2 | no `mr_url` | `merge_mr = true`: `[!]` `no PR URL recorded for this issue; merge the PR by hand, then run /devagent:unstuck and mark this step [x] with /devagent:checklist-mark`; otherwise `[?]` `no PR URL recorded for this issue; merge the PR by hand, then mark this step [x] with /devagent:checklist-mark` |
| read | the PR read failed, timed out or was incomplete | `[?]` `could not read PR <url>: <error>`; no STUCK |
| 3 | PR merged | `[x]`, log `PR <url> merged (merge commit <oid or ->)`, then `on_merge` |
| 4 | PR closed unmerged | `[!]` `PR closed unmerged. To close out an abandoned PR, run /devagent:unstuck, then mark this step [-] with /devagent:checklist-mark` |
| 5 | draft PR | `[?]` `draft PR` |
| 6 | base is not the default base (`default_baseline` without its remote, else `main`) | `[?]` `stacked on <base>`. The step does not retarget; retarget the PR on the forge |
| 7 | a dependency is not satisfied | `[?]` `waiting for <dep> (<found>)[; <dep> (<found>)…]`; a failed dependency read: `[?]` `could not read <dep> <PR state\|linked PRs\|tracker state>: <error>`; a tracker with no `state-class`: `[?]` `cannot read <dep> tracker state on <backend>; merge order is yours: record its PR as [context.<dep>].mr_url, or merge by hand, then mark this step [x] with /devagent:checklist-mark` |
| 8 | `merge_mr` not `true` | `[?]` `waiting for merge (<CI result>, <mergeable>/<mergeStateStatus>)`. With `required_checks` set (#1097) the line ends `; required checks at <sha7>: <name>: <state>[; <name>: <state>…]`: every required check in config order, at the PR head, `<state>` as "Config and knobs" lists them. Then `; self-certifying: <result>`, rule 21's scan: `none`, the paths (as rule 21 lists them, then ` (acknowledged)` once the operator has acknowledged them for this head), or `unknown (<why>)`; besides rule 21's reasons, `<why>` is `no verified head recorded` or, because the result would describe another commit, `PR head <sha7> is not the verified head <sha7>` |
| 9 | the PR is not on ship's target repo (`code_source.upstream`, or `code_source.fork` under `fork_first`; case-insensitive) | `[!]` `PR is not on <target>; it is on <repo>. Fix mr_url or code_source, then run /devagent:unstuck`. No target configured: `[!]` `no code_source.upstream configured for '<project>'; set it, then run /devagent:unstuck` |
| 10 | no `verified_head` | `[!]` `no verified head for this PR; run /devagent:preship` |
| 11 | PR head is not `verified_head` | `[!]` `PR head <sha7> was not verified; run /devagent:preship on it (or push the verified head <verified sha7>)`. With auto-merge on, it first disables it and adds ` (auto-merge disabled)`, or ` (could not disable auto-merge: <error>; disable it on the forge)` |
| 12 | auto-merge on, or the PR is in a merge queue | `[?]` `merge accepted; waiting (<CI result>, <mergeable>/<mergeStateStatus>)`, ending with rule 8's `; required checks at …; self-certifying: …` when `required_checks` is set; no second merge call. The PR is left to the forge only when no later rule still has to decide. It is not left when the head was recorded by `forward` (as rule 17 reads `verified_by`) and CI is not green (#1125): `<why>` is `head <sha7> was recorded by forward and merges only on green CI (<CI result>)`, and the stops below are rule 17. Otherwise it is not left when a required check is not `success` (#1097): `<why>` is `head <sha7> merges only when every required check is successful`, and the stops below are rule 15. Otherwise it is not left when the PR's diff is self-certifying and not acknowledged for this head, or cannot be read (#1097, rule 21): `<why>` is `head <sha7> merges only when an operator has acknowledged its self-certifying diff`, or `head <sha7> merges only when its self-certifying diff can be read`, and the stops below are rule 21. With auto-merge on, the step disables it, prints `mergemr: auto-merge disabled: <why>`, logs the same text, and the rules below decide. A failed disable is `[!]` `<why>; could not disable auto-merge: <error>; disable it on the forge, then run /devagent:unstuck`. In a merge queue it is `[!]` `<why>, but the PR is in a merge queue; remove it from the queue on the forge, then run /devagent:unstuck`. Both stops end with rule 8's `; required checks at …; self-certifying: …` when `required_checks` is set |
| 13 | `mergeable` or `mergeStateStatus` is `UNKNOWN` | `[?]` `mergeability not computed yet` |
| 14 | `CONFLICTING` | `[!]`, naming git's own conflicted paths (`git merge-tree` of `verified_head` and the base tip, after one bounded fetch of `default_baseline`; `<paths>` sorted, joined `, `). With `merge_forward` `verify = "ci"`, every conflicted path in `append_only`, merged by git as text and only insertions on both sides (each conflict hunk's base section empty), no merge driver on any path of git's merged tree (as `forward` checks), and no merge gate in `mr.md`: `conflict only in <paths>; merge it forward keeping both sides' lines, run rebaseline.sh, push, then run preship-verified-head.sh forward`. Otherwise `conflict with <base> in <paths>; merge it forward, run rebaseline.sh, re-run run-suite.sh and evidence-stamp.sh (review.md 6a), push, then run /devagent:preship`. When the paths cannot be known: `conflict with <base> (conflicted paths unknown: <why>); <the same remedy>`, `<why>` one of `could not fetch '<remote>' (<reason>)`, `cannot resolve <base_ref>`, `git merge-tree exited <rc>`, `cannot resolve the issue tree: <reason>`, `a conflicted path contains a newline`, `git reports a conflict but names no conflicted path`. When git finds none: `conflict with <base> (git finds no conflict between <verified sha7> and <tip sha7>); <the same remedy>` |
| 15 | CI red (red wins over pending); a required check that ended without success, or is still not reported after the grace | `[!]` `<CI FAILED line>; fix it, re-run run-suite.sh and evidence-stamp.sh (review.md 6a), push, then run /devagent:preship`. A required check (#1097) that ended without success, even while other checks are pending (a failed one is red CI and stops with the line above): `[!]` `required check not successful on head <sha7>: <name> (<how it ended>)[; <name> (<how it ended>)…][; not reported: <name>[; <name>…]]; re-run the job on the forge and run /devagent:unstuck, or fix it, re-run run-suite.sh and evidence-stamp.sh (review.md 6a), push, then run /devagent:preship`. A required check still not reported after the grace, decided after rule 17's forward stop and before its no-checks arm, so `merge_checks = "if-present"` never merges past it: `[!]` `required check not reported on head <sha7> after <n>s: <name>[; <name>…]; start it on the forge and run /devagent:unstuck, or push a head that runs it, then run /devagent:preship` |
| 16 | CI pending or unknown, no checks inside the grace, or a required check not reported inside the grace | `[?]` the `CI …:` line (a pending required check is a pending check); no checks yet: `checks not reported yet (grace <n>s)`; CI otherwise done and a required check not reported yet: `required check not reported yet: <name>[; <name>…] (grace <n>s)` |
| 17 | a head recorded by `forward` (#1125) that is not green, or no checks after the grace | `verified_by` is `forward` (or unreadable, or neither `preship` nor empty) and CI is not green: `[!]` `head <sha7> was recorded by forward and merges only on green CI (<CI result>); to verify it in full, re-run run-suite.sh and evidence-stamp.sh (review.md 6a), push, then run /devagent:preship`. Otherwise (a required check not reported has stopped at rule 15 by now) no checks after the grace: `merge_checks = "required"`: `[!]` `no CI checks on head commit; set merge_checks = "if-present" to merge without CI, then run /devagent:unstuck`; `"if-present"`: continue |
| 18 | `mergeStateStatus` not `CLEAN` or `HAS_HOOKS` (e.g. `BLOCKED`, `BEHIND`) | `[!]` `blocked by a forge rule (<status>); resolve it on the forge, then run /devagent:unstuck` |
| 19 | merge | see below |
| 20 | `required_checks` set (#1097) and the code backend cannot report checks | `[!]` `CI NOT CHECKED: <why>; required check <name>[, <name>…] cannot be read on this code backend; check it by hand, merge the PR by hand, then run /devagent:unstuck`, whatever `merge_mr` says. Where the step cannot read the PR's state either (a github backend without `mr-view`; another backend without `mr-state`) no later run can see the hand merge, and the text ends `…, then run /devagent:unstuck and mark this step [x] with /devagent:checklist-mark`. It sits where the PR is read: on a github backend whose script has no `mr-view` (exit 78 or 2), in place of the `read` wait and so ahead of rule 3; on any other backend, in place of rule 8's `[?]` for an open PR or of the `cannot read PR state` `[?]`, as "Other code backends" says. `<why>` is `<backend> has no <verb>` (`mr-view`, `mr-checks` or `mr-state`) or `local code backend` |
| 21 | `required_checks` set (#1097) and the PR's diff is self-certifying, as "Self-certifying diffs" defines it, and not acknowledged for this head | `[!]` `self-certifying diff: <paths> changed in <base sha7>..<head sha7>, so this PR can change what its required checks measure. Operator only (reviewed workflow change only): record the review in <issue-dir>/.devagent-selfcert-ack as commands/mergemr.md "Escapes" describes, then /devagent:unstuck`; `<paths>` sorted, joined `, `, the first 10 and then ` (+<n> more)`. It sits after rule 18 and before rule 19, so only when the step would merge: CI is green and no forge rule blocks, and one acknowledgment covers one green head. Under `merge_mr` false nothing stops: rule 8's line names the paths. Acknowledged for this head, the step prints `mergemr: self-certifying diff acknowledged at <sha7>: <paths> — <reason>`, logs it once per recorded head, and goes on to rule 19. When the diff cannot be read: `[!]` `self-certifying diff unknown: <why>; fix that, then run /devagent:unstuck`, `<why>` one of `no baseline_sha recorded`, `<sha7> is not a commit in <tree>`, `git diff exited <rc>`, `required_checks_paths entry '<entry>' names no path at <base sha7> or <head sha7>; fix the key, or merge the base forward` |

A `/devagent:preship` pass after ship records the new head and clears a rule
10, 11, 14 or 15 stop by itself, forward's rule-17 stop, and a stop left by a
failing post-ship preship. A successful `preship-verified-head.sh forward`
(#1125) clears a rule-14 stop, and a rule-11 stop that names HEAD's short SHA;
never rule 10, 15, a `preship:` stop or its own rule 17. Every other stop names
`/devagent:unstuck`. Rule 15's own stop over a required check names both: the
passing preship for a new head, `/devagent:unstuck` once the check has
succeeded at the same head. The rule-15 stops rule 12 raises name
`/devagent:unstuck` only; a passing preship clears them as well. A rule 20
or rule 21 stop is the operator's: no preship pass and no `forward` clears it.

## Dependencies (rule 7)

For each entry of `<state>/<project>.depends.toml`, the first source that
answers decides; an `Issue-Fork-N` dependency reads `issue_source_fork`,
any other `issue_source`:

1. its recorded PR (`[context.<dep>].mr_url`), via `mr-state`: merged is
   satisfied; open or draft waits `PR open`; closed waits `PR closed unmerged`;
2. its linked PRs, one `issue-mrs` call per tracker repo (a GitHub tracker
   only): merged is satisfied; open or draft waits `PR open`; none, or only
   closed-unmerged PRs, falls through;
3. its tracker issue, via the issue backend's `state-class`: closed as
   completed is satisfied; open waits `open, no PR`; closed for another
   reason waits `closed: <reason>` (e.g. `closed: not planned`), so you
   decide whether to drop the dependency.

A dependency is readable only with a GitHub tracker or a recorded `mr_url`;
on any other tracker (no `state-class`) the step waits and names the remedy.

## Self-certifying diffs (rule 21)

With `required_checks` set (#1097), a PR is self-certifying when its own
diff, `baseline_sha..verified_head` (the two commits compared), can change
what those checks measure. The paths that count:

- every changed file under `.github/workflows/`;
- every changed file that is, or is under, a `required_checks_paths` entry;
- every changed `*.bats` file, at any depth, that had a Git Bash tag line at
  `baseline_sha` (a comment line naming `file_tags` and `gitbash`, in any
  case) and whose tag lines at `verified_head` are not the same lines: one
  was removed or edited, or the file was deleted or renamed (it is named by
  its old path). A file with no tag line at `baseline_sha` never counts, so
  adding a tag line, or a new tagged file, does not stop.

The commits are read in the issue's recorded tree while it exists, else in
`source_dir`, which keeps a removed worktree's commits. A commit that is not
there gets one bounded fetch by id from `default_baseline`'s remote first; it
writes no ref. After a merge-forward, `rebaseline.sh` moves `baseline_sha` to
the base commit merged in, so the base's own workflow changes are not the
PR's.

## Merging (rule 19)

- A squash whose PR has more commits than the read returned stops:
  `[!]` `PR has <total> commits but <read> were read; the squash trailers would be incomplete. Merge it by hand, then run /devagent:unstuck and mark this step [x] with /devagent:checklist-mark`.
- Otherwise one `merge-mr <url> --method <merge_method> --match-head-commit
  <verified_head>`. A squash adds `--subject "<PR title> (#<PR number>)"`
  and `--body`, always passed even when empty: one `Closes #N` line per
  entry of the PR's `closingIssuesReferences` (`Closes <owner>/<repo>#N`
  for another repo; a PR that only says `Related: #N` closes nothing), a
  blank line when both blocks are present, the distinct `Signed-off-by:`
  lines of its commits, then their `Co-authored-by:` lines unless
  `include_coauthor = false`.
- A failed call (a method the repo disallows, a head mismatch, a forge
  rule, a network error, a timeout) is `[!]` `merge call failed: <gh's last
  line | timed out after <n>s>; then run /devagent:unstuck`. If the timeout
  killed a call GitHub had already accepted, the run after unstuck sees the
  merge through rule 3.
- After a successful call it reads the PR again: merged is `[x]`, logged as
  `merged <url> by <method> at <verified_head> → <merge commit>`, then
  `on_merge`; still open is `[?]` (rule 19) `merge accepted; PR still open
  (merge queue or auto-merge)`, logged as `merge accepted <url> by <method>
  at <verified_head>; PR still open`, and rule 12 then waits; a failed
  re-read is `[?]` `could not read PR after merge: <error>`; closed is rule 4.

## on_merge

When the step merges the PR, or first sees it merged, it fires the tracker's
`on_merge` transition unless sync's merge marker is already in this
revision's log, through the same helper sync uses (`lib/merge-marker.sh`).
The transition is behind `permissions.transition_issue`; with it off,
nothing fires and no marker is written, so enabling it later still fires
once. The marker is the line sync writes, under the `sync` tag, e.g.
`sync: Issue-N merged → on_merge landed: "Done" on <repo>`. sync and this
step can race: the marker is written after the transition, so a
non-idempotent custom issue backend may see the transition twice.

## Other code backends

Merging is GitHub only. On any other `code_source.backend`, after rules 1
and 2 and whatever `merge_mr` says, one `mr-state` read decides: merged is
`[x]` (log `PR <url> merged (merge commit -)`) and `on_merge`; closed is
rule 4; draft is `[?]` (rule 5) `draft PR`; open is `[?]` (rule 8) `waiting
for merge (merge step supports github only)`; a backend without the verb (exit 78 or 2) is `[?]` `cannot
read PR state on <backend>; merge by hand, then mark this step [x] with
/devagent:checklist-mark`; any other failure is `[?]` (read) `could not
read PR <url>: <error>`.

With `required_checks` set (#1097) the step does not leave such a PR waiting
for a hand merge while nothing can say its required checks succeeded. Merged,
closed and draft read as above. An open PR gets one more read, `mr-checks`
(the `local` backend is not asked):

- a backend without that verb (exit 78 or 2), and the `local` backend: rule
  20, `[!]` `CI NOT CHECKED: <backend> has no mr-checks; …` or `CI NOT
  CHECKED: local code backend; …`;
- a failed read: `[?]` (read) `could not read required checks on <url>:
  <error>`; no STUCK;
- a backend that has the verb: rule 8's `[?]`, ending `; required checks at
  <sha7>: <name>: <state>[; <name>: <state>…]; self-certifying: <result>` as
  on GitHub.

After the hand merge and `/devagent:unstuck`, the next run reads the PR as
merged and marks `[x]`; `/devagent:unstuck` alone stops again.

A backend without `mr-state` (exit 78 or 2) is the same rule 20 stop in place
of the `[?]` above, `CI NOT CHECKED: <backend> has no mr-state; …`. No run
there can see the hand merge, so its text ends `…, then run /devagent:unstuck
and mark this step [x] with /devagent:checklist-mark`.

## Config and knobs

- `permissions.merge_mr` (per project): `true` approves merging. Read
  directly; anything else never merges.
- `merge_method`: `squash` (default), `merge` or `rebase`.
- `merge_checks`: `required` (default) or `if-present`. A repo with no CI
  stops at rule 17 under `required`; set `merge_checks = "if-present"` to
  merge without CI.
- Both are `[project.<name>]` keys with a `[defaults]` fallback, validated on
  every run whatever `merge_mr` says: a bad value dies `merge_checks must be
  required or if-present (got '<v>'); fix [project.<name>] merge_checks` or
  `merge_method must be squash, merge or rebase (got '<v>'); fix
  [project.<name>] merge_method` (`[defaults]` when the value came from
  there).
- `required_checks = ["<check-run name>", …]` (#1097; `[project.<name>]` only,
  no `[defaults]` layer: the names belong to one repository): the CI checks
  the merge needs. A name is compared byte for byte with a check's name on the
  PR, and every check of that name counts. Each required check has one state
  at the PR head: `success` (passed with the conclusion `SUCCESS`, the only
  state that merges); `pending` (rule 16); `missing`, no check of that name
  (rule 16 inside the grace, rule 15 after it); or how it ended without
  success, e.g. `skipped`, `neutral`, `cancelled`, `failure`, or `no
  conclusion` for a passing line whose backend prints none (rule 15). Absent
  or `[]`: no required checks, and every rule reads as it did. On a code
  backend that cannot report checks the step stops at rule 20.
- `required_checks_paths = ["<path>", …]` (#1097; optional, same table):
  repo-relative files or directories (one trailing `/` allowed) that decide
  what a required check measures, e.g. `["scripts/ci/"]`. A PR that changes
  one is self-certifying (rule 21); `.github/workflows/` is always watched and
  needs no entry. An entry is compared byte for byte, and one that names no
  path at `baseline_sha` or at `verified_head` stops the step (`unknown`)
  rather than match nothing.
- Both are validated at the start of every run, whatever `merge_mr` says: a
  bad value dies naming the key, e.g. `required_checks must be an array of
  single-line strings, e.g. required_checks = ["Git Bash tagged files"]; fix
  [project.<name>] required_checks`. Either key under `[defaults]` dies
  (`required_checks is per project (its values belong to one repository);
  move it from [defaults] to [project.<name>]`), and so does
  `required_checks_paths` without `required_checks`.
- `ci_gate = "off"` does **not** apply here: rules 15-17 always use #782's
  CI verdict, because merging is a stronger act than reporting.
- `DEVAGENT_MERGEMR_READ_SECS` (20): the bound on the PR read, the re-read
  after a merge and each dependency read. Dependency reads (rule 7) run on
  every re-check of a waiting row, whatever `merge_mr` says.
- `DEVAGENT_MERGEMR_MERGE_SECS` (30): the bound on the merge call and on the
  auto-merge disable.
- `DEVAGENT_CI_GRACE_SECS` (120): #782's grace before "no checks" counts, and
  before a required check that has not reported stops the step.
- `DEVAGENT_CI_READ_SECS` (20): the bound on the `mr-checks` read an open PR
  gets on a code backend other than github when `required_checks` is set.
- `DEVAGENT_MERGEMR_FETCH_SECS` (20): the bound on rule 14's fetch of
  `default_baseline`'s branch, and on the fetch rule 21's scan makes for a
  commit its tree lacks. Rule 14 also runs a local `git merge-tree`, which
  writes loose objects into the issue tree.
- `[project.<name>.merge_forward]` (#1125; per project, no `[defaults]` layer):
  `verify = "ci"` turns on the cheap remedy for a merge-forward that only
  re-applies git's own merge of the base, `preship-verified-head.sh forward`;
  `append_only = ["CHANGELOG.md"]` lists the exact files whose conflict may be
  resolved by keeping both sides. Absent, or `verify = "preship"`: today's
  behaviour. Validated at the start of every run whatever `merge_mr` says: a bad
  value dies naming the key, e.g. `merge_forward.verify must be "ci" or
  "preship" (got '<v>'); fix [project.<name>.merge_forward] verify`. "On the
  base" means `default_baseline`'s ref: a project whose `default_baseline` does
  not track the PR's base should not set `verify = "ci"`. "A merge gate in
  `mr.md`" means any line of the issue's `mr.md` that contains `merge gate`, in
  any case; name head-tied evidence (for example a Git Bash run at a given SHA)
  with that phrase so `forward` refuses it. #911 replaces this predicate.

The step also dies, with nothing marked, on `mergemr: no mergemr row in
<checklist>` (a checklist without the row; migrate it with
`scripts/migrate-checklist-numbering.sh`) and `mergemr: ship is [<g>]; run
/devagent:ship first`.

## Escapes

To take a `[!]` back after doing what its message says, run
`/devagent:unstuck`, then mark the row if the message says so:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/checklist-mark.sh" --by-name <issue-dir> mergemr x
```

A rule 21 stop is taken back only by the operator, after reviewing what the
listed paths change. The acknowledgment is line 1 of
`<issue-dir>/.devagent-selfcert-ack`: `<verified_head> <reason>`, that is all
40 hex digits of the verified head in lower case, blanks, then a reason that
is not blank, e.g.
`echo "<verified_head> <reason>" > <issue-dir>/.devagent-selfcert-ack`. Then
run `/devagent:unstuck`. It covers that head only: a new head stops again
until it is acknowledged, and `/devagent:unstuck` alone stops again. Only the
operator writes this file, never an agent: it records a person's review of a
change to the checks themselves. An agent that meets a rule 21 stop reports
the paths to the operator and goes no further.

A PR that stays open for a long time (a `merge_mr = false` project, or a
draft) holds cleanup, which waits for this row. Either park the issue with
`/devagent:park`, or give up on the merge and skip the row:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/checklist-mark.sh" --by-name <issue-dir> mergemr -
```

## If merging is not approved

Do NOT set `permissions.merge_mr = true` in
`~/.claude/devagent/config.toml` on your own: that is a standing policy
change the operator makes. Surface the `[?]` reason to the operator instead.

!`bash "${CLAUDE_PLUGIN_ROOT}/scripts/mergemr.sh" $ARGUMENTS`
