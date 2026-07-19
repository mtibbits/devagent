context: subagent
model: opus

# Improve findings — Issue-XYZ

## Summary
1 bug, 0 side-effects, 1 ambiguity

### Bugs
- Task 2 dereferences a pointer that Task 1 may leave null; add a guard.

### Ambiguities
- The encoding of the input string is unstated; assert UTF-8 or ask.
