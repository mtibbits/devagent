---
description: Draft a pre-issue or epic capture under <devdoc>/Captures/<slug>/
allowed-tools: Bash, Read, Write, Edit, Skill
---

# /devagent:capture

Args: `[issue|epic] <free-form text>`

## Behavior

1. Parse args:
   - If first token is exactly `issue`, force-type = issue; remainder = text.
   - If first token is exactly `epic`, force-type = epic; remainder = text.
   - Otherwise, force-type is unset and the model decides.

2. Invoke the **devagent-capture** skill with the text and (if set) the
   forced type. The skill returns:
   - `type`: `issue` or `epic`
   - `subtype` (if issue): one of `bug feature docs perf chore`
   - `title`: a short title suitable for a slug
   - Optionally: a recommendation block such as
     `"this is 7 epics"` with proposed child titles. When the skill
     recommends a multi-epic split, do NOT call capture.sh seven times
     silently. Print the recommendation, ask the operator which epics
     to author, then author the chosen ones.

3. Call the script for each chosen artifact:

   ```bash
   scripts/capture/capture.sh \
     --type "<type>" \
     --subtype "<subtype>"  \
     --title "<title>"
   ```

   For epics, omit `--subtype`. The script prints the slug; record it.

4. Report each created `Captures/<slug>/draft.md` path to the operator
   and suggest the next step (`/devagent:redissue <slug>` or, for
   epics, `/devagent:scaffold <slug>`).

## Non-goals

This command does NOT file the issue to any tracker. Filing is the
job of `/devagent:file` and requires the `permissions.push_mr` gate.

## Env contract

The slash command relies on these env vars (set by the Phase 1
config loader; for now the operator sets them in their shell):

- `DEVAGENT_DEVDOC_DIR`
- `DEVAGENT_PLUGIN_DIR`
- `DEVAGENT_PROJECT`
