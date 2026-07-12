---
description: Manage PAT / SSH-key lifecycle (create, store, rotate, destroy, status, exec) for a project's tracker and code-forge backends.
allowed-tools: Bash(bash ${CLAUDE_PLUGIN_ROOT}/scripts/*)
disable-model-invocation: true
argument-hint: "<create|store|rotate|destroy|status|exec> [project] [backend]"
---

# /devagent:auth

Dispatches to `scripts/auth/<backend>.sh <verb>` based on the
sub-verb and the project's configured backend(s).

## Usage

```
/devagent:auth create   [project] [backend]
/devagent:auth store    [project] [backend] <token-file>
/devagent:auth rotate   [project] [backend]
/devagent:auth destroy  [project] [backend]
/devagent:auth status   [project]                # all backends for the project
/devagent:auth exec     [project] [backend] -- <cmd ...>
```

If `backend` is omitted, the dispatcher uses the project's configured
backends:

- For `create|store|rotate|destroy|exec`: requires an explicit backend.
- For `status`: reports on all configured backends
  (`issue_source.backend`, `issue_source_fork.backend`,
  `code_source.backend`, and `ssh` if a key is registered).

`project` falls back to the active project in state when omitted,
matching the §6.1 invocation grammar.

## What the model does on invocation

1. Parse the verb and remaining tokens via the standard grammar.
2. Resolve `project` (state-active project if omitted).
3. Resolve `backend` (explicit, or derived from config for `status`).
4. Invoke `scripts/auth/<backend>.sh <verb> <project> [args...]`.
   For `exec`, pass the post-`--` tokens through verbatim.
5. Surface the script's stdout/stderr to the operator. Do NOT
   interpret or paraphrase tokens or fingerprints; print them
   verbatim from the script output.
6. On `create`: confirm to the operator that browser was opened and
   prompt for the paste step if the script is waiting on stdin.

## Permission gates

`auth` operations are not subject to `[project.<name>.permissions]`
gates. They affect only local files. Remote operations (creating the
token on GitHub/GitLab/JIRA) are done by the operator in the browser
and not by the plugin.

## Examples

```
/devagent:auth create  myproj github
/devagent:auth status  myproj
/devagent:auth exec    myproj github -- gh pr list --repo myorg/myproj
/devagent:auth rotate  myproj gitlab
/devagent:auth destroy myproj jira
```

## Doctor hook

`/devagent:doctor` calls `bash "${CLAUDE_PLUGIN_ROOT}/scripts/lib/doctor_auth.sh" check <project> <backend>...`
(one or more configured backends) to produce a per-project auth health summary
without leaking tokens.
See that script's header for the contract.
