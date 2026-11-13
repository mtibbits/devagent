# Disk issue files

A project can keep its issues as plain files in a folder instead of in a
tracker such as GitHub. This page says what a valid issue file looks like,
what devagent writes into one and when, and how the shared reader reports
what it found (#1008, epic #1007).

One module reads and writes these files: `scripts/lib/disk-issue.py`. Every
devagent part that touches an issue file goes through it, so they all agree
on what a file means. The disk issue backend that uses it is a later child of
epic #1007 and is not built yet.

## File and folder

- One issue per file, named `<N>.md`, where `N` matches `^[1-9][0-9]*$` and
  has at most 18 digits. A longer number is a fault.
- Other names are not issues and are ignored: `0.md`, `01.md`, `README.md`,
  subfolders, and every name that starts with a dot. The writer's temporary
  files (`.<N>.md.tmp-<random>`) and its lock file (`.disk-issue.lock`) start
  with a dot for this reason.
- A file is UTF-8 text. Lines may end in LF or CRLF, and the file may start
  with a UTF-8 byte order mark (BOM).

## Minimal form and full form

A file starts as plain text and grows. This is the smallest valid issue, a
title line and some prose:

```text
Add a dark-mode toggle to the settings page

The settings page should have a switch that flips the site between light and dark.
Done when the choice survives a page reload.
```

This is the same issue after it merged. A person added `parent: 3` by hand;
devagent wrote the rest:

```text
# Add a dark-mode toggle to the settings page
state: closed
status: Done
parent: 3

## Prompt
The settings page should have a switch that flips the site between light and dark.
Done when the choice survives a page reload.

## Comments
- 2026-11-10 on_draft_start: status In Progress
- 2026-11-10 on_ship: status In Review
- 2026-11-11 on_merge: status Done, closed
```

Both files have the same title and the same prompt.

## Title

The title is the first non-blank line. A leading `# `, a BOM and trailing
spaces are not part of it. A file with no title line is faulty.

## Header

The header is the `key: value` lines directly under the title, with no blank
line between them and the title. Only these five lowercase keys count:

| Key | Value | Example |
|---|---|---|
| `state` | Exactly `open` or `closed`. No `state:` line means open. | `state: closed` |
| `status` | Free text. | `status: In Progress` |
| `parent` | An issue number, with or without a leading `#`. | `parent: 3` |
| `labels` | A comma-separated list. Each label is trimmed and none may be empty, so a label cannot contain a comma. | `labels: ui, settings` |
| `github` | `owner/name#N`. | `github: octo/site#12` |

- A value is trimmed at both ends and must not be empty.
- A key that appears twice is a fault, and so is a value outside these rules.
- The first line that is not one of the five keys ends the header. That line
  and everything after it are the body.

**Only known keys count, and prose needs a blank line above it.** The minimal
form already has that blank line. Without it, a first line of prose that
looks like a header line is read as one: a minimal file whose line under the
title reads `status: broken since Tuesday` gets that status. A line such as
`state: the form loses state` in that place is a fault, because it is not a
valid `state`, and the message says to add a blank line if the line is prose.

The reverse mistake gets a warning, not a fault. When the first non-blank line
after the blank line that ends the title-and-header block is a valid header
line (a hand-written `state: closed` with a blank line above it, say), it is
read as prose, and `check` warns about it. Later prose such as
`status: green on CI` never warns.

## Body

The body has two optional sections. Each starts with a line that reads
exactly `## Prompt` or `## Comments`. Trailing spaces and a CR are tolerated;
the heading is case-sensitive, and it must sit outside a code fence. A line
that ends in a second CR (`\r\r\n`) fails the check, so a mangled file is
never edited.

- **The prompt** is the text under `## Prompt`, up to `## Comments` or the end
  of the file. Leading and trailing blank lines are removed, and line endings
  are read as LF. With no `## Prompt` line, the prompt is all body text before
  `## Comments`.
- **Other `##` headings** are prompt text. A `## Workflow flags` block, for
  example, reaches `pull`'s flag parser unchanged.
- **Faults:** non-blank text between the header and a `## Prompt` line, a
  second `## Prompt` or `## Comments`, and a `## Prompt` after `## Comments`.

**Code fences.** A fence opens with a line whose first non-blank characters
are three or more backticks or tildes, and closes with a later line of the
same character, at least as long, with nothing after it. A backtick opener
whose info text contains a backtick is not an opener.

- An opener with no closer is not a fence, as in `wbs-parser.py` (#701).
- A closer indented two or more spaces never closes a fence when a
  `## Comments` line that starts in the first column lies between the opener
  and that closer. (An indented fence inside a list item in the prompt pairs
  as usual.) Every comment line the
  writer adds is indented two spaces, so a fence inside an added comment can
  never turn earlier text into code. A fence above the comments section may
  still contain `## Comments` and entry-shaped lines, and pairs with a closer
  in the first column.
- Fences inside the comments section have no effect on its structure.
- Pairing takes linear time. A file with more than 1,000 unclosed openers is a
  fault.

## Comments

Under `## Comments`, each entry starts with `- YYYY-MM-DD ` and a real date.
Lines indented by two spaces continue the entry. A blank line followed by an
indented line is a paragraph break inside the entry, and blank lines between
entries are allowed.

```markdown
## Comments
- 2026-11-10 on_draft_start: status In Progress
- 2026-11-12 A note that runs on
  to a second line.

  And a second paragraph.
```

Each of these is a fault: text between `## Comments` and the first entry, a
date that is not a real date, an entry with no text, a `## ` heading, and any
other line that neither starts an entry nor is indented two spaces.

## What devagent writes, and when

**The writer never edits a faulty file.** Every write first checks the file;
a faulty file is left untouched and the write fails with exit code 4.

- **`set`** sets or removes header keys, and optionally adds one comment, in a
  single write, so a transition that sets a status, closes the issue and logs
  an entry is never left half done. New keys go in the order `state`,
  `status`, `parent`, `labels`, `github`. Setting `state` to `open` removes
  the line. Values are written as given, after trimming (`parent=#3` writes
  `parent: #3`). A call that changes nothing writes nothing.
- **Line endings, BOM and mode.** A write keeps the file's own line ending (LF
  or CRLF) on every line, including the lines it adds, and keeps a BOM and the
  file's permission bits. A title or value containing a line break is refused.
- **The first write to a minimal file** turns it into the full form: the
  title gets `# `, the header lines go under it, and when the body has no
  `## Prompt` line, the existing prose is placed under `## Prompt` byte for
  byte. A file already in the full form changes only in the lines the
  operation names.
- **Comments** are dated with today's local date, the date devagent's other
  artifacts use (`date_tag` in `scripts/lib/io.sh`), and honour
  `DEVAGENT_DATE_OVERRIDE` (#338). `--date YYYY-MM-DD` writes an earlier date,
  for example when copying old comments. The first comment creates
  `## Comments`. A multi-line comment is written as indented continuation
  lines, and a blank line inside it as an empty line.
- **`create`** writes a new LF file from a number, a title, a prompt and keys.
  It never overwrites: when `<N>.md` exists it fails with exit code 3 (the
  file exists), so a caller can retry with another number. It refuses, with
  exit code 2, a prompt with an unfenced line that reads exactly `## Prompt`
  or `## Comments`, because that prompt could not be read back unchanged.
- **Safe writes.** Every write is atomic: the writer writes a dot-named temp
  file in the same folder, flushes it to disk, and then puts it in place, so a
  crash never leaves half a file. `set` calls in one folder take turns on
  `.disk-issue.lock` (when the lock file cannot be opened or locked, for
  example for lack of permission, the write goes ahead unlocked). Before the replace, the writer re-reads the file; if it
  changed (another session, or an editor saving), the write starts over once,
  then fails rather than overwrite the other change. A replace refused because
  another program holds the file open (an indexer or antivirus on Windows) is
  retried for about one second. Editors do not take the lock, so an editor
  that saves in the moment between the re-read and the replace can still lose
  that save. Where a folder has no hard links, `create` reserves the name
  first; a crash at that moment leaves an empty `<N>.md`, which `check`
  reports as having no title line.
- **When.** The disk issue backend, a later child of epic #1007, will log the
  stage transitions (`on_draft_start`, `on_ship`, `on_merge`) as comments, as
  in the full form above. Until it lands, nothing in devagent writes these
  files on its own.

## Checking and listing

- **`check <file>...`** exits 0 when every file is valid. Otherwise it prints
  one `<file>:<line>: <message>` line per fault and exits 4. Warnings print as
  `<file>:<line>: warning: <message>` and do not fail the check. Line numbers
  are 1-based.
- **`list <folder>`** prints every issue file in the folder as JSON Lines,
  sorted by `N`, from one process. It prints every line, then exits 4 when any
  file is faulty, or 1 when any file could not be read.
- **`parse <file>`** prints one file's JSON line.

## JSON fields

Each line is one JSON object, UTF-8, with these fields in this order:

| Field | Type | Present |
|---|---|---|
| `n` | integer: the issue number | always |
| `title` | string | valid file |
| `keys` | object: always has `state` (`"open"` when there is no line); `parent` as a bare integer; `labels` as an array of strings; `status` and `github` as strings | valid file |
| `prompt` | string, LF line endings | valid file |
| `comments` | array of objects, each with `date` (string), `text` (string, LF line endings) and `line` (integer, the entry's first line) | valid file |
| `faults` | array of objects, each with `line` (integer) and `message` (string) | faulty file, instead of the four fields above |
| `warnings` | array of objects, each with `line` (integer) and `message` (string) | always |

The full-form example, saved as `2.md`, parses to:

```json
{"n":2,"title":"Add a dark-mode toggle to the settings page","keys":{"state":"closed","status":"Done","parent":3},"prompt":"The settings page should have a switch that flips the site between light and dark.\nDone when the choice survives a page reload.","comments":[{"date":"2026-11-10","text":"on_draft_start: status In Progress","line":11},{"date":"2026-11-10","text":"on_ship: status In Review","line":12},{"date":"2026-11-11","text":"on_merge: status Done, closed","line":13}],"warnings":[]}
```

## Exit codes

| Code | Meaning |
|---|---|
| 0 | OK. |
| 1 | An I/O failure; the file changed underneath the write; another writer held the folder lock for too long; or an internal error where the result did not read back (the file is left unchanged). |
| 2 | Usage, or a refused value or prompt. |
| 3 | `create` found the file already there. |
| 4 | The file fails the check (and was not written). |

## Command line

```text
usage: disk-issue.py parse <file>
       disk-issue.py list <folder>
       disk-issue.py check <file>...
       disk-issue.py set <file> key=value... [--unset key]... [--comment <text>] [--date <YYYY-MM-DD>]
       disk-issue.py create <folder> <N> <title> <prompt-file> [key=value...]
```

Callers run it as `python3 scripts/lib/disk-issue.py <verb> ...`. Python
callers can also load it by path with `importlib` and call `read_issue`.
