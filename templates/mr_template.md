## Summary
<!-- What changed and why? One paragraph is fine. -->


## Related issues
<!-- Link issues: "Closes #NNN" auto-closes on merge. "Related: #NNN" for context only. -->


## Testing
<!-- How did you verify this? For performance changes, include benchmark output if available. -->


## Evidence
<!-- Filled by /devagent:draftmr from the newest analysis/<date>-suite-count.txt
     (run `bash "${CLAUDE_PLUGIN_ROOT}/scripts/run-suite.sh" <project> <Issue-N>` first —
     #572/#659: pass the project and the issue explicitly). Machine-checked by preship (#359) — do not
     hand-edit the lines below. The optional 'born-red:' line is filled from a
     born-red artifact (#362) when present.
     The suite: line names ONLY the frameworks the tree actually has (#466) — write
     whichever ONE of these four the artifact describes:
       both        ->  suite: <bats-ok>/<bats-plan> bats, <pytest-passed> pytest @ <sha>
       bats only   ->  suite: <bats-ok>/<bats-plan> bats @ <sha>
       pytest only ->  suite: <pytest-passed> pytest @ <sha>
       neither     ->  suite: none @ <sha>            (#411)
     "bats only" means the artifact reads `pytest: (none)`; never write ", 0 pytest" for
     an absent framework — it reads as a measured zero (#572 MINOR-5). An artifact
     reading `pytest: (error)` is NOT shippable at all: the suite was never measured;
     fix the interpreter and re-run run-suite.
     The platform: line (#654) is the artifact's own platform: line, copied whole and
     unchanged: preship compares the two byte for byte. Replace the placeholder below,
     or delete it when the artifact has no platform: line: left as it is, it fails
     preship even when nothing is declared. Once the checking config declares
     evidence_platforms, a block without the line fails too. -->
suite: <bats-ok>/<bats-plan> bats, <pytest-passed> pytest @ <sha>
files: <n> changed
platform: <replace this line with the artifact's platform: line, copied whole>


## Checklist
- [ ] Builds cleanly (`cmake --build`)
- [ ] Tests pass (`ctest`)
- [ ] Commits are signed off (`git commit -s`)
- [ ] PR does one thing — no unrelated changes mixed in
