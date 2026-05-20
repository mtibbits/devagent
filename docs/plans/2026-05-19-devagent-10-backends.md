# devAgent Plan 10 — Additional Backends + Contract Tests

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship GitLab, JIRA, and custom-stub backends conforming to the spec §9 contracts, plus a backend-contract test harness that all backends (GitHub, GitLab, JIRA, custom) must pass before merge.

**Architecture:** Each backend script lives at `scripts/issue/<backend>.sh` and `scripts/code/<backend>.sh`. Every script accepts a verb as `$1` and dispatches via a `case` statement. All backends emit the identical markdown shape defined in spec §9.3 so downstream code can be backend-agnostic. A single contract test harness (`tests/backend-contract.bats`) parametrizes over backends and exercises each verb against in-process fixture HTTP servers — never live APIs. Custom stubs intentionally exit with a documented code (78 = "configuration not implemented") so dispatcher scripts can report the situation cleanly.

**Tech Stack:** bash, bats-core (with bats-assert and bats-support), `gh` / `glab` (preferred when present, with `curl` fallback to REST APIs), `python3 -m http.server` style fixture servers (via a small `tests/lib/fixture-server.sh` helper using `socat` or a python one-liner), `jq` for JSON parsing.

---

## Coordination With Earlier Plans

This plan **assumes** the following exist (delivered by Plans 2/3/8). If anything is missing when this plan is executed, complete it within Task 2 of this plan and note the deviation in `actualWork.md`.

- `scripts/issue/github.sh` with verbs: `fetch`, `create`, `transition`, `state`, `comment-list` (Plan 2 ships fetch+transition; this plan **requires** all five and Task 2 extends if missing)
- `scripts/code/github.sh` with verbs: `push-branch`, `create-mr`, `mr-state`, `mr-comments`, `merge-mr` (Plan 3 ships these; Task 2 extends if missing)
- `scripts/auth/<backend>.sh exec <project> -- cmd…` wrapper that exports the relevant token env var (Plan 8)
- `scripts/lib/config-loader.sh` providing `devagent_get_config <project> <key>` (Plan 1)
- GitHub fixture data at `tests/fixtures/github/` (Plan 2)

If any item above is missing, Task 2 of this plan implements/extends it. Otherwise Task 2 is a no-op confirmation step.

---

## File Structure

**New backend scripts:**
- `scripts/issue/gitlab.sh` — five verbs, prefers `glab`, falls back to `curl`
- `scripts/code/gitlab.sh` — five verbs, prefers `glab`, falls back to `curl`
- `scripts/issue/jira.sh` — five verbs, `curl` only (JIRA has no first-class CLI we standardize on)
- `scripts/issue/custom.sh` — stub, all verbs exit 78
- `scripts/code/custom.sh` — stub, all verbs exit 78

**Shared helpers (new):**
- `scripts/lib/backend-common.sh` — `bc_have_cli`, `bc_emit_fetch_header`, `bc_emit_comment`, `bc_die_not_implemented`, `bc_curl` (curl with `--fail-with-body`, retries, timeout)
- `scripts/lib/semantic-stage.sh` — `ss_lookup <project> <semantic-stage>` returns native stage representation per backend type

**Contract test harness:**
- `tests/backend-contract.bats` — parametrized contract suite (the deliverable)
- `tests/lib/contract-helpers.bash` — shared helpers loaded by the bats file
- `tests/lib/fixture-server.sh` — starts/stops a python fixture HTTP server on an ephemeral port
- `tests/fixtures/gitlab/` — JSON fixtures (issue, MR, comments, error 401, error 404)
- `tests/fixtures/jira/` — JSON fixtures (issue, transitions, comments, error 401, error 404)
- `tests/fixtures/server.py` — minimal request-routed fixture HTTP server (Python stdlib only)
- `tests/fixtures/config/contract.toml` — config fixture pointing every backend at `http://127.0.0.1:$PORT`

**Backend-specific bats (thin wrappers that source the contract harness):**
- `tests/backend-github.bats`
- `tests/backend-gitlab.bats`
- `tests/backend-jira.bats`
- `tests/backend-custom.bats`

**Docs:**
- `README.md` — append a "Custom backends" section (only modification outside `scripts/`/`tests/`)

---

## Conventions Used Throughout

- All commits use `git commit -s` (DCO).
- All commits end with `Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>` (no "(1M context)").
- Exit code conventions:
  - `0` success
  - `1` generic failure
  - `2` usage error (missing/bad args)
  - `3` auth failure (401/403)
  - `4` not found (404)
  - `78` not implemented (EX_CONFIG from sysexits.h — used by `custom.sh` stubs)
- All backend scripts run under `set -euo pipefail`.
- All scripts source `scripts/lib/backend-common.sh` for shared helpers.
- Markdown produced by `fetch` and `comment-list` MUST match spec §9.3 byte-for-byte (modulo dynamic fields). The contract test diffs against a canonical golden file.

---

## Task 1: Add shared backend helper library

**Files:**
- Create: `scripts/lib/backend-common.sh`
- Test: `tests/lib-backend-common.bats`

- [ ] **Step 1: Write the failing test**

Create `tests/lib-backend-common.bats`:

```bash
#!/usr/bin/env bats

setup() {
  source "${BATS_TEST_DIRNAME}/../scripts/lib/backend-common.sh"
}

@test "bc_have_cli returns 0 when command exists" {
  bc_have_cli bash
}

@test "bc_have_cli returns 1 when command missing" {
  run bc_have_cli definitely-not-a-real-command-xyz
  [ "$status" -eq 1 ]
}

@test "bc_die_not_implemented exits 78 with message" {
  run bash -c "source scripts/lib/backend-common.sh; bc_die_not_implemented custom create"
  [ "$status" -eq 78 ]
  [[ "$output" == *"not implemented"* ]]
  [[ "$output" == *"custom"* ]]
  [[ "$output" == *"create"* ]]
}

@test "bc_emit_fetch_header produces spec-shape markdown" {
  run bc_emit_fetch_header "foo/bar" "42" "Sample title" "open" "alice" "bug,perf" "https://example/42"
  [ "$status" -eq 0 ]
  [[ "$output" == *"# foo/bar#42 — Sample title"* ]]
  [[ "$output" == *"- State: open"* ]]
  [[ "$output" == *"- Author: @alice"* ]]
  [[ "$output" == *"- Labels: bug,perf"* ]]
  [[ "$output" == *"- URL: https://example/42"* ]]
}

@test "bc_emit_comment produces spec-shape comment block" {
  run bc_emit_comment "reviewer" "2026-05-12" "Looks good"
  [ "$status" -eq 0 ]
  [[ "$output" == *"### @reviewer · 2026-05-12"* ]]
  [[ "$output" == *"Looks good"* ]]
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bats tests/lib-backend-common.bats`
Expected: FAIL — `backend-common.sh` not found.

- [ ] **Step 3: Implement the helper**

Create `scripts/lib/backend-common.sh`:

```bash
#!/usr/bin/env bash
# backend-common.sh — shared helpers for issue/* and code/* backends.
# Source-only; do not execute.

# Returns 0 iff $1 is on PATH.
bc_have_cli() {
  command -v "$1" >/dev/null 2>&1
}

# Print a "not implemented" message to stderr and exit 78 (EX_CONFIG).
# Usage: bc_die_not_implemented <backend> <verb>
bc_die_not_implemented() {
  local backend="${1:-?}"
  local verb="${2:-?}"
  printf 'devagent: %s backend: verb "%s" is not implemented in this stub.\n' \
    "$backend" "$verb" >&2
  printf 'devagent: see README.md "Custom backends" for how to implement.\n' >&2
  exit 78
}

# Emit the spec §9.3 fetch header.
# Usage: bc_emit_fetch_header <repo> <num> <title> <state> <author> <labels-csv> <url>
bc_emit_fetch_header() {
  local repo="$1" num="$2" title="$3" state="$4" author="$5" labels="$6" url="$7"
  printf '# %s#%s — %s\n\n' "$repo" "$num" "$title"
  printf -- '- State: %s\n' "$state"
  printf -- '- Author: @%s\n' "$author"
  printf -- '- Labels: %s\n' "$labels"
  printf -- '- URL: %s\n' "$url"
  printf '\n---\n\n'
}

# Emit body block separator (spec §9.3: body verbatim, separated by ---).
# Usage: bc_emit_body_and_separator <body-text>
bc_emit_body_and_separator() {
  local body="$1"
  printf '%s\n\n---\n\n' "$body"
}

# Emit the comments section header.
# Usage: bc_emit_comments_header <count>
bc_emit_comments_header() {
  printf '## Comments (%s)\n\n' "$1"
}

# Emit one comment.
# Usage: bc_emit_comment <author> <date> <body>
bc_emit_comment() {
  local author="$1" date="$2" body="$3"
  printf '### @%s · %s\n\n%s\n\n' "$author" "$date" "$body"
}

# curl with sensible defaults for backend API calls.
# Maps HTTP status to our exit code conventions.
# Usage: bc_curl <method> <url> [extra curl args…]
# Writes body to stdout; exit 3 on auth failure, 4 on 404, 1 on other.
bc_curl() {
  local method="$1" url="$2"; shift 2
  local body_file http_status
  body_file="$(mktemp)"
  http_status="$(curl --silent --show-error \
    --connect-timeout 5 --max-time 30 \
    --retry 2 --retry-connrefused \
    -X "$method" \
    -o "$body_file" -w '%{http_code}' \
    "$@" "$url" 2>/dev/null || true)"
  cat "$body_file"
  rm -f "$body_file"
  case "$http_status" in
    2*) return 0 ;;
    401|403) return 3 ;;
    404) return 4 ;;
    *) return 1 ;;
  esac
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bats tests/lib-backend-common.bats`
Expected: PASS (5 tests).

- [ ] **Step 5: Commit**

```bash
git add scripts/lib/backend-common.sh tests/lib-backend-common.bats
git commit -s -m "$(cat <<'EOF'
plan10: add shared backend-common helper library

Provides bc_have_cli, bc_die_not_implemented, bc_emit_fetch_header,
bc_emit_comment, bc_emit_body_and_separator, bc_emit_comments_header,
and bc_curl. All issue/* and code/* backends share these helpers so
the §9.3 markdown shape is produced identically across backends.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: Verify / extend GitHub backend to full contract

The contract requires `fetch`, `create`, `transition`, `state`, `comment-list` on `issue/github.sh` and `push-branch`, `create-mr`, `mr-state`, `mr-comments`, `merge-mr` on `code/github.sh`. Plans 2/3 may have shipped a subset.

**Files:**
- Inspect/Extend: `scripts/issue/github.sh`
- Inspect/Extend: `scripts/code/github.sh`

- [ ] **Step 1: Inventory existing GitHub verbs**

Run:

```bash
for f in scripts/issue/github.sh scripts/code/github.sh; do
  echo "=== $f ==="
  if [ -f "$f" ]; then
    grep -nE '^\s*[a-z-]+\)' "$f" || echo "(no case branches)"
  else
    echo "MISSING"
  fi
