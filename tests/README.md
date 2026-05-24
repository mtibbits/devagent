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
