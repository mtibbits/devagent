## Summary
<!-- What changed and why? One paragraph is fine. -->


## Related issues
<!-- Link issues: "Closes #NNN" auto-closes on merge. "Related: #NNN" for context only. -->


## Testing
<!-- How did you verify this? For performance changes, include benchmark output if available. -->


## Evidence
<!-- Filled by /devagent:draftmr from the newest analysis/<date>-suite-count.txt
     (run /devagent:run-suite first). Machine-checked by preship (#359) — do not
     hand-edit the two lines below. The optional 'born-red:' line is filled from a
     born-red artifact (#362) when present.
     A project with NEITHER bats nor pytest uses the no-framework form instead:
       suite: none @ <sha>
     (preship reconciles it against a `bats: (none)` + `pytest: (none)` artifact — #411). -->
suite: <bats-ok>/<bats-plan> bats, <pytest-passed> pytest @ <sha>
files: <n> changed


## Checklist
- [ ] Builds cleanly (`cmake --build`)
- [ ] Tests pass (`ctest`)
- [ ] Commits are signed off (`git commit -s`)
- [ ] PR does one thing — no unrelated changes mixed in