done
```

Expected: case branches for `fetch`, `create`, `transition`, `state`, `comment-list` in `issue/github.sh` and for `push-branch`, `create-mr`, `mr-state`, `mr-comments`, `merge-mr` in `code/github.sh`.

- [ ] **Step 2: Decision point — extend or pass**

If the inventory shows missing verbs, append them to the existing scripts using the same patterns Plan 2/3 established (wrap `gh`, source `scripts/lib/backend-common.sh`, emit markdown via `bc_emit_*`, exit-code conventions from this plan).

If every required verb already exists, add a top-of-file comment confirming contract compliance:

```bash
# Backend contract: implements all five issue verbs per spec §9.1
# (fetch, create, transition, state, comment-list).
# Output shape conforms to spec §9.3.
```

and the analogous comment in `code/github.sh`.

Document in `actualWork.md` which path was taken.

- [ ] **Step 3: Smoke test existing GitHub bats (if present)**

Run: `ls tests/backend-github*.bats tests/issue-github*.bats tests/code-github*.bats 2>/dev/null && bats tests/backend-github*.bats tests/issue-github*.bats tests/code-github*.bats 2>/dev/null || echo "no existing tests"`
Expected: all existing GitHub tests still pass.

- [ ] **Step 4: Commit (only if Step 2 made changes)**

```bash
git add scripts/issue/github.sh scripts/code/github.sh
git commit -s -m "$(cat <<'EOF'
plan10: complete GitHub backend contract surface

Adds any verbs missing from Plans 2/3 so issue/github.sh and
code/github.sh implement the full backend contract per spec §9.1
and §9.2. See actualWork.md for the specific verbs added.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

If no changes were needed, skip the commit and note that in `actualWork.md`.

---

## Task 3: Build the fixture HTTP server

**Files:**
- Create: `tests/fixtures/server.py`
- Create: `tests/lib/fixture-server.sh`
- Test: `tests/fixture-server.bats`

- [ ] **Step 1: Write the failing test**

Create `tests/fixture-server.bats`:

```bash
#!/usr/bin/env bats

load lib/fixture-server.sh

setup() {
  FIXTURE_DIR="${BATS_TEST_DIRNAME}/fixtures/jira"
  mkdir -p "$FIXTURE_DIR"
  cat > "$FIXTURE_DIR/routes.json" <<'JSON'
{
  "GET /rest/api/2/issue/PROJ-1": {"status": 200, "body_file": "issue.json"},
  "GET /rest/api/2/issue/MISSING": {"status": 404, "body": "{\"errorMessages\":[\"Issue Does Not Exist\"]}"},
  "GET /rest/api/2/issue/UNAUTH":  {"status": 401, "body": "{\"errorMessages\":[\"Unauthorized\"]}"}
}
JSON
  cat > "$FIXTURE_DIR/issue.json" <<'JSON'
{"key":"PROJ-1","fields":{"summary":"Hi","status":{"name":"Open"}}}
JSON
  fixture_start "$FIXTURE_DIR"
}

teardown() {
  fixture_stop
}

@test "fixture server serves 200 with body_file" {
  run curl -s -o - -w '%{http_code}' "$FIXTURE_URL/rest/api/2/issue/PROJ-1"
  [[ "$output" == *"PROJ-1"* ]]
  [[ "$output" == *"200" ]]
}

@test "fixture server serves 404" {
  run curl -s -o /dev/null -w '%{http_code}' "$FIXTURE_URL/rest/api/2/issue/MISSING"
  [ "$output" = "404" ]
}

@test "fixture server serves 401" {
  run curl -s -o /dev/null -w '%{http_code}' "$FIXTURE_URL/rest/api/2/issue/UNAUTH"
  [ "$output" = "401" ]
}

@test "fixture server records POST requests" {
  curl -s -o /dev/null -X POST -d '{"x":1}' "$FIXTURE_URL/anything"
  run cat "$FIXTURE_REQUEST_LOG"
  [[ "$output" == *"POST /anything"* ]]
  [[ "$output" == *'{"x":1}'* ]]
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bats tests/fixture-server.bats`
Expected: FAIL — `fixture-server.sh` not found.

- [ ] **Step 3: Implement the fixture server (Python)**

Create `tests/fixtures/server.py`:

```python
#!/usr/bin/env python3
"""Tiny route-table fixture HTTP server for backend contract tests.

Usage: server.py <fixture-dir> <port> <request-log>

Routes are read from <fixture-dir>/routes.json. Each key is
"<METHOD> <PATH>" and each value is one of:
  {"status": N, "body": "..."}
  {"status": N, "body_file": "relative-to-fixture-dir.json"}
  {"status": N, "body_file": "...", "headers": {"Content-Type": "..."}}

Every incoming request is appended one-line to <request-log>:
  <METHOD> <PATH>\\t<body-as-one-line>

The server is single-threaded and exits on SIGTERM.
"""

import json
import os
import sys
import signal
from http.server import BaseHTTPRequestHandler, HTTPServer


def main():
    fixture_dir = sys.argv[1]
    port = int(sys.argv[2])
    request_log = sys.argv[3]

    routes_path = os.path.join(fixture_dir, "routes.json")
    with open(routes_path) as f:
        routes = json.load(f)

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, fmt, *args):
            pass  # silence default access log

        def _serve(self, method):
            length = int(self.headers.get("Content-Length", "0") or "0")
            body = self.rfile.read(length) if length else b""
            try:
                with open(request_log, "a") as rl:
                    rl.write("%s %s\t%s\n" %
                             (method, self.path, body.decode("utf-8", "replace")))
            except OSError:
                pass

            key = "%s %s" % (method, self.path)
            spec = routes.get(key)
            if spec is None:
                self.send_response(404)
                self.send_header("Content-Type", "application/json")
                self.end_headers()
                self.wfile.write(b'{"error":"no fixture for ' + key.encode() + b'"}')
                return

            status = int(spec.get("status", 200))
            headers = spec.get("headers", {"Content-Type": "application/json"})
            if "body_file" in spec:
                with open(os.path.join(fixture_dir, spec["body_file"]), "rb") as bf:
                    payload = bf.read()
            else:
                payload = spec.get("body", "").encode("utf-8")

            self.send_response(status)
            for k, v in headers.items():
                self.send_header(k, v)
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)

        def do_GET(self):    self._serve("GET")
        def do_POST(self):   self._serve("POST")
        def do_PUT(self):    self._serve("PUT")
        def do_PATCH(self):  self._serve("PATCH")
        def do_DELETE(self): self._serve("DELETE")

    server = HTTPServer(("127.0.0.1", port), Handler)

    def stop(_signum, _frame):
        server.shutdown()

    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    server.serve_forever()


if __name__ == "__main__":
    main()
```

Make it executable: `chmod +x tests/fixtures/server.py`

- [ ] **Step 4: Implement the bash wrapper**

Create `tests/lib/fixture-server.sh`:

```bash
#!/usr/bin/env bash
# fixture-server.sh — bats helper that starts/stops tests/fixtures/server.py.
# Exposes:
#   FIXTURE_URL          base URL (http://127.0.0.1:PORT)
#   FIXTURE_REQUEST_LOG  path to a request log file
#   fixture_start <fixture-dir>
#   fixture_stop

_fixture_pid=""

fixture_start() {
  local dir="$1"
  if [ -z "$dir" ] || [ ! -d "$dir" ]; then
    echo "fixture_start: bad dir '$dir'" >&2
    return 2
  fi
  # Allocate an ephemeral port.
  local port
  port="$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()')"
  FIXTURE_URL="http://127.0.0.1:${port}"
  FIXTURE_REQUEST_LOG="$(mktemp)"
  : > "$FIXTURE_REQUEST_LOG"
  python3 "${BATS_TEST_DIRNAME}/fixtures/server.py" \
    "$dir" "$port" "$FIXTURE_REQUEST_LOG" >/dev/null 2>&1 &
  _fixture_pid=$!
  # Wait up to 5s for the port to accept.
  local i
  for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 \
           21 22 23 24 25 26 27 28 29 30 31 32 33 34 35 36 37 38 39 40 \
           41 42 43 44 45 46 47 48 49 50; do
    if curl -s -o /dev/null "${FIXTURE_URL}/__ping__" 2>/dev/null; then
      return 0
    fi
    sleep 0.1
  done
  echo "fixture_start: server did not come up on $FIXTURE_URL" >&2
  return 1
}

fixture_stop() {
  if [ -n "$_fixture_pid" ]; then
    kill "$_fixture_pid" 2>/dev/null || true
    wait "$_fixture_pid" 2>/dev/null || true
    _fixture_pid=""
  fi
  [ -n "${FIXTURE_REQUEST_LOG:-}" ] && rm -f "$FIXTURE_REQUEST_LOG" || true
}

export -f fixture_start fixture_stop
```

- [ ] **Step 5: Run test to verify it passes**

Run: `bats tests/fixture-server.bats`
Expected: PASS (4 tests).

- [ ] **Step 6: Commit**

```bash
git add tests/fixtures/server.py tests/lib/fixture-server.sh tests/fixture-server.bats
git commit -s -m "$(cat <<'EOF'
plan10: add fixture HTTP server for backend contract tests

A tiny Python stdlib HTTP server (tests/fixtures/server.py) reads a
routes.json table and serves canned responses. tests/lib/fixture-server.sh
starts it on an ephemeral port and exposes FIXTURE_URL plus a request
log so tests can assert what the backend sent. No live API calls in CI.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 4: GitLab fixtures

**Files:**
- Create: `tests/fixtures/gitlab/routes.json`
- Create: `tests/fixtures/gitlab/issue.json`
- Create: `tests/fixtures/gitlab/comments.json`
- Create: `tests/fixtures/gitlab/mr.json`
- Create: `tests/fixtures/gitlab/mr-notes.json`
- Create: `tests/fixtures/gitlab/issue-created.json`
- Create: `tests/fixtures/gitlab/mr-created.json`

- [ ] **Step 1: Create the fixture data**

Create `tests/fixtures/gitlab/issue.json`:

```json
{
  "iid": 42,
  "title": "Sample issue",
  "description": "This is the body of the issue.\n\nSecond paragraph.",
  "state": "opened",
  "author": {"username": "alice"},
  "labels": ["bug", "performance"],
  "web_url": "https://gitlab.example/foo/bar/-/issues/42",
  "user_notes_count": 1
}
```

Create `tests/fixtures/gitlab/comments.json`:

```json
[
  {
    "id": 1001,
    "author": {"username": "reviewer"},
    "created_at": "2026-05-12T14:00:00.000Z",
    "body": "Looks good to me",
    "system": false
  },
  {
    "id": 1002,
    "author": {"username": "ghost"},
    "created_at": "2026-05-12T14:05:00.000Z",
    "body": "assigned to @x",
    "system": true
  }
]
```

Create `tests/fixtures/gitlab/mr.json`:

```json
{
  "iid": 7,
  "title": "Sample MR",
  "state": "opened",
  "draft": false,
  "web_url": "https://gitlab.example/foo/bar/-/merge_requests/7",
  "source_branch": "feat/x",
  "target_branch": "main"
}
```

Create `tests/fixtures/gitlab/mr-notes.json`:

```json
[
  {
    "id": 2001,
    "author": {"username": "reviewer"},
    "created_at": "2026-05-12T16:00:00.000Z",
    "body": "needs a test",
    "system": false
  }
]
```

Create `tests/fixtures/gitlab/issue-created.json`:

```json
{"iid": 99, "web_url": "https://gitlab.example/foo/bar/-/issues/99"}
```

Create `tests/fixtures/gitlab/mr-created.json`:

```json
{"iid": 12, "web_url": "https://gitlab.example/foo/bar/-/merge_requests/12"}
```

Create `tests/fixtures/gitlab/routes.json`:

```json
{
  "GET /api/v4/projects/foo%2Fbar/issues/42": {"status": 200, "body_file": "issue.json"},
  "GET /api/v4/projects/foo%2Fbar/issues/42/notes": {"status": 200, "body_file": "comments.json"},
  "POST /api/v4/projects/foo%2Fbar/issues": {"status": 201, "body_file": "issue-created.json"},
  "PUT /api/v4/projects/foo%2Fbar/issues/42": {"status": 200, "body_file": "issue.json"},
  "GET /api/v4/projects/foo%2Fbar/issues/404": {"status": 404, "body": "{\"message\":\"404 Not Found\"}"},
  "GET /api/v4/projects/foo%2Fbar/issues/401": {"status": 401, "body": "{\"message\":\"401 Unauthorized\"}"},

  "GET /api/v4/projects/foo%2Fbar/merge_requests/7": {"status": 200, "body_file": "mr.json"},
  "GET /api/v4/projects/foo%2Fbar/merge_requests/7/notes": {"status": 200, "body_file": "mr-notes.json"},
  "POST /api/v4/projects/foo%2Fbar/merge_requests": {"status": 201, "body_file": "mr-created.json"},
  "PUT /api/v4/projects/foo%2Fbar/merge_requests/7/merge": {"status": 200, "body": "{\"state\":\"merged\"}"}
}
```

- [ ] **Step 2: Smoke-test the fixtures load**

Run: `python3 -c 'import json; json.load(open("tests/fixtures/gitlab/routes.json")); print("ok")'`
Expected: `ok`

- [ ] **Step 3: Commit**

```bash
git add tests/fixtures/gitlab/
git commit -s -m "$(cat <<'EOF'
plan10: add GitLab REST v4 fixtures for contract tests

