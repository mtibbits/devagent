# devAgent

devAgent is a Claude Code plugin that runs development work through a fixed,
auditable issue workflow and keeps all of its state on disk — so you can switch
between issues, or hand one to a fresh session, without losing context. It
provides **53 slash commands** driving a **21-step workflow**, works against
GitHub, GitLab, and JIRA trackers/forges, and layers capture + issue red-team,
revision, WBS, and status-report subsystems on top of the core loop.

See `docs/specs/2026-05-19-devagent-plugin-design.md` for the design spec and
`docs/plans/` for the incremental build history.

## The 21-step workflow

Every issue gets a `checklist.md` that tracks its progress through these steps.
Run them one at a time with `/devagent:next` (which advances to the next
unmarked step), or invoke any step command directly. Steps are numbered 0–20:

- **Plan** — `0 pull` · `1 draft` · `2 scope` · `3 improve` · `4 prune` · `5 tighten`
- **Implement** — `6 branch` · `7 implement` · `8 quality` · `9 document` · `10 commit` · `11 analyze`
- **Ship** — `12 draftmr` · `13 review` · `14 redmr` · `15 ship`
- **Integrate & close** — `16 mergetoall` · `17 updatewbs` · `18 impact` · `19 lessonslearned` · `20 cleanup`

`/devagent:revise` opens a new revision pass (pulling reviewer feedback via
`/devagent:comments` and re-running from review); `/devagent:where` and
`/devagent:catchup` rehydrate an issue's state at any point.

## Commands

All commands live under the `/devagent:` namespace.

### Project setup
| Command | Purpose |
|---------|---------|
| `init` | Interactive bootstrap of a new project under `~/.claude/devagent/` |
| `doctor` | Validate config, state, paths, and template resolution |
| `auth` | Manage PAT / SSH-key lifecycle for a project's tracker and forge backends |
| `template` | Inspect resolved artifact templates (list / show) |

### Issue navigation & state
| Command | Purpose |
|---------|---------|
| `pull` | Fetch an issue (origin or fork) and scaffold its workflow directory |
| `where` / `catchup` | Show / one-screen-rehydrate the active issue's state |
| `status` | Multi-project dashboard of active issues, STUCK, and parked |
| `history` / `grep` | Chronological log / search across per-issue artifacts |
| `depends` | Record or list issue dependencies |
| `park` / `resume` / `switch` | Park, reactivate, or swap the active issue in one step |
| `sync` | Async merge detection — fires `on_merge` for issues merged outside this session |
| `stuck` / `unstuck` | Mark the current step stuck (with a reason) / clear it and resume |

### Capture → issue
| Command | Purpose |
|---------|---------|
| `capture` | Draft a pre-issue or epic capture under `<devdoc>/Captures/<slug>/` |
| `redissue` | Run the issue red-team prompt against a capture draft |
| `scaffold` | Bin an epic capture into child issue drafts |
| `file` | File a capture draft as a tracker issue (origin or fork) |
| `reap` | Harvest follow-up candidates from completed work into a capture draft |

### WBS & reporting
| Command | Purpose |
|---------|---------|
| `wbs` | Work-breakdown-structure authoring and rendering (`init` / `update` / `show`) |
| `statusreport` | Generate a per-project status report and advance the report pin |

### Checklist primitives
Low-level building blocks the workflow commands use; you rarely call them
directly. `checklist-init`, `checklist-mark`, `checklist-advance`,
`checklist-log`, `checklist-stuck`, `checklist-unstuck`.

> The 21 numbered step commands above, plus `next` / `revise` / `comments`,
> together with the tables in this section, are the full set of 53 commands.

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
