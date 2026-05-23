# Fix off-by-one in foo_kernel

## Summary
Replaces `i <= n` with `i < n` in foo_kernel inner loop; adds
boundary test.

## Evidence
- test_foo_boundary added; passes.
- cppcheck: 0 findings.
