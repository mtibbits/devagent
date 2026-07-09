---
description: "Initialize the per-issue checklist.md (default template: standard)."
allowed-tools: Bash
---

Run the shell script `scripts/checklist-init.sh` with the user's arguments. The
expected positional form is `[--template <name>] <issue-dir>`.

Forward all arguments verbatim. Surface stderr to the user.
