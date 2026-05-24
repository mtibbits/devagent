# devAgent

Claude Code plugin that preserves workflow state across issue switches. See
`docs/specs/2026-05-19-devagent-plugin-design.md` for the design
spec. v1 is built in 10 incremental plans under `docs/plans/`.

This plan (Plan 01) ships only the foundation:
`/devagent:init`, `/devagent:doctor`, and the `checklist-*` family.

## Auth subsystem

The auth subsystem manages personal access tokens (PATs) and SSH
keypairs for each project's tracker and forge backends.

### Storage

- `~/.claude/devagent/secrets/<project>.<backend>.pat` (mode 600)
- `~/.claude/devagent/secrets/<project>.ssh` (symlink to `~/.ssh/<key>`)
- Containing directory mode 700

v1 ships file-based storage only. A future `--keyring` mode will swap
in libsecret (Linux), Keychain (macOS), or wincred (Windows) without
changing the caller contract; see `scripts/lib/secrets.sh` for the
abstraction seam.

### Slash command

`/devagent:auth <verb> [project] [backend] [args...]` dispatches to
`scripts/auth/<backend>.sh`. See `commands/auth.md`.

### Verb contract

Every backend script supports:

| Verb     | Purpose                                                          |
|----------|------------------------------------------------------------------|
| create   | Interactive: open browser to PAT page, paste, validate, store    |
| store    | Non-interactive ingest: read token from a file                   |
| rotate   | Atomic: create new, swap into place, destroy old                 |
| destroy  | `shred -u` then `unlink`                                         |
| status   | Print backend, scopes, expiry, last-used (never the token)       |
| exec     | Set the env var (`GH_TOKEN` / `GITLAB_TOKEN` / `JIRA_TOKEN`)     |
|          | and exec the trailing command. Token never on argv.              |

For SSH (`scripts/auth/ssh.sh`), `store` and `exec` are not exposed
(SSH keys are presented to children via `ssh-agent` or `~/.ssh/config`,
not env vars), but `create`, `destroy`, `rotate`, and `status` work
identically.

### Implementing a custom auth backend

`scripts/auth/custom.sh` ships as a stub that exits 64 for every verb
except `status`. To implement a custom backend, copy that file and
fill in each verb following the contract above. The verb dispatch and
argument parsing are provided by `scripts/lib/auth_common.sh`; the
storage layer is `scripts/lib/secrets.sh`. Both are stable v1 APIs.

### Doctor integration

`/devagent:doctor` calls `scripts/lib/doctor_auth.sh check <project>
<backend>...` and reports OK / WARN / MISSING / ERROR per backend
plus the secrets-dir mode. The script never prints the token value
and always exits 0; doctor aggregates statuses across hooks.

### Security tests

`tests/auth_security.bats` pins these invariants:

- token file mode is exactly 600
- secrets directory mode is exactly 700 (auto-repaired on every write)
- `exec` never puts the token on argv (verified via `ps -wwo args=`)
- `destroy` leaves no on-disk traces of the token

Do not write code that bypasses `scripts/lib/secrets.sh` for read or
write; direct file I/O against the secrets directory is a contract
violation and will break the future `--keyring` migration.

## Custom backends

devAgent supports four issue backends out of the box: `github`,
`gitlab`, `jira`, and a `custom` stub. The `custom` backend is a
starting point for implementing a tracker that ships does not support
(in-house Jira-likes, Redmine, Bugzilla, ServiceNow, etc.).

To add a new backend:

1. Copy `scripts/issue/custom.sh` to `scripts/issue/<yourname>.sh` and
   replace each `bc_die_not_implemented` call with a real
   implementation. Same for `scripts/code/custom.sh` if you also host
   code.
2. Set `backend = "<yourname>"` under `[project.<project>.issue_source]`
   (and optionally `[project.<project>.code_source]`) in
   `~/.claude/devagent/config.toml`.
3. Confirm contract compliance by running the contract suite against
   your backend. The harness is parametrized in
   `tests/backend-<name>.bats`. Write a `tests/backend-<yourname>.bats`
   modeled on `tests/backend-gitlab.bats` plus fixtures under
   `tests/fixtures/<yourname>/`. Then:

   ```
   bats tests/backend-<yourname>.bats
   ```

   All tests must pass before the dispatcher (`pull.sh`, `ship.sh`,
   etc.) will work reliably with your backend.

### Contract summary

Every issue backend MUST implement five verbs (spec §9.1):

| Verb           | Args                                            | Output / exit       |
|----------------|-------------------------------------------------|---------------------|
| `fetch`        | `<repo> <num>`                                  | markdown to stdout  |
| `create`       | `<repo> <title> <body-file> [--label X]…`       | new num to stdout   |
| `transition`   | `<repo> <num> <semantic-stage>`                 | exit 0              |
| `state`        | `<repo> <num>`                                  | backend state       |
| `comment-list` | `<repo> <num>`                                  | markdown to stdout  |

Every code backend MUST implement five verbs (spec §9.2):

| Verb          | Args                                                          | Output / exit          |
|---------------|---------------------------------------------------------------|------------------------|
| `push-branch` | `<remote> <branch>`                                           | exit 0                 |
| `create-mr`   | `<repo> <title> <body-file> <head> <base> [--draft]`          | MR URL to stdout       |
| `mr-state`    | `<mr-url>`                                                    | `open|merged|closed|draft` |
| `mr-comments` | `<mr-url>`                                                    | markdown to stdout     |
| `merge-mr`    | `<mr-url> [--method squash|merge|rebase]`                     | exit 0                 |

Exit-code conventions across all backends:

| Code | Meaning                                          |
|------|--------------------------------------------------|
| 0    | success                                          |
| 1    | generic failure                                  |
| 2    | usage error (bad/missing args, unknown verb)     |
| 3    | auth failure (HTTP 401/403)                      |
| 4    | not found (HTTP 404)                             |
| 78   | not implemented (EX_CONFIG; reserved for stubs)  |

The markdown shape produced by `fetch` and `comment-list` is fixed
across backends (spec §9.3) — downstream code is backend-agnostic.
