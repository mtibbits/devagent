# `code/github.sh issue-mrs` fixtures (#704)

Recorded response shapes for the GitHub `issue-mrs` verb, replayed by the
gh-stub's `api graphql` arm (`tests/fixtures/gh-stub`, `$GH_STUB_GRAPHQL_DIR`).

## Source

- Query: the verb's batch query (`issue(number:$nK){ timelineItems(itemTypes:
  [CROSS_REFERENCED_EVENT], first:100){...P} }` per alias, fragment `P` =
  `totalCount pageInfo{hasNextPage endCursor} nodes{ ... on CrossReferencedEvent
  { source { __typename ... on PullRequest { number title body state isDraft
  createdAt mergedAt repository{nameWithOwner} } } } }`).
- Recorded 2026-10-13 with gh 2.95.0 (Windows) against public repositories:
  50 open issues of cli/cli, and 51 issues of
  mtibbits/devagent (including #148, whose closing PR #152 targets the
  non-default base `chore/shellcheck-scripts-review-followups`).
- The per-alias NOT_FOUND shape (`errors[].type == "NOT_FOUND"`, `path ==
  ["repository","i<k>"]`, the alias `null`, gh exit 1 with the JSON still on
  stdout) was recorded from a real alias query for a number that is not an issue.

## Edits

Every file keeps the recorded structure (keys, nesting, value types, `Issue`
sources with no other fields, cursor format). Edited:

- Repository names are rewritten to `acme/testproj` and `me/testproj-fork`.
- PR numbers, titles, bodies and timestamps are rewritten so that each file
  covers one row of the issue's tables:
  - `issue-mrs-links.json`: #21 (merged; stands for the recorded #152 shape,
    a PR into a non-default base, `Closes #6`), #22 (closed unmerged,
    `Fixes #6`), #99 (merged, mentions #6 with no closing keyword).
  - `issue-mrs-aggregate.json`: ids 1-5 = open > draft > merged > none
    (no PR) and closed-only → none.
  - `issue-mrs-fork.json`: one fork PR `me/testproj-fork#3`, `Closes #5`.
  - `issue-mrs-notfound.json`: ids 6, 9; alias `i1` NOT_FOUND.
  - `issue-mrs-ratelimited.json`: a non-NOT_FOUND GraphQL error (`RATE_LIMITED`).
  - `issue-mrs-badstate.json`: a PR state outside OPEN/CLOSED/MERGED (`QUEUED`).
  - `issue-mrs-timestamps.json`: createdAt/mergedAt values for the `mr` line.
- `baseRefName` and `closingIssuesReferences`, which the recording query also
  asked for, are dropped: the verb does not request them.
