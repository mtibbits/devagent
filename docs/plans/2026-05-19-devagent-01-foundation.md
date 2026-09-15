# devAgent Plan 01 — Foundation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Establish the on-disk substrate every later plan depends on — TOML config loader, per-project state files, secrets-dir bootstrap, checklist/log libraries, `/devagent:init`, `/devagent:doctor`, plugin scaffolding (`commands/`, `skills/`, `scripts/`, `templates/`, `tests/`), and the artifact migrations called out in spec §12.

**Architecture:** Bash 5 is the surface language for every script and library so downstream plans (which are already drafted in bash — see Plan 2) can `source` shared libraries directly. The only Python in this plan is a single tiny CLI shim (`scripts/lib/_toml.py`) that wraps Python 3.11+ stdlib `tomllib` for reads and writes back via `tomli-w`-style hand-rolled emit (we avoid third-party deps). Every shell library exposes a flat namespace of `lib_verb` functions (e.g. `config_get_project_field`, `state_set`, `checklist_mark`). Tests live in `tests/<script>.bats` and `tests/lib/bats-helpers.bash` provides `setup_tmp_devagent_home` so every test gets an ephemeral `~/.claude/devagent/` tree. Plan 2 (`2026-05-19-devagent-02-context-core.md`) consumes every public function this plan ships.

**Tech Stack:**
- Bash 5+ for scripts, libraries, and slash-command thin wrappers
- Python 3.11+ stdlib `tomllib` for TOML parsing (no third-party deps); a 70-line `_toml.py` shim provides `get`, `set`, `unset`, `list-keys`, `list-tables` subcommands
- `bats-core` for shell tests (the engineer must install it locally: `apt install bats` or `npm i -g bats`)
- POSIX `mktemp -d`, `install -m`, `chmod` for filesystem ops
- ISO-8601 timestamps via `date -Iseconds`

**Why bash + a tiny Python TOML shim, not all-Python:** Plan 2 is already drafted assuming bash libraries it can `source`. Rewriting the substrate in Python would force Plan 2 to shell out for every call. TOML, however, is a poor fit for pure-bash parsing — using `tomllib` via a single CLI shim is the smallest viable choice and keeps the rest of the codebase shell-native.

**Spec sections covered:** §3.1, §3.2, §3.3, §3.4, §5.1, §5.2, §5.3, §6.5 (init + doctor only), §12, §19.

**Explicitly out of scope for this plan:**
- Any workflow execution (pull/where/next/status/catchup/stuck/unstuck/park/resume/switch) → Plan 2
- Any backend scripts under `scripts/issue/`, `scripts/code/`, `scripts/auth/` → Plans 2, 3, 8, 10
- Doctor's auth/reachability checks → Plan 8 will extend doctor
- Capture/reap, revision, WBS, status-report, MR, redteam → Plans 5–7
- The `[!]`-state STUCK file workflow consumes Plan 1's checklist library but the `stuck.sh` / `unstuck.sh` scripts are Plan 2

---

## File Structure

**Create (plugin root = `/home/user/src/devAgent/`):**

Plugin scaffolding:
- `.claude-plugin/marketplace.json`
- `README.md` (one-paragraph stub; full docs deferred)
- `commands/init.md`
- `commands/doctor.md`
- `commands/checklist-init.md`
- `commands/checklist-advance.md`
- `commands/checklist-mark.md`
- `commands/checklist-log.md`
- `commands/checklist-stuck.md`
- `commands/checklist-unstuck.md`
- `skills/.gitkeep`

Libraries:
- `scripts/lib/_toml.py` — Python `tomllib` CLI shim
- `scripts/lib/io.sh` — `die`, `info`, `warn`, `confirm`, `is_tty`
- `scripts/lib/config.sh` — TOML config reader (`~/.claude/devagent/config.toml`)
- `scripts/lib/state.sh` — TOML per-project state reader/writer
- `scripts/lib/secrets.sh` — secrets-dir bootstrap and permission audit
- `scripts/lib/log.sh` — append/tail timestamped checklist log entries
- `scripts/lib/checklist.sh` — parse/mark/advance the 21-step checklist
- `scripts/lib/paths.sh` — derive `PLUGIN_ROOT`, `DEVAGENT_HOME`, expand `~`

Scripts:
- `scripts/init.sh` — interactive bootstrap for `/devagent:init <project>`
- `scripts/doctor.sh` — config/state/paths/checklist sanity checks
- `scripts/checklist-init.sh`
- `scripts/checklist-advance.sh`
- `scripts/checklist-mark.sh`
- `scripts/checklist-log.sh`
- `scripts/checklist-stuck.sh`
- `scripts/checklist-unstuck.sh`

Templates:
- `templates/checklist-standard.md` — the 21-step template Plan 2 consumes
- `templates/checklist-docs-only.md`
- `templates/checklist-research.md`
- `templates/checklist-perf.md`
- `templates/state.toml.skel`
- `templates/config.toml.skel`
- `templates/commit_template.md` (moved from `commitMessageTemplate.md`)
- `templates/mr_template.md` (moved from `PULL_REQUEST_TEMPLATE.md`)
- `templates/redteam_mr.md` (moved from `pr-redteam-prompt.md`)
- `templates/redteam_issue.md` (moved from `~/.claude/issue-redteam-prompt.md`)

Tests:
- `tests/lib/bats-helpers.bash` — `setup_tmp_devagent_home`, `fixtures_dir`, `assert_file_mode`
- `tests/fixtures/config-onproject.toml`
- `tests/fixtures/config-twoproject.toml`
- `tests/fixtures/config-malformed.toml`
- `tests/_toml.bats`
- `tests/config.bats`
- `tests/state.bats`
- `tests/secrets.bats`
- `tests/log.bats`
- `tests/checklist.bats`
- `tests/checklist-init.bats`
- `tests/checklist-advance.bats`
- `tests/checklist-mark.bats`
- `tests/checklist-log.bats`
- `tests/checklist-stuck.bats`
- `tests/checklist-unstuck.bats`
- `tests/init.bats`
- `tests/doctor.bats`

**Move (spec §12 migrations, in-repo):**
- `commitMessageTemplate.md` → `templates/commit_template.md`
- `PULL_REQUEST_TEMPLATE.md` → `templates/mr_template.md`
- `pr-redteam-prompt.md` → `templates/redteam_mr.md`

**Copy (cross-repo migration):**
- `~/.claude/issue-redteam-prompt.md` → `templates/redteam_issue.md` (copy then leave original; cross-repo symlinks are fragile)

**Modify:** none (this is a greenfield plan).

---

## Public Function Contracts

The following are the exact signatures every later plan consumes. Each task below tests these contracts.

`scripts/lib/io.sh`:
```bash
die <msg>                       # prints "<scriptname>: <msg>" to stderr, exits 1
info <msg>                      # prints "<scriptname>: <msg>" to stderr (no exit)
warn <msg>                      # prints "<scriptname>: WARNING: <msg>" to stderr
confirm <prompt>                # reads y/N; exit 0 on y/Y/Enter, 1 otherwise; auto-yes if $DA_YES=1
is_tty                          # exit 0 if stdin is a tty, else 1
```

`scripts/lib/paths.sh`:
```bash
plugin_root                     # echo absolute path to /home/user/src/devAgent
devagent_home                   # echo ${DA_HOME:-$HOME/.claude/devagent}
config_path                     # echo "$(devagent_home)/config.toml"
state_path <project>            # echo "$(devagent_home)/state/<project>.toml"
secrets_dir                     # echo "$(devagent_home)/secrets"
expand_tilde <path>             # echo path with leading ~ replaced by $HOME
```

`scripts/lib/config.sh`:
```bash
config_load                              # validate config exists/parses; die otherwise
config_get <dotted.key>                  # echo value or empty; exit 0 if found, 1 if not
config_get_default <dotted.key>          # config_get "defaults.<key>"
config_get_project_field <project> <key> # echo project[.<key>] value; '' if unset
config_list_projects                     # one project name per line
config_is_project <project>              # exit 0 if project exists, 1 otherwise
config_active_project                    # echo the only project iff exactly one configured; else die
```

`scripts/lib/state.sh`:
```bash
state_init <project>                          # create empty state file mode 600
state_exists <project>                        # exit 0/1
state_get <project> <key>                     # echo value or empty
state_set <project> <key> <value>             # write key (atomic via tmpfile + mv)
state_unset <project> <key>
state_active_project                          # echo the most-recently-updated project with non-null active_issue
state_list_parked <project>                   # one issue per line
state_add_parked <project> <issue>            # idempotent
state_remove_parked <project> <issue>         # idempotent
```

`scripts/lib/secrets.sh`:
```bash
secrets_bootstrap                # mkdir -p secrets dir, chmod 700, audit owner
secrets_audit                    # warn if dir/file modes drift; exit 0 if clean, 1 otherwise
```

`scripts/lib/log.sh`:
```bash
log_append <issue-dir> <step-name> <message>  # appends to <issue-dir>/checklist.md '## Log' section
log_tail   <issue-dir> <N>                    # print last N log lines (header excluded)
```

`scripts/lib/checklist.sh`:
```bash
checklist_init <issue-dir> <template-name>             # writes <issue-dir>/checklist.md from templates/checklist-<template>.md
checklist_current_step <file>                          # echo step-num of the first non-done step; 'done' if all complete
checklist_step_state   <file> <step-num>               # echo one of: ' ' x - ! ~ ? P
checklist_step_name    <file> <step-num>               # echo human name (e.g. 'pull', 'implement')
checklist_mark         <file> <step-num> <glyph>       # glyph in: ' ' x - ! ~ ? P; rewrites in place atomically
checklist_advance      <file>                          # mark current step done (x), echo new current step
```

`scripts/lib/_toml.py`:
```
_toml.py get   <file> <dotted.key>            # prints value as bare string
_toml.py set   <file> <dotted.key> <value>    # writes string value
_toml.py set-bool  <file> <dotted.key> true|false
_toml.py set-int   <file> <dotted.key> <int>
_toml.py unset <file> <dotted.key>
_toml.py list-keys   <file> [<table>]
_toml.py list-tables <file>
_toml.py validate    <file>
```

---

## Task 0: Plugin scaffolding and migrations

**Files:**
- Create: `.claude-plugin/marketplace.json`, `README.md`, `commands/`, `skills/.gitkeep`, `templates/`, `scripts/lib/`, `tests/lib/`, `tests/fixtures/`
- Move: in-repo template relocations per spec §12
- Copy: `~/.claude/issue-redteam-prompt.md` → `templates/redteam_issue.md`

- [ ] **Step 0.1: Create directory skeleton**

```bash
cd /home/user/src/devAgent
mkdir -p .claude-plugin commands skills scripts/lib templates tests/lib tests/fixtures
touch skills/.gitkeep
```

- [ ] **Step 0.2: Write marketplace.json**

Create `.claude-plugin/marketplace.json`:

```json
{
  "$schema": "https://anthropic.com/claude-code/marketplace.schema.json",
  "name": "devagent",
  "description": "Workflow state preservation for multi-issue development across GitHub/GitLab/JIRA.",
  "owner": {
    "name": "Matt Tibbits",
    "url": "https://github.com/mtibbits/devagent/issues"
  },
  "plugins": [
    {
      "name": "devagent",
      "description": "Plugin that documents the state of in-progress development work so the operator can switch issues without losing context. v1: foundation only.",
      "version": "0.1.0",
      "source": "./",
      "author": { "name": "Matt Tibbits" }
    }
  ]
}
```

- [ ] **Step 0.3: Write README.md stub**

Create `README.md`:

```markdown
# devAgent

Claude Code plugin that preserves workflow state across issue switches. See
`docs/specs/2026-05-19-devagent-plugin-design.md` for the design
spec. v1 is built in 10 incremental plans under `docs/plans/`.

This plan (Plan 01) ships only the foundation:
`/devagent:init`, `/devagent:doctor`, and the `checklist-*` family.
```

- [ ] **Step 0.4: Run migrations (in-repo moves with git)**

```bash
cd /home/user/src/devAgent
git mv commitMessageTemplate.md   templates/commit_template.md
git mv PULL_REQUEST_TEMPLATE.md   templates/mr_template.md
git mv pr-redteam-prompt.md       templates/redteam_mr.md
```

- [ ] **Step 0.5: Copy cross-repo template**

```bash
cp /home/user/.claude/issue-redteam-prompt.md \
   /home/user/src/devAgent/templates/redteam_issue.md
```

The cross-repo source is intentionally left in place. Spec §12 mentions
"symlinks for one release cycle", but cross-repo symlinks are fragile when
the repo is cloned elsewhere; a copy is safer and the original is harmless.

- [ ] **Step 0.6: Commit**

```bash
cd /home/user/src/devAgent
git add .claude-plugin README.md commands skills templates tests scripts
git commit -s -m "$(cat <<'EOF'
plan01: scaffold plugin layout and migrate existing templates

Creates the directory skeleton (commands/, skills/, scripts/lib/,
templates/, tests/) plus marketplace.json. Relocates pre-existing
commit/MR/red-team templates into templates/ per spec §12.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 1: Bats test helpers and fixtures

**Files:**
- Create: `tests/lib/bats-helpers.bash`
- Create: `tests/fixtures/config-onproject.toml`
- Create: `tests/fixtures/config-twoproject.toml`
- Create: `tests/fixtures/config-malformed.toml`
- Test: tested transitively by every later task

- [ ] **Step 1.1: Verify bats is installed**

```bash
bats --version
```

Expected: `Bats <version>`. If `command not found`, install via your OS package manager (`apt install bats` on Ubuntu/Debian) or `npm install -g bats` before continuing.

- [ ] **Step 1.2: Write bats-helpers.bash**

Create `tests/lib/bats-helpers.bash`:

```bash
# tests/lib/bats-helpers.bash
# Sourced by every .bats test via `load 'lib/bats-helpers'`.

