# testproj WBS

> Hand-arranged plan: the groupings, titles and prose are the operator's.

<!-- kept as written: wbs init --merge only inserts lines -->

- [~] Alpha work, hand title {issue: Issue-1}
  - [x] Task 2 {issue: Issue-2}
  - [~] Task 3 {issue: Issue-3}
    Note: task 3 waits on the vendor.

Issue-4 is planned.

- [ ] Misc
  - [ ] Task 7 {issue: Issue-7}
  - [-] Task 11 {issue: Issue-11, status_src: tracker}

```text
- [ ] Fenced {issue: Issue-9}
<!-- wbs-exclude: Issue-13 -->
```

<!-- wbs-exclude: Issue-12, Issue-1 -->

- [ ] Milestone one {milestone: M1}
  - [ ] Plan the release

## Notes

Trailing prose stays the last line.
