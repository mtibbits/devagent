---
description: Fetch MR comments to <issue-dir>/revisions/r<N>/comments.md
argument-hint: "[project] [issue]"
allowed-tools: Bash(bash "${CLAUDE_PLUGIN_ROOT}/scripts/*"), Bash(bash "${CLAUDE_PLUGIN_ROOT}/scripts/*" *)
---

Run the comments script and report the result.

````bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/comments.sh" $ARGUMENTS
````

After it runs:
- Confirm `<issue-dir>/revisions/r<N>/comments.md` exists and report the comment count.
- If the script exited non-zero because `mr_url` is unset, tell the user to run `/devagent:ship` first.
- If it exited non-zero and stderr names `DEVAGENT_MR_COMMENTS_SKIP_INLINE` (github: inline review comments could not be fetched), relay that message. Suggest re-running first. If the user wants the fetch without inline comments, offer `DEVAGENT_MR_COMMENTS_SKIP_INLINE=1 bash "${CLAUDE_PLUGIN_ROOT}/scripts/comments.sh" $ARGUMENTS`: the file then ends with a line saying inline comments were not fetched.
- Do not invoke any other commands — `comments` does not chain.
