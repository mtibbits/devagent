# devagent requirements

devagent's own requirements, in the format of Gantry's
[requirements-format.md](https://github.com/mtibbits/gantry/blob/main/docs/requirements-format.md),
in namespace `devagent`. A bare ID here means `devagent:<ID>`.

Source of truth: this file was derived once from devagent's README and docs
site, the design spec, the v1 build plans, the contract docs, the command,
skill and agent docs, CONTRIBUTING, SECURITY and the CHANGELOG, the open
epics, and the maintainer's private planning notes. From now on it changes
with the code, in the same pull request as the change it describes. It is not
re-derived from those sources, and the sources are not updated from it.

IDs are never renumbered or reused. A withdrawn requirement is deleted, and
its withdrawal is recorded in a prose line in its section.

`tests/test_own_requirements.py` reads this file. Keep every requirement a
top-level `- ID: text` item, add no HTML comment, and write no ID-shaped list
item anywhere else, not even inside a fenced block.

The file holds every layer but business requirements, and no ID in another
namespace. Business requirements live in the operator's private portfolio
file. Links to other projects' requirements are left to Gantry's
cross-project trace ([mtibbits/gantry#21](https://github.com/mtibbits/gantry/issues/21)).

Workflow steps are named here by name, never by their position in the
checklist: positions change when steps are added.

## Terms

- **operator:** the person running devagent on their projects.
- **project:** a repository devagent works on, named by a
  `[project.<name>]` table in devagent's config.
- **issue dir:** the per-issue directory in a project's devdoc tree that
  holds the issue's checklist, plan, analysis records and notes.
- **checklist:** the issue dir's `checklist.md`, one row per workflow step,
  each with a state glyph.
- **capture:** a draft issue or epic in a project's `Captures/` directory,
  red-teamed and filed later.
- **WBS:** a project's `WBS.md`, its work breakdown as a tree of epics and
  issues.
- **portfolio JSON:** devagent's versioned JSON of every configured
  project's plan, gathered from their `WBS.md` files.
- **trust policy:** the host-level `policy.toml` that says which issue
  authors and sources devagent may act on without the operator.
- **permission gate:** a config switch that must be on before devagent takes
  an outward-facing action, such as pushing, opening or merging a pull
  request, or posting to a tracker.
- **autonomous caller:** a program, not a person, that runs devagent's
  workflow without an operator watching, for example a worker draining a
  shared queue.
- **installation:** one private copy of Gantry
  ([mtibbits/gantry](https://github.com/mtibbits/gantry)), the planning tool
  that reads devagent's `WBS.md` files and requirements files.
- **site:** one project in a Gantry installation, named by its devagent
  `[project.<name>]` table.
- **requirements file:** a project's Markdown file of requirements with
  stable IDs, in Gantry's format.
- **qualified ID:** an ID with its namespace, `<namespace>:<code>-<n>`, for
  example `devagent:FR-12`.
- **leaf:** a `WBS.md` line with no children, usually one tracker issue;
  **open leaf:** one that is neither done (`[x]`) nor not planned (`[-]`).
- **trace:** the links from leaves up to the requirements they serve,
  written as a `satisfies:` meta key on the leaf; **in the trace:** a site
  whose `requirements` path is set in the installation config.

## Business rules

None yet.

## Use cases

## System requirements

## Functional requirements

## Quality attributes

## External interfaces

## Constraints
