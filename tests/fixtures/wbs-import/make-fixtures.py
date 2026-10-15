#!/usr/bin/env python3
"""Generate the synthesized tracker fixtures for `wbs init --from-tracker` (#706).

Usage: make-fixtures.py [OUT_ROOT]      (default: tests/fixtures)
       make-fixtures.py --manifest      (print the output paths, one per line)

Writes ONLY the files in MANIFEST, relative to OUT_ROOT; routes.json entries
are hand-edited. tests/wbs-init-tracker.bats regenerates into a temp dir and
diffs the manifest paths against the committed bytes.

Provenance
----------
Synthesized: every title, body, date and id below. Titles are neutral
("Task 17", "Epic: Search"); no real project's data is copied. The shape is
the one a real 62-issue project showed (5 epics, 33 unparented, 44 completed
/ 1 not planned / 17 open), so the demo AC's structure is testable here.

Shapes:
- GitHub, `gh issue list --json number,title,body,state,stateReason,
  createdAt,closedAt,milestone,labels,issueType,parent,blockedBy,url`:
  CONFIRMED live with gh 2.95.0 (2026-10-14) on mtibbits/devagent
  (parent node {id,number,state,title,url}; open stateReason ""; closedAt
  null when open), microsoft/vscode (milestone {number,title,description,
  dueOn}) and djangbahevans/goerp#1769 (blockedBy {nodes:[{id,number,state,
  title,url}],totalCount}). Evidence: devDoc Issue-706
  analysis/2026-10-14-u1-gh-shapes.txt.
- GitHub GraphQL fallback, `repository.issues` pages: field names as the
  GraphQL schema names them (parent{number url}, blockedBy{nodes{number
  url}}, issueType{name}, labels{nodes{name}}); an open stateReason is null.
  ASSERTED from the schema (measured: gh's `parent`/`blockedBy` ARE these
  GraphQL fields).
- GitLab `GET /projects/:id/issues`: key set CONFIRMED live on gitlab.com
  gitlab-org/gitlab-runner (2026-10-14); `blocking_issues_count` counts the
  issues THIS issue blocks: CONFIRMED (REST 1 == GraphQL blockingCount 1,
  blockedByCount 0, gitlab-runner#39469). `GET .../issues/:iid/links`
  (link_type blocks|is_blocked_by|relates_to, each linked issue's web_url):
  ASSERTED from the GitLab REST docs; the endpoint answered 401 without a
  token. Evidence: analysis/2026-10-14-u4-gitlab-links.txt.
- Jira Cloud `GET /rest/api/2/search/jql` (nextPageToken/isLast paging, v2
  string description): doc-derived, as #703's search-page fixtures.
  issuelinks direction ASSERTED from Atlassian's documented link-type
  semantics (U3): the "Blocks" type reads outward "blocks", inward "is
  blocked by", and an entry on issue X holding `inwardIssue: Y` reads
  "X is blocked by Y"; X's own `outwardIssue: Z` entry reads "X blocks Z".
  The doc page could not be fetched verbatim this session.

Per-backend native fields (all else empty, as on the real project):
- GitHub: #14 native parent #2 (its body line says #3: native wins);
  #22 blockedBy #21.
- GitLab: #21 blocking_issues_count 1, its links file says it blocks #22;
  #14's body line says #2; #30 has a null description; #35 is closed with a
  null closed_at (GitLab did not record it before 10.6), its updated_at the
  close time.
- Jira: #14 native parent SHAPED-2 (no body line); #22 carries the inward
  Blocks entry from SHAPED-21 and #21 the outward one; #30 has a null
  description; #40 is done with a null resolutiondate (closed date from
  statuscategorychangedate); #82 is resolved "Won't Do".
"""
from __future__ import annotations

import datetime
import json
import sys
from pathlib import Path

MANIFEST = [
    "issue-github/issue-list-shaped.json",
    "issue-github/issue-list-graphql/1.json",
    "issue-github/issue-list-graphql/2.json",
    "gitlab/issues-shaped.json",
    "gitlab/links-shaped-21.json",
    "gitlab/issues-page1.json",
    "gitlab/issues-page2.json",
    "jira/search-shaped-1.json",
    "jira/search-shaped-2.json",
    "jira/search-cycle-1.json",
    "jira/search-cycle-2.json",
]

