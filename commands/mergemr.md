---
description: "Step 20: merge the issue's PR at the preship-verified head when permissions.merge_mr = true; otherwise mark the step waiting [?] until the PR is merged."
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
passing `/devagent:preship` recorded as `verified_head`. It never uses the
permission gate, so `DA_YES=1` and an interactive terminal cannot open it.
With `merge_mr` false or unset it never merges by any route: it marks `[?]`
until the PR is merged elsewhere.

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
merge.

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
| 8 | `merge_mr` not `true` | `[?]` `waiting for merge (<CI result>, <mergeable>/<mergeStateStatus>)` |
| 9 | the PR is not on ship's target repo (`code_source.upstream`, or `code_source.fork` under `fork_first`; case-insensitive) | `[!]` `PR is not on <target>; it is on <repo>. Fix mr_url or code_source, then run /devagent:unstuck`. No target configured: `[!]` `no code_source.upstream configured for '<project>'; set it, then run /devagent:unstuck` |
| 10 | no `verified_head` | `[!]` `no verified head for this PR; run /devagent:preship` |
| 11 | PR head is not `verified_head` | `[!]` `PR head <sha7> was not verified; run /devagent:preship on it (or push the verified head <verified sha7>)`. With auto-merge on, it first disables it and adds ` (auto-merge disabled)`, or ` (could not disable auto-merge: <error>; disable it on the forge)` |
| 12 | auto-merge on, or the PR is in a merge queue | `[?]` `merge accepted; waiting (<CI result>, <mergeable>/<mergeStateStatus>)`; no second merge call |
| 13 | `mergeable` or `mergeStateStatus` is `UNKNOWN` | `[?]` `mergeability not computed yet` |
| 14 | `CONFLICTING` | `[!]` `conflict with <base>; merge it forward, run rebaseline.sh, re-run run-suite.sh and evidence-stamp.sh (review.md 6a), push, then run /devagent:preship` |
| 15 | CI red (red wins over pending) | `[!]` `<CI FAILED line>; fix it, re-run run-suite.sh and evidence-stamp.sh (review.md 6a), push, then run /devagent:preship` |
| 16 | CI pending or unknown, or no checks inside the grace | `[?]` the `CI …:` line; no checks yet: `checks not reported yet (grace <n>s)` |
| 17 | no checks after the grace | `merge_checks = "required"`: `[!]` `no CI checks on head commit; set merge_checks = "if-present" to merge without CI, then run /devagent:unstuck`; `"if-present"`: continue |
| 18 | `mergeStateStatus` not `CLEAN` or `HAS_HOOKS` (e.g. `BLOCKED`, `BEHIND`) | `[!]` `blocked by a forge rule (<status>); resolve it on the forge, then run /devagent:unstuck` |
| 19 | merge | see below |

A `/devagent:preship` pass after ship records the new head and clears a rule
10, 11, 14 or 15 stop by itself (and a stop left by a failing post-ship
preship). Every other stop names `/devagent:unstuck`.

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
- `ci_gate = "off"` does **not** apply here: rules 15-17 always use #782's
  CI verdict, because merging is a stronger act than reporting.
- `DEVAGENT_MERGEMR_READ_SECS` (20): the bound on the PR read, the re-read
  after a merge and each dependency read. Dependency reads (rule 7) run on
  every re-check of a waiting row, whatever `merge_mr` says.
- `DEVAGENT_MERGEMR_MERGE_SECS` (30): the bound on the merge call and on the
  auto-merge disable.
- `DEVAGENT_CI_GRACE_SECS` (120): #782's grace before "no checks" counts.

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
