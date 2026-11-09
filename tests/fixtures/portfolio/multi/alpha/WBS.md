# alpha WBS

Fixture for tests/test_portfolio.py and tests/portfolio.bats (#726). Every
planted line carries a plant-<shape> marker; tests locate lines by marker.

<!-- wbs-exclude: bad/token -->
<!-- wbs-scope plant-scope -->

- [ ] Portfolio view plant-parent {est: 10.5pr}
  - [x] Schema plant-issue1 {issue: Issue-1, est: 6h, est_src: confirmed}
  - [~] Producer plant-issue2 {issue: Issue-2, est: 4h, est_src: derived, satisfies: [gantry:FR-12, gantry:UC-3], h: 3, objective: [gantry:UC-3], depends_on: [Issue-1, alpha:Issue-1, beta:Issue-1]}
  - [ ] Readiness plant-issue3 {issue: Issue-3, est: ?w}
  - [ ] Readiness again plant-dup3 {issue: Issue-3, est: 48pr, h: high}
  - [ ] Spike plant-noissue-est {est: 1d (actual ~14h), satisfies: gantry:FR-1, objective: gantry:FR-1}
  - [ ] Outline plant-outline {depends_on: [4.1]}
  - [ ] Cross plant-issue4 {issue: Issue-4, depends_on: [beta:Issue-99, nosuch:Issue-1, gamma:Issue-1]}
  - [ ] Guessed plant-est-src {issue: Issue-6, est: 2h, est_src: guessed}
  - [ ] Jira plant-jira {issue: Issue-7, jira: PROJ-1}
  - [ ] Merged plant-merged {issue: Issue-8, foo, est: 1w}
  - [ ] Bracket plant-bracket {issue: Issue-9, depends_on: [Issue-1, est: 1w}
  - [ ] Trailing plant-trailing {issue: Issue-10, trailing}
  - [ ] Duplicate key plant-dupkey {issue: Issue-11, est: 1w, est: 2w}
  - [ ] Swallowed plant-swallowed {issue: Issue-12 est: 1w}
  - [ ] Two issues plant-issue-list {issue: [Issue-13, Issue-14]}
  - [ ] Not an id plant-not-id {issue: GH-726!}
  - [ ] Stuck unreadable plant-issue5 {issue: Issue-5, est: 2h}

- [X] near plant-near-x
* [ ] near plant-near-star

```text
- [X] fenced plant-fenced
```
