<!--
Placeholder semantics (substituted by commit.sh):
  {{type}}   — branch prefix from .devagent-type via branch_prefix_map (e.g. "perf")
  {{title}}  — the contents of .devagent-title verbatim
  {{issue}}  — the active_issue directory name, including any "Issue-Fork-" prefix
               (e.g. "Issue-Fork-62", NOT "62"). For URLs that need just the number,
               author your template assuming the prefix is part of the substitution.
  {{note}}   — operator-supplied $NOTE from the slash-command tail (may be empty)

Commit conventions reference: docs/commit-conventions.md
Signed-off-by is appended automatically by `git commit -s`; do not add it here.
-->
{{type}}: {{title}}

Per-issue dev doc: {{issue}}/

{{note}}
