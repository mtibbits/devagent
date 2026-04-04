# VOLK Commit Message Conventions

**Sources:** GREP1 coding guidelines, `docs/CONTRIBUTING.md`, analysis of the last 100 commits on `origin/main`, and reviewer feedback.

---

## Rules

### Subject line

- **Component prefix** (lowercase, with colon): `cmake:`, `ci:`, `tests:`, or the kernel/file name being changed. Optional on small self-evident changes, but preferred.
- **Imperative mood:** "fix", "add", "remove", "update" — not "fixed", "added", "removed".
- **Lowercase first word** after the prefix is the predominant style, though maintainer commits sometimes capitalize. Be consistent: use lowercase.
- **Keep under 72 characters.** Aim for under 55.
- **Do NOT use Conventional Commits prefixes** (`feat:`, `fix:`, `chore:`). Use the component/scope as the prefix instead.
- **Do not reference issue numbers in the subject line.** Put them in the body.

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

## Observed Patterns (last 100 commits)

| Aspect | Observed |
|--------|----------|
| Prefixes used | 17% of commits; `cmake:`, `ci:`, kernel names, file names |
| Capitalization | ~70% lowercase start; maintainers sometimes capitalize |
| Mood | Imperative dominant; occasional past-tense from contributors |
| Subject length | Median ~38 chars; max observed 84 |
| Body present | ~32% of commits |
| Signed-off-by | 85% (effectively mandatory; the 15% are older or merge commits) |
| Co-Authored-By | 0% (never used) |
| Issue refs in subject | 0% (always in body) |

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

## Examples by Category

### CMake / build system

```
cmake: allow custom CMAKE_BUILD_TYPE values

VOLK_CHECK_BUILD_TYPE() issued FATAL_ERROR for build types not in its
hardcoded allowlist, blocking distros like Gentoo that use custom
CMAKE_BUILD_TYPE names. Downgrade to WARNING so configuration completes
while still informing the user that VOLK-specific flags won't apply.

Fixes #383

Signed-off-by: Matt Tibbits <matt@example.com>
```

### Bug fix (short)

```
fix RVV index_max/min kernels returning wrong index

Signed-off-by: Magnus Lundmark <magnuslundmark@gmail.com>
```

### Bug fix (with explanation)

```
cmake: remove CMakeParseArgumentsCopy.cmake

Remove the legacy parser compatibility module and stop including it from
VOLK modules. This avoids shadowing CMake's built-in
cmake_parse_arguments(), which broke FetchContent internals in subproject
builds.

Related: https://github.com/gnuradio/gnuradio/issues/7716
Fixes #815.

Signed-off-by: Sergi Granell Escalfet <xerpi.g.12@gmail.com>
```

### New feature / kernel

```
add saturated sum kernels

Signed-off-by: Magnus Lundmark <magnuslundmark@gmail.com>
```

### Refactor

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

### CI

```
ci: fix obsolete MacOS Intel CI

GH migrates to MacOS 15 for Intel CPUs. In turn, this will be the last
Intel MacOS release. Afterwards, we'll probably drop support for these
then old platforms.

Signed-off-by: Johannes Demel <jdemel@gnuradio.org>
```

### Style-only

```
16u_bytswap: update code style

Move loop variable declaration into loop. Fix maybe-uninitialized
warning by initializing the corresponding variable.

Signed-off-by: Johannes Demel <jdemel@gnuradio.org>
```

---

## Common Mistakes to Avoid

1. Using `feat:` or `fix:` Conventional Commits prefixes — use component scope instead.
2. Past tense ("added", "fixed") — use imperative ("add", "fix").
3. Putting issue numbers in the subject line.
4. Omitting `Signed-off-by` (`-s` flag).
5. Exceeding 72 characters in the subject line.
6. Including `Co-Authored-By` — not used in this project.
