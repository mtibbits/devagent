# devAgent

devAgent is a Claude Code plugin that runs development work through a fixed,
auditable issue workflow and keeps all of its state on disk — so you can switch
between issues, or hand one to a fresh session, without losing context. It
provides **58 slash commands** driving a **24-step workflow** (21 mandatory steps + 3 optional), works against
GitHub, GitLab, and JIRA issue trackers and GitHub and GitLab code forges (JIRA
is tracker-only; pair it with either forge), and layers capture + issue red-team,
revision, WBS, and status-report subsystems on top of the core loop.

See `docs/specs/2026-05-19-devagent-plugin-design.md` for the design spec and
`docs/plans/` for the incremental build history. New to devAgent? Start with
the onboarding site at https://mtibbits.github.io/devagent/ (source:
`docs-site/`, beginning at `docs-site/index.md`).

## Install

devAgent is a Claude Code plugin. Add its marketplace, then install the plugin:

```sh
# 1. Add the marketplace (the devagent repo)
claude plugin marketplace add mtibbits/devagent

# 2. Install the plugin
claude plugin install devagent@devagent
```

The install reports two `userConfig` options not yet set (`devdoc_root`,
`default_project`); they only seed the `/devagent:init` interview and can be
left unset.

**Recommended — superpowers.** When the
[`superpowers`](https://github.com/anthropics/claude-plugins-official)
plugin is installed, devAgent's implement and review steps — and draft on
its inline (non-dispatched) path — use its skills. When it is absent, those
steps fall back to compact built-in paths and print a one-line install
nudge; devAgent itself always loads either way, and `/devagent:doctor`
warns when the plugin is missing or disabled (#541: recommended, never
hard-required; plugin dependencies do not auto-install, so these are
separate, optional commands):

```sh
# Not configured on a fresh install (measured on 2.1.260; not version-specific)
claude plugin marketplace add anthropics/claude-plugins-official
claude plugin install superpowers@claude-plugins-official
```

Installs from before #541: run `claude plugin update devagent@devagent`
once — the old manifest declared superpowers as a hard dependency, and a
cached copy of it keeps devAgent disabled until updated.

**Updates.** Releases are tagged semver versions (`.claude-plugin/plugin.json`
carries the `version`), so `claude plugin update devagent@devagent` picks up the
next release without an uninstall + reinstall. Merges to `master` between
releases do not reach an installed plugin; see
[Versioning & releases](#versioning--releases).

**Prerequisites.** The workflow scripts need `bash` ≥ 4.4 (the resolver libs use
namerefs), `python3` ≥ 3.11 (or 3.8–3.10 plus `tomli`), `jq`, and `git`. The
backend and auth scripts additionally call `gh` (GitHub), `glab` or `curl`
(GitLab), or `curl` (JIRA), as appropriate for your backend.

**Supported platforms.** devAgent is developed and tested on **Linux**, including
WSL on Windows; CI runs Linux only. macOS is currently untested: the scripts
assume GNU coreutils (`stat -c`, GNU `sed -i`, `readlink -f`). Native Git Bash on
Windows can run the plugin but is not a supported environment for the test suite
(see [Running the test suite](#running-the-test-suite)).

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

`/devagent:comments` fetches reviewer feedback, then `/devagent:revise` opens a
new revision pass that re-runs from `draft` — the revision's first pending step
(`revise` refuses until `comments` has run; it does not fetch them itself); `/devagent:where` and `/devagent:catchup` rehydrate an issue's state at
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
| status   | Print presence, file mode/size/mtime, scopes when known (never the token) |
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
starting point for implementing a tracker that devAgent does not ship
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

The markdown shapes produced by `fetch`, `comment-list` and `mr-comments`
are fixed across backends (spec §9.3) — downstream code is backend-agnostic.
`mr-comments` entries may add an optional ` · review: <STATE>` or
` · <path>:<line>` suffix; the github backend includes review summaries and
inline code comments this way.

## Running the test suite

The canonical runner is `scripts/run-suite.sh`, which runs bats and pytest with
the hermetic environment baked in and writes the provenance artifact
`<issue-dir>/analysis/<date>-suite-count.txt` that `preship-evidence.sh` reads:

```sh
bash "$CLAUDE_PLUGIN_ROOT/scripts/run-suite.sh" <project>
```

`$CLAUDE_PLUGIN_ROOT` is set inside a Claude Code session; in a plain shell use
the path to your clone. The runner needs `<project>` configured in devAgent with
an active issue (the artifact lands in that issue's directory). With only a
clone, run `LC_ALL=C.UTF-8 bats tests/` and `python3 -m pytest tests/` directly
— see `CONTRIBUTING.md`.

The suite has three environmental requirements. `run-suite.sh` enforces the first two
by refusing to write an artifact at all, rather than producing one it cannot stand
behind — the first only for a suite that references file modes, as this repo's does
(#600, below). The third it RECORDS, and `preship-evidence.sh` refuses on the recorded value.
A minimal container running these tests must provide all three.

**A POSIX filesystem where `chmod` actually changes the mode.**
`tests/auth_security.bats` and its siblings pin 0700/0600 modes on the secrets
store; on a mount where `chmod` is a no-op those tests can never pass, and the
run tells you nothing about your branch. `run-suite.sh` probes this
behaviourally. Where `chmod` is a no-op it then scans the suite source — `tests/`
recursively, plus a root `conftest.py` — for file-mode tokens (`chmod`, `umask`,
`st_mode`, `os.access`, `stat -c`, `ls -l`, `PermissionError`, `0o600`-style literals
and similar). A hit refuses and names the first one; this repo's own suite always
hits, so everything below about WSL applies to it unchanged. For another project's
suite with no hit, `run-suite.sh` proceeds and records
`file_modes: no-op; no test file references a file mode (scanned: tests/ + root conftest.py)`
in the artifact, so a reader can tell that run from a `file_modes: posix` one. (`posix`
means the probe found `chmod` effective; the probe fails open on a directory it cannot
probe at all, so read it as "no no-op detected".) The scan is a proxy (#600): it cannot
see a mode dependency that lives only in the code under test or in test-support code
loaded from outside the scanned paths, and a suite that merely
`chmod +x`es a stub counts as a reference — over-refusing is the safe direction. A scan
that cannot run refuses. On native Windows a `.venv/Scripts/` interpreter still needs
`DEVAGENT_PYTEST_PYTHON` (the pytest requirement below).

On Windows that means **a WSL clone on a native Linux filesystem (ext4) — not a
checkout under `/mnt/c`, and not native Git Bash**, whose default `/etc/fstab`
mounts are `noacl`. Give the WSL clone its own `~/.claude/devagent/config.toml`
with a WSL `source_dir`; the devdoc tree can stay shared via `/mnt/c`. Git Bash
is fine for individual scripts (a preship check there attests the WSL tree,
below) — it is not a supported environment for the suite, and that is a
property of the mount, not a defect to repair.

A preship run from the Windows checkout cannot see the WSL tree that the
suite-count artifact's `tree:` line names, so `preship-evidence.sh` fails
`TREE UNATTESTED` until that tree is checked in WSL
(`git -C <tree> rev-parse HEAD` and `git -C <tree> status --porcelain`) and
the check re-runs with `--attest-tree 'head=<sha> dirty=no path=<tree>'`. The
preship verifier does both itself (#655).

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

**pandoc, for one file (optional).** `tests/build-docs-site.bats` renders
`docs-site/` and needs `pandoc` 3.x. Where pandoc is absent — including the
`test suite` workflow's runners — its rendering tests skip with a reason (the
input-refusal tests still run). pandoc is a contributor tool for this one file;
the plugin itself never calls it. The skipped tests are not unrun:
`.github/workflows/publish-docs-site.yml` installs pandoc, runs the file, and
fails if anything in it skips; `docs/pages-deployment.md` has the local build
command.

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

**Policy (re-taken at go-public 2026-09-18, #532): tagged semver releases.**
`.claude-plugin/plugin.json` carries the release `version`; the marketplace
entry deliberately carries none — Claude Code uses the plugin.json value
without warning when both are set, so a second copy can only go stale. Until
1.0.0 the plugin was versioned by git commit SHA (the #532 branch (a) policy,
ratified 2026-07-20 while the repository was private); that decision named the
go-public flip as its revisit trigger, and its branch (b) is now in force. The
decision doc in devDoc `Issue-532/decision-plugin-versioning.md` records both
takes with the measured evidence.

What a version pins: a marketplace install resolves to the `version` string
and only sees an update when that string changes. Merging to `master` no
longer reaches installed users by itself — a release does. A marketplace added
from a local checkout (`claude plugin marketplace add <path>`) loads that
checkout in place and is not pinned.

Cutting a release, all on a clean `master`:

1. Bump `version` in `.claude-plugin/plugin.json`. Patch for fixes; minor for
   added commands, steps or options; major for a change that breaks an
   existing project's `config.toml`, devdoc layout or command contract.
2. Move the `## [Unreleased]` entries in `CHANGELOG.md` under a new
   `## [<version>] — <date>` heading; `tests/test_plugin_versioning.py` fails
   until the section for the manifest version exists.
3. Merge that change, then run `claude plugin tag --push`. It validates the
   plugin, checks that plugin.json and the marketplace entry agree, refuses a
   dirty tree or an existing tag, and pushes the annotated
   `devagent--v<version>` tag — the name Claude Code's dependency resolver
   reads when another plugin declares a version constraint on devAgent.
4. Publish the GitHub release on that tag with the CHANGELOG section as its
   notes: `gh release create devagent--v<version> --title "devagent <version>"
   --notes-file <section>`.

Guards: `tests/test_plugin_versioning.py` (CI) requires a semver `version` in
plugin.json, none in the marketplace entry, and a matching CHANGELOG section.
`tests/plugin-validate.bats` (local-only — CI has no claude CLI) runs
`claude plugin validate --strict` (rc=0 once the version landed, measured on
2.1.223; it was documented-red on the missing version before) and
`claude plugin tag --dry-run`.