EM = chr(0x2014)
GH_REPO = "acme/testproj"
GL_REPO = "foo/shaped"
JIRA_KEY = "SHAPED"

# --- the dataset --------------------------------------------------------------
IDS = list(range(1, 51)) + list(range(82, 94))
TITLES = {1: "Data pipeline", 2: "Reporting", 3: "Storage layer",
          83: "Epic: Search", 84: "Epic: Notifications"}
SLUGS = {1: "data-pipeline", 2: "reporting", 3: "storage-layer",
         83: "search", 84: "notifications"}
EPIC_LABEL = {1, 2, 3}
PARENT = {**{n: 1 for n in range(4, 10)}, **{n: 2 for n in range(10, 15)},
          **{n: 3 for n in range(15, 19)}, **{n: 83 for n in range(85, 90)},
          **{n: 84 for n in range(90, 94)}}
# Parent line form per child; "key" is a bare Jira key there and `#N` elsewhere.
FORM = {4: "num", 5: "url", 6: "slug-dash", 7: "slug-space", 8: "key", 9: "url",
        10: "num", 11: "url", 12: "slug-dash", 13: "slug-space", 14: "num",
        15: "num", 16: "url", 17: "slug-dash", 18: "key",
        85: "num", 86: "url", 87: "slug-dash", 88: "slug-space", 89: "num",
        90: "url", 91: "num", 92: "slug-dash", 93: "url"}
LINE_FIRST = set(range(85, 94))
OPEN = {83, 84, *range(88, 94), *range(42, 51)}
NOT_PLANNED = {82}
LABELS = {25: ["bug"]}
NULL_DESCRIPTION = 30          # GitLab and Jira only
GITLAB_NULL_CLOSED_AT = 35     # closed before GitLab recorded closed_at
JIRA_NO_RESOLUTIONDATE = 40


def created(n: int) -> datetime.datetime:
    return datetime.datetime(2026, 1, 1, 10, 0) + datetime.timedelta(days=2 * n)


def closed(n: int) -> datetime.datetime | None:
    if n in OPEN:
        return None
    return created(n) + datetime.timedelta(days=20 + n % 7, hours=5, minutes=30)


def title(n: int) -> str:
    return TITLES.get(n, f"Task {n}")


def labels(n: int) -> list[str]:
    return ["epic"] if n in EPIC_LABEL else LABELS.get(n, [])


def ref(backend: str, n: int, form: str) -> str:
    e = PARENT[n]
    if backend == "github":
        url = f"https://github.com/{GH_REPO}/issues/{e}"
    elif backend == "gitlab":
        kind = "work_items" if n == 90 else "issues"
        url = f"https://gitlab.example/{GL_REPO}/-/{kind}/{e}"
    else:
        url = f"https://jira.example/browse/{JIRA_KEY}-{e}"
    if form == "url":
        return url
    if form == "slug-dash":
        return f"{SLUGS[e]} {EM} {url}"
    if form == "slug-space":
        return f"{SLUGS[e]} {url}"
    if form == "key" and backend == "jira":
        return f"{JIRA_KEY}-{e}"
    return f"#{e}"


def body(backend: str, n: int) -> str | None:
    if n == NULL_DESCRIPTION and backend != "github":
        return None
    if n in TITLES:
        return f"Epic {title(n)}."
    if n == 19:
        return "Work item 19.\n\n```\nParent epic: #1\n```\n"
    if n == 20:
        return "Parent epic: data-pipeline\n\nWork item 20."
    if n not in PARENT:
        return f"Work item {n}."
    if n == 14:
        if backend == "github":
            line = "Parent epic: #3"           # loses to the native parent #2
        elif backend == "gitlab":
            line = "Parent epic: #2"
        else:
            return "Work item 14.\n\nDetails for task 14."   # native parent only
    else:
        line = f"Parent epic: {ref(backend, n, FORM[n])}"
    if n in LINE_FIRST:
        return f"{line}\n\nWork item {n}."
    return f"Work item {n}.\n\nDetails for task {n}.\n\n{line}"


