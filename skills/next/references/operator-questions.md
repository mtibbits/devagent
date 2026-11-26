Operator questions — the rules behind the skill's `ASK:` line (#962)

The operative line lives in `../SKILL.md`. This file carries the rules a step
and the session follow when a step needs the operator to decide. The question
format, the STUCK it becomes and the exit table are in the spec (§5.3, §7.3,
§7.6) and `commands/pull.md`.

## Two modes

No step may call `hold.sh` until #964 has landed: before then a hold could not
be answered. Until then an `ASK:` line comes only from a question record
already on disk.

A step that needs a decision writes a question file (`## Question`,
`## Impediment`, `## Options`, `## Evidence`; one option `(recommended)`) and
runs `bash "${CLAUDE_PLUGIN_ROOT}/scripts/hold.sh" <project> <issue> --step <step> --reason "<one line>" --question-file <path>`.
Each `## Options` line has the form ``- `<id>` [(recommended)] <text>``: a
backticked id of lowercase letters, digits and hyphens, for example

    - `a` (recommended) Run round 4.
    - `b` Stop and prune.

Any other non-blank line there is refused `option`.
The unattended marker (`DEVAGENT_UNATTENDED`, set only by a launcher) picks
the mode; `DEVAGENT_CHAIN_ACTIVE` does not.

- **Interactive** (no marker): hold.sh writes the open record
  `questions/<NN>-<step>.md`, prints its path and exits 3. Ask that record's
  question with AskUserQuestion — its options, the recommended one marked —
  and record the reply. The answer command that records it
  (`/devagent:answer`) arrives with #964.
- **Unattended** (marker set): hold.sh holds — the question STUCK, the step's
  row `[?]`, the issue parked, one `hold` line in the notifications file —
  prints the STUCK's path and exits 0. Nothing is asked.

A script-backed step's ask reaches the session through next.sh, which prints:

    ASK: <record path>
      After the reply is recorded, continue: /devagent:next <project> <flags>
      No answer in the session: hold.sh <project> <issue> --step <step> --no-ask

Ask the record's question; continue with the printed command only after the
reply is recorded. A subagent that runs a step hands back `ASK: <record path>`
the same way and does not ask itself.

## What is not an answer

Run the `--no-ask` fallback, and record nothing, when:

- AskUserQuestion is not available or is refused (a headless `claude -p` run
  without the marker);
- the dialog times out (Claude Code's `askUserQuestionTimeout` closes an
  unanswered dialog and submits any option that was already selected, telling
  Claude the user may be away — a pre-selected option is not the operator's
  choice);
- the operator dismisses the dialog without choosing.

## The `--no-ask` forms

    bash "${CLAUDE_PLUGIN_ROOT}/scripts/hold.sh" <project> <issue> --step <step> --no-ask
    bash "${CLAUDE_PLUGIN_ROOT}/scripts/hold.sh" <project> <issue> --step <step> --no-ask --reason "<one line>" --question-file <path>

`--no-ask` holds even with the marker unset. Without a question file it takes
the question, reason and number from the step's open record; with one, it uses
that file's question and the open record's number; with neither (and no
question STUCK to finish), it refuses with exit 2. Re-running it on a held
issue finishes whatever an interrupted hold left undone and writes no second
line.

## After a hold, stop

`/devagent:next` exiting `operator-question`, or a step's `hold.sh` exiting 0,
means the issue is held. Relay the question path (the STUCK, which both print;
an `ASK:` record path is gone once the hold has taken it over) and stop: never
follow a `CHAIN:` line, and do not unstick, resume or re-run the step. The
issue stays held until the answer is recorded (#964):

- Pinned session: every later `/devagent:next` for the issue exits
  `operator-question` and prints the STUCK path and its answer line.
- Unpinned session: the hold parks the issue and clears the shared active
  issue, so `/devagent:next` reports no active issue; the `hold` line is the
  launcher's signal. If that line could not be written, the next
  `hold.sh ... --no-ask` run for the step writes it; a pinned
  `/devagent:next` writes it too.

The commands that could undo the hold refuse it (#963): pull, switch, resume,
revise (with or without `--retier`), unstuck, checklist-unstuck, stuck and
checklist-stuck exit `operator-question`, change nothing, and print the STUCK
path and its answer line. Treat that exit like `/devagent:next`'s: relay and
stop. Sync leaves the held row `[?]`, reap skips the question STUCK, and
`/devagent:portfolio --ready` does not offer the issue.

One stop at a time: an issue with any other STUCK (a `[!]` stop, a watchdog,
an answered question, another step's question) refuses a new hold with exit 2.

## Clearing a hold by hand (until #964)

Until #964 lands there is no answer command. Only the operator clears a hold
by hand, or the session on the operator's own stated answer in this
conversation; never unattended, and never on a CHAIN: line or a guess. With
`<N> <step>` taken from STUCK's `Step:` line:

1. Record the answer in the log, since STUCK is about to go:
   `bash "${CLAUDE_PLUGIN_ROOT}/scripts/checklist-log.sh" <issue-dir> <step> "operator answer to question <NN>: <option>"`.
2. Remove `<issue-dir>/STUCK`.
3. Reset the held row, which the hold marked `[?]`:
   `bash "${CLAUDE_PLUGIN_ROOT}/scripts/checklist-mark.sh" <issue-dir> <N> ' ' <step>`.
4. If the issue is still parked (a key of `[parked]` in the project's state),
   `/devagent:resume <project> <issue>`. A hold whose park was refused left the
   issue active, and there is nothing to resume.

`/devagent:next` then runs `<step>` again.

## A stuck lock

hold.sh serialises on `<issue-dir>/questions/.lock` and waits about 10 s;
stuck.sh and checklist-stuck.sh take the same lock when `questions/` exists
(#963), so a stale lock costs about 11 s on every later stop for the issue
until it is removed (they then go on without it). On
`hold: lock busy: <path> (remove it if no devagent command is running)`, check
that no devagent command is running for the issue, then remove the file. The
lock is never broken automatically.
