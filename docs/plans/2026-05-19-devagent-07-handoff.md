# Phase 7 Handoff — interfaces consumed and exposed

## Consumed (must exist before phase 7 ships)

### From Plan 1 (foundation)
- `scripts/lib/log.sh`         → `devagent_log <level> <msg>`
- `scripts/lib/config-loader.sh` → `devagent_load_config` sets:
  - `DEVAGENT_PROJECT`
  - `DEVAGENT_DEVDOC_DIR`
  - `DEVAGENT_STATE_DIR`
  - `DEVAGENT_PERM_COMMIT_DEVDOC`  ("true"/"false")
- `scripts/lib/checklist.sh`   → `checklist_log_entries <path>` emits one JSON object per line: `{"ts": "...", "step": "...", "message": "..."}`. Phase 7 currently reimplements this in Python (`statusreport-detect._parse_log_entries`) for test isolation; before Plan 1 merges, switch the Python helper to shell out to `checklist_log_entries`.

### From Plan 2 (state)
- `scripts/lib/state.sh`       → `state_get <file> <key>` / `state_set <file> <key> <value>`
- State schema for `~/.claude/devagent/state/<project>.statusreport.toml`:
  - `last_pin = "ISO-8601 timestamp"`
  - `last_pin_by = "username"`

### From Plan 3 (cleanup)
- Issue checklist log entries with `step = "cleanup"` mark completion (used for velocity).

## Exposed (downstream plans may consume)

### To workflow (Plan 4)
- `/devagent:updatewbs` slash command (= `/devagent:wbs update`).
  Workflow step 17 invokes this.

### To capture family (Plan 5)
- `/devagent:wbs update` is reentrant; capture flows should call it
  after creating new issues so the WBS gains an "Unassigned" entry
  per new issue.

### To doctor (Plan 1 or 9)
- `<devdoc>/WBS.md` should be checked for parse-cleanness.
  `scripts/lib/wbs-parser.py parse <path>` returns non-zero on
  malformed input (today: only on missing file; future tasks can
  tighten validation).

### To v2/v3 (out of scope)
- `wbs-parser.py` produces a stable JSON tree designed to feed:
  - mermaid/PlantUML Gantt renderer
  - MS Project XML (mspdi) exporter
  - OpenProject REST API poster
  No schema migration is anticipated. Unknown metadata keys are
  preserved on `meta` and surfaced on `meta_unknown_keys` so a
  renderer can pass-through or warn.