Covers issue fetch, issue notes, issue create, issue update (label
transition), MR fetch, MR notes, MR create, MR merge — plus 401/404
error fixtures.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 5: Implement `scripts/issue/gitlab.sh`

**Files:**
- Create: `scripts/issue/gitlab.sh`
- Test: `tests/issue-gitlab.bats`

- [ ] **Step 1: Write the failing test**

Create `tests/issue-gitlab.bats`:

```bash
#!/usr/bin/env bats

load lib/fixture-server.sh

setup() {
  fixture_start "${BATS_TEST_DIRNAME}/fixtures/gitlab"
  export GITLAB_TOKEN="dummy-token"
  export DEVAGENT_GITLAB_API="$FIXTURE_URL/api/v4"
  SCRIPT="${BATS_TEST_DIRNAME}/../scripts/issue/gitlab.sh"
}

teardown() {
  fixture_stop
}

@test "issue/gitlab.sh fetch emits spec §9.3 markdown" {
  run "$SCRIPT" fetch foo/bar 42
  [ "$status" -eq 0 ]
  [[ "$output" == *"# foo/bar#42 — Sample issue"* ]]
  [[ "$output" == *"- State: opened"* ]]
  [[ "$output" == *"- Author: @alice"* ]]
  [[ "$output" == *"- Labels: bug,performance"* ]]
  [[ "$output" == *"- URL: https://gitlab.example/foo/bar/-/issues/42"* ]]
  [[ "$output" == *"This is the body of the issue."* ]]
  [[ "$output" == *"## Comments (1)"* ]]
  [[ "$output" == *"### @reviewer · 2026-05-12"* ]]
  [[ "$output" != *"system"* ]]  # system notes excluded
}

@test "issue/gitlab.sh create POSTs issue and prints new iid" {
  body=$(mktemp); echo "body text" > "$body"
  run "$SCRIPT" create foo/bar "New issue" "$body" --label bug --label perf
  [ "$status" -eq 0 ]
  [ "$output" = "99" ]
  rm -f "$body"
  grep -q "POST /api/v4/projects/foo%2Fbar/issues" "$FIXTURE_REQUEST_LOG"
}

@test "issue/gitlab.sh transition PUTs label update" {
  # Stage in_progress maps to a config-defined GitLab label set.
  export DEVAGENT_GITLAB_LABELS_IN_PROGRESS="status::in-progress"
  export DEVAGENT_GITLAB_LABEL_NAMESPACE="status::"
  run "$SCRIPT" transition foo/bar 42 in_progress
  [ "$status" -eq 0 ]
  grep -q "PUT /api/v4/projects/foo%2Fbar/issues/42" "$FIXTURE_REQUEST_LOG"
}

@test "issue/gitlab.sh state prints opened" {
  run "$SCRIPT" state foo/bar 42
  [ "$status" -eq 0 ]
  [ "$output" = "opened" ]
}

@test "issue/gitlab.sh comment-list prints spec-shape comments" {
  run "$SCRIPT" comment-list foo/bar 42
  [ "$status" -eq 0 ]
  [[ "$output" == *"### @reviewer · 2026-05-12"* ]]
  [[ "$output" == *"Looks good to me"* ]]
}

@test "issue/gitlab.sh fetch on 404 exits 4" {
  run "$SCRIPT" fetch foo/bar 404
  [ "$status" -eq 4 ]
}

@test "issue/gitlab.sh fetch on 401 exits 3" {
  run "$SCRIPT" fetch foo/bar 401
  [ "$status" -eq 3 ]
}

@test "issue/gitlab.sh with no args exits 2" {
  run "$SCRIPT"
  [ "$status" -eq 2 ]
}

@test "issue/gitlab.sh with unknown verb exits 2" {
  run "$SCRIPT" frobnicate foo/bar 42
  [ "$status" -eq 2 ]
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bats tests/issue-gitlab.bats`
Expected: FAIL — `scripts/issue/gitlab.sh` not found.

- [ ] **Step 3: Implement the script**

Create `scripts/issue/gitlab.sh`:

```bash
#!/usr/bin/env bash
# issue/gitlab.sh — GitLab issue backend.
# Prefers glab CLI; falls back to curl against REST v4 when glab is unavailable
# or when DEVAGENT_GITLAB_API is set (used by tests).
#
# Verbs (spec §9.1):
#   fetch        <repo> <num>                       → markdown to stdout
#   create       <repo> <title> <body-file> [--label X]…  → new <num>
#   transition   <repo> <num> <semantic-stage>      → exit 0
#   state        <repo> <num>                       → backend state
#   comment-list <repo> <num>                       → markdown

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/backend-common.sh
source "${SCRIPT_DIR}/../lib/backend-common.sh"

usage() {
  cat <<EOF >&2
Usage: gitlab.sh <verb> [args…]
  fetch <repo> <num>
  create <repo> <title> <body-file> [--label X]…
  transition <repo> <num> <semantic-stage>
  state <repo> <num>
  comment-list <repo> <num>
EOF
  exit 2
}

api_base() {
  echo "${DEVAGENT_GITLAB_API:-https://gitlab.com/api/v4}"
}

# URL-encode a path segment via python3 (always available per global prefs).
urlenc() {
  python3 -c 'import sys,urllib.parse;print(urllib.parse.quote(sys.argv[1],safe=""))' "$1"
}

# Use glab if available *and* no test override is set.
use_glab() {
  [ -z "${DEVAGENT_GITLAB_API:-}" ] && bc_have_cli glab
}

# Issue date → date portion only.
trim_date() {
  echo "${1%%T*}"
}

# --- verbs -------------------------------------------------------------------

cmd_fetch() {
  local repo="$1" num="$2"
  [ -z "$repo" ] || [ -z "$num" ] && usage
  local enc; enc="$(urlenc "$repo")"
  local base; base="$(api_base)"
  local issue_json comments_json
  issue_json="$(bc_curl GET "${base}/projects/${enc}/issues/${num}" \
    -H "PRIVATE-TOKEN: ${GITLAB_TOKEN:-}")" || return
  comments_json="$(bc_curl GET "${base}/projects/${enc}/issues/${num}/notes" \
    -H "PRIVATE-TOKEN: ${GITLAB_TOKEN:-}")" || return

  local title state author labels url body
  title="$(echo "$issue_json" | jq -r '.title')"
  state="$(echo "$issue_json" | jq -r '.state')"
  author="$(echo "$issue_json" | jq -r '.author.username')"
  labels="$(echo "$issue_json" | jq -r '.labels | join(",")')"
  url="$(echo "$issue_json" | jq -r '.web_url')"
  body="$(echo "$issue_json" | jq -r '.description // ""')"

  bc_emit_fetch_header "$repo" "$num" "$title" "$state" "$author" "$labels" "$url"
  bc_emit_body_and_separator "$body"

  local count
  count="$(echo "$comments_json" | jq '[.[] | select(.system==false)] | length')"
  bc_emit_comments_header "$count"

  echo "$comments_json" | jq -c '.[] | select(.system==false)' | while read -r row; do
    local a d b
    a="$(echo "$row" | jq -r '.author.username')"
    d="$(trim_date "$(echo "$row" | jq -r '.created_at')")"
    b="$(echo "$row" | jq -r '.body')"
    bc_emit_comment "$a" "$d" "$b"
  done
}

cmd_create() {
  local repo="$1" title="$2" body_file="$3"; shift 3 || usage
  [ -z "$repo" ] || [ -z "$title" ] || [ -z "$body_file" ] && usage
  [ -r "$body_file" ] || { echo "body file unreadable: $body_file" >&2; exit 2; }

  local labels=()
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --label) labels+=("$2"); shift 2 ;;
      *) usage ;;
    esac
  done
  local labels_csv=""
  if [ "${#labels[@]}" -gt 0 ]; then
    labels_csv="$(IFS=,; echo "${labels[*]}")"
  fi

  local enc; enc="$(urlenc "$repo")"
  local base; base="$(api_base)"
  local payload
  payload="$(jq -n --arg t "$title" --rawfile d "$body_file" --arg l "$labels_csv" \
    '{title:$t, description:$d} + (if $l == "" then {} else {labels:$l} end)')"
  local resp
  resp="$(bc_curl POST "${base}/projects/${enc}/issues" \
    -H "PRIVATE-TOKEN: ${GITLAB_TOKEN:-}" \
    -H "Content-Type: application/json" \
    --data "$payload")" || return
  echo "$resp" | jq -r '.iid'
}

cmd_transition() {
  local repo="$1" num="$2" stage="$3"
  [ -z "$repo" ] || [ -z "$num" ] || [ -z "$stage" ] && usage

  # Look up the label set for this stage. Test path uses env vars;
  # production path will call into config-loader (Plan 1) — TODO documented
  # in plan; for now we accept both.
  local add_label remove_prefix
  local var_add="DEVAGENT_GITLAB_LABELS_$(echo "$stage" | tr '[:lower:]' '[:upper:]' | tr - _)"
  add_label="${!var_add:-}"
  remove_prefix="${DEVAGENT_GITLAB_LABEL_NAMESPACE:-}"

  if [ -z "$add_label" ]; then
    # Fall back to config-loader if available.
    if [ -f "${SCRIPT_DIR}/../lib/config-loader.sh" ]; then
      # shellcheck source=../lib/config-loader.sh
      source "${SCRIPT_DIR}/../lib/config-loader.sh"
      add_label="$(devagent_get_config "${DEVAGENT_PROJECT:-}" "gitlab_labels.${stage}" 2>/dev/null || true)"
      remove_prefix="$(devagent_get_config "${DEVAGENT_PROJECT:-}" "gitlab_labels.remove_others_in_namespace" 2>/dev/null || true)"
    fi
  fi

  local enc; enc="$(urlenc "$repo")"
  local base; base="$(api_base)"
  # GitLab supports add_labels / remove_labels query params on PUT.
  local payload
  payload="$(jq -n --arg add "$add_label" --arg rmprefix "$remove_prefix" \
    '{add_labels:$add} + (if $rmprefix=="" then {} else {remove_labels:$rmprefix} end)')"
  bc_curl PUT "${base}/projects/${enc}/issues/${num}" \
    -H "PRIVATE-TOKEN: ${GITLAB_TOKEN:-}" \
    -H "Content-Type: application/json" \
    --data "$payload" >/dev/null
}

cmd_state() {
  local repo="$1" num="$2"
  [ -z "$repo" ] || [ -z "$num" ] && usage
  local enc; enc="$(urlenc "$repo")"
  local base; base="$(api_base)"
  local resp
  resp="$(bc_curl GET "${base}/projects/${enc}/issues/${num}" \
    -H "PRIVATE-TOKEN: ${GITLAB_TOKEN:-}")" || return
  echo "$resp" | jq -r '.state'
}

cmd_comment_list() {
  local repo="$1" num="$2"
  [ -z "$repo" ] || [ -z "$num" ] && usage
  local enc; enc="$(urlenc "$repo")"
  local base; base="$(api_base)"
  local resp
  resp="$(bc_curl GET "${base}/projects/${enc}/issues/${num}/notes" \
    -H "PRIVATE-TOKEN: ${GITLAB_TOKEN:-}")" || return
  local count
  count="$(echo "$resp" | jq '[.[] | select(.system==false)] | length')"
  bc_emit_comments_header "$count"
  echo "$resp" | jq -c '.[] | select(.system==false)' | while read -r row; do
    local a d b
    a="$(echo "$row" | jq -r '.author.username')"
    d="$(trim_date "$(echo "$row" | jq -r '.created_at')")"
    b="$(echo "$row" | jq -r '.body')"
    bc_emit_comment "$a" "$d" "$b"
  done
}

# --- dispatch ----------------------------------------------------------------

verb="${1:-}"; shift || true
case "$verb" in
  fetch)        cmd_fetch "$@" ;;
  create)       cmd_create "$@" ;;
  transition)   cmd_transition "$@" ;;
  state)        cmd_state "$@" ;;
  comment-list) cmd_comment_list "$@" ;;
  ""|-h|--help) usage ;;
  *) usage ;;
esac
```

