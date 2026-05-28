<!--
Placeholder semantics (substituted by commit.sh):
  {{type}}   — branch prefix from .devagent-type via branch_prefix_map (e.g. "perf")
  {{title}}  — the contents of .devagent-title verbatim
  {{issue}}  — the active_issue directory name, including any "Issue-Fork-" prefix
               (e.g. "Issue-Fork-62", NOT "62"). For URLs that need just the number,
               author your template assuming the prefix is part of the substitution.
  {{note}}   — operator-supplied $NOTE from the slash-command tail (may be empty)
-->
# VOLK Commit Message Conventions

**Sources:** GREP1 coding guidelines, `docs/CONTRIBUTING.md`, analysis of the last 100 commits on `origin/main`, and reviewer feedback.

---

## Rules

### Subject line

- **Component prefix** (lowercase, with colon): `cmake:`, `ci:`, `tests:`, or the kernel/file name being changed. Optional on small self-evident changes, but preferred.
- **Imperative mood:** "fix", "add", "remove", "update" — not "fixed", "added", "removed".
- **Lowercase first word** after the prefix.
- **Keep under 72 characters.** Aim for under 55.
- **Do NOT use Conventional Commits prefixes** (`feat:`, `fix:`, `chore:`). Use the component/scope as the prefix instead.
- **Do not reference issue numbers in the subject line.** Put them in the body.
- **Write for `git log --oneline`:** a reviewer scanning 50 commits should understand yours without opening the diff.

### Body (optional but encouraged for non-trivial changes)

- Separated from subject by a blank line.
- Wrap lines at 72 characters.
- Explain **what** changed and **why**, not how (the diff shows how).
- Reference issues with `Fixes #N` or `Related: <URL>` on their own lines.
- For cross-repo references, use the full URL.

### Trailers

- **`Signed-off-by:`** is **required** on every commit (`git commit -s`). The project uses DCO.
- **`Co-Authored-By:`** is not used in this project. Omit it.

---

## Template

```
<scope>: <imperative verb> <what changed>

<Optional body: explain why this change is needed. Wrap at 72 chars.
For kernel changes, note which proto-kernels are affected.
For bug fixes, describe the symptom and root cause.>

<Optional issue references:>
Fixes #NNN
Related: https://github.com/gnuradio/volk/issues/NNN

Signed-off-by: Your Name <your@email.com>
```

---

## Examples

### Short (no body needed)

```
fix RVV index_max/min kernels returning wrong index

Signed-off-by: Magnus Lundmark <magnuslundmark@gmail.com>
```

### With body (build system)

```
cmake: allow custom CMAKE_BUILD_TYPE values

VOLK_CHECK_BUILD_TYPE() issued FATAL_ERROR for build types not in its
hardcoded allowlist, blocking distros like Gentoo that use custom
CMAKE_BUILD_TYPE names. Downgrade to WARNING so configuration completes
while still informing the user that VOLK-specific flags won't apply.

Fixes #383

Signed-off-by: Matt Tibbits <matt@example.com>
```

### With body (refactor)

```
volk_common: math cores to own file; robustify C++ usage

As Greg Troxel figured out, isnan() might not be globally available on
every C++ compiler (where it might be std::isnan); same for isinf.

Move that functionality, used by very few kernels, into volk_mathfun.h,
hopefully fix the compiler-doesn't-automatically-using std::isnan.

While doing that, also make sure #defined constants are UPPERCASE, and
all functions are volk_ prefixed. This is C - we can't be cluttering
the one namespace we have.

Signed-off-by: Marcus Muller <mmueller@gnuradio.org>
```
