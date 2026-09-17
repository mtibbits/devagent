## Summary
<!-- What changed and why? One paragraph is fine. -->


## Related issues
<!-- "Closes #NNN" auto-closes on merge. "Related: #NNN" for context only. -->


## Testing
<!-- How did you verify this? Name the test that was red before the change and green after.
     If no test could be made to fail first, say so and what guards the change instead. -->


## Checklist
- [ ] Every commit is signed off (`git commit -s`, Developer Certificate of Origin)
- [ ] Commit subject reads `<type>: <title>` with issue references in the body
- [ ] Suite passes: `LC_ALL=C.UTF-8 bats tests/` and `python3 -m pytest tests/` (or `bash scripts/run-suite.sh <project>` if you run devAgent on this repo)
- [ ] A behaviour change ships with a test that was red first
- [ ] `shellcheck -x -s bash` is clean over touched files under `scripts/` and `hooks/`
- [ ] Docs updated in the same PR (README, `docs-site/`, the command body) where behaviour changed
- [ ] PR does one thing, with no unrelated changes mixed in
- [ ] No tool grant was widened beyond the quoted `${CLAUDE_PLUGIN_ROOT}/scripts/*` form
