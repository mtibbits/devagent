# devAgent commit message conventions

These are the conventions for commits to this repository. They describe what
`scripts/commit.sh` produces from `templates/commit_template.md` (workflow
step 12), so a hand-written commit and a workflow-written one look the same.

A project that *uses* devAgent is not bound by this page: it overrides
`commit_template` in its own devdoc `templates/` directory and follows its own
upstream's rules.

## Subject line

- **`<type>: <title>`.** `<type>` is the branch prefix for the issue's type,
  taken from `branch_prefix_map` in the config. The shipped map is
  `bug → fix`, `feature → feat`, `docs → docs`, `perf → perf`,
  `chore → chore`.
- **Imperative mood** in the title: "add", "fix", "remove", not "added" or
  "fixes".
- **Under 72 characters**, so `git log --oneline` stays readable.
- **No issue numbers in the subject.** They go in the body. The one exception
  is mechanical: PRs are squash-merged, and GitHub appends `(#N)` to the squash
  subject on `master`.

## Body

- Separated from the subject by a blank line, wrapped at 72 characters.
- Say **what** changed and **why**. The diff already shows how.
- Reference issues on their own lines: `Closes #N` to close on merge,
  `Related: #N` for context. Use a full URL for another repository.
- A workflow-written commit also carries `Per-issue dev doc: Issue-N/`, which
  names the issue's artifact directory in the maintainer's devdoc repository.

## Trailers

- **`Signed-off-by:` is required on every commit** (`git commit -s`). The
  project uses the Developer Certificate of Origin
  (https://developercertificate.org/). `commit.sh` always passes `-s`; do not
  write the trailer into a template by hand.
- **`Co-Authored-By:` is accepted** and is normal here for AI-assisted work.
  A project that does not want it sets `include_coauthor = false`, and
  `commit.sh` and `ship.sh` strip the trailer.

## Template

```
<type>: <imperative title under 72 chars>

<Why this change is needed, and what it does. Wrap at 72 chars.
For a bug fix, describe the symptom and the root cause.>

Closes #NNN
Related: #NNN

Signed-off-by: Your Name <you@example.com>
```

## Examples

### Short

```
docs: correct the step count on the workflow page

Closes #123

Signed-off-by: Your Name <you@example.com>
```

### With a body

```
fix: checklist mark refuses a row it cannot find

checklist-mark.sh fell back to the first pending row when the named
step was absent, so a typo in --by-name silently marked the wrong
step. Exit 2 with the list of known step names instead.

Closes #123

Signed-off-by: Your Name <you@example.com>
Co-Authored-By: Claude <noreply@anthropic.com>
```

## What to avoid

- A subject with no type prefix, or one that describes the activity rather
  than the change ("updates", "WIP", "address review").
- Unrelated changes in one commit. One change per PR (see `CONTRIBUTING.md`).
- A commit without `Signed-off-by`. It will not be merged.
