# `code/github.sh mr-checks` fixtures (#782)

Response bodies of `gh pr view <url> --json headRefOid,state,statusCheckRollup`,
replayed by the gh-stub's `pr view` arm (`$GH_STUB_PR_CHECKS_FILE`).

## Recorded

- `mr-checks-760.json`: the live body for mtibbits/devagent#760, recorded
  2026-10-29 with gh 2.95.0 (Windows). Unedited: MERGED, 12 CheckRun entries
  (11 SUCCESS, 1 SKIPPED). Probe transcript: Issue-782
  `analysis/2026-10-29-t1-probes-run.txt`.

## Synthetic

The rest keep the recorded key set and value types (CheckRun: `__typename
completedAt conclusion detailsUrl name startedAt status workflowName`; an
unfinished run has `conclusion ""` and `completedAt 0001-01-01T00:00:00Z`).
StatusContext entries use the shape recorded from kubernetes/kubernetes#143547
(`__typename context startedAt state targetUrl`). Repository `acme/volk`; head
`a1b2c3d4e5f60718293a4b5c6d7e8f9012345678` throughout.

- `red`: SUCCESS, FAILURE (`bats shard 2 of 4`), IN_PROGRESS.
- `pending`: IN_PROGRESS and QUEUED, nothing finished.
- `green`: SUCCESS, SUCCESS, SKIPPED.
- `none`: an empty rollup.
- `merged`: state MERGED with a FAILURE entry (merged prints no line).
- `superseded`: one check CANCELLED, then a later run SUCCESS.
- `requeued`: one check FAILURE, then a QUEUED re-run with an empty startedAt.
- `twoworkflows`: two workflows' jobs both named `build`.
- `buckets`: one entry per bucket-table row, plus a QUEUED CheckRun.
- `unmapped`: a COMPLETED CheckRun whose conclusion is `STALE`.
