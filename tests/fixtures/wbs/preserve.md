<!-- hand-written note above the title -->
#  preserve  WBS

> Source-of-truth for work-breakdown structure. Edited by hand and by
> `/devagent:wbs update`.
>
> Recognized keys (v1): issue, est, cost, owner, milestone, start, due, depends_on

Prose paragraph under the preamble.

## Milestone one

- [ ] Epic one {est: "4w", milestone: M1, note: 'two words'}
  <!-- comment between nodes -->
  - [ ] Leaf A {issue: Issue-1,est:1w}
    Note under Leaf A; it must not make Leaf A a non-leaf.
  - [~] Leaf B {issue: Issue-2, est: 1w, depends_on: Issue-1}
  - [x] Leaf C {}


```text
- [ ] Fenced example {issue: Issue-9, depends_on: Issue-1}
# Fenced heading
```

- plain list item
* [ ] star checkbox {issue: Issue-8}
+ [ ] plus checkbox {issue: Issue-6}

- [ ] Epic two {est: 2w}
  - [ ] Leaf D {issue: Issue-3, est: 1w}
    Note under the last leaf.

## Notes

Trailing prose after the last node.