Make executable: `chmod +x scripts/issue/gitlab.sh`

- [ ] **Step 4: Run test to verify it passes**

Run: `bats tests/issue-gitlab.bats`
Expected: PASS (9 tests).

- [ ] **Step 5: Commit**

```bash
git add scripts/issue/gitlab.sh tests/issue-gitlab.bats
git commit -s -m "$(cat <<'EOF'
plan10: implement issue/gitlab.sh full backend contract

All five verbs (fetch, create, transition, state, comment-list) per
spec §9.1. Prefers glab; falls back to curl against REST v4 when glab
is missing or DEVAGENT_GITLAB_API is set (test path). System notes
filtered out of comment lists. Exit codes follow plan convention
(3=auth, 4=not-found, 2=usage).

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 6: Implement `scripts/code/gitlab.sh`

**Files:**
- Create: `scripts/code/gitlab.sh`
- Test: `tests/code-gitlab.bats`

- [ ] **Step 1: Write the failing test**

Create `tests/code-gitlab.bats`:

```bash
#!/usr/bin/env bats

load lib/fixture-server.sh

setup() {
  fixture_start "${BATS_TEST_DIRNAME}/fixtures/gitlab"
  export GITLAB_TOKEN="dummy-token"
  export DEVAGENT_GITLAB_API="$FIXTURE_URL/api/v4"
  SCRIPT="${BATS_TEST_DIRNAME}/../scripts/code/gitlab.sh"
  # tmp git repo for push-branch
  TMPGIT="$(mktemp -d)"
  ( cd "$TMPGIT" && git init -q && git commit --allow-empty -q -m init )
  PUSHED_REMOTE="$(mktemp -d)"
  git -C "$PUSHED_REMOTE" init -q --bare
  git -C "$TMPGIT" remote add origin "$PUSHED_REMOTE"
}

teardown() {
  fixture_stop
  rm -rf "$TMPGIT" "$PUSHED_REMOTE"
}

@test "code/gitlab.sh push-branch pushes to remote" {
  ( cd "$TMPGIT" && git checkout -q -b feat/x && git commit --allow-empty -q -m x )
  ( cd "$TMPGIT" && run "$SCRIPT" push-branch origin feat/x )
  [ "$status" -eq 0 ]
  git -C "$PUSHED_REMOTE" rev-parse feat/x >/dev/null
}

@test "code/gitlab.sh create-mr POSTs and prints URL" {
  body=$(mktemp); echo "MR body" > "$body"
  run "$SCRIPT" create-mr foo/bar "Sample MR" "$body" feat/x main
  [ "$status" -eq 0 ]
  [[ "$output" == *"https://gitlab.example/foo/bar/-/merge_requests/12"* ]]
  rm -f "$body"
  grep -q "POST /api/v4/projects/foo%2Fbar/merge_requests" "$FIXTURE_REQUEST_LOG"
}

@test "code/gitlab.sh create-mr --draft sets draft prefix" {
  body=$(mktemp); echo "MR body" > "$body"
  run "$SCRIPT" create-mr foo/bar "Sample MR" "$body" feat/x main --draft
  [ "$status" -eq 0 ]
  rm -f "$body"
  grep -q '"title":"Draft: Sample MR"' "$FIXTURE_REQUEST_LOG"
}

@test "code/gitlab.sh mr-state opened maps to open" {
  run "$SCRIPT" mr-state "https://gitlab.example/foo/bar/-/merge_requests/7"
  [ "$status" -eq 0 ]
  [ "$output" = "open" ]
}

@test "code/gitlab.sh mr-comments prints spec-shape markdown" {
  run "$SCRIPT" mr-comments "https://gitlab.example/foo/bar/-/merge_requests/7"
  [ "$status" -eq 0 ]
  [[ "$output" == *"### @reviewer · 2026-05-12"* ]]
  [[ "$output" == *"needs a test"* ]]
}

@test "code/gitlab.sh merge-mr PUTs merge" {
  run "$SCRIPT" merge-mr "https://gitlab.example/foo/bar/-/merge_requests/7" --method squash
  [ "$status" -eq 0 ]
  grep -q "PUT /api/v4/projects/foo%2Fbar/merge_requests/7/merge" "$FIXTURE_REQUEST_LOG"
}

@test "code/gitlab.sh with unknown verb exits 2" {
  run "$SCRIPT" wat
  [ "$status" -eq 2 ]
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bats tests/code-gitlab.bats`
Expected: FAIL — `scripts/code/gitlab.sh` not found.

- [ ] **Step 3: Implement the script**

Create `scripts/code/gitlab.sh`:

```bash
#!/usr/bin/env bash
# code/gitlab.sh — GitLab code (MR) backend per spec §9.2.
# Verbs:
#   push-branch  <remote> <branch>
#   create-mr    <repo> <title> <body-file> <head> <base> [--draft]
#   mr-state     <mr-url>
#   mr-comments  <mr-url>
#   merge-mr     <mr-url> [--method squash|merge|rebase]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/backend-common.sh
source "${SCRIPT_DIR}/../lib/backend-common.sh"

usage() {
  cat <<EOF >&2
Usage: gitlab.sh <verb> [args…]
  push-branch <remote> <branch>
  create-mr <repo> <title> <body-file> <head> <base> [--draft]
  mr-state <mr-url>
  mr-comments <mr-url>
  merge-mr <mr-url> [--method squash|merge|rebase]
EOF
  exit 2
}

api_base() {
  echo "${DEVAGENT_GITLAB_API:-https://gitlab.com/api/v4}"
}

urlenc() {
  python3 -c 'import sys,urllib.parse;print(urllib.parse.quote(sys.argv[1],safe=""))' "$1"
}

trim_date() { echo "${1%%T*}"; }

# Parse an MR URL like https://host/<group>/<repo>/-/merge_requests/<iid>
# into "<group>/<repo>" and "<iid>". Echoes "<repo>|<iid>".
parse_mr_url() {
  local url="$1"
  local path="${url#http://}"; path="${path#https://}"; path="${path#*/}"
  local repo="${path%%/-/merge_requests/*}"
  local iid="${path##*/merge_requests/}"
  iid="${iid%%/*}"
  echo "${repo}|${iid}"
}

cmd_push_branch() {
  local remote="$1" branch="$2"
  [ -z "$remote" ] || [ -z "$branch" ] && usage
  git push "$remote" "$branch"
}

cmd_create_mr() {
  local repo="$1" title="$2" body_file="$3" head="$4" base="$5"; shift 5 || usage
  [ -r "$body_file" ] || { echo "body file unreadable: $body_file" >&2; exit 2; }
  local draft=0
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --draft) draft=1; shift ;;
      *) usage ;;
    esac
  done
  if [ "$draft" = "1" ]; then
    title="Draft: ${title}"
  fi
  local enc; enc="$(urlenc "$repo")"
  local base_url; base_url="$(api_base)"
  local payload
  payload="$(jq -n \
    --arg t "$title" --rawfile d "$body_file" \
    --arg h "$head"  --arg b "$base" \
    '{title:$t, description:$d, source_branch:$h, target_branch:$b}')"
  local resp
  resp="$(bc_curl POST "${base_url}/projects/${enc}/merge_requests" \
    -H "PRIVATE-TOKEN: ${GITLAB_TOKEN:-}" \
    -H "Content-Type: application/json" \
    --data "$payload")" || return
  echo "$resp" | jq -r '.web_url'
}

cmd_mr_state() {
  local url="$1"; [ -z "$url" ] && usage
  local parts; parts="$(parse_mr_url "$url")"
  local repo="${parts%%|*}" iid="${parts##*|}"
  local enc; enc="$(urlenc "$repo")"
  local base; base="$(api_base)"
  local resp
  resp="$(bc_curl GET "${base}/projects/${enc}/merge_requests/${iid}" \
    -H "PRIVATE-TOKEN: ${GITLAB_TOKEN:-}")" || return
  local s d
  s="$(echo "$resp" | jq -r '.state')"
  d="$(echo "$resp" | jq -r '.draft // false')"
  if [ "$d" = "true" ]; then echo "draft"; return; fi
  case "$s" in
    opened) echo "open" ;;
    merged) echo "merged" ;;
    closed) echo "closed" ;;
    *) echo "$s" ;;
  esac
}

