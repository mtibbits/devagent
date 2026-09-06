# tests/ layout

## Discovery

`bats tests/` discovers only top-level `tests/*.bats` files — it does
**not** recurse. Library tests therefore use the flat naming
convention `tests/lib_<topic>.bats` (e.g. `tests/lib_depends.bats`).
Anything under `tests/lib/` is for sourcing (helpers, the fixture
server, etc.), not direct discovery.

## Helpers

The plugin grew across 10 plans, each of which introduced its own
bats helper for project/fixture setup. They overlap heavily but were
not consolidated during plan execution. Current state:

| Helper                              | Origin   | Primary callers                           |
|-------------------------------------|----------|-------------------------------------------|
| `tests/lib/bats-helpers.bash`       | Plan 1   | `checklist-*`, `catchup`, etc.            |
| `tests/helpers/common.bash`         | Plan 3   | `analyze*`, `branch`, `ship`, `cleanup`   |
| `tests/helpers.bash`                | Plan 5   | capture-family                            |
| `tests/helpers/auth_setup.bash`     | Plan 8   | `auth_*`                                  |
| `tests/helpers/fixtures.bash`       | Plan 6   | `revision_*`                              |
| `tests/lib/_helpers.bash`           | Plan 9   | `lib_depends`, `lib_history`, `lib_template_resolve` |
| `tests/lib/fixture-server.sh`       | Plan 10  | `issue-gitlab`, `code-gitlab`, `issue-jira`, `backend-*` |
| `tests/lib/contract-helpers.bash`   | Plan 10  | `backend-{github,gitlab,jira}`            |

A future polish pass could fold these into a single
`tests/lib/devagent-test.bash` with composable setup functions
(`setup_project`, `setup_secrets_env`, `setup_fixture_http`, etc.).
Risk: touches every test file. Reward: small. Deferred.

## Backend contract suite

The single CI gate for backend conformance is
`bats tests/backend-contract.bats`. It shells out to
`tests/backend-{github,gitlab,jira,custom}.bats` so failures are
attributed to the right backend.

`backend-github.bats` currently skips because the github backend uses
the `gh` CLI exclusively (no REST path). See the comment at the top
of that file for what would need to change to make it run.

## Parallel execution

When a project sets `suite_jobs = N` (N > 1; devagent's own config sets 4),
`scripts/run-suite.sh` runs this suite with `bats --jobs N
--no-parallelize-within-files` (#593): test FILES run N at a time, the tests
inside one file still run in order. Every `.bats` file must therefore be
hermetic at file granularity — the rules the Issue-593 audit verified and that
a new file inherits:

- HOME and the devagent state dir come from a setup layer (`helpers/common`,
  `lib/bats-helpers` + `setup_tmp_devagent_home`, `helpers/auth_setup`,
  `helpers/fixtures`, `lib/_helpers`, `helpers.bash`), never the real
  `~/.claude/devagent`.
- Fixtures live under `$BATS_TEST_TMPDIR` or a `mktemp` path; never create a
  fixed path such as `/tmp/<name>` (passing one as a config VALUE is fine).
- Nothing writes into the plugin tree (`$PLUGIN_ROOT`, `$BATS_TEST_DIRNAME/..`).
- Git identity is per-repo under tmp; `lib/hermetic-env.bash` nulls the global
  config, TZ and locale, and unsets the session pins and `DEVAGENT_SUITE_JOBS`.
- Network fixtures use `lib/fixture-server.sh`, which takes an OS-assigned port.
- A nested `bats` inside a test stays serial (bats does not export its job count).

A test that passes serially and fails only under `suite_jobs > 1` is a
hermeticity defect in that test; fix the test, do not set `suite_jobs = 1`.
