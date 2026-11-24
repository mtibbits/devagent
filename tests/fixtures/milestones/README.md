# `milestones` fixtures (#734)

Checklists and tracker/forge replies for `scripts/lib/milestones.py`
(`tests/test_milestones.py`) and `scripts/milestones.sh`
(`tests/milestones.bats`).

## Private-content rule

No line in this directory is copied from a private project's checklist,
and no private project is named. Checklist text is synthesised; only its
SHAPES come from the corpus measured at #734's draft (746 checklists under
the devdoc, 16,722 dated `## Log` lines), and the only sources cited are
public: devagent's own checklists and volk's.

## Checklists

- `rev2/Issue-465/checklist.md`: the shape of devagent `Issue-465` (a
  standard checklist whose Log carries `revise: revision 2 started, 0
  comments to address` partway through, with the `## Revision 2` block
  after the Log). `Created:` carries `-04:00`, as 262 corpus files do.
- `shapes/Issue-700/checklist.md`: the real shapes the parser must
  classify, in one file: a step logged twice (`analyze`), `park`/`resume`,
  non-step names (`reap`, `sync`, `quality-fix`), a numbered name (`17:`),
  a name holding a space and parentheses (`real-silicon (prior session):`),
  a retier line (`revise: retier: … (revision 2)`, as `scripts/revise.sh`
  writes it) followed by a step line and a matching `## Revision 2` block,
  one date-only line (the volk `Issue-Fork-*` shape, 8 in the corpus) and
  one dated line outside `## Log` (1 in the corpus). `Created:` is devagent
  Issue-700's `-04:00` offset.
- `mismatch/Issue-9/checklist.md`: a `## Revision 2` heading with no logged
  revision start (a hand-opened Revision block), the start-count
  cross-check's fixture.

## Tracker and forge replies

- `gh-issue-list.json`: `tests/fixtures/issue-github/issue-list-shaped.json`
  (the recorded `gh issue list --json …` structure, provenance in
  `tests/fixtures/wbs-import/make-fixtures.py`) cut to issues 6 and 7. Issue
  6 is unchanged (closed 2026-01-13 → 2026-02-08, `COMPLETED`); issue 7 is
  edited to `OPEN` (`stateReason` and `closedAt` null). The AC1 test pairs
  it with `tests/fixtures/code-github/issue-mrs-links.json`, whose PRs #21
  and #22 close issue 6.
- `gitlab/`: a server dir of its own (`tests/fixtures/server.py`), so the
  shared `tests/fixtures/gitlab/routes.json` is untouched. Project `foo/bar`
  (the repo `related-mrs-3.json`'s MRs `foo/bar!51`/`!52` resolve `#3`
  against). `issues-page1.json` keeps `tests/fixtures/gitlab/issues-page1.json`'s
  recorded fields for its first three issues, renumbered 1-3: 1 and 2 open,
  3 closed (created 2026-06-20, closed 2026-07-05), no blocking issues, so
  `issue/gitlab.sh issue-list` asks for one page and no `links`.
  `related-mrs-3.json` is a copy of the shared fixture (!51 merged, !52
  closed unmerged); issues 1 and 2 answer `[]`.
