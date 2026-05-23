---
description: Fetch MR comments to <issue-dir>/revisions/r<N>/comments.md
argument-hint: "[project] [issue]"
allowed-tools: Bash
---

Run the comments script and report the result.

````bash
bash "$CLAUDE_PLUGIN_ROOT/scripts/comments.sh" $ARGUMENTS
````

After it runs:
- Confirm `<issue-dir>/revisions/r<N>/comments.md` exists and report the comment count.
- If the script exited non-zero because `mr_url` is unset, tell the user to run `/devagent:ship` first.
- Do not invoke any other commands — `comments` does not chain.