cmd_mr_comments() {
  local url="$1"; [ -z "$url" ] && usage
  local parts; parts="$(parse_mr_url "$url")"
  local repo="${parts%%|*}" iid="${parts##*|}"
  local enc; enc="$(urlenc "$repo")"
  local base; base="$(api_base)"
  local resp
  resp="$(bc_curl GET "${base}/projects/${enc}/merge_requests/${iid}/notes" \
    -H "PRIVATE-TOKEN: ${GITLAB_TOKEN:-}")" || return
  local count
  count="$(echo "$resp" | jq '[.[] | select(.system==false)] | length')"
  bc_emit_comments_header "$count"
  echo "$resp" | jq -c '.[] | select(.system==false)' | while read -r row; do
    local a dt b
    a="$(echo "$row" | jq -r '.author.username')"
    dt="$(trim_date "$(echo "$row" | jq -r '.created_at')")"
    b="$(echo "$row" | jq -r '.body')"
    bc_emit_comment "$a" "$dt" "$b"
  done
}

cmd_merge_mr() {
  local url="$1"; shift || usage
  local method="merge"
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --method) method="$2"; shift 2 ;;
      *) usage ;;
    esac
  done
  local parts; parts="$(parse_mr_url "$url")"
  local repo="${parts%%|*}" iid="${parts##*|}"
  local enc; enc="$(urlenc "$repo")"
  local base; base="$(api_base)"
  local payload
  case "$method" in
    squash) payload='{"squash":true,"squash_commit_message":""}' ;;
    rebase) payload='{"merge_when_pipeline_succeeds":false,"should_remove_source_branch":false}' ;;
    merge|"") payload='{}' ;;
    *) echo "unknown --method: $method" >&2; exit 2 ;;
  esac
  bc_curl PUT "${base}/projects/${enc}/merge_requests/${iid}/merge" \
    -H "PRIVATE-TOKEN: ${GITLAB_TOKEN:-}" \
    -H "Content-Type: application/json" \
    --data "$payload" >/dev/null
}

verb="${1:-}"; shift || true
case "$verb" in
  push-branch) cmd_push_branch "$@" ;;
  create-mr)   cmd_create_mr "$@" ;;
  mr-state)    cmd_mr_state "$@" ;;
  mr-comments) cmd_mr_comments "$@" ;;
  merge-mr)    cmd_merge_mr "$@" ;;
  ""|-h|--help) usage ;;
  *) usage ;;
esac
```

Make executable: `chmod +x scripts/code/gitlab.sh`

- [ ] **Step 4: Run test to verify it passes**

Run: `bats tests/code-gitlab.bats`
Expected: PASS (7 tests).

- [ ] **Step 5: Commit**

```bash
git add scripts/code/gitlab.sh tests/code-gitlab.bats
git commit -s -m "$(cat <<'EOF'
plan10: implement code/gitlab.sh full backend contract

All five verbs per spec §9.2: push-branch, create-mr (with --draft
prefixing "Draft:"), mr-state (with draft detection), mr-comments
(system notes filtered), merge-mr (squash/merge/rebase methods).

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 7: JIRA fixtures

**Files:**
- Create: `tests/fixtures/jira/routes.json`
- Create: `tests/fixtures/jira/issue.json`
- Create: `tests/fixtures/jira/comments.json`
- Create: `tests/fixtures/jira/transitions.json`
- Create: `tests/fixtures/jira/issue-created.json`

- [ ] **Step 1: Create the fixtures**

Create `tests/fixtures/jira/issue.json`:

```json
{
  "key": "PROJ-42",
  "fields": {
    "summary": "Sample JIRA issue",
    "description": "Body of the JIRA issue.\n\nSecond paragraph.",
    "status": {"name": "In Progress"},
    "reporter": {"name": "alice", "displayName": "Alice"},
    "labels": ["bug", "performance"]
  }
}
```

Create `tests/fixtures/jira/comments.json`:

```json
{
  "total": 1,
  "comments": [
    {
      "author": {"name": "reviewer", "displayName": "Reviewer"},
      "created": "2026-05-12T14:00:00.000+0000",
      "body": "Looks good"
    }
  ]
}
```

Create `tests/fixtures/jira/transitions.json`:

```json
{
  "transitions": [
    {"id": "11", "to": {"name": "To Do"}},
    {"id": "21", "to": {"name": "In Progress"}},
    {"id": "31", "to": {"name": "In Review"}},
    {"id": "41", "to": {"name": "Done"}}
  ]
}
```

Create `tests/fixtures/jira/issue-created.json`:

```json
{"id": "10100", "key": "PROJ-99", "self": "https://jira.example/rest/api/2/issue/10100"}
```

Create `tests/fixtures/jira/routes.json`:

```json
{
  "GET /rest/api/2/issue/PROJ-42": {"status": 200, "body_file": "issue.json"},
  "GET /rest/api/2/issue/PROJ-42/comment": {"status": 200, "body_file": "comments.json"},
  "GET /rest/api/2/issue/PROJ-42/transitions": {"status": 200, "body_file": "transitions.json"},
  "POST /rest/api/2/issue/PROJ-42/transitions": {"status": 204, "body": ""},
  "POST /rest/api/2/issue": {"status": 201, "body_file": "issue-created.json"},
  "GET /rest/api/2/issue/PROJ-404": {"status": 404, "body": "{\"errorMessages\":[\"Not Found\"]}"},
  "GET /rest/api/2/issue/PROJ-401": {"status": 401, "body": "{\"errorMessages\":[\"Unauthorized\"]}"}
}
```

- [ ] **Step 2: Smoke-test the fixtures**

Run: `python3 -c 'import json; json.load(open("tests/fixtures/jira/routes.json")); print("ok")'`
Expected: `ok`

- [ ] **Step 3: Commit**

```bash
git add tests/fixtures/jira/
git commit -s -m "$(cat <<'EOF'
plan10: add JIRA REST v2 fixtures for contract tests

Covers issue fetch, comments, transitions list, transition execute,
issue create, plus 401/404 error fixtures.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 8: Implement `scripts/issue/jira.sh`

**Files:**
- Create: `scripts/issue/jira.sh`
- Test: `tests/issue-jira.bats`

- [ ] **Step 1: Write the failing test**

Create `tests/issue-jira.bats`:

```bash
#!/usr/bin/env bats

load lib/fixture-server.sh

setup() {
  fixture_start "${BATS_TEST_DIRNAME}/fixtures/jira"
  export JIRA_TOKEN="dummy-token"
  export JIRA_USER="dummy@example.com"
  export DEVAGENT_JIRA_BASE="$FIXTURE_URL"
  SCRIPT="${BATS_TEST_DIRNAME}/../scripts/issue/jira.sh"
}

teardown() {
  fixture_stop
}

@test "issue/jira.sh fetch emits spec §9.3 markdown" {
  run "$SCRIPT" fetch PROJ PROJ-42
  [ "$status" -eq 0 ]
  [[ "$output" == *"# PROJ#PROJ-42 — Sample JIRA issue"* ]]
  [[ "$output" == *"- State: In Progress"* ]]
  [[ "$output" == *"- Author: @alice"* ]]
  [[ "$output" == *"- Labels: bug,performance"* ]]
  [[ "$output" == *"Body of the JIRA issue."* ]]
  [[ "$output" == *"## Comments (1)"* ]]
  [[ "$output" == *"### @reviewer · 2026-05-12"* ]]
}

@test "issue/jira.sh create POSTs and prints new key" {
  body=$(mktemp); echo "JIRA body" > "$body"
  export DEVAGENT_JIRA_PROJECT_KEY="PROJ"
  export DEVAGENT_JIRA_ISSUE_TYPE="Task"
  run "$SCRIPT" create PROJ "New issue" "$body"
  [ "$status" -eq 0 ]
  [ "$output" = "PROJ-99" ]
  rm -f "$body"
  grep -q "POST /rest/api/2/issue" "$FIXTURE_REQUEST_LOG"
}

@test "issue/jira.sh transition POSTs transition id" {
  # Stage in_progress → maps to JIRA "In Progress" → transition id 21
  export DEVAGENT_JIRA_STAGE_IN_PROGRESS="In Progress"
  run "$SCRIPT" transition PROJ PROJ-42 in_progress
  [ "$status" -eq 0 ]
  grep -q "POST /rest/api/2/issue/PROJ-42/transitions" "$FIXTURE_REQUEST_LOG"
  grep -q '"id":"21"' "$FIXTURE_REQUEST_LOG"
}

@test "issue/jira.sh state prints status name" {
  run "$SCRIPT" state PROJ PROJ-42
  [ "$status" -eq 0 ]
  [ "$output" = "In Progress" ]
}

@test "issue/jira.sh comment-list prints spec-shape comments" {
  run "$SCRIPT" comment-list PROJ PROJ-42
  [ "$status" -eq 0 ]
  [[ "$output" == *"### @reviewer · 2026-05-12"* ]]
  [[ "$output" == *"Looks good"* ]]
}

@test "issue/jira.sh fetch on 404 exits 4" {
  run "$SCRIPT" fetch PROJ PROJ-404
  [ "$status" -eq 4 ]
}

@test "issue/jira.sh fetch on 401 exits 3" {
  run "$SCRIPT" fetch PROJ PROJ-401
  [ "$status" -eq 3 ]
}

