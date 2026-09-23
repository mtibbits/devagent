---
description: Autonomous capture, red-team, revise, and file for one discussed topic
allowed-tools: Bash(bash "${CLAUDE_PLUGIN_ROOT}/scripts/*"), Bash(bash "${CLAUDE_PLUGIN_ROOT}/scripts/*" *), Read, Write, Edit, Skill
argument-hint: "[topic hint]"
---

# /devagent:crrf

Args: `[topic hint]` — optional quoted free-form text narrowing the scope.

**crrf** = **c**apture, **r**ed-team, **r**evise, **f**ile. Invoking this
command IS the operator's explicit permission to run that chain end to end,
without intermediate confirmation prompts. It is not a workflow-checklist
step; it lives in the pre-issue capture stage.

Stage semantics belong to the verbs, not to this document — see
`skills/capture/SKILL.md`, `commands/scaffold.md`, `commands/redissue.md`,
and `commands/file.md`. crrf owns only the ORCHESTRATION and the bounds
below. Execute each verb's command doc inline under this session's grants —
no slash-command facility is assumed.

## 1. Declare the topic

Open with one line naming the topic you understood, folding in the topic
hint when one was given.
It is a statement, not a question — the declaration exists so a misread
is visible immediately.
Do this before any artifact is created.

## 2. Capture

Invoke `/devagent:capture` normally — its procedure is unchanged.

`skills/capture/SKILL.md` asks the operator which epics to author when it
recommends a multi-epic split. **The crrf invocation supplies that answer in
advance:** author those you deem appropriate for the declared topic. The
prompt is answered, not skipped.

For each epic captured, run `/devagent:scaffold <epic-slug>` to bin it into
`children/NN-<kebab-title>.md`, then **promote** every child into its own
top-level capture — `file.sh` files a capture's `draft.md` and nothing else,
so a child left under `children/` is not filable:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/capture/capture.sh" --type issue --subtype <bug|feature|docs|perf|chore> --title "<child title>" --body-file "<epic-dir>/children/NN-<kebab-title>.md" --on-collision suffix
```
<!-- Editor note: tests/capture.bats EXTRACTS and RUNS this fence (#597).
     Changing its flags or placeholders changes that test. -->

- `--body-file` writes the scaffolded child's body as the capture's
  `draft.md` — no hand-editing after the fact — and the script prints the
  final slug. It REFUSES with exit **5** when the body's H1 does not equal
  `--title`: `file.sh` takes the tracker title from the draft's H1 while the
  slug came from `--title`, so a mismatch would ship a tracker issue whose
  title and slug disagree. Fix the child's H1, do not retry past the refusal.
- `--on-collision suffix` resolves a date-plus-title collision between two
  children itself: it retries once at the first six hex chars of the child
  body's content hash — the idempotent, content-derived form `reap.sh`
  already uses (#252) — and prints the final slug. A content-identical
  (whitespace/case-insensitive) re-run of this command prints the existing
  slug, writes nothing, and says so in a `note:` line on stderr — so an
  edit that only changes case or spacing does NOT land. That idempotence
  is per invocation, because the `Parent epic:` line added next changes
  `draft.md` after the write, so a later crrf re-run over the same
  children hashes differently. Exit **3**
  now means a different child already holds even the suffixed slug: give
  this child a distinct title and matching H1. Never pass `--force` — it
  would overwrite a sibling's draft, which is why `capture.sh` refuses it
  alongside `--on-collision suffix` (exit 2).
- Add a `Parent epic: <epic-slug>` line to the promoted child's `draft.md`.
  Append the epic's tracker URL to that line only **after** the epic's
  `filed.toml` exists — an issue number is provisional until the tracker
  write succeeds, so never bake a URL you have not been handed.
- Leave `children/NN-*.md` in place as the binning record (the manifest
  states their disposition — see the Manifest section).

The epic draft is filed as well, alongside its promoted children.

## 3. Red-team and adjudicate

Run `redissue` on each draft — epic drafts and promoted child captures
alike. Cycle accounting: the initial redissue run is **r1**; preserve each
run's findings as `Captures/<slug>/revisions/r<N>/redteam.md` (the repo-wide
revision layout) before the next run — preservation is a COPY, and the root
`Captures/<slug>/redteam.md` stays in place as the live latest run (it is
what `commands/file.md` checks before filing). So r1 is the pre-revision
record and each revise cycle adds one more numbered run. The manifest's
kept-vs-discarded claims must be checkable against these files, not recalled
from context.

- crrf MAY revise the draft and re-run `redissue` when Blocking findings are
  addressable in the draft text — at most two revise cycles per draft. The
  revise is performed by crrf, exercising the operator's standing grant;
  `commands/redissue.md`'s "the operator decides whether to revise" and
  core-redissue's "do not edit draft.md" both remain true — the red-team
  never edits the draft.
- crrf MUST halt before filing, and report instead, when any finding
  challenges the capture's premise — a duplicate of an existing issue, a
  fundamentally unsound capture, or a `Verdict: split` the topic hint does
  not resolve — or when Blocking findings survive the second revise cycle.

## 4. File

Config outranks conversation. crrf MUST NOT pass `--yes` to `file.sh`; the
`[project.<name>.permissions].push_mr` gate is the only gate, and this
command supersedes only the conversational "may I file?" round-trip.

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/capture/file.sh" --slug <slug> --target origin
```

`file.sh` returns **exit code 4** when the gate is closed. On 4: stop, do
not retry, and report the draft as ready-to-file (gate-closed) in the
manifest — noting that `file.sh` runs its post-gate validations (H1 title,
repo config) only after the gate, so a gate-closed draft has not yet passed
them. Exit 3 (draft or state problem) and exit 2 (usage) are errors, not
gate closures — report them as such.

Filing/processing order is your discretion, with one dependency: an epic
must be filed before any promoted child's `Parent epic:` line can carry a
URL. If the epic is not filed (gate closed, or halted), the children's
linkage stays slug-only — never a guessed number. A child MAY file before
its epic; in that case the filed tracker body's linkage remains slug-only
permanently — `file.sh` has no update verb, so the later URL append lands in
the local `draft.md` only. State the linkage as slug-or-URL accordingly in
the manifest.

## 5. Manifest

End every run — halted or complete — with:

| Artifact | Outcome |
|---|---|
| `Captures/<epic-slug>` | filed, `<tracker URL>` — or unfiled, `<halt reason>` |
| ↳ `Captures/<promoted-child-slug>` | filed, `<tracker URL>` — or unfiled, `<halt reason>` |

Group promoted children under the epic they came from, and state once that
the epic's `children/NN-*.md` files are staging copies superseded by the
promoted captures. Then list every red-team finding, marked kept or
discarded, with a one-line reason each.

## Env contract

Inherited unchanged from the verbs — `DEVAGENT_PLUGIN_DIR`,
`DEVAGENT_PROJECT`, `DEVAGENT_DEVDOC_DIR` (see `skills/capture/SKILL.md`),
plus `DEVAGENT_PERMISSION_PUSH_MR` for filing (see `commands/file.md`).

## Non-goals

- Changes no verb's behavior: `scaffold`, `redissue` and `file.sh` behave as
  before, and the `capture.sh` flags this loop uses (`--body-file`,
  `--on-collision suffix`) are optional additions from #597 that leave every
  other caller unchanged.
- Adds no permission model.
- One invocation covers one discussed topic; no batching across
  conversations.