# --- GitHub (gh issue list --json) --------------------------------------------
def gh_ts(d: datetime.datetime | None) -> str | None:
    return None if d is None else d.strftime("%Y-%m-%dT%H:%M:%SZ")


def gh_node(n: int) -> dict:
    return {"id": f"I_kwSYNTH{n:04d}", "number": n,
            "state": "OPEN" if n in OPEN else "CLOSED", "title": title(n),
            "url": f"https://github.com/{GH_REPO}/issues/{n}"}


def gh_record(n: int) -> dict:
    blocked = [gh_node(21)] if n == 22 else []
    reason = "" if n in OPEN else ("NOT_PLANNED" if n in NOT_PLANNED else "COMPLETED")
    return {
        "blockedBy": {"nodes": blocked, "totalCount": len(blocked)},
        "body": body("github", n),
        "closedAt": gh_ts(closed(n)),
        "createdAt": gh_ts(created(n)),
        "issueType": None,
        "labels": [{"id": f"LA_SYNTH{i}", "name": l, "description": "", "color": "ededed"}
                   for i, l in enumerate(labels(n))],
        "milestone": None,
        "number": n,
        "parent": gh_node(2) if n == 14 else None,
        "state": "OPEN" if n in OPEN else "CLOSED",
        "stateReason": reason,
        "title": title(n),
        "url": f"https://github.com/{GH_REPO}/issues/{n}",
    }


def gql_node(n: int) -> dict:
    r = gh_record(n)
    return {
        "number": n, "title": r["title"], "body": r["body"], "state": r["state"],
        "stateReason": r["stateReason"] or None,
        "createdAt": r["createdAt"], "closedAt": r["closedAt"], "milestone": None,
        "labels": {"nodes": [{"name": l["name"]} for l in r["labels"]]},
        "issueType": None,
        "parent": {"number": 2, "url": f"https://github.com/{GH_REPO}/issues/2"} if n == 14 else None,
        "blockedBy": {"nodes": [{"number": 21, "url": f"https://github.com/{GH_REPO}/issues/21"}]
                      if n == 22 else []},
        "url": r["url"],
    }


def gql_page(ids: list[int], cursor: str | None) -> dict:
    return {"data": {"repository": {"issues": {
        "pageInfo": {"hasNextPage": cursor is not None, "endCursor": cursor},
        "nodes": [gql_node(n) for n in ids]}}}}


# --- GitLab (GET /projects/:id/issues) ----------------------------------------
def gl_ts(d: datetime.datetime | None) -> str | None:
    return None if d is None else d.strftime("%Y-%m-%dT%H:%M:%S.000Z")


def gl_record(n: int) -> dict:
    return {
        "id": 910000 + n, "iid": n, "project_id": 5151, "title": title(n),
        "description": body("gitlab", n),
        "state": "opened" if n in OPEN else "closed",
        "created_at": gl_ts(created(n)), "updated_at": gl_ts(closed(n) or created(n)),
        "closed_at": None if n == GITLAB_NULL_CLOSED_AT else gl_ts(closed(n)),
        "labels": labels(n), "milestone": None,
        "issue_type": "issue",
        "web_url": f"https://gitlab.example/{GL_REPO}/-/issues/{n}",
        "blocking_issues_count": 1 if n == 21 else 0,
    }


def gl_links_21() -> list[dict]:
    return [{
        "id": 910022, "iid": 22, "project_id": 5151, "title": title(22),
        "state": "closed", "web_url": f"https://gitlab.example/{GL_REPO}/-/issues/22",
        "issue_link_id": 7001, "link_type": "blocks",
        "link_created_at": "2026-01-20T09:00:00.000Z",
        "link_updated_at": "2026-01-20T09:00:00.000Z",
    }]


def gl_page_record(i: int) -> dict:
    """#703's foo/bar paging fixture, plus the issue-list keys (#706)."""
    state = "closed" if i % 3 == 1 else "opened"
    labs = ["bug", "status::in-progress"] if i % 3 == 2 else ["bug"]
    return {
        "id": 900000 + i, "iid": i, "project_id": 4242, "title": f"Issue {i}",
        "description": "", "state": state, "labels": labs,
        "created_at": "2026-09-01T09:00:00.000Z",
        "closed_at": "2026-10-01T12:00:00.000Z" if state == "closed" else None,
        "milestone": None, "issue_type": "issue", "blocking_issues_count": 0,
        "web_url": f"https://gitlab.example/foo/bar/-/issues/{i}",
    }


