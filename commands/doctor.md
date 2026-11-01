---
description: Validate config, state, paths, and template resolution.
allowed-tools: Bash(bash "${CLAUDE_PLUGIN_ROOT}/scripts/*"), Bash(bash "${CLAUDE_PLUGIN_ROOT}/scripts/*" *)
argument-hint: "[project]"
---

Run `bash "${CLAUDE_PLUGIN_ROOT}/scripts/doctor.sh" [project]`. With no argument, doctor runs against
every project in `~/.claude/devagent/config.toml` and reports each one.
With a project argument, only that project is checked.

doctor checks structural concerns (config parses; required project fields
present; source_dir/devdoc_dir exist; state file mode 600; secrets dir mode
700; checklist template resolves; and — #541, global phase — whether the
recommended `superpowers` plugin is installed and enabled, WARN + install
hint when it is absent or disabled — deliberately silent when the CLI is
missing or errors, an undetermined state, not an absence claim) and, via
the auth doctor hook, auth-secret presence and reachability.

Forward arguments verbatim.

With a trust policy on the host (spec §3.8, #713), doctor's first global
block reports it: the policy's location and digest, an empty or shadowed
location, the worker account (`whoami`) per scope, the hardenings met and not
met (`system_policy` reads unverified until #902), a set `GH_TOKEN` or
`GITHUB_TOKEN`, a non-default `GH_HOST`/`GITLAB_HOST`, and more than one gh
account (one `gh auth status --hostname <h>` call per GitHub host, doctor
only). A host-level refusal there exits 9 (or 10) before the per-project
checks. With no policy the block is absent.

Per project, the tracker-mapping check (#710, warn-only) flags `github_labels`/`gitlab_labels` keys no transition reads, the retired keys and a nested `issue_workflow.<backend>_labels` table. With `transition_issue = true` it also asks the tracker (`state-exists`, up to three calls per tracker, so a network call) whether each mapped label or status exists, and skips when the tracker is unreachable or unauthenticated. One global check warns while a process-global per-stage override (`DEVAGENT_GITHUB_LABEL_<STAGE>` and its GitLab/JIRA kin) or a retired env name is set.

Per project, two #885 checks (warn-only): `permissions.merge_mr` set without `permissions.merge_to_all_prs` (merge_mr now approves merging the PR at step 20, mergemr, and no longer gates mergetoall), and a devdoc override of a `checklist-*.md` or `revision_block.md` template that has a `ship` row but no `mergemr` row (the merge step would not run or gate closeout).

Per project, `potholes_workflow register: <path|not configured|absent>` names the shared workflow register the project resolves (FAIL on a relative path or unreadable config). One global #611 row, WARN only: `seed carries no private project name` runs the
private-project-name predicate over the shipped `templates/potholes.md` for
every non-public project key in the LIVE config (the suite canary skips until
the seed is curated; doctor is ungated; an unreadable seed, or a missing seed/fixture, is a FAIL — the check never silently skips). A key
absent from the suite fixture `tests/fixtures/private-project-names.txt` is
reported as INFO only — that fixture must never be the first disclosure of a
private name into the public repo, so new projects are checked live, not added.
