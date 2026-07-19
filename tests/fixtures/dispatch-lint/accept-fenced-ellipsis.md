context: subagent
model: opus

# Review — Issue-XYZ

The changed hunk under test (elided for brevity):

```diff
-    old = compute(a)
...
+    new = compute(a, b)
```

The surrounding logic is unaffected and the tests cover the new branch.

## Blocking
None.
