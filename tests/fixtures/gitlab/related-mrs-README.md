# `code/gitlab.sh issue-mrs` fixtures (#704)

Recorded response shapes for the GitLab `issue-mrs` verb, served by
`tests/fixtures/server.py` through `routes.json` (keys
`GET /api/v4/projects/<enc>/issues/<iid>/related_merge_requests?per_page=100`).

## Source

- Endpoint: `GET /projects/:id/issues/:iid/related_merge_requests`.
- Recorded 2026-10-13, unauthenticated, from gitlab.com against public project
  gitlab-org/cli (21 issues, among them #8597, whose related list carries
  !4013, an MR with no closing reference to it).
- Fields kept (the verb reads `state`, `draft` / `work_in_progress`,
  `references.full`, `title`, `description`, `created_at`, `merged_at`):
  `id iid project_id title description state created_at updated_at merged_at
  closed_at target_branch source_branch draft work_in_progress references
  web_url`, in the recorded order. Timestamps keep the recorded millisecond
  `Z` form (`2026-10-07T03:24:16.575Z` is !4013's `created_at`).

## Edits

- Pruned to the fields above; every other recorded field is dropped.
- Projects are renamed to `foo/bar` and its fork `me/bar`; numbers, titles,
  descriptions and timestamps are rewritten so that each file covers one row
  of the issue's tables:
  - `related-mrs-links.json` (issues 6, 7): !21 merged into the non-default
    target `dev/all-prs` with `Closes #6, #7 and grp/sub/bar#8`; !99 mentions
    #6 and #7 with no closing keyword.
  - `related-mrs-1.json` open > draft > merged; `-2.json` draft (legacy
    `work_in_progress` only, no `draft` key) > merged; `-3.json` merged >
    closed; issue 4 `[]`; `-13.json` closed-only; `-10.json` a `locked` MR
    (open).
  - `related-mrs-fork.json`: one fork MR `me/bar!3`, `Closes #5`, listed on
    both `foo/bar` #5 and `me/bar` #5.
  - `related-mrs-badstate.json`: a state outside opened/locked/closed/merged.
  - `related-mrs-full.json`: 100 entries, a full page (the verb's cap).
  - `project-bar.json`: the project probe after a 404.
