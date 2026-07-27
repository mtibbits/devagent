# Coding Standards (plugin default)

Project-specific override at `<devdoc>/templates/coding_standards.md` shadows
this file per spec §12. Override at `[project.<name>.paths].coding_standards`
in `config.toml` shadows both.

This default is intentionally minimal — operators are expected to maintain a
real per-project standards document. The default exists so `quality` (step 10)
and `review` (step 15) always have a file to read.

## Style

- Match existing code in the file you are editing.
- Don't reformat lines you didn't otherwise change.

## Comments

- Default to no comments. Add one only when the WHY is non-obvious.
- Never narrate WHAT well-named code already says.

## Tests

- Add tests for new behavior. Don't delete or weaken tests to make a fix pass.

## Commits

- One logical change per commit.
- Include `Signed-off-by:` (DCO).
- Subject ≤ 70 chars; body wraps at 72.