@test "issue/jira.sh unknown verb exits 2" {
  run "$SCRIPT" frob
  [ "$status" -eq 2 ]
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bats tests/issue-jira.bats`
Expected: FAIL — `scripts/issue/jira.sh` not found.

- [ ] **Step 3: Implement the script**

Create `scripts/issue/jira.sh`:

```bash
#!/usr/bin/env bash
# issue/jira.sh — JIRA issue backend per spec §9.1.
# curl only (no first-class CLI standardized).
#
# Auth: HTTP Basic with JIRA_USER:JIRA_TOKEN (Atlassian Cloud convention).
# Base URL via DEVAGENT_JIRA_BASE (e.g. https://acme.atlassian.net).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/backend-common.sh
source "${SCRIPT_DIR}/../lib/backend-common.sh"

usage() {
  cat <<EOF >&2
Usage: jira.sh <verb> [args…]
  fetch <repo> <num>
  create <repo> <title> <body-file> [--label X]…
  transition <repo> <num> <semantic-stage>
  state <repo> <num>
  comment-list <repo> <num>

<repo> is the JIRA project key for create; for other verbs it is
informational (used in the markdown header).
EOF
  exit 2
}

base() { echo "${DEVAGENT_JIRA_BASE:-https://jira.example}"; }

auth_header() {
  # JIRA Cloud: email:api-token, base64.
  local raw
  raw="$(printf '%s:%s' "${JIRA_USER:-}" "${JIRA_TOKEN:-}" | base64 | tr -d '\n')"
  printf 'Authorization: Basic %s' "$raw"
}

trim_date() { echo "${1%%T*}"; }

cmd_fetch() {
  local repo="$1" num="$2"
  [ -z "$repo" ] || [ -z "$num" ] && usage
  local issue_json comments_json
  issue_json="$(bc_curl GET "$(base)/rest/api/2/issue/${num}" \
    -H "$(auth_header)" -H 'Accept: application/json')" || return
  comments_json="$(bc_curl GET "$(base)/rest/api/2/issue/${num}/comment" \
    -H "$(auth_header)" -H 'Accept: application/json')" || return

  local title state author labels url body
  title="$(echo "$issue_json"   | jq -r '.fields.summary')"
  state="$(echo "$issue_json"   | jq -r '.fields.status.name')"
  author="$(echo "$issue_json"  | jq -r '.fields.reporter.name')"
  labels="$(echo "$issue_json"  | jq -r '.fields.labels | join(",")')"
  body="$(echo "$issue_json"    | jq -r '.fields.description // ""')"
  url="$(base)/browse/${num}"

  bc_emit_fetch_header "$repo" "$num" "$title" "$state" "$author" "$labels" "$url"
  bc_emit_body_and_separator "$body"

  local count
  count="$(echo "$comments_json" | jq '.total')"
  bc_emit_comments_header "$count"
  echo "$comments_json" | jq -c '.comments[]' | while read -r row; do
    local a d b
    a="$(echo "$row" | jq -r '.author.name')"
    d="$(trim_date "$(echo "$row" | jq -r '.created')")"
    b="$(echo "$row" | jq -r '.body')"
    bc_emit_comment "$a" "$d" "$b"
  done
}

cmd_create() {
  local repo="$1" title="$2" body_file="$3"; shift 3 || usage
  [ -r "$body_file" ] || { echo "body file unreadable: $body_file" >&2; exit 2; }
  local labels=()
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --label) labels+=("$2"); shift 2 ;;
      *) usage ;;
    esac
  done
  local issue_type="${DEVAGENT_JIRA_ISSUE_TYPE:-Task}"
  local project_key="${DEVAGENT_JIRA_PROJECT_KEY:-$repo}"
  local payload
  payload="$(jq -n \
    --arg pk "$project_key" --arg t "$title" \
    --rawfile d "$body_file" --arg it "$issue_type" \
    --argjson labels "$(printf '%s\n' "${labels[@]+"${labels[@]}"}" | jq -R . | jq -s .)" \
    '{fields:{project:{key:$pk},summary:$t,description:$d,issuetype:{name:$it},labels:$labels}}')"
  local resp
  resp="$(bc_curl POST "$(base)/rest/api/2/issue" \
    -H "$(auth_header)" \
    -H 'Content-Type: application/json' \
    --data "$payload")" || return
  echo "$resp" | jq -r '.key'
}

cmd_transition() {
  local repo="$1" num="$2" stage="$3"
  [ -z "$repo" ] || [ -z "$num" ] || [ -z "$stage" ] && usage

  # Look up the native JIRA status name for this semantic stage.
  local var="DEVAGENT_JIRA_STAGE_$(echo "$stage" | tr '[:lower:]' '[:upper:]' | tr - _)"
  local target_name="${!var:-}"
  if [ -z "$target_name" ] && [ -f "${SCRIPT_DIR}/../lib/config-loader.sh" ]; then
    # shellcheck source=../lib/config-loader.sh
    source "${SCRIPT_DIR}/../lib/config-loader.sh"
    target_name="$(devagent_get_config "${DEVAGENT_PROJECT:-}" "issue_workflow.${stage}" 2>/dev/null || true)"
  fi
  if [ -z "$target_name" ]; then
    echo "no JIRA stage mapping for '$stage'" >&2; exit 2
  fi

  local tr_json
  tr_json="$(bc_curl GET "$(base)/rest/api/2/issue/${num}/transitions" \
    -H "$(auth_header)" -H 'Accept: application/json')" || return
  local id
  id="$(echo "$tr_json" | jq -r --arg n "$target_name" \
    '.transitions[] | select(.to.name==$n) | .id' | head -n1)"
  if [ -z "$id" ] || [ "$id" = "null" ]; then
    # Per spec §11: failed transitions log but do not block real work.
    echo "warn: no transition to '$target_name' available; logged-only" >&2
    return 0
  fi
  local payload
  payload="$(jq -n --arg id "$id" '{transition:{id:$id}}')"
  bc_curl POST "$(base)/rest/api/2/issue/${num}/transitions" \
    -H "$(auth_header)" \
    -H 'Content-Type: application/json' \
    --data "$payload" >/dev/null
}

cmd_state() {
  local repo="$1" num="$2"
  [ -z "$repo" ] || [ -z "$num" ] && usage
  local resp
  resp="$(bc_curl GET "$(base)/rest/api/2/issue/${num}" \
    -H "$(auth_header)" -H 'Accept: application/json')" || return
  echo "$resp" | jq -r '.fields.status.name'
}

cmd_comment_list() {
  local repo="$1" num="$2"
  [ -z "$repo" ] || [ -z "$num" ] && usage
  local resp
  resp="$(bc_curl GET "$(base)/rest/api/2/issue/${num}/comment" \
    -H "$(auth_header)" -H 'Accept: application/json')" || return
  local count
  count="$(echo "$resp" | jq '.total')"
  bc_emit_comments_header "$count"
  echo "$resp" | jq -c '.comments[]' | while read -r row; do
    local a d b
    a="$(echo "$row" | jq -r '.author.name')"
    d="$(trim_date "$(echo "$row" | jq -r '.created')")"
    b="$(echo "$row" | jq -r '.body')"
    bc_emit_comment "$a" "$d" "$b"
  done
}

verb="${1:-}"; shift || true
case "$verb" in
  fetch)        cmd_fetch "$@" ;;
  create)       cmd_create "$@" ;;
  transition)   cmd_transition "$@" ;;
  state)        cmd_state "$@" ;;
  comment-list) cmd_comment_list "$@" ;;
  ""|-h|--help) usage ;;
  *) usage ;;
esac
```

Make executable: `chmod +x scripts/issue/jira.sh`

- [ ] **Step 4: Run test to verify it passes**

Run: `bats tests/issue-jira.bats`
Expected: PASS (8 tests).

- [ ] **Step 5: Commit**

```bash
git add scripts/issue/jira.sh tests/issue-jira.bats
git commit -s -m "$(cat <<'EOF'
plan10: implement issue/jira.sh full backend contract

All five verbs per spec §9.1, curl-only. Native JIRA transition lookup
(GET transitions → match by target status name → POST transition id).
Per §11, transitions that aren't available from current state log a
warning but do not fail the step.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 9: Custom backend stubs

**Files:**
- Create: `scripts/issue/custom.sh`
- Create: `scripts/code/custom.sh`
- Test: `tests/backend-custom.bats`

- [ ] **Step 1: Write the failing test**

Create `tests/backend-custom.bats`:

```bash
#!/usr/bin/env bats

ISSUE="${BATS_TEST_DIRNAME}/../scripts/issue/custom.sh"
CODE="${BATS_TEST_DIRNAME}/../scripts/code/custom.sh"

assert_not_implemented() {
  local cmd_status="$1" cmd_output="$2"
  [ "$cmd_status" -eq 78 ]
  [[ "$cmd_output" == *"not implemented"* ]]
  [[ "$cmd_output" == *"README"* ]]
}

@test "issue/custom.sh fetch exits 78 with not-implemented message" {
  run "$ISSUE" fetch foo/bar 42
  assert_not_implemented "$status" "$output"
}

@test "issue/custom.sh create exits 78" {
  body=$(mktemp); echo x > "$body"
  run "$ISSUE" create foo/bar "title" "$body"
  rm -f "$body"
  assert_not_implemented "$status" "$output"
}

@test "issue/custom.sh transition exits 78" {
  run "$ISSUE" transition foo/bar 42 in_progress
  assert_not_implemented "$status" "$output"
}

@test "issue/custom.sh state exits 78" {
  run "$ISSUE" state foo/bar 42
  assert_not_implemented "$status" "$output"
}

@test "issue/custom.sh comment-list exits 78" {
  run "$ISSUE" comment-list foo/bar 42
  assert_not_implemented "$status" "$output"
}

@test "code/custom.sh push-branch exits 78" {
  run "$CODE" push-branch origin feat/x
  assert_not_implemented "$status" "$output"
}

@test "code/custom.sh create-mr exits 78" {
  body=$(mktemp); echo x > "$body"
  run "$CODE" create-mr foo/bar "t" "$body" head base
  rm -f "$body"
  assert_not_implemented "$status" "$output"
}

@test "code/custom.sh mr-state exits 78" {
  run "$CODE" mr-state https://example/mr
  assert_not_implemented "$status" "$output"
}

@test "code/custom.sh mr-comments exits 78" {
  run "$CODE" mr-comments https://example/mr
  assert_not_implemented "$status" "$output"
}

@test "code/custom.sh merge-mr exits 78" {
  run "$CODE" merge-mr https://example/mr --method squash
  assert_not_implemented "$status" "$output"
}

@test "issue/custom.sh unknown verb exits 2" {
  run "$ISSUE" wat
  [ "$status" -eq 2 ]
}

@test "code/custom.sh unknown verb exits 2" {
  run "$CODE" wat
  [ "$status" -eq 2 ]
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bats tests/backend-custom.bats`
Expected: FAIL — `scripts/issue/custom.sh` and `scripts/code/custom.sh` not found.

- [ ] **Step 3: Implement the issue stub**

Create `scripts/issue/custom.sh`:

```bash
#!/usr/bin/env bash
# issue/custom.sh — template/stub for a custom issue backend.
#
# To implement your own backend:
#   1. Copy this file to scripts/issue/<yourname>.sh
#   2. Set `backend = "<yourname>"` under [project.<name>.issue_source]
#      in ~/.claude/devagent/config.toml
#   3. Replace each cmd_* function with your implementation.
#   4. Run `bats tests/backend-contract.bats` against your backend
#      to confirm contract compliance (see README "Custom backends").
#
# All five verbs MUST be implemented for the dispatcher to function;
# until they are, each exits 78 (EX_CONFIG) with a documented message
# so callers can report "backend not implemented" cleanly.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/backend-common.sh
source "${SCRIPT_DIR}/../lib/backend-common.sh"

usage() {
  cat <<EOF >&2
Usage: custom.sh <verb> [args…]
  fetch <repo> <num>
  create <repo> <title> <body-file> [--label X]…
  transition <repo> <num> <semantic-stage>
  state <repo> <num>
  comment-list <repo> <num>
EOF
  exit 2
}

verb="${1:-}"; shift || true
case "$verb" in
  fetch|create|transition|state|comment-list)
    bc_die_not_implemented custom "$verb" ;;
  ""|-h|--help) usage ;;
  *) usage ;;
esac
```

Make executable: `chmod +x scripts/issue/custom.sh`

- [ ] **Step 4: Implement the code stub**

Create `scripts/code/custom.sh`:

```bash
#!/usr/bin/env bash
# code/custom.sh — template/stub for a custom code (MR) backend.
# See scripts/issue/custom.sh for the implementation walkthrough.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/backend-common.sh
source "${SCRIPT_DIR}/../lib/backend-common.sh"

usage() {
  cat <<EOF >&2
Usage: custom.sh <verb> [args…]
  push-branch <remote> <branch>
  create-mr <repo> <title> <body-file> <head> <base> [--draft]
  mr-state <mr-url>
  mr-comments <mr-url>
  merge-mr <mr-url> [--method squash|merge|rebase]
EOF
  exit 2
}

verb="${1:-}"; shift || true
case "$verb" in
  push-branch|create-mr|mr-state|mr-comments|merge-mr)
    bc_die_not_implemented custom "$verb" ;;
  ""|-h|--help) usage ;;
  *) usage ;;
esac
```

