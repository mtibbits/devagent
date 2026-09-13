# devAgent

devAgent is a Claude Code plugin that runs development work through a fixed,
auditable issue workflow and keeps all of its state on disk — so you can switch
between issues, or hand one to a fresh session, without losing context. It
provides **58 slash commands** driving a **24-step workflow** (21 mandatory steps + 3 optional), works against
GitHub, GitLab, and JIRA trackers/forges, and layers capture + issue red-team,
revision, WBS, and status-report subsystems on top of the core loop.

See `docs/specs/2026-05-19-devagent-plugin-design.md` for the design spec and
`docs/plans/` for the incremental build history. New to devAgent? Start with
the onboarding pages in `docs-site/` (`docs-site/index.md`).

## Install

devAgent is a Claude Code plugin. Add its marketplace, then install the plugin:

```sh
# 1. Add the marketplace (the devagent repo)
claude plugin marketplace add mtibbits/devagent

# 2. Install the plugin
claude plugin install devagent@devagent
```

**Recommended — superpowers.** When the
[`superpowers`](https://github.com/anthropics/claude-plugins-official)
plugin is installed, devAgent's implement and review steps — and draft on
its inline (non-dispatched) path — use its skills. When it is absent, those
steps fall back to compact built-in paths and print a one-line install
nudge; devAgent itself always loads either way, and `/devagent:doctor`
warns when the plugin is missing or disabled (#541: recommended, never
hard-required; plugin dependencies do not auto-install, so this is a
separate, optional command):

```sh
claude plugin install superpowers@claude-plugins-official
```

Installs from before #541: run `claude plugin update devagent@devagent`
once — the old manifest declared superpowers as a hard dependency, and a
cached copy of it keeps devAgent disabled until updated.

**Private-repo access.** While `mtibbits/devagent` is private,
`claude plugin marketplace add` clones it over your configured git access — you
need read access to the repo (an SSH key, or `gh auth` with `repo` scope). Once
the repo is public this note no longer applies.

**Updates.** The plugin is versioned by git commit SHA (no pinned `version`), so
`claude plugin update devagent@devagent` picks up new commits without an
uninstall + reinstall.

Requires a `bash` (≥ 4.4 — the resolver libs use namerefs) + `python3` toolchain (the workflow scripts) and, for the auth
subsystem, `gh`/`glab`/`curl` as appropriate for your backend.

**Claude Code version.** Developed and verified against Claude Code **2.1.223**;
earlier versions are untested. Workflow-script calls auto-approve: as of 2.1.223,
`${CLAUDE_PLUGIN_ROOT}` substitutes inside `allowed-tools`, and devAgent ships the
probe-verified quoted grant form
`Bash(bash "${CLAUDE_PLUGIN_ROOT}/scripts/*"), Bash(bash "${CLAUDE_PLUGIN_ROOT}/scripts/*" *)`
that matches the quoted script invocations the command bodies emit (#548 decision doc). Since #584 the same grant sits on every `core-*` skill whose body makes a script call, so an `--auto` chain does not stall on a step-internal call either (the four judgment-only core skills make none and carry no grant).
On older Claude Code (measured at 2.1.211 in #533, where the substitution does not fire;
older versions are untested but assumed the same, and the exact landing version between
2.1.211 and 2.1.223 is unmeasured, so intermediate versions may or may not prompt)
every workflow script call prompts; approve-and-remember there, or upgrade. The model can
occasionally retype a command in a form that misses the literal prefix match (e.g. a
different drive-letter case) — that falls back to a one-off prompt, never to a wider
grant. Never widen to bare `Bash`.

## The 24-step workflow

Every issue gets a `checklist.md` that tracks its progress through these steps.
Run them one at a time with `/devagent:next` (which advances to the next
unmarked step), or invoke any step command directly. Steps are numbered 0–23 in
execution order — 24 numbered steps, 21 of them mandatory; the optional steps
are off by default: `1 research` and `3 spike` opt in per issue via the
`## Workflow flags` block, and `19 mergetoall` opts in per project by
configuring `all_prs_branch`. A normal issue's checklist reads top-to-bottom
with those rows pre-marked `[-]` (skipped):

- **Plan** — `0 pull` · `1 research` _(optional, flagged)_ · `2 draft` · `3 spike` _(optional, flagged)_ · `4 scope` · `5 improve` · `6 prune` · `7 tighten`
- **Implement** — `8 branch` · `9 implement` · `10 quality` · `11 document` · `12 commit` · `13 analyze`
- **Ship** — `14 draftmr` · `15 review` · `16 redmr` · `17 preship` · `18 ship`
- **Integrate & close** — `19 mergetoall` _(optional, `all_prs_branch`)_ · `20 updatewbs` · `21 impact` · `22 lessonslearned` · `23 cleanup`

`/devagent:revise` opens a new revision pass (pulling reviewer feedback via
`/devagent:comments` and re-running from `draft` — the revision's first pending
step); `/devagent:where` and `/devagent:catchup` rehydrate an issue's state at
any point.

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
| `use` | Deliberately switch the active project (the one arg-driven pointer writer) |
| `sync` | Async merge detection — fires `on_merge` for issues merged outside this session |
| `stuck` / `unstuck` | Mark the current step stuck (with a reason) / clear it and resume |

### Capture → issue
| Command | Purpose |
|---------|---------|
| `capture` | Draft a pre-issue or epic capture under `<devdoc>/Captures/<slug>/` |
| `redissue` | Run the issue red-team prompt against a capture draft |
| `scaffold` | Bin an epic capture into child issue drafts |
| `file` | File a capture draft as a tracker issue (origin or fork) |
| `crrf` | Autonomous capture → red-team → revise → file for one discussed topic |
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

> The 24 numbered step commands above (21 mandatory + the optional `1 research`,
> `3 spike`, and `19 mergetoall` steps), plus `next` / `revise` / `comments`, together with the tables in this
> section, are the full set of 58 slash commands (55 commands + 3 user-invocable
> skills — `next`, `capture`, `ship`; #452).

## Concurrent sessions

Two sessions on DIFFERENT projects are safe as of #282 — pin each session via
`"env": { "DEVAGENT_ACTIVE_PROJECT": "<project>" }` in that directory's Claude
Code `settings.local.json`; the shared pointer is only written when actually
consulted. Same-project sessions are isolated per issue as of #240/#303 — each
issue's state lives under `[context.<issue>]`, so keys can't launder between
issues; the only residual is the last-writer-wins pick of the shared
`active_issue` scalar, which a per-session `DEVAGENT_ACTIVE_ISSUE` pin avoids.

To switch the active project deliberately (rather than via the per-session env
pin), run `/devagent:use <project>` — the one arg-driven writer of the shared
pointer; hand-editing `_active.toml` is the fallback.
Details: `skills/next/references/concurrency.md`.

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
<backend>...` and reports OK / WARN / SKIP / MISSING / ERROR per backend
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
   LC_ALL=C.UTF-8 bats tests/backend-<yourname>.bats
   ```

   (The locale pin matters for any direct `bats` invocation — see
   [Running the test suite](#running-the-test-suite).)

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

## Running the test suite

The canonical runner is `scripts/run-suite.sh`, which runs bats and pytest with
the hermetic environment baked in and writes the provenance artifact
`<issue-dir>/analysis/<date>-suite-count.txt` that `preship-evidence.sh` reads:

```sh
bash "$CLAUDE_PLUGIN_ROOT/scripts/run-suite.sh" <project>
```

The suite has three environmental requirements. `run-suite.sh` enforces the first two
by refusing to write an artifact at all, rather than producing one it cannot stand
behind. The third it RECORDS, and `preship-evidence.sh` refuses on the recorded value.
A minimal container running these tests must provide all three.

**A POSIX filesystem where `chmod` actually changes the mode.**
`tests/auth_security.bats` and its siblings pin 0700/0600 modes on the secrets
store; on a mount where `chmod` is a no-op those tests can never pass, and the
run tells you nothing about your branch. `run-suite.sh` probes this
behaviourally and refuses.

On Windows that means **a WSL clone on a native Linux filesystem (ext4) — not a
checkout under `/mnt/c`, and not native Git Bash**, whose default `/etc/fstab`
mounts are `noacl`. Give the WSL clone its own `~/.claude/devagent/config.toml`
with a WSL `source_dir`; the devdoc tree can stay shared via `/mnt/c`. Git Bash
is fine for individual scripts — it is not a supported environment for the
suite, and that is a property of the mount, not a defect to repair.

**A UTF-8 locale.** Many `@test` names in this repo carry non-ASCII characters
(em dash, `§`, `⇒`). bats encodes each name into a shell function name in a
child process, walking it one unit at a time; without a UTF-8 locale it walks
BYTES instead of characters.

What happens next is platform-dependent, and it is why the locale is pinned
rather than left to the invoking shell:

- On **Git Bash / MSYS**, a leading byte such as `0xe2` is classified as
  `[[:alnum:]]` in the C locale, so it is copied into the function name RAW.
  The resulting name is never defined, and bats prints `unknown test name` and
  **skips** the test while still counting it in the `1..N` plan — the run looks
  complete and is quietly thinner.
- On **glibc** (Linux, WSL, CI) the same byte is not `[[:alnum:]]`, so it is
  hex-escaped consistently on both sides and the test still registers. The
  silent skip does not occur there.

`run-suite.sh` and CI both pin a UTF-8 locale, so neither depends on that
difference. If you invoke `bats` directly, pin it yourself:

```sh
LC_ALL=C.UTF-8 bats tests/some-file.bats
```

`tests/locale-registration.bats` fails loudly if the bats process running it
has no UTF-8 locale, so a bare `bats tests/` reports the condition rather than
hiding it — and it asserts both platform branches above, so it is not vacuous
on either.

CI (`.github/workflows/test.yml`) runs the bats files as four shards, each with
`bats --jobs 2 --no-parallelize-within-files`: files in a shard run
concurrently, tests within a file serially. A test may therefore not depend on
another file's side effects, on the order files run in, or on a fixed path
outside its own `$DEVAGENT_TMP`; `run-suite.sh` is serial unless the project
opts in to `suite_jobs > 1` ("Parallel bats" below), so a test that passes under
a serial `run-suite.sh` and fails in CI is usually sharing state across files.

**A pytest-capable interpreter for a tree that has `tests/test_*.py`.**
`run-suite.sh` prefers `<tree>/.venv/bin/python` when it exists and falls back to
ambient `python3` — a Python project conventionally carries its interpreter inside the
tree, and measuring with the system one recorded `0 passed` for a 51-test suite. If
neither can RUN pytest, the artifact records `pytest: (error)` rather than a zero count,
and `preship-evidence.sh` refuses it — including when the `## Evidence` block is absent,
so the refusal cannot be sidestepped by deleting it. An unmeasured suite must not ship
as a green (#466).

A suite that RAN and had nothing to count is a different thing and stays shippable: all
tests skipped, or nothing collected, records a truthful `pytest: 0 passed, 0 failed`.
`(error)` means *could not run*, never *ran and found nothing*. Only the `.venv/` spelling is searched, so for any other layout — `venv/`,
`.venv/Scripts/`, conda, uv, pyenv, or a linked worktree, where an untracked virtualenv
never travels — point `DEVAGENT_PYTEST_PYTHON` at the interpreter instead:

```sh
DEVAGENT_PYTEST_PYTHON=/path/to/python bash scripts/run-suite.sh <project>
```

That names a working interpreter; it does not silence the `(error)` verdict, so the
fail-closed property is unweakened. `born-red.sh` resolves the interpreter the same way
(both go through `scripts/lib/python-interp.sh`) and refuses when it cannot run pytest
at all — an unmeasurable baseline is not a red one.

**Parallel bats (optional).** `suite_jobs = N` in `[project.<name>]` runs bats test
FILES N at a time (`bats --jobs N --no-parallelize-within-files`; the tests inside a
file still run in order), which cut this repo's bats leg from ~9 minutes to well under
half of that at four jobs. It needs GNU parallel on PATH (the `parallel` package —
Debian's moreutils `parallel` is a different program); with `suite_jobs > 1` and no
GNU parallel, `run-suite.sh` dies loud naming the remedy rather than letting bats
report a truncated run — so a second clone of a project that has opted in (a WSL
clone with its own `config.toml`, say) needs the package too, or `suite_jobs = 1` in
that clone's config. `DEVAGENT_SUITE_JOBS=1` forces one serial run (the A/B seam; it
is never inherited by the suite itself), and the artifact's `bats_jobs:` line records
what actually ran. Opt a project in only after auditing its suite at file
granularity (shared HOME, `/tmp`, ports, git state — `tests/README.md` "Parallel
execution" has the rules for this repo); a test that fails only under
`suite_jobs > 1` is a hermeticity defect in that test, never a reason to go back to
serial. Invoking bats directly:

```sh
LC_ALL=C.UTF-8 bats --jobs 4 --no-parallelize-within-files tests/
```

### Writing a new test file

Every test file must be hermetic: one stray `export DEVAGENT_ACTIVE_ISSUE=…` in a
developer's shell must not change a verdict. `tests/lib/hermetic-env.bash` is the
single home for that — it unsets the #240 session pins and neutralizes a hostile
global gitconfig, `TZ`, and locale. How a file gets it depends on its shape:

- A file that `load`s a setup layer (`load 'lib/bats-helpers'`, `load 'helpers/fixtures'`)
  inherits the guard from that layer. Nothing to do.
- A **bare-setup** file — one that `load`s nothing — must source it directly, at file
  scope, in column 0:

  ```sh
  . "${BATS_TEST_DIRNAME}/lib/hermetic-env.bash"
  ```

  At file scope, not inside a test body: `tests/lib_setup_layers.bats` anchors its
  check to column 0, because a line indented inside `if false; then … fi` would
  otherwise read as guarded.

`tests/lib_setup_layers.bats` enforces both arms and fails naming the file and the
line to add. A file that genuinely must vary what the guard pins — today only
`tests/locale-registration.bats`, which varies `LC_ALL` on purpose — goes in that
file's `HERMETIC_EXEMPT` array as `name|reason`, with the reason machine-checked. The
list is capped at two: a third entry refuses, because a growing exemption list is a
backlog wearing the costume of a decision.

A test that shells out to the `claude` CLI takes a live dependency on the developer's
machine. `tests/doctor-hermetic.bats` enforces that any file invoking `scripts/doctor.sh`
loads `tests/lib/doctor-harness.bash`, which PATH-shadows `claude` with a deterministic
stub; loading the harness installs the stub, so the two cannot drift apart.

## Git hooks (opt-in)

CI gates `tests/*.bats` against shellcheck **SC2314** — "In bats, `!` does
not cause a test failure", a vacuous negative assertion (`! grep -q x foo`)
that `bats` silently passes. The failure only shows up in GitHub Actions,
*after* a push.

To catch it in the dev loop instead, enable the tracked pre-push hook:

```sh
scripts/install-git-hooks.sh   # sets core.hooksPath -> .githooks
```

`.githooks/pre-push` runs the same SC2314 check locally before every push
(SC2314-specific, like the CI gate — it ignores the other findings the gate
tolerates). It is **opt-in**: a fresh clone runs no hooks until you run the
installer. Requires `shellcheck >= 0.9.0`; it fails loudly (never silently
passes) if shellcheck is missing or too old.

- Bypass once: `git push --no-verify`
- Disable: `git config --unset core.hooksPath`

CI (`.github/workflows/shellcheck.yml`) remains the authoritative, enforcing
gate; the hook is a faster local mirror, not a replacement.

## Versioning & releases

**Policy (ratified, #532): SHA-tracking — no `version` field anywhere.**
The marketplace entry and `.claude-plugin/plugin.json` both deliberately set
no `version` while devAgent is under active iteration. Per the Claude Code
plugin docs, an unset version means each commit is versioned by its git SHA,
so `/plugin update` picks up new commits without an `uninstall` + `install`
round-trip.

Do **not** re-add a `version` to `.claude-plugin/plugin.json`: a plugin.json
`version` wins over the marketplace entry and silently re-pins the plugin for
every installed user, reintroducing the reinstall tax (#445). This is enforced
by `tests/test_plugin_versioning.py` (CI) and recorded with the measured
evidence in the #532 decision doc.

Consequence, accepted: `claude plugin validate --strict` fails on the missing
version (measured on 2.1.211, re-verified on 2.1.223 — #548) and stays red by design. The wired check is the
**non-strict** `claude plugin validate` (rc=0). Both invocations — the
non-strict check and the strict inverse canary — live in
`tests/plugin-validate.bats`, a local-only rung, since CI has no claude CLI;
the CI-enforcing half is the pytest guard above. Real conformance coverage
comes from the pytest frontmatter canaries (#447): `--strict` is manifest-only
and never opens agent/skill files.

When a stable release cadence is wanted (go-public, #404), revisit #532
branch (b): explicit versions with
[`claude plugin tag`](https://docs.claude.com/en/docs/claude-code/plugins), a
`CHANGELOG.md` section per release, and an explicit migration note — adding a
version changes `/plugin update` behavior for every installed user.