PLUGIN_ROOT="${PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
export PLUGIN_ROOT

setup_tmp_devagent_home() {
  DA_HOME="$(mktemp -d)"
  export DA_HOME
  mkdir -p "$DA_HOME/state" "$DA_HOME/secrets"
  chmod 700 "$DA_HOME/secrets"
}

teardown_tmp_devagent_home() {
  if [[ -n "${DA_HOME:-}" && -d "$DA_HOME" && "$DA_HOME" == /tmp/* ]]; then
    rm -rf "$DA_HOME"
  fi
}

fixtures_dir() {
  echo "$PLUGIN_ROOT/tests/fixtures"
}

assert_file_mode() {
  local path="$1" want="$2"
  local got
  got="$(stat -c '%a' "$path")"
  [[ "$got" == "$want" ]] || {
    echo "expected mode $want on $path, got $got" >&2
    return 1
  }
}

install_fixture_config() {
  local fixture="$1"
  cp "$(fixtures_dir)/$fixture" "$DA_HOME/config.toml"
}
```

- [ ] **Step 1.3: Write fixture configs**

Create `tests/fixtures/config-onproject.toml`:

```toml
[defaults]
checklist_template = "standard"
ship_as_draft = false

[project.volk]
source_dir = "~/src/volk"
source_remote = "git@gitlab.com:mtibbits/volk.git"
upstream_remote = "https://github.com/gnuradio/volk"
devdoc_dir = "~/src/devDoc/volk"
fork_first = true
ship_as_draft = true
default_baseline = "origin/main"
all_prs_branch = "dev/all-prs"

[project.volk.permissions]
push_mr = true
merge_mr = true
commit_devdoc = true
transition_issue = true
cleanup_on_merge = false

[project.volk.issue_source]
backend = "github"
repo = "gnuradio/volk"
dir_prefix = "Issue-"

[project.volk.code_source]
backend = "github"
upstream = "gnuradio/volk"
fork = "mtibbits/volk"
```

Create `tests/fixtures/config-twoproject.toml` — same as above plus a second `[project.toy]` block (single-backend, minimal fields):

```toml
[defaults]
checklist_template = "standard"

[project.volk]
source_dir = "~/src/volk"
devdoc_dir = "~/src/devDoc/volk"
default_baseline = "origin/main"

[project.volk.issue_source]
backend = "github"
repo = "gnuradio/volk"
dir_prefix = "Issue-"

[project.volk.code_source]
backend = "github"
upstream = "gnuradio/volk"
fork = "mtibbits/volk"

[project.toy]
source_dir = "~/src/toy"
devdoc_dir = "~/src/devDoc/toy"
default_baseline = "origin/main"

[project.toy.issue_source]
backend = "github"
repo = "me/toy"
dir_prefix = "Issue-"

[project.toy.code_source]
backend = "github"
upstream = "me/toy"
fork = "me/toy"
```

Create `tests/fixtures/config-malformed.toml`:

```toml
[defaults
not_real_toml = yes
```

- [ ] **Step 1.4: Commit**

```bash
cd /home/user/src/devAgent
git add tests/lib tests/fixtures
git commit -s -m "$(cat <<'EOF'
plan01: add bats test helpers and config fixtures

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: TOML CLI shim (`scripts/lib/_toml.py`)

**Files:**
- Create: `scripts/lib/_toml.py`
- Test: `tests/_toml.bats`

- [ ] **Step 2.1: Write the failing test**

Create `tests/_toml.bats`:

```bash
#!/usr/bin/env bats

load 'lib/bats-helpers'

setup() {
  setup_tmp_devagent_home
  install_fixture_config config-onproject.toml
  TOML="$PLUGIN_ROOT/scripts/lib/_toml.py"
}

teardown() { teardown_tmp_devagent_home; }

@test "get reads a top-level scalar" {
  run python3 "$TOML" get "$DA_HOME/config.toml" defaults.checklist_template
  [ "$status" -eq 0 ]
  [ "$output" = "standard" ]
}

@test "get reads a nested scalar" {
  run python3 "$TOML" get "$DA_HOME/config.toml" project.volk.devdoc_dir
  [ "$status" -eq 0 ]
  [ "$output" = "~/src/devDoc/volk" ]
}

@test "get returns nonzero on missing key" {
  run python3 "$TOML" get "$DA_HOME/config.toml" project.volk.nope
  [ "$status" -ne 0 ]
}

@test "list-tables enumerates project subtable names" {
  run python3 "$TOML" list-tables "$DA_HOME/config.toml"
  [ "$status" -eq 0 ]
  [[ "$output" == *"project.volk"* ]]
  [[ "$output" == *"project.volk.issue_source"* ]]
}

@test "set then get round-trips a string" {
  python3 "$TOML" set "$DA_HOME/config.toml" project.volk.new_key '"hello world"'
  run python3 "$TOML" get "$DA_HOME/config.toml" project.volk.new_key
  [ "$status" -eq 0 ]
  [ "$output" = "hello world" ]
}

@test "set-bool writes a boolean" {
  python3 "$TOML" set-bool "$DA_HOME/config.toml" project.volk.fork_first false
  run python3 "$TOML" get "$DA_HOME/config.toml" project.volk.fork_first
  [ "$status" -eq 0 ]
  [ "$output" = "false" ]
}

@test "unset removes a key" {
  python3 "$TOML" unset "$DA_HOME/config.toml" defaults.checklist_template
  run python3 "$TOML" get "$DA_HOME/config.toml" defaults.checklist_template
  [ "$status" -ne 0 ]
}

@test "validate exits 0 on good file, nonzero on malformed" {
  run python3 "$TOML" validate "$DA_HOME/config.toml"
  [ "$status" -eq 0 ]
  cp "$(fixtures_dir)/config-malformed.toml" "$DA_HOME/bad.toml"
  run python3 "$TOML" validate "$DA_HOME/bad.toml"
  [ "$status" -ne 0 ]
}

@test "concurrent writes do not lose updates" {
  # Launch 20 concurrent writers each setting a distinct key.
  # Without flock, lost-update races would drop some keys.
  local i pids=()
  for i in $(seq 1 20); do
    python3 "$TOML" set "$DA_HOME/config.toml" \
      "project.volk.race_$i" "\"v$i\"" &
    pids+=($!)
  done
  for pid in "${pids[@]}"; do wait "$pid"; done

  # All 20 keys must be readable.
  local missing=0
  for i in $(seq 1 20); do
    run python3 "$TOML" get "$DA_HOME/config.toml" "project.volk.race_$i"
    [ "$status" -eq 0 ] || { missing=$((missing+1)); continue; }
    [ "$output" = "v$i" ] || missing=$((missing+1))
  done
  [ "$missing" -eq 0 ]
}

@test "lock file is released on exception" {
  # Force a malformed write (a bad value type) and verify the lock
  # does not stick around blocking subsequent writers.
  ! python3 "$TOML" set-bool "$DA_HOME/config.toml" \
      project.volk.fork_first not-a-bool
  # Now a normal write must still succeed.
  run python3 "$TOML" set "$DA_HOME/config.toml" \
      project.volk.after_error '"ok"'
  [ "$status" -eq 0 ]
}
```

- [ ] **Step 2.2: Run tests to verify they fail**

```bash
cd /home/user/src/devAgent && bats tests/_toml.bats
```

Expected: every test (10 total) fails with `_toml.py: No such file or directory`.

- [ ] **Step 2.3: Write `_toml.py`**

Create `scripts/lib/_toml.py`:

```python
#!/usr/bin/env python3
"""Minimal TOML CLI shim used by devAgent bash libraries.

Reads via Python 3.11+ stdlib tomllib. Writes by emitting a conservative
subset of TOML by hand — we only need: top-level tables, nested tables,
string/bool/int scalars. Lists/dates/inline-tables are read-only.

Mutation verbs (set, set-bool, set-int, unset) acquire an exclusive
fcntl.flock on a sibling .lock file for the entire read-modify-write
cycle and write via tempfile + atomic os.rename. Concurrent writers
are serialized; readers do not need to lock (POSIX rename atomicity
guarantees a consistent view).
"""

from __future__ import annotations
import fcntl
import sys
import tomllib
from contextlib import contextmanager
from pathlib import Path


def _load(path: Path) -> dict:
    with path.open("rb") as fh:
        return tomllib.load(fh)


@contextmanager
def _locked_rmw(path: Path):
    """Exclusive-locked read-modify-write.

    Usage:
        with _locked_rmw(path) as data:
            data["x"] = 1
        # _dump(path, data) happens automatically on clean exit;
        # lock is released even on exception.
    """
    lock_path = path.with_suffix(path.suffix + ".lock")
    lock_path.touch(exist_ok=True)
    with lock_path.open("w") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        try:
            data = _load(path)
            yield data
            _dump(path, data)
        finally:
            fcntl.flock(lock, fcntl.LOCK_UN)


def _walk(data: dict, dotted: str):
    cur = data
    for part in dotted.split("."):
        if not isinstance(cur, dict) or part not in cur:
            raise KeyError(dotted)
        cur = cur[part]
    return cur


def _emit_value(v) -> str:
    if isinstance(v, bool):
        return "true" if v else "false"
    if isinstance(v, int):
        return str(v)
    if isinstance(v, str):
        # quote double-quotes and backslashes
        esc = v.replace("\\", "\\\\").replace('"', '\\"')
        return f'"{esc}"'
    raise TypeError(f"cannot emit type {type(v).__name__}")


def _emit_table(name: str, table: dict, out: list[str]) -> None:
    if name:
        out.append(f"[{name}]")
    scalars = []
    subtables = []
    for k, v in table.items():
        if isinstance(v, dict):
            subtables.append((k, v))
        else:
            scalars.append((k, v))
    for k, v in scalars:
        out.append(f"{k} = {_emit_value(v)}")
    if name or scalars:
        out.append("")
    for k, sub in subtables:
        _emit_table(f"{name}.{k}" if name else k, sub, out)


def _dump(path: Path, data: dict) -> None:
    out: list[str] = []
    _emit_table("", data, out)
    text = "\n".join(out).rstrip() + "\n"
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_text(text)
    tmp.replace(path)


def _set_path(data: dict, dotted: str, value) -> None:
    parts = dotted.split(".")
    cur = data
    for p in parts[:-1]:
        cur = cur.setdefault(p, {})
        if not isinstance(cur, dict):
            raise ValueError(f"{p} is not a table")
    cur[parts[-1]] = value


def _unset_path(data: dict, dotted: str) -> None:
    parts = dotted.split(".")
    cur = data
    for p in parts[:-1]:
        if p not in cur or not isinstance(cur[p], dict):
            return
        cur = cur[p]
    cur.pop(parts[-1], None)


def _list_tables(data: dict, prefix: str = "") -> list[str]:
    out = []
    for k, v in data.items():
        if isinstance(v, dict):
            name = f"{prefix}.{k}" if prefix else k
            out.append(name)
            out.extend(_list_tables(v, name))
    return out


def _list_keys(data: dict, table: str | None) -> list[str]:
    cur = data if not table else _walk(data, table)
    if not isinstance(cur, dict):
        raise KeyError(table or "")
    return [k for k, v in cur.items() if not isinstance(v, dict)]


def _parse_raw(raw: str):
    """Parse a raw CLI-supplied scalar.

    Quoted strings ('...' or "...") are stripped. Bare tokens are passed
    through as strings (callers should use set-bool/set-int for typed values).
    """
    if len(raw) >= 2 and raw[0] == raw[-1] and raw[0] in ('"', "'"):
        return raw[1:-1]
    return raw


def main(argv: list[str]) -> int:
    if len(argv) < 2:
        print("usage: _toml.py <verb> <file> [args...]", file=sys.stderr)
        return 2
    verb, file = argv[0], Path(argv[1])
    rest = argv[2:]

    if verb == "validate":
        try:
            _load(file)
        except Exception as e:
            print(f"_toml: {e}", file=sys.stderr)
            return 1
        return 0

    if verb == "get":
        data = _load(file)
        try:
            v = _walk(data, rest[0])
        except KeyError:
            return 1
        if isinstance(v, dict):
            print(f"_toml: '{rest[0]}' is a table, not a value", file=sys.stderr)
            return 1
        print(_emit_value(v).strip('"') if isinstance(v, str)
              else _emit_value(v))
        return 0

    if verb == "list-tables":
        data = _load(file)
        for t in _list_tables(data):
            print(t)
        return 0

    if verb == "list-keys":
        data = _load(file)
        table = rest[0] if rest else None
        try:
            for k in _list_keys(data, table):
                print(k)
        except KeyError:
            return 1
        return 0

    if verb in {"set", "set-bool", "set-int", "unset"}:
        # Validate args BEFORE entering the lock so a bad invocation
        # doesn't briefly hold the lock for no reason.
        if verb == "set-bool" and rest[1] not in ("true", "false"):
            print("_toml: set-bool wants true|false", file=sys.stderr)
            return 2
        with _locked_rmw(file) as data:
            if verb == "unset":
                _unset_path(data, rest[0])
            else:
                key, raw = rest[0], rest[1]
                if verb == "set-bool":
                    _set_path(data, key, raw == "true")
                elif verb == "set-int":
                    _set_path(data, key, int(raw))
                else:
                    _set_path(data, key, _parse_raw(raw))
        return 0

    print(f"_toml: unknown verb '{verb}'", file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
```

- [ ] **Step 2.4: Make executable and rerun tests**

```bash
cd /home/user/src/devAgent
chmod +x scripts/lib/_toml.py
bats tests/_toml.bats
```

Expected: all 10 tests PASS. The concurrent-writes test must finish
without losing any of the 20 racing updates.

- [ ] **Step 2.5: Commit**

```bash
git add scripts/lib/_toml.py tests/_toml.bats
git commit -s -m "$(cat <<'EOF'
plan01: add _toml.py CLI shim over Python tomllib

Provides get/set/set-bool/set-int/unset/list-keys/list-tables/validate
verbs used by scripts/lib/config.sh and scripts/lib/state.sh.

Mutation verbs hold an exclusive fcntl.flock on a sibling .lock file
across the entire read-modify-write cycle and write via tempfile +
atomic rename. Concurrent writers are serialized; readers do not need
to lock (POSIX rename atomicity guarantees a consistent view).

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: `scripts/lib/paths.sh` and `scripts/lib/io.sh`

**Files:**
- Create: `scripts/lib/paths.sh`, `scripts/lib/io.sh`
- Test: implicitly tested by every later task; no dedicated bats file (these are 30-line utilities)

- [ ] **Step 3.1: Write `paths.sh`**

Create `scripts/lib/paths.sh`:

```bash
#!/usr/bin/env bash
# scripts/lib/paths.sh — path helpers. Safe to source multiple times.

plugin_root() {
  # The file lives at <root>/scripts/lib/paths.sh. Walk up two dirs.
  cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd
}

devagent_home() {
  echo "${DA_HOME:-$HOME/.claude/devagent}"
}

config_path() {
  echo "$(devagent_home)/config.toml"
}

state_path() {
  local project="$1"
  [[ -n "$project" ]] || { echo "state_path: project required" >&2; return 1; }
  echo "$(devagent_home)/state/${project}.toml"
}

secrets_dir() {
  echo "$(devagent_home)/secrets"
}

expand_tilde() {
  local p="$1"
  echo "${p/#\~/$HOME}"
}
```

- [ ] **Step 3.2: Write `io.sh`**

Create `scripts/lib/io.sh`:

```bash
#!/usr/bin/env bash
# scripts/lib/io.sh — small io helpers. Safe to source multiple times.

_io_progname() {
  basename "${BASH_SOURCE[1]:-${0}}"
}

die() {
  echo "$(_io_progname): $*" >&2
  exit 1
}

info() {
  echo "$(_io_progname): $*" >&2
}

warn() {
  echo "$(_io_progname): WARNING: $*" >&2
}

is_tty() {
  [[ -t 0 ]]
}

confirm() {
  local prompt="${1:-Proceed?}"
  if [[ "${DA_YES:-}" == "1" ]]; then
    return 0
  fi
  if ! is_tty; then
    return 1
  fi
  local reply
  read -r -p "$prompt [Y/n] " reply
  case "$reply" in
    ""|y|Y|yes|YES) return 0 ;;
    *)              return 1 ;;
  esac
}
```

- [ ] **Step 3.3: Smoke-test interactively**

```bash
cd /home/user/src/devAgent
bash -c 'source scripts/lib/paths.sh; plugin_root; devagent_home'
bash -c 'source scripts/lib/io.sh; DA_YES=1; confirm "test?" && echo OK'
```

Expected: prints `/home/user/src/devAgent`, then the home dir, then `OK`.

- [ ] **Step 3.4: Commit**

```bash
git add scripts/lib/paths.sh scripts/lib/io.sh
git commit -s -m "$(cat <<'EOF'
plan01: add paths.sh and io.sh shared helpers

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 4: `scripts/lib/config.sh`

**Files:**
- Create: `scripts/lib/config.sh`
- Test: `tests/config.bats`

- [ ] **Step 4.1: Write the failing test**

Create `tests/config.bats`:

```bash
#!/usr/bin/env bats

load 'lib/bats-helpers'

setup() {
  setup_tmp_devagent_home
  install_fixture_config config-twoproject.toml
  source "$PLUGIN_ROOT/scripts/lib/paths.sh"
  source "$PLUGIN_ROOT/scripts/lib/io.sh"
  source "$PLUGIN_ROOT/scripts/lib/config.sh"
}

teardown() { teardown_tmp_devagent_home; }

@test "config_load passes on a good file" {
  run config_load
  [ "$status" -eq 0 ]
}

@test "config_load dies on a missing file" {
  rm "$DA_HOME/config.toml"
  run config_load
  [ "$status" -ne 0 ]
}

@test "config_get reads a default" {
  run config_get defaults.checklist_template
  [ "$status" -eq 0 ]
  [ "$output" = "standard" ]
}

@test "config_get_project_field reads a nested field" {
  run config_get_project_field volk issue_source.repo
  [ "$status" -eq 0 ]
  [ "$output" = "gnuradio/volk" ]
}

@test "config_list_projects lists both" {
  run config_list_projects
  [ "$status" -eq 0 ]
  [[ "$output" == *"volk"* ]]
  [[ "$output" == *"toy"*  ]]
}

@test "config_is_project true/false" {
  run config_is_project volk
  [ "$status" -eq 0 ]
  run config_is_project nope
  [ "$status" -ne 0 ]
}

@test "config_active_project dies on multi-project file" {
  run config_active_project
  [ "$status" -ne 0 ]
}

@test "config_active_project echoes the one project on single-project file" {
  install_fixture_config config-onproject.toml
  run config_active_project
  [ "$status" -eq 0 ]
  [ "$output" = "volk" ]
}
```

- [ ] **Step 4.2: Run tests to verify they fail**

```bash
bats tests/config.bats
```

Expected: every test fails with `command not found: config_load`.

- [ ] **Step 4.3: Implement `config.sh`**

Create `scripts/lib/config.sh`:

```bash
#!/usr/bin/env bash
# scripts/lib/config.sh — read ~/.claude/devagent/config.toml.
# Requires paths.sh and io.sh sourced first.

_config_toml() {
  python3 "$(plugin_root)/scripts/lib/_toml.py" "$@"
}

config_load() {
  local f
  f="$(config_path)"
  [[ -f "$f" ]] || die "config not found at $f (run /devagent:init <project>)"
  _config_toml validate "$f" || die "config at $f is not valid TOML"
}

config_get() {
  local key="$1"
  _config_toml get "$(config_path)" "$key"
}

config_get_default() {
  config_get "defaults.$1"
}

config_get_project_field() {
  local project="$1" field="$2"
  [[ -n "$project" && -n "$field" ]] || {
    echo "config_get_project_field: project and field required" >&2
    return 2
  }
  config_get "project.${project}.${field}"
}

config_list_projects() {
  _config_toml list-tables "$(config_path)" \
    | awk -F. '$1=="project" && NF==2 { print $2 }'
}

config_is_project() {
  local target="$1" p
  while IFS= read -r p; do
    [[ "$p" == "$target" ]] && return 0
  done < <(config_list_projects)
  return 1
}

config_active_project() {
  local count=0 only=""
  local p
  while IFS= read -r p; do
    count=$((count + 1))
    only="$p"
  done < <(config_list_projects)
  if (( count == 1 )); then
    echo "$only"
    return 0
  fi
  die "config_active_project: $count projects configured; pass project explicitly"
}
```

- [ ] **Step 4.4: Run tests to verify they pass**

```bash
bats tests/config.bats
```

Expected: 8/8 PASS.

- [ ] **Step 4.5: Commit**

```bash
git add scripts/lib/config.sh tests/config.bats
git commit -s -m "$(cat <<'EOF'
plan01: add config.sh TOML config reader

Exposes config_load, config_get, config_get_project_field,
config_list_projects, config_is_project, config_active_project,
config_get_default. Backed by _toml.py shim.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 5: `scripts/lib/state.sh`

**Files:**
- Create: `scripts/lib/state.sh`
- Create: `templates/state.toml.skel`
- Test: `tests/state.bats`

- [ ] **Step 5.1: Write the failing test**

Create `tests/state.bats`:

```bash
#!/usr/bin/env bats

load 'lib/bats-helpers'

setup() {
  setup_tmp_devagent_home
  source "$PLUGIN_ROOT/scripts/lib/paths.sh"
  source "$PLUGIN_ROOT/scripts/lib/io.sh"
  source "$PLUGIN_ROOT/scripts/lib/state.sh"
}

teardown() { teardown_tmp_devagent_home; }

@test "state_init creates a mode-600 file" {
  state_init volk
  [ -f "$DA_HOME/state/volk.toml" ]
  assert_file_mode "$DA_HOME/state/volk.toml" 600
}

@test "state_exists reflects state_init" {
  run state_exists volk
  [ "$status" -ne 0 ]
  state_init volk
  run state_exists volk
  [ "$status" -eq 0 ]
}

@test "state_set then state_get round-trips" {
  state_init volk
  state_set volk active_issue Issue-676
  run state_get volk active_issue
  [ "$status" -eq 0 ]
  [ "$output" = "Issue-676" ]
}

@test "state_unset removes a key" {
  state_init volk
  state_set volk active_issue Issue-676
  state_unset volk active_issue
  run state_get volk active_issue
  [ -z "$output" ]
}

@test "parked list add/remove/list is idempotent" {
  state_init volk
  state_add_parked volk Issue-12
  state_add_parked volk Issue-12   # idempotent
  state_add_parked volk Issue-34
  run state_list_parked volk
  [ "$status" -eq 0 ]
  [[ "$output" == *"Issue-12"* ]]
  [[ "$output" == *"Issue-34"* ]]
  state_remove_parked volk Issue-12
  state_remove_parked volk Issue-12 # idempotent
  run state_list_parked volk
  [[ "$output" != *"Issue-12"* ]]
  [[ "$output" == *"Issue-34"* ]]
}

@test "state_active_project returns the most recently updated" {
  state_init volk
  state_init toy
  state_set toy  active_issue Issue-1
  sleep 1
  state_set volk active_issue Issue-2
  run state_active_project
  [ "$status" -eq 0 ]
  [ "$output" = "volk" ]
}

@test "state_active_project ignores projects with null active_issue" {
  state_init toy
  run state_active_project
  [ "$status" -ne 0 ]
}

@test "state_set updates updated_at field automatically" {
  state_init volk
  state_set volk active_issue Issue-1
  run state_get volk updated_at
  [ "$status" -eq 0 ]
  [[ "$output" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T ]]
}
```

- [ ] **Step 5.2: Run tests to verify they fail**

```bash
bats tests/state.bats
```

Expected: every test fails.

- [ ] **Step 5.3: Write `templates/state.toml.skel`**

Create `templates/state.toml.skel`:

```toml
active_issue   = ""
issue_dir      = ""
branch         = ""
baseline_sha   = ""
worktree_path  = ""
last_step      = 0
last_step_name = ""
mr_url         = ""
revision       = 1
updated_at     = ""

[parked]
# (no entries by default; populated as `"Issue-XYZ" = true` keys)
```

Note: `[parked]` is a TOML table with boolean-true keys, not an array.
Per spec §3.3, this representation was chosen over the array form for
two reasons: (1) per-issue add/remove is a direct key write/delete with
no read-splice-write of an array body, and (2) the table form composes
naturally with future per-issue metadata (`[parked."Issue-12"]` with
`parked_at`, `reason`, …) if v2 ever needs it. Order is not preserved;
v1 does not depend on order.

- [ ] **Step 5.4: Implement `state.sh`**

Create `scripts/lib/state.sh`:

```bash
#!/usr/bin/env bash
# scripts/lib/state.sh — read/write ~/.claude/devagent/state/<project>.toml.
# Requires paths.sh and io.sh sourced first.

_state_toml() {
  python3 "$(plugin_root)/scripts/lib/_toml.py" "$@"
}

_state_now() {
  date -Iseconds
}

state_init() {
  local project="$1" f
  [[ -n "$project" ]] || die "state_init: project required"
  f="$(state_path "$project")"
  mkdir -p "$(dirname "$f")"
  chmod 700 "$(dirname "$f")" 2>/dev/null || true
  if [[ ! -f "$f" ]]; then
    install -m 600 /dev/null "$f"
    _state_toml set     "$f" active_issue   '""'
    _state_toml set     "$f" issue_dir      '""'
    _state_toml set     "$f" branch         '""'
    _state_toml set     "$f" baseline_sha   '""'
    _state_toml set     "$f" worktree_path  '""'
    _state_toml set-int "$f" last_step      0
    _state_toml set     "$f" last_step_name '""'
    _state_toml set     "$f" mr_url         '""'
    _state_toml set-int "$f" revision       1
    _state_toml set     "$f" updated_at     '""'
    chmod 600 "$f"
  fi
}

state_exists() {
  local project="$1"
  [[ -f "$(state_path "$project")" ]]
}

state_get() {
  local project="$1" key="$2"
  state_exists "$project" || return 1
  _state_toml get "$(state_path "$project")" "$key" 2>/dev/null
}

state_set() {
  local project="$1" key="$2" value="$3"
  state_init "$project"
  local f
  f="$(state_path "$project")"
  # Quote the value so _toml.py treats it as a string.
  _state_toml set "$f" "$key" "\"${value//\"/\\\"}\""
  _state_toml set "$f" updated_at "\"$(_state_now)\""
}

state_unset() {
  local project="$1" key="$2"
  state_exists "$project" || return 0
  _state_toml unset "$(state_path "$project")" "$key"
}

state_add_parked() {
  local project="$1" issue="$2"
  state_init "$project"
  _state_toml set-bool "$(state_path "$project")" "parked.${issue}" true
}

state_remove_parked() {
  local project="$1" issue="$2"
  state_exists "$project" || return 0
  _state_toml unset "$(state_path "$project")" "parked.${issue}"
}

state_list_parked() {
  local project="$1"
  state_exists "$project" || return 0
  _state_toml list-keys "$(state_path "$project")" parked 2>/dev/null || true
}

state_active_project() {
  local best="" best_ts=""
  local p ts ai
  while IFS= read -r p; do
    [[ -z "$p" ]] && continue
    ai="$(state_get "$p" active_issue 2>/dev/null || true)"
    [[ -z "$ai" ]] && continue
    ts="$(state_get "$p" updated_at 2>/dev/null || true)"
    if [[ -z "$best_ts" || "$ts" > "$best_ts" ]]; then
      best="$p"
      best_ts="$ts"
    fi
  done < <(_state_list_projects)
  [[ -n "$best" ]] || return 1
  echo "$best"
}

_state_list_projects() {
  local dir
  dir="$(devagent_home)/state"
  [[ -d "$dir" ]] || return 0
  ( cd "$dir" && for f in *.toml; do
      [[ -e "$f" ]] || continue
      echo "${f%.toml}"
    done )
}
```

- [ ] **Step 5.5: Run tests to verify they pass**

```bash
bats tests/state.bats
```

Expected: 8/8 PASS.

- [ ] **Step 5.6: Commit**

```bash
git add scripts/lib/state.sh templates/state.toml.skel tests/state.bats
git commit -s -m "$(cat <<'EOF'
plan01: add state.sh per-project state library

Files at $DA_HOME/state/<project>.toml mode 600. Public surface:
state_init, state_exists, state_get, state_set (auto-stamps
updated_at), state_unset, state_active_project,
state_{add,remove,list}_parked.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 6: `scripts/lib/secrets.sh`

**Files:**
- Create: `scripts/lib/secrets.sh`
- Test: `tests/secrets.bats`

- [ ] **Step 6.1: Write the failing test**

Create `tests/secrets.bats`:

```bash
#!/usr/bin/env bats

load 'lib/bats-helpers'

setup() {
  setup_tmp_devagent_home
  rm -rf "$DA_HOME/secrets"   # ensure clean
  source "$PLUGIN_ROOT/scripts/lib/paths.sh"
  source "$PLUGIN_ROOT/scripts/lib/io.sh"
  source "$PLUGIN_ROOT/scripts/lib/secrets.sh"
}

teardown() { teardown_tmp_devagent_home; }

@test "secrets_bootstrap creates dir mode 700" {
  secrets_bootstrap
  [ -d "$DA_HOME/secrets" ]
  assert_file_mode "$DA_HOME/secrets" 700
}

@test "secrets_bootstrap is idempotent" {
  secrets_bootstrap
  secrets_bootstrap
  assert_file_mode "$DA_HOME/secrets" 700
}

@test "secrets_audit warns when dir mode drifts" {
  secrets_bootstrap
  chmod 755 "$DA_HOME/secrets"
  run secrets_audit
  [ "$status" -ne 0 ]
  [[ "$output" == *"WARNING"* ]]
}

@test "secrets_audit warns when a file mode drifts" {
  secrets_bootstrap
  echo dummy >"$DA_HOME/secrets/volk.github.pat"
  chmod 644 "$DA_HOME/secrets/volk.github.pat"
  run secrets_audit
  [ "$status" -ne 0 ]
  [[ "$output" == *"volk.github.pat"* ]]
}
```

- [ ] **Step 6.2: Run tests to verify they fail**

```bash
bats tests/secrets.bats
```

- [ ] **Step 6.3: Implement `secrets.sh`**

Create `scripts/lib/secrets.sh`:

```bash
#!/usr/bin/env bash
# scripts/lib/secrets.sh — bootstrap and audit the secrets directory.
# Requires paths.sh and io.sh sourced first.

secrets_bootstrap() {
  local dir
  dir="$(secrets_dir)"
  mkdir -p "$dir"
  chmod 700 "$dir"
}

secrets_audit() {
  local dir mode f ok=1
  dir="$(secrets_dir)"
  if [[ ! -d "$dir" ]]; then
    warn "secrets dir missing: $dir (run secrets_bootstrap)"
    return 1
  fi
  mode="$(stat -c '%a' "$dir")"
  if [[ "$mode" != "700" ]]; then
    warn "secrets dir mode is $mode, expected 700: $dir"
    ok=0
  fi
  shopt -s nullglob
  for f in "$dir"/*; do
    [[ -L "$f" ]] && continue
    [[ -f "$f" ]] || continue
    mode="$(stat -c '%a' "$f")"
    if [[ "$mode" != "600" ]]; then
      warn "secret file mode is $mode, expected 600: $f"
      ok=0
    fi
  done
  shopt -u nullglob
  [[ "$ok" == "1" ]]
}
```

- [ ] **Step 6.4: Run tests to verify they pass**

```bash
bats tests/secrets.bats
```

Expected: 4/4 PASS.

- [ ] **Step 6.5: Commit**

```bash
git add scripts/lib/secrets.sh tests/secrets.bats
git commit -s -m "$(cat <<'EOF'
plan01: add secrets.sh dir-bootstrap and mode audit

Creates ~/.claude/devagent/secrets/ mode 700; secrets_audit warns
when dir mode != 700 or any contained file mode != 600.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 7: `templates/checklist-standard.md` (+ the other three templates)

**Files:**
- Create: `templates/checklist-standard.md`, `templates/checklist-docs-only.md`, `templates/checklist-research.md`, `templates/checklist-perf.md`
- Test: shape verified via `tests/checklist.bats` in Task 8

These templates are pure data; this task has no separate test. The next task validates the parser against `checklist-standard.md`.

- [ ] **Step 7.1: Write `checklist-standard.md`**

Create `templates/checklist-standard.md` (verbatim from spec §5.2; placeholders the init script will substitute marked `{{...}}`):

```markdown
# {{ISSUE_ID}} — Workflow checklist

State key: [ ] pending  [x] done  [-] skipped  [!] stuck  [~] in-progress  [?] blocked-external  [P] parked

Template: standard
Created: {{CREATED_AT}}
Active revision: 1

## Revision 1

- [ ]  0. pull
- [ ]  1. draft
- [ ]  2. scope
- [ ]  3. improve
- [ ]  4. prune
- [ ]  5. tighten
- [ ]  6. branch
- [ ]  7. implement
- [ ]  8. quality
- [ ]  9. document
- [ ] 10. commit
- [ ] 11. analyze
- [ ] 12. draftmr
- [ ] 13. review
- [ ] 14. redmr
- [ ] 15. ship
- [ ] 16. mergetoall
- [ ] 17. updatewbs
- [ ] 18. impact
- [ ] 19. lessonslearned
- [ ] 20. cleanup

## Log
```

- [ ] **Step 7.2: Write `checklist-docs-only.md`**

Create `templates/checklist-docs-only.md`:

```markdown
# {{ISSUE_ID}} — Workflow checklist

State key: [ ] pending  [x] done  [-] skipped  [!] stuck  [~] in-progress  [?] blocked-external  [P] parked

Template: docs-only
Created: {{CREATED_AT}}
Active revision: 1

## Revision 1

- [ ]  0. pull
- [ ]  1. draft
- [ ]  6. branch
- [ ]  9. document
- [ ] 10. commit
- [ ] 12. draftmr
- [ ] 13. review
- [ ] 15. ship
- [ ] 16. mergetoall
- [ ] 20. cleanup

## Log
```

- [ ] **Step 7.3: Write `checklist-research.md`**

Create `templates/checklist-research.md`:

```markdown
# {{ISSUE_ID}} — Workflow checklist

State key: [ ] pending  [x] done  [-] skipped  [!] stuck  [~] in-progress  [?] blocked-external  [P] parked

Template: research
Created: {{CREATED_AT}}
Active revision: 1

## Revision 1

- [ ]  0. pull
- [ ]  1. draft
- [ ]  2. scope
- [ ]  3. improve
- [ ]  9. document
- [ ] 19. lessonslearned
- [ ] 20. cleanup

## Log
```

- [ ] **Step 7.4: Write `checklist-perf.md`**

Create `templates/checklist-perf.md`:

```markdown
# {{ISSUE_ID}} — Workflow checklist

State key: [ ] pending  [x] done  [-] skipped  [!] stuck  [~] in-progress  [?] blocked-external  [P] parked

Template: perf
Created: {{CREATED_AT}}
Active revision: 1

## Revision 1

- [ ]  0. pull
- [ ]  1. draft
- [ ]  2. scope
- [ ]  3. improve
- [ ]  4. prune
- [ ]  5. tighten
- [ ]  6. branch
- [ ]  7. implement
- [ ]  8. quality
- [ ]  9. document
- [ ] 10. commit
- [ ] 11. analyze
- [ ] 12. draftmr
- [ ] 13. review
- [ ] 14. redmr
- [ ] 15. ship
- [ ] 16. mergetoall
- [ ] 18. impact
- [ ] 19. lessonslearned
- [ ] 20. cleanup
```

(Note: perf template intentionally omits step 17 updatewbs — perf PRs land in a dedicated WBS branch — and the trailing `## Log` line is added by the init script so all four templates end up with the section.)

Actually, to keep parsing simple, every template ends with `## Log\n`. Append that line to `checklist-perf.md` as well so all four templates are uniform.

Final `templates/checklist-perf.md`:

```markdown
# {{ISSUE_ID}} — Workflow checklist

State key: [ ] pending  [x] done  [-] skipped  [!] stuck  [~] in-progress  [?] blocked-external  [P] parked

Template: perf
Created: {{CREATED_AT}}
Active revision: 1

## Revision 1

- [ ]  0. pull
- [ ]  1. draft
- [ ]  2. scope
- [ ]  3. improve
- [ ]  4. prune
- [ ]  5. tighten
- [ ]  6. branch
- [ ]  7. implement
- [ ]  8. quality
- [ ]  9. document
- [ ] 10. commit
- [ ] 11. analyze
- [ ] 12. draftmr
- [ ] 13. review
- [ ] 14. redmr
- [ ] 15. ship
- [ ] 16. mergetoall
- [ ] 18. impact
- [ ] 19. lessonslearned
- [ ] 20. cleanup

## Log
```

- [ ] **Step 7.5: Commit**

```bash
git add templates/checklist-standard.md templates/checklist-docs-only.md \
        templates/checklist-research.md templates/checklist-perf.md
git commit -s -m "$(cat <<'EOF'
plan01: add four checklist templates per spec §5.2

standard (21 steps), docs-only, research, perf.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 8: `scripts/lib/checklist.sh`

**Files:**
- Create: `scripts/lib/checklist.sh`
- Test: `tests/checklist.bats`

- [ ] **Step 8.1: Write the failing test**

Create `tests/checklist.bats`:

```bash
#!/usr/bin/env bats

load 'lib/bats-helpers'

setup() {
  setup_tmp_devagent_home
  source "$PLUGIN_ROOT/scripts/lib/paths.sh"
  source "$PLUGIN_ROOT/scripts/lib/io.sh"
  source "$PLUGIN_ROOT/scripts/lib/checklist.sh"
  ISSUE_DIR="$DA_HOME/Issue-1"
  mkdir -p "$ISSUE_DIR"
}

teardown() { teardown_tmp_devagent_home; }

@test "checklist_init writes a checklist from the standard template" {
  checklist_init "$ISSUE_DIR" standard
  [ -f "$ISSUE_DIR/checklist.md" ]
  run grep -q '0. pull' "$ISSUE_DIR/checklist.md"
  [ "$status" -eq 0 ]
  run grep -q '20. cleanup' "$ISSUE_DIR/checklist.md"
  [ "$status" -eq 0 ]
  run grep -q '## Log' "$ISSUE_DIR/checklist.md"
  [ "$status" -eq 0 ]
}

@test "checklist_init substitutes placeholders" {
  ISSUE_ID=Issue-42 checklist_init "$ISSUE_DIR" standard
  run head -1 "$ISSUE_DIR/checklist.md"
  [[ "$output" == *"Issue-42"* ]]
}

@test "checklist_init refuses unknown template" {
  run checklist_init "$ISSUE_DIR" no-such-template
  [ "$status" -ne 0 ]
}

@test "checklist_current_step is 0 on a fresh standard" {
  checklist_init "$ISSUE_DIR" standard
  run checklist_current_step "$ISSUE_DIR/checklist.md"
  [ "$status" -eq 0 ]
  [ "$output" = "0" ]
}

@test "checklist_step_name maps numbers to names" {
  checklist_init "$ISSUE_DIR" standard
  run checklist_step_name "$ISSUE_DIR/checklist.md" 0
  [ "$output" = "pull" ]
  run checklist_step_name "$ISSUE_DIR/checklist.md" 7
  [ "$output" = "implement" ]
  run checklist_step_name "$ISSUE_DIR/checklist.md" 20
  [ "$output" = "cleanup" ]
}

@test "checklist_mark flips a glyph" {
  checklist_init "$ISSUE_DIR" standard
  checklist_mark "$ISSUE_DIR/checklist.md" 0 x
  run checklist_step_state "$ISSUE_DIR/checklist.md" 0
  [ "$output" = "x" ]
}

@test "checklist_mark refuses an unknown glyph" {
  checklist_init "$ISSUE_DIR" standard
  run checklist_mark "$ISSUE_DIR/checklist.md" 0 Q
  [ "$status" -ne 0 ]
}

@test "checklist_advance marks current done and returns new current" {
  checklist_init "$ISSUE_DIR" standard
  run checklist_advance "$ISSUE_DIR/checklist.md"
  [ "$output" = "1" ]
  run checklist_step_state "$ISSUE_DIR/checklist.md" 0
  [ "$output" = "x" ]
}

@test "checklist_current_step echoes 'done' when all done" {
  checklist_init "$ISSUE_DIR" docs-only
  # docs-only has 10 steps; mark them all done
  for s in 0 1 6 9 10 12 13 15 16 20; do
    checklist_mark "$ISSUE_DIR/checklist.md" "$s" x
  done
  run checklist_current_step "$ISSUE_DIR/checklist.md"
  [ "$output" = "done" ]
}

@test "checklist_current_step skips x, returns first non-x" {
  checklist_init "$ISSUE_DIR" standard
  checklist_mark "$ISSUE_DIR/checklist.md" 0 x
  checklist_mark "$ISSUE_DIR/checklist.md" 1 x
  checklist_mark "$ISSUE_DIR/checklist.md" 2 '~'
  run checklist_current_step "$ISSUE_DIR/checklist.md"
  [ "$output" = "2" ]
}
```

- [ ] **Step 8.2: Run tests to verify they fail**

```bash
bats tests/checklist.bats
```

- [ ] **Step 8.3: Implement `checklist.sh`**

Create `scripts/lib/checklist.sh`:

```bash
#!/usr/bin/env bash
# scripts/lib/checklist.sh — parse/mark the per-issue checklist.md.
# Format defined in spec §5.2. Requires paths.sh + io.sh sourced.
#
# Lines look like:
#   - [ ]  0. pull
#   - [x]  7. implement
# A single-space step number is allowed for steps 0-9.

_checklist_template_path() {
  echo "$(plugin_root)/templates/checklist-${1}.md"
}

checklist_init() {
  local issue_dir="$1" template="${2:-standard}" tpl
  [[ -n "$issue_dir" ]] || die "checklist_init: issue-dir required"
  tpl="$(_checklist_template_path "$template")"
  [[ -f "$tpl" ]] || die "checklist_init: unknown template '$template' (no $tpl)"
  mkdir -p "$issue_dir"
  local issue_id="${ISSUE_ID:-$(basename "$issue_dir")}"
  local created
  created="$(date -Iseconds)"
  sed -e "s|{{ISSUE_ID}}|${issue_id}|g" \
      -e "s|{{CREATED_AT}}|${created}|g" \
      "$tpl" > "$issue_dir/checklist.md"
}

# Matches valid step lines into BASH_REMATCH: glyph=1 num=2 name=3
_checklist_line_re='^- \[(.)\][[:space:]]+([0-9]+)\.[[:space:]]+([A-Za-z][A-Za-z0-9_-]*)'

checklist_current_step() {
  local file="$1" line glyph num name found=""
  [[ -f "$file" ]] || die "checklist_current_step: no such file '$file'"
  while IFS= read -r line; do
    if [[ "$line" =~ $_checklist_line_re ]]; then
      glyph="${BASH_REMATCH[1]}"
      num="${BASH_REMATCH[2]}"
      if [[ "$glyph" != "x" && "$glyph" != "-" ]]; then
        echo "$num"
        return 0
      fi
      found=1
    fi
  done < "$file"
  if [[ -n "$found" ]]; then
    echo "done"
    return 0
  fi
  die "checklist_current_step: no step lines found in '$file'"
}

checklist_step_state() {
  local file="$1" target="$2" line
  while IFS= read -r line; do
    if [[ "$line" =~ $_checklist_line_re ]]; then
      if [[ "${BASH_REMATCH[2]}" == "$target" ]]; then
        echo "${BASH_REMATCH[1]}"
        return 0
      fi
    fi
  done < "$file"
  return 1
}

checklist_step_name() {
  local file="$1" target="$2" line
  while IFS= read -r line; do
    if [[ "$line" =~ $_checklist_line_re ]]; then
      if [[ "${BASH_REMATCH[2]}" == "$target" ]]; then
        echo "${BASH_REMATCH[3]}"
        return 0
      fi
    fi
  done < "$file"
  return 1
}

_checklist_valid_glyph() {
  case "$1" in
    ' '|x|-|'!'|'~'|'?'|P) return 0 ;;
    *) return 1 ;;
  esac
}

checklist_mark() {
  local file="$1" target="$2" glyph="$3"
  [[ -f "$file" ]] || die "checklist_mark: no such file '$file'"
  _checklist_valid_glyph "$glyph" || die "checklist_mark: bad glyph '$glyph'"
  local tmp
  tmp="$(mktemp)"
  awk -v target="$target" -v glyph="$glyph" '
    {
      if (match($0, /^- \[(.)\]([ \t]+)([0-9]+)\./, m)) {
        if (m[3] == target) {
          sub(/^- \[.\]/, "- [" glyph "]")
        }
      }
      print
    }
  ' "$file" > "$tmp"
  mv "$tmp" "$file"
  # Sanity: did we actually find the step?
  checklist_step_state "$file" "$target" >/dev/null \
    || die "checklist_mark: step $target not found in '$file'"
}

checklist_advance() {
  local file="$1" cur
  cur="$(checklist_current_step "$file")"
  if [[ "$cur" == "done" ]]; then
    echo "done"
    return 0
  fi
  checklist_mark "$file" "$cur" x
  checklist_current_step "$file"
}
```

- [ ] **Step 8.4: Run tests to verify they pass**

```bash
bats tests/checklist.bats
```

Expected: 10/10 PASS.

- [ ] **Step 8.5: Commit**

```bash
git add scripts/lib/checklist.sh tests/checklist.bats
git commit -s -m "$(cat <<'EOF'
plan01: add checklist.sh parser/marker library

Public API: checklist_init, checklist_current_step,
checklist_step_state, checklist_step_name, checklist_mark,
checklist_advance. Supports all 7 glyphs from spec §5.1.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 9: `scripts/lib/log.sh`

**Files:**
- Create: `scripts/lib/log.sh`
- Test: `tests/log.bats`

- [ ] **Step 9.1: Write the failing test**

Create `tests/log.bats`:

```bash
#!/usr/bin/env bats

load 'lib/bats-helpers'

setup() {
  setup_tmp_devagent_home
  source "$PLUGIN_ROOT/scripts/lib/paths.sh"
  source "$PLUGIN_ROOT/scripts/lib/io.sh"
  source "$PLUGIN_ROOT/scripts/lib/checklist.sh"
  source "$PLUGIN_ROOT/scripts/lib/log.sh"
  ISSUE_DIR="$DA_HOME/Issue-1"
  mkdir -p "$ISSUE_DIR"
  checklist_init "$ISSUE_DIR" standard
}

teardown() { teardown_tmp_devagent_home; }

@test "log_append writes an ISO-stamped line under ## Log" {
  log_append "$ISSUE_DIR" pull "fetched gnuradio/volk#1, scaffold created"
  run grep -E '^- [0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2} +pull: fetched' \
    "$ISSUE_DIR/checklist.md"
  [ "$status" -eq 0 ]
}

@test "log_append preserves existing log lines and appends in order" {
  log_append "$ISSUE_DIR" pull   "fetched #1"
  log_append "$ISSUE_DIR" draft  "imPlan written"
  local n
  n="$(grep -c '^- 20' "$ISSUE_DIR/checklist.md")"
  [ "$n" = "2" ]
  run grep -n '^- 20' "$ISSUE_DIR/checklist.md"
  # second match must contain 'draft'
  [[ "${lines[1]}" == *"draft"* ]]
}

@test "log_append refuses missing checklist" {
  rm "$ISSUE_DIR/checklist.md"
  run log_append "$ISSUE_DIR" pull "x"
  [ "$status" -ne 0 ]
}

@test "log_tail returns last N log lines" {
  for i in 1 2 3 4 5; do
    log_append "$ISSUE_DIR" pull "msg $i"
  done
  run log_tail "$ISSUE_DIR" 2
  [ "$status" -eq 0 ]
  [[ "$output" == *"msg 4"* ]]
  [[ "$output" == *"msg 5"* ]]
  [[ "$output" != *"msg 3"* ]]
}

@test "log_append rejects multi-line message" {
  run log_append "$ISSUE_DIR" pull $'line1\nline2'
  [ "$status" -ne 0 ]
}
```

- [ ] **Step 9.2: Run tests to verify they fail**

```bash
bats tests/log.bats
```

- [ ] **Step 9.3: Implement `log.sh`**

Create `scripts/lib/log.sh`:

```bash
#!/usr/bin/env bash
# scripts/lib/log.sh — append/tail log entries in <issue-dir>/checklist.md.
# Requires paths.sh + io.sh sourced.
# Format (spec §5.2):
#   - YYYY-MM-DD HH:MM  <step-name>: <message>

_log_now() {
  date '+%Y-%m-%d %H:%M'
}

log_append() {
  local issue_dir="$1" step="$2" msg="$3"
  local file="$issue_dir/checklist.md"
  [[ -f "$file" ]] || die "log_append: no checklist at $file"
  [[ -n "$step" ]] || die "log_append: step name required"
  [[ -n "$msg"  ]] || die "log_append: message required"
  if [[ "$msg" == *$'\n'* ]]; then
    die "log_append: message must be a single line"
  fi
  if ! grep -q '^## Log' "$file"; then
    die "log_append: '## Log' section missing in $file"
  fi
  local line
  line="- $(_log_now)  ${step}: ${msg}"
  printf '%s\n' "$line" >> "$file"
}

log_tail() {
  local issue_dir="$1" n="${2:-10}"
  local file="$issue_dir/checklist.md"
  [[ -f "$file" ]] || die "log_tail: no checklist at $file"
  awk '/^## Log/{p=1; next} p' "$file" | grep -E '^- [0-9]{4}-' | tail -n "$n"
}
```

- [ ] **Step 9.4: Run tests to verify they pass**

```bash
bats tests/log.bats
```

Expected: 5/5 PASS.

- [ ] **Step 9.5: Commit**

```bash
git add scripts/lib/log.sh tests/log.bats
git commit -s -m "$(cat <<'EOF'
plan01: add log.sh append/tail under ## Log section

Format: '- YYYY-MM-DD HH:MM  <step>: <msg>' per spec §5.2.
Single-line enforcement on append.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 10: `checklist-*.sh` user-facing scripts

These six scripts are thin wrappers around the libraries. They share a common header that sources `paths.sh`, `io.sh`, `checklist.sh`, `log.sh`. Plan 2 ships `pull.sh`/`where.sh`/etc.; these `checklist-*` scripts are operator escape hatches for direct manipulation of any issue's checklist.

**Files:**
- Create: `scripts/checklist-init.sh`, `scripts/checklist-advance.sh`, `scripts/checklist-mark.sh`, `scripts/checklist-log.sh`, `scripts/checklist-stuck.sh`, `scripts/checklist-unstuck.sh`
- Test: `tests/checklist-init.bats`, `tests/checklist-advance.bats`, `tests/checklist-mark.bats`, `tests/checklist-log.bats`, `tests/checklist-stuck.bats`, `tests/checklist-unstuck.bats`

- [ ] **Step 10.1: Write `checklist-init.sh` test**

Create `tests/checklist-init.bats`:

```bash
#!/usr/bin/env bats

load 'lib/bats-helpers'

setup() { setup_tmp_devagent_home; }
teardown() { teardown_tmp_devagent_home; }

@test "checklist-init.sh creates a checklist with default template" {
  ISSUE_DIR="$DA_HOME/Issue-1"
  run "$PLUGIN_ROOT/scripts/checklist-init.sh" "$ISSUE_DIR"
  [ "$status" -eq 0 ]
  [ -f "$ISSUE_DIR/checklist.md" ]
  run grep -q '20. cleanup' "$ISSUE_DIR/checklist.md"
  [ "$status" -eq 0 ]
}

@test "checklist-init.sh accepts --template flag" {
  ISSUE_DIR="$DA_HOME/Issue-2"
  run "$PLUGIN_ROOT/scripts/checklist-init.sh" --template research "$ISSUE_DIR"
  [ "$status" -eq 0 ]
  run grep -q 'Template: research' "$ISSUE_DIR/checklist.md"
  [ "$status" -eq 0 ]
}

@test "checklist-init.sh fails on bad template" {
  ISSUE_DIR="$DA_HOME/Issue-3"
  run "$PLUGIN_ROOT/scripts/checklist-init.sh" --template foo "$ISSUE_DIR"
  [ "$status" -ne 0 ]
}
```

- [ ] **Step 10.2: Verify the test fails**

```bash
bats tests/checklist-init.bats
```

- [ ] **Step 10.3: Write `checklist-init.sh`**

Create `scripts/checklist-init.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail
PLUGIN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$PLUGIN_ROOT/scripts/lib/paths.sh"
source "$PLUGIN_ROOT/scripts/lib/io.sh"
source "$PLUGIN_ROOT/scripts/lib/checklist.sh"

usage() {
  cat <<USAGE
usage: checklist-init.sh [--template <name>] <issue-dir>
   <name> one of: standard | docs-only | research | perf  (default: standard)
USAGE
  exit 2
}

template=standard
while [[ $# -gt 0 ]]; do
  case "$1" in
    --template) template="$2"; shift 2 ;;
    -h|--help)  usage ;;
    --)         shift; break ;;
    -*)         usage ;;
    *)          break ;;
  esac
done
[[ $# -eq 1 ]] || usage
issue_dir="$1"

checklist_init "$issue_dir" "$template"
echo "wrote $issue_dir/checklist.md (template: $template)"
```

- [ ] **Step 10.4: Make executable, run tests**

```bash
chmod +x scripts/checklist-init.sh
bats tests/checklist-init.bats
```

Expected: 3/3 PASS.

- [ ] **Step 10.5: Write `checklist-advance.sh` test + script**

Create `tests/checklist-advance.bats`:

```bash
#!/usr/bin/env bats

load 'lib/bats-helpers'

setup() {
  setup_tmp_devagent_home
  ISSUE_DIR="$DA_HOME/Issue-1"
  "$PLUGIN_ROOT/scripts/checklist-init.sh" "$ISSUE_DIR"
}
teardown() { teardown_tmp_devagent_home; }

@test "advance marks current done and prints new current" {
  run "$PLUGIN_ROOT/scripts/checklist-advance.sh" "$ISSUE_DIR"
  [ "$status" -eq 0 ]
  [[ "$output" == *"now at step 1"* ]]
}

@test "advance is a no-op when all steps are done" {
  for s in 0 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    "$PLUGIN_ROOT/scripts/checklist-mark.sh" "$ISSUE_DIR" "$s" x >/dev/null
  done
  run "$PLUGIN_ROOT/scripts/checklist-advance.sh" "$ISSUE_DIR"
  [ "$status" -eq 0 ]
  [[ "$output" == *"all steps complete"* ]]
}
```

Create `scripts/checklist-advance.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail
PLUGIN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$PLUGIN_ROOT/scripts/lib/paths.sh"
source "$PLUGIN_ROOT/scripts/lib/io.sh"
source "$PLUGIN_ROOT/scripts/lib/checklist.sh"

[[ $# -eq 1 ]] || { echo "usage: checklist-advance.sh <issue-dir>" >&2; exit 2; }
issue_dir="$1"
file="$issue_dir/checklist.md"
[[ -f "$file" ]] || die "no checklist at $file"

new="$(checklist_advance "$file")"
if [[ "$new" == "done" ]]; then
  echo "all steps complete"
else
  echo "now at step $new"
fi
```

```bash
chmod +x scripts/checklist-advance.sh
bats tests/checklist-advance.bats
```

Expected: 2/2 PASS.

- [ ] **Step 10.6: Write `checklist-mark.sh` test + script**

Create `tests/checklist-mark.bats`:

```bash
#!/usr/bin/env bats

load 'lib/bats-helpers'

setup() {
  setup_tmp_devagent_home
  ISSUE_DIR="$DA_HOME/Issue-1"
  "$PLUGIN_ROOT/scripts/checklist-init.sh" "$ISSUE_DIR"
}
teardown() { teardown_tmp_devagent_home; }

@test "mark sets a glyph" {
  run "$PLUGIN_ROOT/scripts/checklist-mark.sh" "$ISSUE_DIR" 7 '~'
  [ "$status" -eq 0 ]
  run grep -E '^- \[~\]  7\. implement' "$ISSUE_DIR/checklist.md"
  [ "$status" -eq 0 ]
}

@test "mark refuses an invalid glyph" {
  run "$PLUGIN_ROOT/scripts/checklist-mark.sh" "$ISSUE_DIR" 7 Q
  [ "$status" -ne 0 ]
}
```

Create `scripts/checklist-mark.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail
PLUGIN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$PLUGIN_ROOT/scripts/lib/paths.sh"
source "$PLUGIN_ROOT/scripts/lib/io.sh"
source "$PLUGIN_ROOT/scripts/lib/checklist.sh"

[[ $# -eq 3 ]] || {
  echo "usage: checklist-mark.sh <issue-dir> <step-num> <glyph>" >&2
  exit 2
}
issue_dir="$1"; step="$2"; glyph="$3"
file="$issue_dir/checklist.md"
[[ -f "$file" ]] || die "no checklist at $file"
checklist_mark "$file" "$step" "$glyph"
echo "step $step → [$glyph]"
```

```bash
chmod +x scripts/checklist-mark.sh
bats tests/checklist-mark.bats
```

Expected: 2/2 PASS.

- [ ] **Step 10.7: Write `checklist-log.sh` test + script**

Create `tests/checklist-log.bats`:

```bash
#!/usr/bin/env bats

load 'lib/bats-helpers'

setup() {
  setup_tmp_devagent_home
  ISSUE_DIR="$DA_HOME/Issue-1"
  "$PLUGIN_ROOT/scripts/checklist-init.sh" "$ISSUE_DIR"
}
teardown() { teardown_tmp_devagent_home; }

@test "log appends a line" {
  run "$PLUGIN_ROOT/scripts/checklist-log.sh" "$ISSUE_DIR" pull "fetched #42"
  [ "$status" -eq 0 ]
  run grep 'pull: fetched #42' "$ISSUE_DIR/checklist.md"
  [ "$status" -eq 0 ]
}
```

Create `scripts/checklist-log.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail
PLUGIN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$PLUGIN_ROOT/scripts/lib/paths.sh"
source "$PLUGIN_ROOT/scripts/lib/io.sh"
source "$PLUGIN_ROOT/scripts/lib/checklist.sh"
source "$PLUGIN_ROOT/scripts/lib/log.sh"

[[ $# -ge 3 ]] || {
  echo "usage: checklist-log.sh <issue-dir> <step-name> <message...>" >&2
  exit 2
}
issue_dir="$1"; step="$2"; shift 2
log_append "$issue_dir" "$step" "$*"
```

```bash
chmod +x scripts/checklist-log.sh
bats tests/checklist-log.bats
```

Expected: 1/1 PASS.

- [ ] **Step 10.8: Write `checklist-stuck.sh` test + script**

Create `tests/checklist-stuck.bats`:

```bash
#!/usr/bin/env bats

load 'lib/bats-helpers'

setup() {
  setup_tmp_devagent_home
  ISSUE_DIR="$DA_HOME/Issue-1"
  "$PLUGIN_ROOT/scripts/checklist-init.sh" "$ISSUE_DIR"
  "$PLUGIN_ROOT/scripts/checklist-mark.sh" "$ISSUE_DIR" 0 x >/dev/null
}
teardown() { teardown_tmp_devagent_home; }

@test "stuck marks current step ! and writes STUCK file" {
  run "$PLUGIN_ROOT/scripts/checklist-stuck.sh" "$ISSUE_DIR" "needs help with X"
  [ "$status" -eq 0 ]
  [ -f "$ISSUE_DIR/STUCK" ]
  run grep -E '^- \[!\]  1\. draft' "$ISSUE_DIR/checklist.md"
  [ "$status" -eq 0 ]
  run grep 'Reason:' "$ISSUE_DIR/STUCK"
  [[ "$output" == *"needs help with X"* ]]
}

@test "stuck refuses when checklist already done" {
  for s in 0 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    "$PLUGIN_ROOT/scripts/checklist-mark.sh" "$ISSUE_DIR" "$s" x >/dev/null
  done
  run "$PLUGIN_ROOT/scripts/checklist-stuck.sh" "$ISSUE_DIR" "why"
  [ "$status" -ne 0 ]
}
```

Create `scripts/checklist-stuck.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail
PLUGIN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$PLUGIN_ROOT/scripts/lib/paths.sh"
source "$PLUGIN_ROOT/scripts/lib/io.sh"
source "$PLUGIN_ROOT/scripts/lib/checklist.sh"
source "$PLUGIN_ROOT/scripts/lib/log.sh"

[[ $# -ge 2 ]] || {
  echo "usage: checklist-stuck.sh <issue-dir> <reason...>" >&2
  exit 2
}
issue_dir="$1"; shift
reason="$*"
file="$issue_dir/checklist.md"
[[ -f "$file" ]] || die "no checklist at $file"

cur="$(checklist_current_step "$file")"
[[ "$cur" != "done" ]] || die "checklist is already complete; nothing to mark stuck"
name="$(checklist_step_name "$file" "$cur")"

# Find last good step number for the STUCK file.
last_good=""
for ((i = cur - 1; i >= 0; i--)); do
  st="$(checklist_step_state "$file" "$i" 2>/dev/null || true)"
  if [[ "$st" == "x" ]]; then
    last_good="$i $(checklist_step_name "$file" "$i")"
    break
  fi
done

checklist_mark "$file" "$cur" '!'

cat > "$issue_dir/STUCK" <<EOF
Step:        $cur $name
Reason:      $reason
Last good:   ${last_good:-(none)}
Created:     $(date -Iseconds)
EOF

log_append "$issue_dir" "$name" "STUCK: $reason"
echo "marked step $cur ($name) [!] and wrote $issue_dir/STUCK"
```

```bash
chmod +x scripts/checklist-stuck.sh
bats tests/checklist-stuck.bats
```

Expected: 2/2 PASS.

- [ ] **Step 10.9: Write `checklist-unstuck.sh` test + script**

Create `tests/checklist-unstuck.bats`:

```bash
#!/usr/bin/env bats

load 'lib/bats-helpers'

setup() {
  setup_tmp_devagent_home
  ISSUE_DIR="$DA_HOME/Issue-1"
  "$PLUGIN_ROOT/scripts/checklist-init.sh" "$ISSUE_DIR"
  "$PLUGIN_ROOT/scripts/checklist-mark.sh" "$ISSUE_DIR" 0 x >/dev/null
  "$PLUGIN_ROOT/scripts/checklist-stuck.sh" "$ISSUE_DIR" "blocked" >/dev/null
}
teardown() { teardown_tmp_devagent_home; }

@test "unstuck with --pending flips ! to ' ' and removes STUCK" {
  run "$PLUGIN_ROOT/scripts/checklist-unstuck.sh" --pending "$ISSUE_DIR"
  [ "$status" -eq 0 ]
  [ ! -f "$ISSUE_DIR/STUCK" ]
  run grep -E '^- \[ \]  1\. draft' "$ISSUE_DIR/checklist.md"
  [ "$status" -eq 0 ]
}

@test "unstuck with --in-progress flips ! to ~" {
  run "$PLUGIN_ROOT/scripts/checklist-unstuck.sh" --in-progress "$ISSUE_DIR"
  [ "$status" -eq 0 ]
  run grep -E '^- \[~\]  1\. draft' "$ISSUE_DIR/checklist.md"
  [ "$status" -eq 0 ]
}

@test "unstuck refuses when no STUCK file exists" {
  rm -f "$ISSUE_DIR/STUCK"
  run "$PLUGIN_ROOT/scripts/checklist-unstuck.sh" --pending "$ISSUE_DIR"
  [ "$status" -ne 0 ]
}
```

Create `scripts/checklist-unstuck.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail
PLUGIN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$PLUGIN_ROOT/scripts/lib/paths.sh"
source "$PLUGIN_ROOT/scripts/lib/io.sh"
source "$PLUGIN_ROOT/scripts/lib/checklist.sh"
source "$PLUGIN_ROOT/scripts/lib/log.sh"

usage() {
  echo "usage: checklist-unstuck.sh (--pending|--in-progress) <issue-dir>" >&2
  exit 2
}

[[ $# -eq 2 ]] || usage
case "$1" in
  --pending)     new=' ' ;;
  --in-progress) new='~' ;;
  *) usage ;;
esac
issue_dir="$2"
file="$issue_dir/checklist.md"
[[ -f "$file" ]] || die "no checklist at $file"
[[ -f "$issue_dir/STUCK" ]] || die "no STUCK file at $issue_dir/STUCK"

# Find the step currently marked [!]
target=""
for ((i = 0; i <= 20; i++)); do
  st="$(checklist_step_state "$file" "$i" 2>/dev/null || true)"
  if [[ "$st" == '!' ]]; then
    target="$i"
    break
  fi
done
[[ -n "$target" ]] || die "no step is currently [!] in $file"

name="$(checklist_step_name "$file" "$target")"
checklist_mark "$file" "$target" "$new"
rm -f "$issue_dir/STUCK"
log_append "$issue_dir" "$name" "UNSTUCK (now [$new])"
echo "step $target ($name) cleared → [$new]"
```

```bash
chmod +x scripts/checklist-unstuck.sh
bats tests/checklist-unstuck.bats
```

Expected: 3/3 PASS.

- [ ] **Step 10.10: Write slash-command wrappers**

Create `commands/checklist-init.md`:

```markdown
---
name: devagent:checklist-init
description: Initialize the per-issue checklist.md (default template: standard).
---

Run the shell script `scripts/checklist-init.sh` with the user's arguments. The
expected positional form is `[--template <name>] <issue-dir>`.

Forward all arguments verbatim. Surface stderr to the user.
```

Repeat the same minimal three-line YAML body for the other five
checklist commands, swapping name + script:

- `commands/checklist-advance.md` → wraps `checklist-advance.sh <issue-dir>`
- `commands/checklist-mark.md`    → wraps `checklist-mark.sh <issue-dir> <step-num> <glyph>`
- `commands/checklist-log.md`     → wraps `checklist-log.sh <issue-dir> <step-name> <message...>`
- `commands/checklist-stuck.md`   → wraps `checklist-stuck.sh <issue-dir> <reason...>`
- `commands/checklist-unstuck.md` → wraps `checklist-unstuck.sh (--pending|--in-progress) <issue-dir>`

For brevity, the exact text of each is:

`commands/checklist-advance.md`:
```markdown
---
name: devagent:checklist-advance
description: Mark the current checklist step done and report the next step.
---

Run `scripts/checklist-advance.sh <issue-dir>`. Forward all arguments
verbatim. Surface stderr to the user.
```

`commands/checklist-mark.md`:
```markdown
---
name: devagent:checklist-mark
description: Set the glyph on a specific checklist step.
---

Run `scripts/checklist-mark.sh <issue-dir> <step-num> <glyph>` where glyph
is one of ' ', x, -, !, ~, ?, P. Forward all arguments verbatim.
```

`commands/checklist-log.md`:
```markdown
---
name: devagent:checklist-log
description: Append a timestamped entry to the checklist log.
---

Run `scripts/checklist-log.sh <issue-dir> <step-name> <message...>`.
Forward all arguments verbatim.
```

`commands/checklist-stuck.md`:
```markdown
---
name: devagent:checklist-stuck
description: Mark the current step stuck and write a STUCK file with a reason.
---

Run `scripts/checklist-stuck.sh <issue-dir> <reason...>`. Forward all
arguments verbatim.
```

`commands/checklist-unstuck.md`:
```markdown
---
name: devagent:checklist-unstuck
description: Clear STUCK, flip the [!] step to either pending or in-progress.
---

Run `scripts/checklist-unstuck.sh (--pending|--in-progress) <issue-dir>`.
Forward all arguments verbatim.
```

- [ ] **Step 10.11: Commit**

```bash
git add scripts/checklist-*.sh tests/checklist-*.bats commands/checklist-*.md
git commit -s -m "$(cat <<'EOF'
plan01: add checklist-{init,advance,mark,log,stuck,unstuck}.sh

Six operator-facing scripts wrapping checklist.sh + log.sh, plus one
slash command per script under commands/checklist-*.md.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 11: `scripts/init.sh` and `/devagent:init`

**Files:**
- Create: `scripts/init.sh`, `templates/config.toml.skel`, `commands/init.md`
- Test: `tests/init.bats`

- [ ] **Step 11.1: Write the failing test**

Create `tests/init.bats`:

```bash
#!/usr/bin/env bats

load 'lib/bats-helpers'

setup() {
  setup_tmp_devagent_home
  rm -rf "$DA_HOME/secrets"  # ensure bootstrap is exercised
}
teardown() { teardown_tmp_devagent_home; }

@test "init bootstraps config, state file, and secrets dir" {
  # supply non-interactive answers via env
  DA_INIT_SOURCE_DIR="/tmp/srcvolk" \
  DA_INIT_DEVDOC_DIR="/tmp/devvolk" \
  DA_INIT_ISSUE_BACKEND="github" \
  DA_INIT_ISSUE_REPO="gnuradio/volk" \
  DA_INIT_CODE_BACKEND="github" \
  DA_INIT_CODE_UPSTREAM="gnuradio/volk" \
  DA_INIT_CODE_FORK="mtibbits/volk" \
  DA_YES=1 \
  run "$PLUGIN_ROOT/scripts/init.sh" volk
  [ "$status" -eq 0 ]
  [ -f "$DA_HOME/config.toml" ]
  [ -f "$DA_HOME/state/volk.toml" ]
  [ -d "$DA_HOME/secrets" ]
  assert_file_mode "$DA_HOME/secrets" 700
  assert_file_mode "$DA_HOME/state/volk.toml" 600
  run grep -q '^\[project.volk\]' "$DA_HOME/config.toml"
  [ "$status" -eq 0 ]
  run grep -q 'backend = "github"' "$DA_HOME/config.toml"
  [ "$status" -eq 0 ]
}

@test "init refuses to overwrite an existing project block" {
  DA_INIT_SOURCE_DIR="/tmp/srcvolk" \
  DA_INIT_DEVDOC_DIR="/tmp/devvolk" \
  DA_INIT_ISSUE_BACKEND="github" \
  DA_INIT_ISSUE_REPO="gnuradio/volk" \
  DA_INIT_CODE_BACKEND="github" \
  DA_INIT_CODE_UPSTREAM="gnuradio/volk" \
  DA_INIT_CODE_FORK="mtibbits/volk" \
  DA_YES=1 \
  "$PLUGIN_ROOT/scripts/init.sh" volk
  run "$PLUGIN_ROOT/scripts/init.sh" volk
  [ "$status" -ne 0 ]
  [[ "$output" == *"already exists"* ]]
}

@test "init refuses an empty project name" {
  run "$PLUGIN_ROOT/scripts/init.sh" ""
  [ "$status" -ne 0 ]
}
```

- [ ] **Step 11.2: Write the config skeleton template**

Create `templates/config.toml.skel`:

```toml
[defaults]
checklist_template = "standard"
ship_as_draft = false

[project.{{PROJECT}}]
source_dir       = "{{SOURCE_DIR}}"
devdoc_dir       = "{{DEVDOC_DIR}}"
fork_first       = false
ship_as_draft    = false
default_baseline = "origin/main"

[project.{{PROJECT}}.permissions]
push_mr            = false
merge_mr           = false
commit_devdoc      = false
transition_issue   = false
cleanup_on_merge   = false

[project.{{PROJECT}}.issue_source]
backend    = "{{ISSUE_BACKEND}}"
repo       = "{{ISSUE_REPO}}"
dir_prefix = "Issue-"

[project.{{PROJECT}}.code_source]
backend  = "{{CODE_BACKEND}}"
upstream = "{{CODE_UPSTREAM}}"
fork     = "{{CODE_FORK}}"

[project.{{PROJECT}}.issue_workflow]
on_draft_start = "In Progress"
on_ship        = "In Review"
on_merge       = "Done"
```

- [ ] **Step 11.3: Run tests to verify they fail**

```bash
bats tests/init.bats
```

- [ ] **Step 11.4: Write `init.sh`**

Create `scripts/init.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail
PLUGIN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$PLUGIN_ROOT/scripts/lib/paths.sh"
source "$PLUGIN_ROOT/scripts/lib/io.sh"
source "$PLUGIN_ROOT/scripts/lib/state.sh"
source "$PLUGIN_ROOT/scripts/lib/secrets.sh"

usage() {
  echo "usage: init.sh <project>" >&2
  exit 2
}

[[ $# -eq 1 && -n "$1" ]] || usage
project="$1"

# Validate project name: lowercase alnum, dot, dash, underscore.
[[ "$project" =~ ^[a-z0-9][a-z0-9._-]*$ ]] || die "bad project name '$project' (must be lowercase alnum/./-/_)"

cfg="$(config_path)"
home="$(devagent_home)"
mkdir -p "$home/state"
chmod 700 "$home" 2>/dev/null || true
secrets_bootstrap

# Refuse overwrite.
if [[ -f "$cfg" ]] && grep -qE "^\[project\.${project}\]" "$cfg"; then
  die "[project.$project] already exists in $cfg"
fi

# Gather answers. Env vars short-circuit prompts (for tests/CI).
ask() {
  local var="$1" prompt="$2" default="${3:-}" envvar="$4" answer=""
  if [[ -n "${!envvar:-}" ]]; then
    answer="${!envvar}"
  elif is_tty; then
    if [[ -n "$default" ]]; then
      read -r -p "$prompt [$default]: " answer
      [[ -z "$answer" ]] && answer="$default"
    else
      read -r -p "$prompt: " answer
    fi
  else
    [[ -n "$default" ]] || die "missing answer for $var (set $envvar)"
    answer="$default"
  fi
  printf -v "$var" '%s' "$answer"
}

ask source_dir    "source repo dir" ""               DA_INIT_SOURCE_DIR
ask devdoc_dir    "devdoc dir"      ""               DA_INIT_DEVDOC_DIR
ask issue_backend "issue backend"   "github"         DA_INIT_ISSUE_BACKEND
ask issue_repo    "issue repo (org/name)" ""         DA_INIT_ISSUE_REPO
ask code_backend  "code backend"    "$issue_backend" DA_INIT_CODE_BACKEND
ask code_upstream "code upstream (org/name)" "$issue_repo" DA_INIT_CODE_UPSTREAM
ask code_fork     "code fork (org/name)"     ""      DA_INIT_CODE_FORK

# Render skeleton.
skel="$PLUGIN_ROOT/templates/config.toml.skel"
rendered="$(mktemp)"
sed -e "s|{{PROJECT}}|$project|g" \
    -e "s|{{SOURCE_DIR}}|$source_dir|g" \
    -e "s|{{DEVDOC_DIR}}|$devdoc_dir|g" \
    -e "s|{{ISSUE_BACKEND}}|$issue_backend|g" \
    -e "s|{{ISSUE_REPO}}|$issue_repo|g" \
    -e "s|{{CODE_BACKEND}}|$code_backend|g" \
    -e "s|{{CODE_UPSTREAM}}|$code_upstream|g" \
    -e "s|{{CODE_FORK}}|$code_fork|g" \
    "$skel" > "$rendered"

if [[ ! -f "$cfg" ]]; then
  install -m 644 "$rendered" "$cfg"
else
  # Append only the project-specific blocks (skip the [defaults] header,
  # which already exists in the file).
  awk 'BEGIN{p=0} /^\[project\./{p=1} p{print}' "$rendered" >> "$cfg"
fi
rm -f "$rendered"

state_init "$project"

info "bootstrapped $project"
info "  config:  $cfg"
info "  state:   $(state_path "$project")"
info "  secrets: $(secrets_dir)/"
info "next: run /devagent:doctor $project"
```

- [ ] **Step 11.5: Make executable, run tests**

```bash
chmod +x scripts/init.sh
bats tests/init.bats
```

Expected: 3/3 PASS.

- [ ] **Step 11.6: Write slash-command wrapper**

Create `commands/init.md`:

```markdown
---
name: devagent:init
description: Interactive bootstrap of a new project under ~/.claude/devagent/.
---

Run `scripts/init.sh <project>`. The script prompts interactively for
source_dir, devdoc_dir, issue/code backends and repos. Forward the user's
single positional argument verbatim.

On success the script prints the paths it created and suggests
`/devagent:doctor <project>` as the next step.
```

- [ ] **Step 11.7: Commit**

```bash
git add scripts/init.sh templates/config.toml.skel tests/init.bats commands/init.md
git commit -s -m "$(cat <<'EOF'
plan01: add init.sh and /devagent:init bootstrap

Interactive (with env-var overrides for CI) bootstrap of a new
project in ~/.claude/devagent/config.toml plus state file and
secrets dir.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 12: `scripts/doctor.sh` and `/devagent:doctor`

**Files:**
- Create: `scripts/doctor.sh`, `commands/doctor.md`
- Test: `tests/doctor.bats`

Doctor in Plan 1 validates structural concerns only:
1. Config file exists and parses
2. Required project fields present (`source_dir`, `devdoc_dir`, `issue_source.backend`, `issue_source.repo`, `code_source.backend`)
3. `source_dir` and `devdoc_dir` are existing directories
4. State file exists for the project (mode 600)
5. Secrets dir exists mode 700; contained files mode 600
6. Templates referenced (`checklist_template`) actually resolve

Plan 8 will extend doctor to call `auth/<backend>.sh status` for reachability/scope checks.

- [ ] **Step 12.1: Write the failing test**

Create `tests/doctor.bats`:

```bash
#!/usr/bin/env bats

load 'lib/bats-helpers'

setup() {
  setup_tmp_devagent_home
  # Real dirs the doctor must find.
  mkdir -p "$DA_HOME/fake-src" "$DA_HOME/fake-devdoc"
  cat > "$DA_HOME/config.toml" <<TOML
[defaults]
checklist_template = "standard"

[project.volk]
source_dir = "$DA_HOME/fake-src"
devdoc_dir = "$DA_HOME/fake-devdoc"
default_baseline = "origin/main"

[project.volk.issue_source]
backend    = "github"
repo       = "gnuradio/volk"
dir_prefix = "Issue-"

[project.volk.code_source]
backend  = "github"
upstream = "gnuradio/volk"
fork     = "mtibbits/volk"
TOML
  # Have the state file + secrets dir bootstrapped.
  source "$PLUGIN_ROOT/scripts/lib/paths.sh"
  source "$PLUGIN_ROOT/scripts/lib/io.sh"
  source "$PLUGIN_ROOT/scripts/lib/state.sh"
  source "$PLUGIN_ROOT/scripts/lib/secrets.sh"
  state_init volk
  secrets_bootstrap
}
teardown() { teardown_tmp_devagent_home; }

@test "doctor passes on a well-formed setup" {
  run "$PLUGIN_ROOT/scripts/doctor.sh" volk
  [ "$status" -eq 0 ]
  [[ "$output" == *"OK"* ]]
}

@test "doctor flags a missing source_dir" {
  rmdir "$DA_HOME/fake-src"
  run "$PLUGIN_ROOT/scripts/doctor.sh" volk
  [ "$status" -ne 0 ]
  [[ "$output" == *"source_dir"* ]]
}

@test "doctor flags a missing devdoc_dir" {
  rmdir "$DA_HOME/fake-devdoc"
  run "$PLUGIN_ROOT/scripts/doctor.sh" volk
  [ "$status" -ne 0 ]
  [[ "$output" == *"devdoc_dir"* ]]
}

@test "doctor flags missing required field" {
  python3 "$PLUGIN_ROOT/scripts/lib/_toml.py" unset "$DA_HOME/config.toml" project.volk.issue_source.repo
  run "$PLUGIN_ROOT/scripts/doctor.sh" volk
  [ "$status" -ne 0 ]
  [[ "$output" == *"issue_source.repo"* ]]
}

@test "doctor flags missing state file" {
  rm "$DA_HOME/state/volk.toml"
  run "$PLUGIN_ROOT/scripts/doctor.sh" volk
  [ "$status" -ne 0 ]
  [[ "$output" == *"state"* ]]
}

@test "doctor flags drifted secrets dir mode" {
  chmod 755 "$DA_HOME/secrets"
  run "$PLUGIN_ROOT/scripts/doctor.sh" volk
  [ "$status" -ne 0 ]
  [[ "$output" == *"secrets"* ]]
}

@test "doctor flags unknown checklist_template" {
  python3 "$PLUGIN_ROOT/scripts/lib/_toml.py" set "$DA_HOME/config.toml" defaults.checklist_template '"no-such"'
  run "$PLUGIN_ROOT/scripts/doctor.sh" volk
  [ "$status" -ne 0 ]
  [[ "$output" == *"template"* ]]
}

@test "doctor without project arg runs against all projects" {
  run "$PLUGIN_ROOT/scripts/doctor.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"volk"* ]]
}

@test "doctor fails when config does not exist" {
  rm "$DA_HOME/config.toml"
  run "$PLUGIN_ROOT/scripts/doctor.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"config"* ]]
}
```

- [ ] **Step 12.2: Run tests to verify they fail**

```bash
bats tests/doctor.bats
```

- [ ] **Step 12.3: Implement `doctor.sh`**

Create `scripts/doctor.sh`:

```bash
#!/usr/bin/env bash
set -uo pipefail   # not -e: we want to accumulate failures, not abort
PLUGIN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$PLUGIN_ROOT/scripts/lib/paths.sh"
source "$PLUGIN_ROOT/scripts/lib/io.sh"
source "$PLUGIN_ROOT/scripts/lib/config.sh"
source "$PLUGIN_ROOT/scripts/lib/state.sh"
source "$PLUGIN_ROOT/scripts/lib/secrets.sh"

declare -i ERRORS=0

check() {
  local label="$1" status="$2" detail="${3:-}"
  if [[ "$status" == "ok" ]]; then
    echo "  OK   $label"
  else
    echo "  FAIL $label${detail:+ — $detail}"
    ERRORS=$((ERRORS + 1))
  fi
}

require_field() {
  local project="$1" field="$2" v
  v="$(config_get_project_field "$project" "$field" 2>/dev/null || true)"
  if [[ -z "$v" ]]; then
    check "project.$project.$field" fail "required field unset"
  else
    check "project.$project.$field" ok
  fi
  printf '%s' "$v"
}

check_template_resolves() {
  local name="$1" path
  path="$PLUGIN_ROOT/templates/checklist-${name}.md"
  if [[ -f "$path" ]]; then
    check "checklist template '$name'" ok
  else
    check "checklist template '$name'" fail "no such file: $path"
  fi
}

check_one_project() {
  local project="$1"
  echo "[project: $project]"
  config_is_project "$project" \
    || { check "project block" fail "no [project.$project] in $(config_path)"; return; }

  local src devdoc
  src="$(require_field "$project" source_dir)"
  devdoc="$(require_field "$project" devdoc_dir)"
  require_field "$project" issue_source.backend >/dev/null
  require_field "$project" issue_source.repo    >/dev/null
  require_field "$project" code_source.backend  >/dev/null

  src="$(expand_tilde "$src")"
  devdoc="$(expand_tilde "$devdoc")"
  if [[ -d "$src" ]]; then
    check "source_dir exists ($src)" ok
  else
    check "source_dir exists ($src)" fail "directory not found"
  fi
  if [[ -d "$devdoc" ]]; then
    check "devdoc_dir exists ($devdoc)" ok
  else
    check "devdoc_dir exists ($devdoc)" fail "directory not found"
  fi

  # State file
  if state_exists "$project"; then
    local mode
    mode="$(stat -c '%a' "$(state_path "$project")")"
    if [[ "$mode" == "600" ]]; then
      check "state file ($mode)" ok
    else
      check "state file ($mode)" fail "expected mode 600"
    fi
  else
    check "state file" fail "missing — run /devagent:init $project"
  fi

  # Checklist template resolution
  local tpl
  tpl="$(config_get_project_field "$project" checklist_template 2>/dev/null || true)"
  [[ -z "$tpl" ]] && tpl="$(config_get_default checklist_template 2>/dev/null || echo standard)"
  check_template_resolves "$tpl"
}

# ---- main ----------------------------------------------------------------

echo "devagent doctor — $(date -Iseconds)"
echo "home: $(devagent_home)"
echo

# Global checks
if [[ -f "$(config_path)" ]]; then
  check "config exists" ok
  if python3 "$PLUGIN_ROOT/scripts/lib/_toml.py" validate "$(config_path)" >/dev/null 2>&1; then
    check "config is valid TOML" ok
  else
    check "config is valid TOML" fail "tomllib failed to parse $(config_path)"
  fi
else
  check "config exists" fail "no $(config_path) — run /devagent:init"
fi

if [[ -d "$(secrets_dir)" ]]; then
  if secrets_audit 2>/dev/null; then
    check "secrets dir clean" ok
  else
    check "secrets dir clean" fail "mode drift — see warnings (re-run secrets_audit)"
  fi
else
  check "secrets dir present" fail "no $(secrets_dir)"
fi

echo

if (( ERRORS > 0 )); then
  echo "doctor: aborting per-project checks due to $ERRORS global error(s)"
  exit 1
fi

if [[ $# -ge 1 ]]; then
  check_one_project "$1"
else
  any=0
  while IFS= read -r p; do
    [[ -z "$p" ]] && continue
    check_one_project "$p"
    any=1
  done < <(config_list_projects)
  (( any == 1 )) || { echo "no projects configured"; exit 1; }
fi

echo
if (( ERRORS == 0 )); then
  echo "OK ($(date -Iseconds))"
  exit 0
else
  echo "FAIL ($ERRORS error(s))"
  exit 1
fi
```

- [ ] **Step 12.4: Make executable, run tests**

```bash
chmod +x scripts/doctor.sh
bats tests/doctor.bats
```

Expected: 9/9 PASS.

- [ ] **Step 12.5: Write slash-command wrapper**

Create `commands/doctor.md`:

```markdown
---
name: devagent:doctor
description: Validate config, state, paths, and template resolution.
---

Run `scripts/doctor.sh [project]`. With no argument, doctor runs against
every project in `~/.claude/devagent/config.toml` and reports each one.
With a project argument, only that project is checked.

Plan 1's doctor checks structural concerns only (config parses; required
project fields present; source_dir/devdoc_dir exist; state file mode 600;
secrets dir mode 700; checklist template resolves). Auth and reachability
checks are added in Plan 8.

Forward arguments verbatim.
```

- [ ] **Step 12.6: Commit**

```bash
git add scripts/doctor.sh tests/doctor.bats commands/doctor.md
git commit -s -m "$(cat <<'EOF'
plan01: add doctor.sh and /devagent:doctor

Validates config + state + paths + template resolution. Auth and
reachability checks deferred to Plan 8.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 13: Full test sweep and final commit

- [ ] **Step 13.1: Run the entire bats suite**

```bash
cd /home/user/src/devAgent
bats tests/
```

Expected: every `.bats` file passes; 0 failures.

- [ ] **Step 13.2: Verify file mode invariants on the working tree**

```bash
cd /home/user/src/devAgent
ls -la scripts/*.sh scripts/lib/*.sh scripts/lib/_toml.py
```

Expected: every `.sh` and `_toml.py` is mode 755 (`rwxr-xr-x`). If any
are not, `chmod +x` and commit the fix.

- [ ] **Step 13.3: Sanity-test `/devagent:init` end-to-end in `$HOME`**

```bash
DA_HOME="$(mktemp -d)" \
DA_INIT_SOURCE_DIR="/tmp" \
DA_INIT_DEVDOC_DIR="/tmp" \
DA_INIT_ISSUE_BACKEND=github DA_INIT_ISSUE_REPO=foo/bar \
DA_INIT_CODE_BACKEND=github DA_INIT_CODE_UPSTREAM=foo/bar \
DA_INIT_CODE_FORK=me/bar DA_YES=1 \
scripts/init.sh smoketest && echo INIT_OK

DA_HOME=… scripts/doctor.sh smoketest && echo DOCTOR_OK
```

(Substitute the same `DA_HOME` value in the doctor call.) Expected:
`INIT_OK` then `DOCTOR_OK` printed.

- [ ] **Step 13.4: Final wrap commit if any fixes were needed**

If steps 13.1–13.3 surfaced fixes, commit them:

```bash
git add -p
git commit -s -m "$(cat <<'EOF'
plan01: final wrap — fix file modes / sweep findings

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

If no fixes were needed, this step is a no-op.

---

## Self-Review

**Spec-coverage cross-check:**

| Spec ref | Covered by |
|---|---|
| §3.1 plugin tree | Task 0 (scaffolding), Tasks 7/10/11/12 (templates/, commands/) |
| §3.2 `config.toml` | Task 4 (`config.sh` reader), Task 11 (init writes one) |
| §3.3 `state/<project>.toml` | Task 5 (`state.sh`), Task 11 (init creates one) |
| §3.4 secrets dir | Task 6 (`secrets.sh`), Task 11 (init bootstraps), Task 12 (doctor audits) |
| §5.1 glyphs | Task 8 (`_checklist_valid_glyph`), Task 10 (mark/stuck/unstuck use them) |
| §5.2 layout | Task 7 (templates), Task 8 (parser), Task 9 (log section) |
| §5.3 STUCK file | Task 10.8/10.9 (stuck.sh writes, unstuck.sh removes) |
| §6.5 init + doctor | Task 11, Task 12 |
| §12 migrations | Task 0.4 (in-repo) + Task 0.5 (cross-repo copy) |
| §19 testing strategy | bats files alongside every script; `_toml.py` covered by `_toml.bats` |

**Things deferred (named here so the plan-review pass can spot-check that they belong to the right downstream plan):**

- Doctor's `auth/<backend>.sh status` and reachability checks → Plan 8
- `where`, `next`, `status`, `catchup`, `stuck`/`unstuck` slash commands as workflow verbs (Family D) → Plan 2 (note: Plan 1's `checklist-stuck.sh` / `checklist-unstuck.sh` operate on an arbitrary issue dir and do not require a project state; Plan 2's `/devagent:stuck` will additionally update `<project>.toml`)
- `pull.sh` / `branch.sh` / `commit.sh` / etc. → Plans 2, 3
- `_toml.py` write support for arrays/dates → deliberately not implemented per spec §3.3 (parked is a `[parked]` table with boolean-true keys, not an array)
- README full content → docs sweep at end of Plan 10
- Symlink-back of cross-repo migrated templates → opted out; Step 0.5 leaves the original in place instead

**Type-consistency pass:** The Plan 2 contract block at the top of this plan was checked against the actual function signatures in Tasks 4–9; all names match (`config_get_project_field`, `state_get`, `state_set`, `state_active_project`, `checklist_mark`, `checklist_current_step`, `log_append`, `log_tail`, `confirm`, `die`).

**Open questions for the operator:**

1. **Cross-repo template migration:** Spec §12 calls for symlinks "for one release cycle". This plan opts for a one-way copy of `~/.claude/issue-redteam-prompt.md` → `templates/redteam_issue.md` and leaves the original in place. Confirm this is acceptable, or specify how to handle the cross-repo symlink (the in-repo three are `git mv`'d).
2. **Default permissions:** `init.sh` writes all `[project.<name>.permissions]` flags as `false`. The example in spec §3.2 shows volk with most flags `true`. Confirm new projects should default safe (all false) and require explicit opt-in, rather than mirroring volk's permissive defaults.

**Resolved during plan review (no action needed):**

- **`parked` representation** — keys-form retained (`[parked]` table with `"Issue-X" = true` keys, not an array). Spec §3.3 updated to match. `_toml.py` extended in Task 2 with `fcntl.flock`-based atomic writes so that concurrent `state_add_parked` / `state_remove_parked` calls cannot lose updates regardless of representation.
- **`bats` availability** — installed locally; no fallback needed.
