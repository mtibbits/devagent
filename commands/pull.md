---
description: Fetch an issue from origin or fork and scaffold its workflow directory
allowed-tools: Bash(bash "${CLAUDE_PLUGIN_ROOT}/scripts/*"), Bash(bash "${CLAUDE_PLUGIN_ROOT}/scripts/*" *)
argument-hint: "<project> origin|fork <issue-num>"
---

# /devagent:pull

**Usage:** `/devagent:pull <project> origin|fork <issue-num>`

Runs `scripts/pull.sh` to fetch issue `<num>` from the configured
backend, write `<devdoc>/<dir_prefix><num>/issue.md`, initialise
`checklist.md`, mark step 0 done, and promote the issue to active.

Implements workflow step 0 per spec §6.3.

## Behavior

- `origin` reads `[project.<name>.issue_source]` from config.toml
- `fork`   reads `[project.<name>.issue_source_fork]`
- Existing `checklist.md` is preserved; `issue.md` is overwritten on refetch

## Per-issue tier (#537)

A `tier: <name>` key in the issue body's `## Workflow flags` block selects
the checklist template at scaffold, overriding the project's
`checklist_template` default (legal names: the spec §6.3 tier table; an
unknown value dies pre-path listing them). Body segment only — a flags
block quoted in a comment, or shown inside a fenced code block, never fires
(#582). Scaffold-only: a tier key added after the first pull is inert on
re-pull; the post-scaffold path is `/devagent:revise --retier <tier>`. Block
diagnostics (`flags_validate`, #582) run on EVERY pull, so a late key is
validated — warned about if the key is unknown or the block is malformed —
even though it stays inert; value validation stays die-class and scaffold-only.

Duplicate `tier:` lines are FIRST-match-wins, so a body combining a template
tier with a model annotation (below) must use one line of each key.

## Per-issue model steering (#561)

Orthogonal to `tier:` — these select WHICH MODEL runs a class of steps, not
which steps run. At first scaffold `pull.sh` resolves them into the per-issue
`.devagent-step-models` marker (format and full precedence: spec §7.4).

| Source | Class steered |
|---|---|
| body `implementation-model: <token>` | *thinking*: 2 draft · 9 implement · 10 quality · 11 document · 14 draftmr |
| body `checking-model: <token>` | *checking*: 5 improve · 15 review · 16 redmr · 17 preship |
| body `tier: <model>-checking` (legacy shim) | *checking* — warns, means `checking-model: <model>` |
| label `tier:impl-<model>` | *thinking* |
| label `tier:check-<model>` / `tier:<model>-checking` | *checking* |

**Enforcement differs by step; the key names under-promise their coverage.**
`checking-model` is fully enforced — all four checking steps dispatch and consume
the tier as the Agent-tool `model:` override. `implementation-model` is enforced
for **draft only** (its dispatched planner) and **advisory** for 9/10/11/14, which
run inline and cannot swap their own model; there it surfaces only as the
`next` / `catchup` hint.

Legal tokens: `sonnet opus haiku fable inherit`. Validated fail-closed BEFORE any
write — a rejected value leaves neither a checklist nor a marker.

Per-class precedence: body key > body `tier:` shim > forge label > the
`[project.<name>.step_models]` config chain. A body source beating a conflicting
label warns. Two labels steering one class to different models DIE naming both,
even when a body key would have won that class. An unrecognized `tier:*` label
warns and is ignored; a non-`tier:` label is silent.

Labels are read once from `issue.md`'s `- Labels:` HEADER line — a `- Labels:`
line in the body or in a tracker comment never steers. Scaffold-only, like
`tier:`: later body-key or forge-label edits do not retro-edit the marker, an
existing marker is never stomped, and the post-scaffold path is hand-editing it
(`--retier` stays template-only).

## Exit codes

Under a trust policy (#711) pull can refuse before it fetches anything. A
polling consumer keys on the exit code alone; the registry is
`scripts/lib/refusals.sh`, and `tests/trust-registry.bats` keeps this table
equal to it.

| Code | Id | Meaning | Owner |
|---|---|---|---|
| 6 | `quarantined-by-pull` | quarantined by this pull | #714 |
| 7 | `pull-quarantined` | pull refused: quarantined and not released | #714 |
| 8 | `held` | held elsewhere — reserved until #719 | #719 |
| 9 | `host` | host-level refusal: identity, policy or environment | #713 |
| 10 | `try-later` | a check could not run (`whoami` or `events` could-not-run) | #713 |
| 11 | `quarantine-refused` | refused on quarantine, every entry point but pull | #714 |

Consumer action per code:

- `6` → skip the ticket.
- `7` → skip the ticket.
- `8` → reserved; will mean "skip the ticket".
- `9` → stop polling: the host needs fixing, and a retry will refuse again.
- `10` → retry later: a check could not run (network, rate limit, 5xx). Under trust a missing or inaccessible issue also reads 10 (the `events` read cannot tell a 404 from an outage; its detail carries the backend's message), so bound the retries per ticket.
- `11` → skip the ticket; a human must release it.

With no trust policy on the host and no quarantine marker in the issue dir, none of these codes is emitted.

## Run the script

Execute, substituting positional args. Pass through `$NOTE` only as
documentation — `pull` does not consume notes.

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/pull.sh" <project> <origin|fork> <num>
```
