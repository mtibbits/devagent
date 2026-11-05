# Portfolio document schema (v1.0)

The portfolio document is one generated JSON file that describes every
configured project: its WBS nodes, the issues those nodes name, and a
rollup of the remaining work. This page is the written contract for it
(#725, epic #724). It landed before the first producer, so the producer
and its consumers can build against the same text.

| File | Role |
|---|---|
| `scripts/lib/portfolio-schema.json` | The machine schema. Its root `version` annotation is the schema's own version. |
| `scripts/lib/portfolio-check.py` | The stdlib checker and CLI. It validates a document and runs the compatibility guard. |
| `tests/fixtures/portfolio/example-1.0.json` | A hand-written example document that validates. |
| `tests/fixtures/portfolio/schema-history/<version>.json` | One byte-exact snapshot per released schema version. The guard compares against these. |
| `tests/test_portfolio_schema.py` | The tests that hold all of the above together. |

**Consumers.** #726 produces the document and validates its real output
through the checker. #727 fills readiness and resolution. The slot epics fill
their reserved slots: actuals (#729), derived estimates (#736), forecasts (#742)
and lanes (#748). Gantry (mtibbits/gantry) reads the document from outside.

## Dialect

The schema is written in a **subset of JSON Schema draft 2020-12**. It uses
only these keywords: `$schema $id $defs $ref title description type
properties required additionalProperties items enum const minimum maximum`,
plus two annotations, `x-reserved` (marks a reserved slot and names its owner)
and the root-only `version`. The checker's loader refuses every other keyword,
so a schema edit cannot lean on a rule the checker does not enforce.

- `$ref` is local only (`#/$defs/<name>`), may stand only beside
  `description`/`title`, and may not form a cycle.
- `additionalProperties` is a boolean or a schema. An object that is not a
  slot and has no free-form keys says `false`.
- Two semantics are **stricter than the standard**. `integer` means a JSON
  integer token, so `1.0` is refused (the standard accepts it). `enum` and
  `const` compare type-strictly, so `1.0` does not match a member `1`. (v1.0
  has no numeric enum members, so this second rule changes nothing yet.) As in
  the standard, `true` is neither an `integer` nor a `number`.

A stock 2020-12 validator accepts the schema and the example, because it
treats `x-reserved` and `version` as annotations and the subset means the same
there. A stock validator does **not** implement the version rules, though. It
rejects the unknown fields of a newer-minor document (rule 5) under
`additionalProperties: false`. It also accepts a non-null reserved slot. Use
it for documents at your own version; use `portfolio-check.py` for the version
behaviour. CI does not install `jsonschema`. The suite runs the stock-validator
check only where `jsonschema` 4.x is installed, so the differential's evidence
is a scratch-venv transcript kept with the issue, not the CI gate.

Two constraints are outside what the schema can say:
- The `schema_version` form (`MAJOR.MINOR`) is **checked by
  `portfolio-check.py`, not the schema**.
- The `generated_at` form (RFC 3339, UTC) is **documented, not checked**.

## Version rules

<!-- editor: test_doc_states_version_rules_verbatim requires each rule below to
     equal the "(N) ..." text in the schema's root description, character for
     character. Edit both together. -->

1. schema_version is MAJOR.MINOR: two non-negative integers, no leading zeros.
2. A MINOR bump adds optional fields, or defines the contents of a reserved slot. Nothing else.
3. A MAJOR bump is needed to remove or rename a field, or to change its type, nullability, required-ness, enum values, bounds or meaning. MINOR resets to 0. Enums are closed, so adding a value is a MAJOR change.
4. A reader refuses a document whose MAJOR differs from its own, with a message naming both versions.
5. A reader that meets its own MAJOR with a newer MINOR reads the document and ignores fields it does not know. At its own or an older MINOR, an unknown field is an error.
6. The document is regenerated on every run. A slot is filled at generation time from a source its owning epic defines, never by editing the output. A defined slot stays optional and object-or-null; making a slot required or non-nullable is a MAJOR bump.

A **reserved slot** is optional, typed object-or-null, accepts any contents,
and carries `x-reserved: "<owner>"`. It is null in every document whose minor
is at or below the reader's, and the checker reports a non-null slot there.
Its owning epic defines it in a minor bump by dropping `x-reserved` and
declaring its properties.

### Changing the schema

- **Every change bumps the version.** That includes a new optional field. A
  bump also owes a new snapshot `tests/fixtures/portfolio/schema-history/<version>.json`
  (a byte copy of the schema) and its line in `HISTORY_SHA256` in the tests.
  The guard fails until both exist.
- **The guard** (`compat_violations` in the checker) compares the snapshots in
  version order and ends at the live schema. Within one major it reports each
  of these: a removed or renamed field; a change to a field's type,
  required-ness, enum, bounds, `additionalProperties` or `x-reserved`; a new
  required field; a field declared under an **open object** (one whose
  `additionalProperties` is `true` or a schema, such as `meta` or `non_time`,
  that is not a reserved slot); and any change made without a version bump.
  The open-object case needs a major bump because an older reader already checks
  every key of that object against its free-form rule, so a newer document
  would fail it. Past snapshots are pinned by digest; editing one is a failure,
  while adding one is not.
- **Minor bumps are serialised by merge order: a branch that meets a newer
  minor on rebase re-bumps and adds its own snapshot.** Two branches cannot
  both ship `1.1`.
- Descriptions and titles are not part of the contract; editing them needs no bump.

## Field reference

Paths use the inventory syntax that the checker and guard use. Fields are
dotted; `[]` marks array items and `{}` marks the values of a free-form object.
For example, `projects[].nodes[].est.class` is the estimate class of every node
of every project. "req" means the key must be present; a nullable field is
present with `null`.

<!-- editor: test_doc_lists_every_schema_field requires every inventory path of
     the schema to appear in backticks somewhere on this page, and pins the
     count. A new field needs a row here. -->

### Document (top level)

| Path | Type | Req | Meaning |
|---|---|---|---|
| `schema` | const `"devagent-portfolio"` | req | Identifies the document kind. |
| `schema_version` | string `MAJOR.MINOR` | req | See the version rules. |
| `generated_at` | string | req | RFC 3339 UTC. The only field that may differ between two runs over unchanged inputs. |
| `projects` | array of Project | req | One per configured project, in config order. |
| `parse_report` | array of ReportEntry | req | `[]` when clean. |
| `forecast` | slot (#742) | opt | Reserved. |

### Project — `projects[]`

| Path | Type | Req | Meaning |
|---|---|---|---|
| `projects[].project` | string | req | The `[project.<name>]` table name in `config.toml`. It may differ from the devdoc dir name. |
| `projects[].status` | `read` \| `no_wbs` \| `no_devdoc_dir` \| `unreadable` | req | See "Project status" below. |
| `projects[].status_reason` | string\|null | req | Null exactly when `read`; a non-empty reason otherwise. |
| `projects[].wbs_title` | string\|null | req | The parser's root title (`""` when none) when `read`, else null. |
| `projects[].nodes` | array of Node | req | Every node, leaf and parent, in source order. `[]` unless `read`. |
| `projects[].issues` | array of IssueEntry | req | One per distinct issue on this project's nodes. `[]` unless `read`. |
| `projects[].rollup` | Rollup\|null | req | Null unless `read`. |
| `projects[].lanes` | slot (#748) | opt | Reserved. |
| `projects[].forecast` | slot (#742) | opt | Reserved. |

### Node — `projects[].nodes[]`

| Path | Type | Req | Meaning |
|---|---|---|---|
| `projects[].nodes[].id` | string | req | Opaque and unique within one document. It is deterministic over unchanged inputs but **not stable across edits to `WBS.md`**: join on `(project, issue)`, never on `id`. |
| `projects[].nodes[].parent` | string\|null | req | The parent's `id`; null at top level. |
| `projects[].nodes[].depth` | integer ≥ 1 | req | The parser's depth. |
| `projects[].nodes[].leaf` | boolean | req | The node has no children. |
| `projects[].nodes[].text` | string | req | The parser's text. |
| `projects[].nodes[].state` | `pending` `done` `skipped` `stuck` `in_progress` `blocked_external` `parked` | req | The parser's state. |
| `projects[].nodes[].glyph` | `" "` `x` `-` `!` `~` `?` `P` | req | The parser's glyph. |
| `projects[].nodes[].source_line` | integer ≥ 1 | req | The node's line in `WBS.md`. |
| `projects[].nodes[].issue` | string\|null | req | `meta.issue` as written (`Issue-N`, `Issue-Fork-N`; no prefix stripped); null when absent. |
| `projects[].nodes[].meta` | object | req | The raw metadata, verbatim. |
| `projects[].nodes[].meta{}` | string\|array | — | Each metadata value. |
| `projects[].nodes[].meta{}[]` | string | — | Each entry of a list value. |
| `projects[].nodes[].meta_unknown_keys` | array | req | Metadata keys the parser did not know at generation time. |
| `projects[].nodes[].meta_unknown_keys[]` | string | — | One key. |
| `projects[].nodes[].est` | Est | req | The classified estimate (below). |
| `projects[].nodes[].satisfies` | array | req | `meta.satisfies` as a list: absent gives `[]`, a scalar gives one entry; entries as written. |
| `projects[].nodes[].satisfies[]` | string | — | One entry. |
| `projects[].nodes[].h` | integer\|null, 0..4 | req | `meta.h` when it is one digit 0–4 (quotes already stripped by the parser); null when absent or malformed. |
| `projects[].nodes[].depends_on` | array of Dep | req | `meta.depends_on`, one entry per id. |
| `projects[].nodes[].ready` | boolean\|null | req | Readiness; null when not computed, and always null on a parent. |

### Est — `projects[].nodes[].est`

Carried on every node. A parent's `est` is the operator's roll-up: it is
carried as written and never summed.

| Path | Type | Req | Meaning |
|---|---|---|---|
| `projects[].nodes[].est.raw` | string\|array\|null | req | Equals `meta.est`; null when absent. |
| `projects[].nodes[].est.raw[]` | string | — | One entry of a list value. |
| `projects[].nodes[].est.class` | `absent` `placeholder` `time` `non-time` `unparseable` | req | The #737 class. Only `time` counts as estimated; `pr` is `non-time`. |
| `projects[].nodes[].est.low_hours` | number\|null | req | `time` only: the low bound in hours. |
| `projects[].nodes[].est.high_hours` | number\|null | req | `time` only: the high bound; equal to the low bound for a single value. |
| `projects[].nodes[].est.quantity` | number\|null | req | `non-time` only: the number as written, e.g. `48`. |
| `projects[].nodes[].est.unit` | string\|null | req | `non-time` only: the unit as written, e.g. `pr`. |
| `projects[].nodes[].est.src` | `confirmed` \| `derived` \| null | req | Provenance of `est` alone (#754). Null means operator-owned: `est_src` absent **or any other value**. |

### Dep — `projects[].nodes[].depends_on[]`

| Path | Type | Req | Meaning |
|---|---|---|---|
| `projects[].nodes[].depends_on[]` | object | — | One dependency. |
| `projects[].nodes[].depends_on[].raw` | string | req | The entry as written. |
| `projects[].nodes[].depends_on[].scope` | `local` \| `foreign` | req | See "Dependency split" below. |
| `projects[].nodes[].depends_on[].project` | string | req | The named project; this project when local. |
| `projects[].nodes[].depends_on[].issue` | string | req | The issue id. |
| `projects[].nodes[].depends_on[].resolved` | boolean\|null | req | Whether the reference resolves; null when not computed. |

### IssueEntry — `projects[].issues[]`

| Path | Type | Req | Meaning |
|---|---|---|---|
| `projects[].issues[].issue` | string | req | The issue id as written on its nodes. |
| `projects[].issues[].nodes` | array | req | Ids of every node carrying the issue, in order. Two or more means a duplicate within the project. |
| `projects[].issues[].nodes[]` | string | — | One node id. |
| `projects[].issues[].stuck` | Stuck\|null | req | Non-null exactly when the issue dir has a `STUCK` file. |
| `projects[].issues[].checklist` | `absent` \| `open` \| `complete` | req | `absent`: no issue dir, or no `checklist.md`. `open`: a step is still to do. `complete`: every step is done or skipped. |
| `projects[].issues[].next_step` | string\|null | req | The name of the first step not `[x]`/`[-]` in the **active revision block** (the rule `next.sh` uses, `checklist_current_step` in `scripts/lib/checklist.sh`). Null unless `open`. |
| `projects[].issues[].next_step_number` | integer\|null | req | That step's number. Null unless `open`. |
| `projects[].issues[].actuals` | slot (#729) | opt | Reserved. |
| `projects[].issues[].estimates` | slot (#736) | opt | Reserved: derived estimates. |

### Stuck — `projects[].issues[].stuck`

All three are copied **verbatim** from the `STUCK` file, and each is null when
its line is missing. No format is promised, because there are two writers:
`checklist-stuck.sh` writes `Created:` with `date -Iseconds`, while `stuck.sh`
writes a zoneless `%Y-%m-%d %H:%M`. `Last good:` is not carried: it may be
absent, and its form also differs by writer.

| Path | Type | Req | Meaning |
|---|---|---|---|
| `projects[].issues[].stuck.step` | string\|null | req | The `Step:` value. |
| `projects[].issues[].stuck.reason` | string\|null | req | The `Reason:` value. |
| `projects[].issues[].stuck.since` | string\|null | req | The `Created:` value. |

### Rollup — `projects[].rollup`

The rollup counts **leaves only**; parents are never summed. Each leaf falls
into exactly one of three buckets: `estimated` (class `time`, `est.src` not
`derived`), `estimated_derived` (class `time`, `est.src` = `derived`) or
`unestimated` (every other class). The three buckets partition `leaves`.

| Path | Type | Req | Meaning |
|---|---|---|---|
| `projects[].rollup.by_state` | object | req | One Counts object per state; all seven keys are required. |
| `projects[].rollup.remaining` | object | req | Leaves whose state is not `done`/`skipped` (in-progress included). |
| `projects[].rollup.remaining.leaves` | integer | req | |
| `projects[].rollup.remaining.estimated` | integer | req | |
| `projects[].rollup.remaining.estimated_derived` | integer | req | |
| `projects[].rollup.remaining.unestimated` | integer | req | |
| `projects[].rollup.remaining.low_hours` | number | req | Sum of the `time` leaves' low bounds (derived included). |
| `projects[].rollup.remaining.high_hours` | number | req | Sum of their high bounds. |
| `projects[].rollup.remaining.non_time` | object | req | `non-time` totals per unit as written, e.g. `{"pr": 48}`. |
| `projects[].rollup.remaining.non_time{}` | number | — | One unit's total. |

Each `by_state` entry is a Counts object with four required integers:
`leaves`, `estimated`, `estimated_derived`, `unestimated`.

| State | Paths |
|---|---|
| pending | `projects[].rollup.by_state.pending`, `projects[].rollup.by_state.pending.leaves`, `projects[].rollup.by_state.pending.estimated`, `projects[].rollup.by_state.pending.estimated_derived`, `projects[].rollup.by_state.pending.unestimated` |
| done | `projects[].rollup.by_state.done`, `projects[].rollup.by_state.done.leaves`, `projects[].rollup.by_state.done.estimated`, `projects[].rollup.by_state.done.estimated_derived`, `projects[].rollup.by_state.done.unestimated` |
| skipped | `projects[].rollup.by_state.skipped`, `projects[].rollup.by_state.skipped.leaves`, `projects[].rollup.by_state.skipped.estimated`, `projects[].rollup.by_state.skipped.estimated_derived`, `projects[].rollup.by_state.skipped.unestimated` |
| stuck | `projects[].rollup.by_state.stuck`, `projects[].rollup.by_state.stuck.leaves`, `projects[].rollup.by_state.stuck.estimated`, `projects[].rollup.by_state.stuck.estimated_derived`, `projects[].rollup.by_state.stuck.unestimated` |
| in_progress | `projects[].rollup.by_state.in_progress`, `projects[].rollup.by_state.in_progress.leaves`, `projects[].rollup.by_state.in_progress.estimated`, `projects[].rollup.by_state.in_progress.estimated_derived`, `projects[].rollup.by_state.in_progress.unestimated` |
| blocked_external | `projects[].rollup.by_state.blocked_external`, `projects[].rollup.by_state.blocked_external.leaves`, `projects[].rollup.by_state.blocked_external.estimated`, `projects[].rollup.by_state.blocked_external.estimated_derived`, `projects[].rollup.by_state.blocked_external.unestimated` |
| parked | `projects[].rollup.by_state.parked`, `projects[].rollup.by_state.parked.leaves`, `projects[].rollup.by_state.parked.estimated`, `projects[].rollup.by_state.parked.estimated_derived`, `projects[].rollup.by_state.parked.unestimated` |

With the split carried per state and for `remaining`, a consumer can derive
both "pending" and "remaining" views without guessing.

### ReportEntry — `parse_report[]`

| Path | Type | Req | Meaning |
|---|---|---|---|
| `parse_report[]` | object | — | One problem met while reading the inputs. |
| `parse_report[].project` | string | req | The project it concerns. |
| `parse_report[].source_line` | integer\|null, ≥ 1 | req | The `WBS.md` line; null when not tied to a line. |
| `parse_report[].kind` | string | req | An **open vocabulary** defined by #726. Readers accept unknown kinds. |
| `parse_report[].message` | string | req | Human-readable text. |

## Semantics

**Project status.** `no_devdoc_dir`: the project has no devdoc dir configured,
or the dir is absent. `no_wbs`: the dir exists but has no `WBS.md` file.
`unreadable`: `WBS.md` is present but is not a readable regular file, or it
failed to parse. `read`: parsed. `status_reason` is null exactly when `read`
and non-empty otherwise.

**Duplicates.** An issue that appears on two nodes of one project has one
IssueEntry whose `nodes` lists both ids. Two projects naming the same issue id
each have their own IssueEntry: the join key is `(project, issue)`.

**Issue-less leaves.** A leaf with no `issue` is an ordinary node. It is counted
in the rollup, has no IssueEntry, and carries its own `est.src` on the node.

**Dependency split** (#887's grammar). An entry is foreign or own-prefixed
exactly when it holds one `:` and both halves fullmatch the parser's
`ID_TOKEN_RE`. Then `project` is the left half and `issue` the right; `scope` is
`foreign` unless the left half is this project (`alpha:Issue-9` in `alpha` is
`local`). Every other entry is `local`, with `project` = this project and
`issue` = `raw`. So `":Issue-1"`, `"a:b:c"` and `Issue-Fork-134` are local raw
ids. A malformed prefixed entry is a local id that resolves to nothing.

**`meta_unknown_keys` in the example** is illustrative of the parser at the
time of writing (`est_src`, `satisfies` and `h` were not yet known keys). It is
not a key list, and readers must not treat it as one.

### Who writes each field

| Field or member | Writer |
|---|---|
| Every field, at generation time | #726 (the producer) |
| `est.class`, `est.low_hours`, `est.high_hours`, `est.quantity`, `est.unit` | #726, through #737's classifier and its hour factors |
| `est.src` (`confirmed`, `derived`, null) | #726, from `meta.est_src` (#754). A value other than `confirmed`/`derived` reads as null; #726 also reports it in `parse_report` under a kind it names. |
| `satisfies`, `h` | #726, from the known keys #888 adds |
| `depends_on[].scope`, `.project`, `.issue` | #726, by the split rule above (#887) |
| `ready`, `depends_on[].resolved` | #727; null until it lands |
| `stuck` | #726, from the issue dir's `STUCK` file |
| `checklist`, `next_step`, `next_step_number` | #726, from the issue dir's `checklist.md` |
| `parse_report[].kind` | #726 (open vocabulary) |
| `lanes`, `forecast`, `actuals`, `estimates` slots | #748, #742, #729, #736 — null until each defines its slot |

## The checker

    usage: portfolio-check.py <document.json>

It reads the file as strict JSON: UTF-8 with no BOM, no `NaN`/`Infinity`
(nor a number such as `1e400` that overflows to it), no duplicate keys, and no
nesting deeper than the interpreter's stack. Then it runs the version preflight (object, `schema` id,
`schema_version` form, major) and validates the structure. Errors go to stderr,
one per line, prefixed `portfolio-check: `. stdout stays silent.

<!-- editor: test_doc_states_usage_and_exit_codes requires the usage line above
     to equal USAGE in portfolio-check.py, and one table row per exit code. -->

| Exit | Meaning |
|---|---|
| `0` | Valid. At a newer minor, also prints "document is schema X, newer than this reader's Y; fields this reader does not know are ignored". |
| `1` | Invalid: not a JSON object, not a portfolio document, a malformed `schema_version`, or structural errors. |
| `2` | Could not run: a usage error, an unreadable file, input that is not strict JSON, or a schema load error. |
| `3` | Unsupported major version. The message names both versions: `unsupported portfolio schema_version "2.0": this reader supports major 1 (schema 1.0)`. |

Structural errors name a JSONPath-like location, such as
`$.projects[0].nodes[2].est.class: 'quantity' is not one of ...`,
`$.projects[0]: missing required field status`,
`$.projects[0].nodes[1].h: 5 is outside 0..4`, or
`$.projects[0].x: unknown field`.

The checker uses only the Python standard library (3.10+; the tests prove it
with an import walk and a `python -I -S` run), so no dependency manifest exists.

### What this checker does not decide (owned by #726)

Exit `0` means **structurally well-formed**, nothing more. Cross-field
consistency belongs to the producer, whose own correctness check cannot rest on
this exit code. The checker does not verify that:

- node ids are unique, nodes ascend by `source_line`, and `parent` names an
  earlier, shallower node of the same project;
- `leaf` matches the parent links, and `ready` is null on parents;
- `issue`, `est.raw`, `est.src`, `satisfies`, `h` and `depends_on[].raw` agree
  with `meta`;
- an estimate's class agrees with its hour, quantity and unit fields;
- `issues` holds exactly one entry per distinct node issue, listing exactly its nodes;
- `meta_unknown_keys` is a duplicate-free subset of the `meta` keys;
- project names are unique, and each status agrees with `nodes`, `issues`,
  `rollup`, `wbs_title` and `status_reason`;
- `rollup` equals a recomputation from the nodes;
- `checklist` is `open` exactly when the next-step fields are set;
- a report entry names a project in the document.

## Deferred

- **Token estimates.** #737 has not settled its token key's name. Its
  classification and a `tokens_src` provenance key arrive in a later minor bump
  when #737 lands (owner #737).
- **Report kinds.** #726 defines the `parse_report[].kind` vocabulary.
- **Range syntax and unit factors** for `est` belong to #737; the schema
  carries the result and converts nothing.
