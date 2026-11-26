---
description: Mark the current step stuck and write a STUCK file with a reason.
allowed-tools: Bash(bash "${CLAUDE_PLUGIN_ROOT}/scripts/*"), Bash(bash "${CLAUDE_PLUGIN_ROOT}/scripts/*" *)
argument-hint: "[--step <N> <name> | --name <step-name>] <issue-dir> <reason...>"
---

Run `bash "${CLAUDE_PLUGIN_ROOT}/scripts/checklist-stuck.sh" [--step <N> <name> | --name <step-name>] <issue-dir> <reason...>`. Forward all
arguments verbatim.

## A held issue (#963)

While the issue's `STUCK` is an operator question (`Kind: question`, written
by a hold, #962), checklist-stuck refuses before it marks any row, so the open question is
never overwritten. It changes nothing, prints the `STUCK` path and its
answer line on stderr, and exits `operator-question` (the code is in
`scripts/lib/refusals.sh`). When the issue has a `questions/` directory, the check and the `STUCK` write run under the issue's question lock, the lock a hold takes while it creates `STUCK`; if the lock is still held after its wait (about 10 s, `hold: lock busy: …`), the check runs without it, so a real stop is never lost. The internal callers that run it with `|| true` (next.sh's CI gate, mergetoall, mergemr, the preship preflight) keep the question on a refusal.
On that exit, stop: the issue is held. Report the `STUCK` path and the answer line to the operator; do not retry, unstick, resume or re-pull the issue. Any other `STUCK` is handled as before.
