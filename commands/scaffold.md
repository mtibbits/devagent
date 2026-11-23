---
description: Bin an epic capture into child issue drafts under children/
allowed-tools: Bash(bash "${CLAUDE_PLUGIN_ROOT}/scripts/*"), Bash(bash "${CLAUDE_PLUGIN_ROOT}/scripts/*" *), Read, Write, Edit, Skill
argument-hint: "<capture-slug>"
---

# /devagent:scaffold

Args: `<capture-slug>`

## Behavior

1. Resolve `<devdoc>/Captures/<slug>/draft.md`. If `draft.md` does
   not start with `# Epic:`, abort with a clear error suggesting
   `/devagent:capture epic`.

2. Invoke the **core-scaffold** skill, passing `draft.md`. The
   skill returns an ordered list of child entries:

   ```
   - subtype: bug | feature | docs | perf | chore
     title:   <imperative title>
     summary: <one paragraph>
   ```

3. For each entry (1-indexed N), write the file:

   `<devdoc>/Captures/<slug>/children/NN-<kebab-title>.md`

   The body is the resolved `issue_template-<subtype>.md` with
   `{{title}}`, `{{project}}`, and `{{source}}` substituted. `{{source}}`
   becomes `Captures/<slug>/draft.md (scaffolded)`. Write the skill's
   `summary` for this child into the template's first section — the `<…>`
   placeholder under the `# {{title}}` heading, whose name varies by subtype
   (`## Summary` for bug, `## Motivation` for feature, `## Affected docs` for
   docs, `## Hot path` for perf, `## Scope` for chore). That is where the
   per-child summary lands (the skill forbids authoring the rest of the body).
   The template's `<!-- required-checks: … -->` marker line follows the
   rule `capture.sh` applies (#1097): run
   `bash "${CLAUDE_PLUGIN_ROOT}/scripts/required-checks.sh" "$DEVAGENT_PROJECT"`;
   when it prints one or more checks, replace the marker line with the
   required-check criterion comment `capture.sh` writes, naming them; when it
   prints nothing, or there is no `DEVAGENT_PROJECT`, delete the marker line.
   On a non-zero exit, report its stderr as a warning and delete the marker
   (scaffolding is not a gate).

4. Print the list of created child paths.

## Idempotence

If `children/` already contains files, refuse without `--force`. With
`--force`, overwrite by index — existing higher-N files that the new
scaffolding does not produce are left in place (do not delete).

## Env contract

Same as `/devagent:capture`.