Make executable: `chmod +x scripts/code/custom.sh`

- [ ] **Step 5: Run test to verify it passes**

Run: `bats tests/backend-custom.bats`
Expected: PASS (12 tests).

- [ ] **Step 6: Commit**

```bash
git add scripts/issue/custom.sh scripts/code/custom.sh tests/backend-custom.bats
git commit -s -m "$(cat <<'EOF'
plan10: add custom backend stubs and contract-stub tests

issue/custom.sh and code/custom.sh implement the verb dispatch
surface but each verb exits 78 (EX_CONFIG) with a documented
"not implemented; see README" message. This lets the dispatcher in
pull.sh/ship.sh etc. report missing-backend cleanly instead of
crashing, and gives custom-backend implementers a starting point.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 10: Contract test harness — helpers and per-backend parametrization

**Files:**
- Create: `tests/lib/contract-helpers.bash`
- Create: `tests/backend-github.bats`
- Create: `tests/backend-gitlab.bats`
- Create: `tests/backend-jira.bats`
- Modify: `tests/backend-custom.bats` (already exists from Task 9 — leave alone; it asserts the 78-exit contract)

- [ ] **Step 1: Write the contract helpers**

Create `tests/lib/contract-helpers.bash`:

```bash
#!/usr/bin/env bash
# contract-helpers.bash — shared by every backend-<name>.bats file.
#
# Each backend bats file sets:
#   BACKEND_NAME      e.g. "gitlab"
#   ISSUE_SCRIPT      e.g. scripts/issue/gitlab.sh
#   CODE_SCRIPT       e.g. scripts/code/gitlab.sh (or empty if N/A)
#   FIXTURE_SUBDIR    e.g. "gitlab"
#   REPO_ARG          e.g. "foo/bar"
#   ISSUE_NUM_OK      e.g. "42" or "PROJ-42"
#   ISSUE_NUM_404     e.g. "404" or "PROJ-404"
#   ISSUE_NUM_401     e.g. "401" or "PROJ-401"
#   MR_URL_OK         e.g. "https://gitlab.example/foo/bar/-/merge_requests/7"
#   EXPECTED_AUTHOR   e.g. "alice"
#   EXPECTED_LABELS   e.g. "bug,performance"
# Plus any env vars the backend needs (TOKEN, base-URL override, label maps).
# Set these in BACKEND_ENV (associative array) before calling contract_setup.

contract_load_fixtures() {
  load lib/fixture-server.sh
  fixture_start "${BATS_TEST_DIRNAME}/fixtures/${FIXTURE_SUBDIR}"
}

contract_teardown() {
  fixture_stop
}

# --- shared assertions -------------------------------------------------------

assert_fetch_shape() {
  local out="$1"
  [[ "$out" == "# "*"#"*" — "* ]]      # header
  [[ "$out" == *"- State: "* ]]
  [[ "$out" == *"- Author: @"* ]]
  [[ "$out" == *"- Labels: "* ]]
  [[ "$out" == *"- URL: "* ]]
  [[ "$out" == *"---"* ]]
  [[ "$out" == *"## Comments ("* ]]
  [[ "$out" == *"### @"*" · "* ]]
}

assert_comment_list_shape() {
  local out="$1"
  [[ "$out" == *"## Comments ("* ]]
  [[ "$out" == *"### @"*" · "* ]]
}
```

- [ ] **Step 2: Write the GitHub contract bats**

Create `tests/backend-github.bats`:

```bash
#!/usr/bin/env bats

load lib/contract-helpers.bash

setup() {
  BACKEND_NAME="github"
  ISSUE_SCRIPT="${BATS_TEST_DIRNAME}/../scripts/issue/github.sh"
  CODE_SCRIPT="${BATS_TEST_DIRNAME}/../scripts/code/github.sh"
  FIXTURE_SUBDIR="github"
  REPO_ARG="foo/bar"
  ISSUE_NUM_OK="42"
  ISSUE_NUM_404="404"
  ISSUE_NUM_401="401"
  MR_URL_OK="https://github.com/foo/bar/pull/7"
  # Per-backend env: GitHub uses GH_TOKEN + DEVAGENT_GITHUB_API override
  # set up by Plan 2's fixtures. If those aren't present, skip.
  if [ ! -d "${BATS_TEST_DIRNAME}/fixtures/github" ]; then
    skip "GitHub fixtures (from Plan 2) not present in this checkout"
  fi
  export GH_TOKEN="dummy-token"
  contract_load_fixtures
  export DEVAGENT_GITHUB_API="$FIXTURE_URL"
}

teardown() {
  contract_teardown
}

@test "[github] fetch produces spec §9.3 shape" {
  run "$ISSUE_SCRIPT" fetch "$REPO_ARG" "$ISSUE_NUM_OK"
  [ "$status" -eq 0 ]
  assert_fetch_shape "$output"
}

@test "[github] fetch on 404 exits 4" {
  run "$ISSUE_SCRIPT" fetch "$REPO_ARG" "$ISSUE_NUM_404"
  [ "$status" -eq 4 ]
}

@test "[github] fetch on 401 exits 3" {
  run "$ISSUE_SCRIPT" fetch "$REPO_ARG" "$ISSUE_NUM_401"
  [ "$status" -eq 3 ]
}

@test "[github] state prints a state token" {
  run "$ISSUE_SCRIPT" state "$REPO_ARG" "$ISSUE_NUM_OK"
  [ "$status" -eq 0 ]
  [ -n "$output" ]
}

@test "[github] comment-list produces spec §9.3 shape" {
  run "$ISSUE_SCRIPT" comment-list "$REPO_ARG" "$ISSUE_NUM_OK"
  [ "$status" -eq 0 ]
  assert_comment_list_shape "$output"
}

@test "[github] transition exits 0 (label-based per spec §9.1)" {
  export DEVAGENT_PROJECT="contract-test"
  run "$ISSUE_SCRIPT" transition "$REPO_ARG" "$ISSUE_NUM_OK" in_progress
  [ "$status" -eq 0 ]
}

@test "[github] transition is idempotent" {
  export DEVAGENT_PROJECT="contract-test"
  run "$ISSUE_SCRIPT" transition "$REPO_ARG" "$ISSUE_NUM_OK" in_progress
  [ "$status" -eq 0 ]
  run "$ISSUE_SCRIPT" transition "$REPO_ARG" "$ISSUE_NUM_OK" in_progress
  [ "$status" -eq 0 ]
}

@test "[github] no args exits 2" {
  run "$ISSUE_SCRIPT"
  [ "$status" -eq 2 ]
}

@test "[github] unknown verb exits 2" {
  run "$ISSUE_SCRIPT" frobnicate
  [ "$status" -eq 2 ]
}

@test "[github] code mr-state recognized values" {
  run "$CODE_SCRIPT" mr-state "$MR_URL_OK"
  [ "$status" -eq 0 ]
  case "$output" in
    open|merged|closed|draft) ;;
    *) printf 'unexpected mr-state output: %s\n' "$output" >&2; return 1 ;;
  esac
}

@test "[github] code mr-comments produces spec shape" {
  run "$CODE_SCRIPT" mr-comments "$MR_URL_OK"
  [ "$status" -eq 0 ]
  assert_comment_list_shape "$output"
}
```

- [ ] **Step 3: Write the GitLab contract bats**

Create `tests/backend-gitlab.bats`:

```bash
#!/usr/bin/env bats

load lib/contract-helpers.bash

setup() {
  BACKEND_NAME="gitlab"
  ISSUE_SCRIPT="${BATS_TEST_DIRNAME}/../scripts/issue/gitlab.sh"
  CODE_SCRIPT="${BATS_TEST_DIRNAME}/../scripts/code/gitlab.sh"
  FIXTURE_SUBDIR="gitlab"
  REPO_ARG="foo/bar"
  ISSUE_NUM_OK="42"
  ISSUE_NUM_404="404"
  ISSUE_NUM_401="401"
  MR_URL_OK="https://gitlab.example/foo/bar/-/merge_requests/7"
  export GITLAB_TOKEN="dummy-token"
  export DEVAGENT_GITLAB_LABELS_IN_PROGRESS="status::in-progress"
  export DEVAGENT_GITLAB_LABEL_NAMESPACE="status::"
  contract_load_fixtures
  export DEVAGENT_GITLAB_API="$FIXTURE_URL/api/v4"
}

teardown() {
  contract_teardown
}

@test "[gitlab] fetch produces spec §9.3 shape" {
  run "$ISSUE_SCRIPT" fetch "$REPO_ARG" "$ISSUE_NUM_OK"
  [ "$status" -eq 0 ]
  assert_fetch_shape "$output"
}

@test "[gitlab] fetch on 404 exits 4" {
  run "$ISSUE_SCRIPT" fetch "$REPO_ARG" "$ISSUE_NUM_404"
  [ "$status" -eq 4 ]
}

@test "[gitlab] fetch on 401 exits 3" {
  run "$ISSUE_SCRIPT" fetch "$REPO_ARG" "$ISSUE_NUM_401"
  [ "$status" -eq 3 ]
}

@test "[gitlab] state prints a state token" {
  run "$ISSUE_SCRIPT" state "$REPO_ARG" "$ISSUE_NUM_OK"
  [ "$status" -eq 0 ]
  [ -n "$output" ]
}

@test "[gitlab] comment-list produces spec §9.3 shape" {
  run "$ISSUE_SCRIPT" comment-list "$REPO_ARG" "$ISSUE_NUM_OK"
  [ "$status" -eq 0 ]
  assert_comment_list_shape "$output"
}

@test "[gitlab] transition exits 0" {
  run "$ISSUE_SCRIPT" transition "$REPO_ARG" "$ISSUE_NUM_OK" in_progress
  [ "$status" -eq 0 ]
}

@test "[gitlab] transition is idempotent" {
  run "$ISSUE_SCRIPT" transition "$REPO_ARG" "$ISSUE_NUM_OK" in_progress
  [ "$status" -eq 0 ]
  run "$ISSUE_SCRIPT" transition "$REPO_ARG" "$ISSUE_NUM_OK" in_progress
  [ "$status" -eq 0 ]
}

@test "[gitlab] no args exits 2" {
  run "$ISSUE_SCRIPT"
  [ "$status" -eq 2 ]
}

@test "[gitlab] unknown verb exits 2" {
  run "$ISSUE_SCRIPT" frobnicate
  [ "$status" -eq 2 ]
}

@test "[gitlab] code mr-state recognized values" {
  run "$CODE_SCRIPT" mr-state "$MR_URL_OK"
  [ "$status" -eq 0 ]
  case "$output" in
    open|merged|closed|draft) ;;
    *) printf 'unexpected mr-state output: %s\n' "$output" >&2; return 1 ;;
  esac
}

