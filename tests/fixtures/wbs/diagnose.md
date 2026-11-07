# diagnose fixture

Characterization input for tests/test_wbs_diagnose.py (#726). Each planted
line carries a plant-<shape> marker; tests locate lines by marker, never by
number. The goldens beside this file are CLI output at the base commit.

- [ ] Root plant-root {issue: Issue-1, est: 1w, depends_on: Issue-9}
  - [ ] plant-trailing-key {issue: Issue-2, trailing}
  - [ ] plant-merged-key {issue: Issue-3, foo, est: 1w}
  - [ ] plant-unmatched-bracket {depends_on: [Issue-1, est: 1w }
  - [ ] plant-unterminated-quote {issue: Issue-4, owner: "bob, est: 1w}
  - [ ] plant-empty-key {issue: Issue-5, : 1w, est: 2h}
  - [ ] plant-duplicate-key {issue: Issue-6, est: 1w, est: 2w}
  - [ ] plant-unclosed-brace {issue: Issue-7, est: 1w
  - [ ] plant-swallowed-pair {issue: Issue-8 est: 1w}
  - [x] plant-dep-no-issue {depends_on: [Issue-1, Issue-2]}
  - [ ] plant-clean {issue: Issue-10, est: 1w}
  - [ ] plant-padded {issue: Issue-13 , est:  3h , depends_on: [ Issue-1 , , 'Issue-2', ], owner: 'ann', milestone: M1 }

- [X] plant-near-upper-x
* [ ] plant-near-star
+ [x] plant-near-plus
- [ ]
-[ ] a plant-near-nospace

- plain plant-control-plain

```text
- [X] plant-control-fenced
```

<!--
- [ ] plant-comment-node {issue: Issue-11}
-->

```text
- [ ] plant-after-unclosed {issue: Issue-12}
