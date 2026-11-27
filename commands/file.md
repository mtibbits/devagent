---
description: File a capture draft as a tracker issue (origin or fork)
allowed-tools: Bash(bash "${CLAUDE_PLUGIN_ROOT}/scripts/*"), Bash(bash "${CLAUDE_PLUGIN_ROOT}/scripts/*" *), Read
argument-hint: "<capture-slug> [origin|fork]"
---

# /devagent:file

Args: `<capture-slug> [origin|fork]` (default: the project's `default_issue_source`; unset, its only configured issue source, else `origin`: the rule `/devagent:pull` uses, #1099)

If `default_issue_source` is set to anything but `"origin"` or `"fork"`, or
names a source with no `backend`, STOP and report the key —
`/devagent:doctor <project>` names it. Never fall back to `origin`.

## Behavior

1. Validate that `<devdoc>/Captures/<slug>/draft.md` exists.
2. If `<devdoc>/Captures/<slug>/redteam.md` does NOT exist, warn the
   operator and require confirmation. (Filing without a red-team is
   allowed but should be a conscious choice.)
3. Call:

   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/capture/file.sh" --slug <slug> --target <origin|fork>
   ```

   The script reads the env var `DEVAGENT_PERMISSION_PUSH_MR` (which
   mirrors config `[project.<name>.permissions].push_mr` once exported),
   defaulting to `false`. When the gate is `false`, the script prints
   the plan and exits **4**; the operator re-invokes with `--yes`
   to confirm. A disk target asks no gate (nothing leaves the machine) and
   records `url = "disk:<N>"` and `repo = "disk"` (#1009); that holds for
   the plugin's own `disk.sh` only. (An autonomous caller — `/devagent:crrf` —
   instead treats
   4 as halt-and-report and never passes `--yes`.)

   Exit map (#559 — rc-precise, pinned by `tests/file.bats`): `0` filed ·
   `2` usage/bad `--target` · `3` draft or state problem (e.g. missing
   `draft.md`, already filed, stale `.pending`, no H1 title,
   invalid `tiers.toml`, backend failure) · `4` `push_mr` gate closed ·
   `9` refused by a trust policy (#713: under a policy in scope the
   policy's `file` gate decides and `--yes` is refused; stop and report). With any policy on the host, in
   scope or not, the backend and repo come from the config of the project
   that owns `DEVAGENT_DEVDOC_DIR`, never from the env below.

   **Tier proposal (#1101).** When `Captures/<slug>/tiers.toml` exists
   (capture's *Propose model tiers* step writes it):
   - `file.sh` validates it before the gate; an invalid one exits 3 with
     nothing created.
   - It compares each proposed class with the class tier of the project that
     owns `DEVAGENT_DEVDOC_DIR` (or the trust policy's project), never
     `DEVAGENT_PROJECT`: `step_models.<class>`, else `default`; per-step keys
     never count. Only a departure becomes a label, `tier:impl-<token>` or
     `tier:check-<token>`, and the gate plan lists it on a `labels:` line.
   - After the gate, github, gitlab and any custom backend are asked
     `state-exists <repo> <label>`: 0 passes it as `--label`, 4 is missing,
     anything else is a failed lookup. A custom backend must answer that for
     labels, or exit non-0/4. jira and disk take the label unchecked.
   - After filing it prints one `file.sh: tier <class>=<token>: <outcome>`
     line per proposed class on stderr. A missing label is left off and its
     create command printed (`gh label create <label> --repo <repo>`, or
     `glab label create --name <label> --repo <repo>`; on self-hosted GitLab
     set `GITLAB_HOST`, as `--repo` is host-relative). `file.sh` never creates
     a label (#87): create it, then add it to the issue before its first pull.
   - Until #1042, GitHub's lookup is fuzzy: a missing label reads
     `label missing` when a similar label exists and
     `lookup failed; state-exists exit 1` when none does (usually: no
     similar label). Both leave the label off. GitHub's check ignores case
     but pull reads `tier:` labels case-sensitively, so keep them lowercase.
   - To override after filing, replace the label; never add a second:
     two same-class labels make `pull.sh` die.
   - Known gap: a labelled class's per-issue marker line overrides that
     class's `step_models.<N>` pins; the other class keeps them.

   **devDoc commit (#1055).** With `commit_devdoc = true` (from
   `[project.<owner>.permissions]` of the project that owns
   `DEVAGENT_DEVDOC_DIR`, or the policy's value under a trust policy) and the
   devDoc in git, `file.sh` commits `Captures/<slug>/` alone, `filed.toml`
   included, after the URL is printed: subject `devdoc: file <slug> as
   <repo>#<issue_num>`, as `devagent <devagent@local>`, under the devDoc
   lock. No owner, the gate off, or a devDoc outside git means no commit and
   no lock. The commit is best effort: a failure (lock busy for 10 s,
   mid-merge, detached HEAD, a failed add or commit) prints one
   `file.sh: WARNING: devdoc commit of <dir> skipped - <reason>; <remedy>`
   line on stderr and the exit stays `0`, because the issue is filed.

4. On success, print the returned URL, relay every `file.sh: tier …` stderr
   line and any `devdoc commit … skipped` warning with it (the warning's
   remedy is the hand commit), and remind the operator that
   `Captures/<slug>/filed.toml` now records the issue number.

## Targets

- `origin` — the upstream tracker repo (from
  `[project.<name>.issue_source].repo`)
- `fork` — the personal/fork tracker repo (from
  `[project.<name>.issue_source_fork].repo`)

Forks vs origins matter when working on a project where some issues
are filed to your fork (private, scratch, exploratory) and others to
the upstream organization.

## Env contract

Same as `/devagent:capture` (see its derivation table), plus the
backend env vars `file.sh` consumes:

- `DEVAGENT_PERMISSION_PUSH_MR` — the push gate (default `false`);
  mirrors config `[project.<name>.permissions].push_mr`.
- the tracker backend/repo vars from `[project.<name>.issue_source]`
  (and `issue_source_fork` for `--target fork`). With a trust policy on the
  host these vars are overwritten from config, never read (#713). With no
  policy and `DEVAGENT_ISSUE_BACKEND` unset, the backend comes from the config
  of the project that owns `DEVAGENT_DEVDOC_DIR`, and each repo var and the
  backend dir left unset is filled from it too; an exported value wins (#1009).
- No env var carries `commit_devdoc`: `file.sh` reads it from config (or the
  trust policy) itself (#1055).

## Non-goals

- Does not transition issue state. That's `issue_workflow` hooks in
  the workflow family.
- Does not create the MR. That's `/devagent:ship`.