# --- Jira Cloud (GET /rest/api/2/search/jql) ---------------------------------
def jira_ts(d: datetime.datetime | None) -> str | None:
    return None if d is None else d.strftime("%Y-%m-%dT%H:%M:%S.000+0000")


def jira_link(kind: str, n: int) -> dict:
    return {"id": f"3{n:04d}", "type": {"id": "10000", "name": "Blocks",
                                        "inward": "is blocked by", "outward": "blocks"},
            kind: {"id": str(20000 + n), "key": f"{JIRA_KEY}-{n}",
                   "fields": {"summary": title(n)}}}


def jira_record(n: int, key: str = JIRA_KEY) -> dict:
    is_open = n in OPEN
    if is_open:
        status = {"name": "To Do", "statusCategory": {"id": 2, "key": "new", "name": "To Do"}}
        resolution = None
    else:
        status = {"name": "Done", "statusCategory": {"id": 3, "key": "done", "name": "Done"}}
        resolution = {"name": "Won't Do" if n in NOT_PLANNED else "Done"}
    fields = {
        "summary": title(n), "description": body("jira", n), "status": status,
        "resolution": resolution, "created": jira_ts(created(n)),
        "resolutiondate": None if is_open or n == JIRA_NO_RESOLUTIONDATE else jira_ts(closed(n)),
        "statuscategorychangedate": jira_ts(closed(n) or created(n)),
        "labels": labels(n), "issuetype": {"name": "Task"},
        "issuelinks": ([jira_link("outwardIssue", 22)] if n == 21 else
                       [jira_link("inwardIssue", 21)] if n == 22 else []),
    }
    if n == 14:
        fields["parent"] = {"id": "20002", "key": f"{key}-2", "fields": {"summary": title(2)}}
    return {"id": str(20000 + n), "key": f"{key}-{n}",
            "self": f"https://jira.example/rest/api/2/issue/{20000 + n}", "fields": fields}


def jira_page(recs: list[dict], token: str | None) -> dict:
    page = {"issues": recs, "isLast": token is None}
    if token is not None:
        page["nextPageToken"] = token
    return page


# --- output -------------------------------------------------------------------
def build() -> dict[str, object]:
    return {
        "issue-github/issue-list-shaped.json": [gh_record(n) for n in IDS],
        "issue-github/issue-list-graphql/1.json": gql_page(IDS[:50], "Y3Vyc29yOjUw"),
        "issue-github/issue-list-graphql/2.json": gql_page(IDS[50:], None),
        "gitlab/issues-shaped.json": [gl_record(n) for n in IDS],
        "gitlab/links-shaped-21.json": gl_links_21(),
        "gitlab/issues-page1.json": [gl_page_record(i) for i in range(1, 101)],
        "gitlab/issues-page2.json": [gl_page_record(i) for i in range(101, 104)],
        "jira/search-shaped-1.json": jira_page([jira_record(n) for n in IDS[:50]], "SHAPEDPAGE2"),
        "jira/search-shaped-2.json": jira_page([jira_record(n) for n in IDS[50:]], None),
        "jira/search-cycle-1.json": jira_page([jira_record(4, "CYCLE")], "TOKB"),
        "jira/search-cycle-2.json": jira_page([jira_record(5, "CYCLE")], "TOKA"),
    }


def main(argv: list[str]) -> int:
    if argv[1:] == ["--manifest"]:
        sys.stdout.write("".join(p + "\n" for p in MANIFEST))
        return 0
    root = Path(argv[1]) if len(argv) > 1 else Path(__file__).resolve().parent.parent
    files = build()
    assert sorted(files) == sorted(MANIFEST)
    for rel in MANIFEST:
        out = root / rel
        out.parent.mkdir(parents=True, exist_ok=True)
        text = json.dumps(files[rel], indent=2, ensure_ascii=False) + "\n"
        out.write_bytes(text.encode("utf-8"))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