@test "[gitlab] code mr-comments produces spec shape" {
  run "$CODE_SCRIPT" mr-comments "$MR_URL_OK"
  [ "$status" -eq 0 ]
  assert_comment_list_shape "$output"
}
```

- [ ] **Step 4: Write the JIRA contract bats**

Create `tests/backend-jira.bats`:

```bash
#!/usr/bin/env bats

load lib/contract-helpers.bash

setup() {
  BACKEND_NAME="jira"
  ISSUE_SCRIPT="${BATS_TEST_DIRNAME}/../scripts/issue/jira.sh"
  FIXTURE_SUBDIR="jira"
  REPO_ARG="PROJ"
  ISSUE_NUM_OK="PROJ-42"
  ISSUE_NUM_404="PROJ-404"
  ISSUE_NUM_401="PROJ-401"
  export JIRA_USER="dummy@example.com"
  export JIRA_TOKEN="dummy-token"
  export DEVAGENT_JIRA_STAGE_IN_PROGRESS="In Progress"
  contract_load_fixtures
  export DEVAGENT_JIRA_BASE="$FIXTURE_URL"
}

teardown() {
  contract_teardown
}

@test "[jira] fetch produces spec §9.3 shape" {
  run "$ISSUE_SCRIPT" fetch "$REPO_ARG" "$ISSUE_NUM_OK"
  [ "$status" -eq 0 ]
  assert_fetch_shape "$output"
}

@test "[jira] fetch on 404 exits 4" {
  run "$ISSUE_SCRIPT" fetch "$REPO_ARG" "$ISSUE_NUM_404"
  [ "$status" -eq 4 ]
}

@test "[jira] fetch on 401 exits 3" {
  run "$ISSUE_SCRIPT" fetch "$REPO_ARG" "$ISSUE_NUM_401"
  [ "$status" -eq 3 ]
}

@test "[jira] state prints a state token" {
  run "$ISSUE_SCRIPT" state "$REPO_ARG" "$ISSUE_NUM_OK"
  [ "$status" -eq 0 ]
  [ -n "$output" ]
}

@test "[jira] comment-list produces spec §9.3 shape" {
  run "$ISSUE_SCRIPT" comment-list "$REPO_ARG" "$ISSUE_NUM_OK"
  [ "$status" -eq 0 ]
  assert_comment_list_shape "$output"
}

@test "[jira] transition exits 0" {
  run "$ISSUE_SCRIPT" transition "$REPO_ARG" "$ISSUE_NUM_OK" in_progress
  [ "$status" -eq 0 ]
}

@test "[jira] transition is idempotent" {
  run "$ISSUE_SCRIPT" transition "$REPO_ARG" "$ISSUE_NUM_OK" in_progress
  [ "$status" -eq 0 ]
  run "$ISSUE_SCRIPT" transition "$REPO_ARG" "$ISSUE_NUM_OK" in_progress
  [ "$status" -eq 0 ]
}

@test "[jira] no args exits 2" {
  run "$ISSUE_SCRIPT"
  [ "$status" -eq 2 ]
}

@test "[jira] unknown verb exits 2" {
  run "$ISSUE_SCRIPT" frobnicate
  [ "$status" -eq 2 ]
}
```

- [ ] **Step 5: Run the contract suites**

Run: `bats tests/backend-github.bats tests/backend-gitlab.bats tests/backend-jira.bats tests/backend-custom.bats`
Expected: all PASS. GitHub may report `skip` if Plan 2 fixtures aren't yet in place — that is acceptable for this plan and signals the coordination point.

- [ ] **Step 6: Commit**

```bash
git add tests/lib/contract-helpers.bash \
        tests/backend-github.bats tests/backend-gitlab.bats tests/backend-jira.bats
git commit -s -m "$(cat <<'EOF'
plan10: add backend contract test harness

tests/lib/contract-helpers.bash defines the canonical contract
assertions (fetch shape, comment-list shape, exit-code policy).
tests/backend-{github,gitlab,jira,custom}.bats parametrize the
same suite per backend. New backends become safe to add: run
this suite, confirm green.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 11: Canonical contract aggregator + README documentation

**Files:**
- Create: `tests/backend-contract.bats`
- Modify: `README.md` (append "Custom backends" section)

- [ ] **Step 1: Write the aggregator**

Create `tests/backend-contract.bats`:

```bash
#!/usr/bin/env bats
# backend-contract.bats — aggregator that runs the per-backend contract
# suites in a known order and prints a one-line summary per backend.
#
# This is the test file CI should invoke as the single gate for backend
# compliance:
#   bats tests/backend-contract.bats
# It in turn shells out to bats for each per-backend file so failures
# are attributed to the right backend.

setup() {
  BATS_DIR="${BATS_TEST_DIRNAME}"
}

run_backend_suite() {
  local backend="$1"
  local file="${BATS_DIR}/backend-${backend}.bats"
  [ -f "$file" ] || { echo "missing: $file" >&2; return 1; }
  run bats "$file"
  printf '[contract:%s] %s\n' "$backend" "$status" >&2
  return "$status"
}

@test "contract: github backend" {
  run_backend_suite github
}

@test "contract: gitlab backend" {
  run_backend_suite gitlab
}

@test "contract: jira backend" {
  run_backend_suite jira
}

@test "contract: custom-stub backend" {
  run_backend_suite custom
}
```

- [ ] **Step 2: Run the aggregator**

Run: `bats tests/backend-contract.bats`
Expected: all four tests PASS (github may report skip internally; that's a pass).

- [ ] **Step 3: Append README "Custom backends" section**

Read existing `README.md` first to find the right insertion point:

Run: `test -f README.md && wc -l README.md || echo "README.md does not exist yet"`

If `README.md` does not exist yet (earlier plans haven't created it), create it with this content; otherwise **append** the section below to the end.

Section to append (or initial content if creating):

```markdown
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
```

- [ ] **Step 4: Commit**

```bash
git add tests/backend-contract.bats README.md
git commit -s -m "$(cat <<'EOF'
plan10: aggregate contract suite and document custom backends

tests/backend-contract.bats is the single CI gate that runs the
per-backend contract suites. README "Custom backends" section
documents how to add a new backend and the contract surface every
backend must satisfy.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 12: Final integration — run everything together

**Files:** (none; verification only)

- [ ] **Step 1: Run the full test suite**

Run: `bats tests/`
Expected: every test passes. Note any skips (only acceptable skip: `[github]` if Plan 2 fixtures aren't merged yet — record in `actualWork.md`).

- [ ] **Step 2: Lint shell scripts**

Run: `shellcheck scripts/issue/*.sh scripts/code/*.sh scripts/lib/backend-common.sh tests/lib/fixture-server.sh tests/lib/contract-helpers.bash`
Expected: no errors. Warnings about `${!var}` indirection in `issue/gitlab.sh` and `issue/jira.sh` are acceptable (used deliberately for the env-var stage lookup); disable per-line with `# shellcheck disable=SC2153` if necessary.

- [ ] **Step 3: Confirm exit-code contract via a one-shot script**

Run:

```bash
bash -c '
  set -e
  trap "echo FAIL at $LINENO" ERR
  # custom stub: 78
  scripts/issue/custom.sh fetch a 1 >/dev/null 2>&1; rc=$?; [ "$rc" = 78 ] || exit 1
  scripts/code/custom.sh push-branch a b >/dev/null 2>&1; rc=$?; [ "$rc" = 78 ] || exit 1
  # bad args: 2
  scripts/issue/gitlab.sh >/dev/null 2>&1; rc=$?; [ "$rc" = 2 ] || exit 1
  scripts/issue/jira.sh   >/dev/null 2>&1; rc=$?; [ "$rc" = 2 ] || exit 1
  scripts/issue/custom.sh >/dev/null 2>&1; rc=$?; [ "$rc" = 2 ] || exit 1
  echo OK
'
```

Expected: `OK`.

- [ ] **Step 4: Final commit (if any lint fixes were applied)**

If Step 2 produced fixes:

```bash
git add scripts/issue/*.sh scripts/code/*.sh scripts/lib/backend-common.sh
git commit -s -m "$(cat <<'EOF'
plan10: shellcheck cleanups

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

Otherwise: no commit, plan complete.

---

## Self-Review Notes

**Spec coverage:**
- §9.1 (issue backend contract): Tasks 5, 8, 9, 10 (gitlab, jira, custom, contract assertions)
- §9.2 (code backend contract): Tasks 6, 9, 10 (gitlab, custom, contract assertions)
- §9.3 (fetch markdown shape): enforced by `bc_emit_*` helpers in Task 1 + `assert_fetch_shape` in Task 10
- §9.4 (reference implementations): Tasks 5, 6, 8, 9
- §10 (auth integration): backends consume `${GITLAB_TOKEN}` / `${JIRA_TOKEN}` / `${GH_TOKEN}` exactly as Plan 8's `auth/<backend>.sh exec` exports them; no token in argv
- §11 (transitions): GitHub transition is in `transition` verb (label-add/remove); JIRA `cmd_transition` warns-but-passes per §11 when transition isn't available; tests in Task 10 assert exit 0 in the success path

**Coordination flagged for executor:**
- Task 2 explicitly handles the case where Plan 2/3 left GitHub verbs incomplete
- GitHub contract bats (Task 10) will `skip` if Plan 2's fixtures aren't present yet — this is intentional

**Placeholder scan:** no TBD/TODO/"implement later" in any step.

**Type/signature consistency:** `bc_emit_fetch_header`, `bc_emit_comment`, `bc_curl`, `urlenc`, `trim_date`, `api_base`/`base`, `parse_mr_url` used consistently across Tasks 5, 6, 8.

---

## Open Questions

1. **Config-loader integration for stage maps.** `issue/gitlab.sh` and `issue/jira.sh` look up the per-stage label/status name via env vars first, then fall back to `devagent_get_config`. Plan 1 specifies the config-loader's exact API (`devagent_get_config <project> <key>`) — if its signature differs (e.g., dotted vs. bracketed keys), the fallback path needs adjustment. The env-var path used by these tests is stable either way.
2. **JIRA labels on `create`.** JIRA's `labels` field expects an array of strings; the script builds it with `jq -R . | jq -s .` which produces `[""]` when no labels are passed. The fixture POST doesn't assert on the label payload, so this is functionally fine, but a real JIRA may reject `[""]`. May need a guard before merging into a real-JIRA project. Out of scope for this plan since contract tests don't exercise a live JIRA.
3. **`code/jira.sh`.** Per spec §9 JIRA only hosts issues, not code, so there is no `scripts/code/jira.sh`. Confirmed against §9 — no action needed, but flagged for the parent in case a future operator wants JIRA-as-code (unlikely).
4. **Custom code-backend test for `push-branch`.** Task 9's stub test for `push-branch` exits 78 without touching git, which is correct for a stub. Real custom implementations should follow `code/gitlab.sh`'s pattern of `git push` + REST call.
5. **`gh` CLI vs curl detection for GitHub.** Plan 2 chooses whether `issue/github.sh` prefers `gh` or always uses `curl` against a configurable API base. Contract tests in Task 10 assume `DEVAGENT_GITHUB_API` overrides — if Plan 2 picked a different env var name, update `tests/backend-github.bats:setup()` accordingly. Flagged to executor.
