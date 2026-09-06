#!/usr/bin/env python3
"""Run static analysis tools and filter findings to changed lines only.

Usage:
    static_analysis_diff.py <base_ref> <build_dir> [--files FILE...]

Examples:
    static_analysis_diff.py origin/main /tmp/build-pr1
    static_analysis_diff.py feat/32-with-minmax /tmp/build-pr33 --files lib/qa_utils.cc apps/volk_profile.cc
"""

import argparse
import concurrent.futures
import json
import os
import re
import shutil
import subprocess
import sys
from dataclasses import dataclass, field
from pathlib import Path
from typing import Optional


@dataclass
class LineRange:
    start: int
    count: int

    @property
    def end(self) -> int:
        return self.start + self.count - 1 if self.count > 0 else self.start


@dataclass
class Finding:
    tool: str
    severity: str
    file: str
    line: int
    message: str
    novel: bool = False


@dataclass
class ToolResult:
    tool: str
    findings: list[Finding] = field(default_factory=list)
    error: Optional[str] = None
    passed: bool = True
    # True when the tool/executable was absent (Windows, a lean CI image) and
    # its analysis was skipped. Distinct from a real failure (passed=False):
    # static analysis is a Linux gate, so an absent tool is skipped, not failed,
    # and never crashes the run (issue #295).
    skipped: bool = False


# Suffix on error strings returned by _build_sanitizer() to mark "build tool
# absent → skip" rather than "build failed". It is the only signalling channel
# a plain error-string return has; callers strip it and set ToolResult.skipped.
# ASCII-only so it can never provoke a UnicodeEncodeError on a restricted
# output locale (the whole point of #295 is to not crash).
_SKIP_MARK = " -- skipped"

# The exact string _build_sanitizer() returns to signal build-tool absence.
# _build_skipped() matches it by EQUALITY (not suffix) so a genuine
# "build failed: <stderr>" whose tail happened to end in _SKIP_MARK can never be
# misclassified as a skip.
_BUILD_ABSENT = "cmake not found" + _SKIP_MARK


def get_changed_ranges(base_ref: str, files: Optional[list[str]] = None) -> dict[str, list[LineRange]]:
    """Get changed line ranges from git diff. Returns {filepath: [LineRange, ...]}.

    Diffs base_ref against the *working tree* (not base_ref..HEAD) so the analyze
    step inspects uncommitted edits — it runs before commit in the workflow, so a
    HEAD-anchored diff would be empty and every linter would skip vacuously. On a
    clean committed tree `git diff base_ref` equals `base_ref..HEAD`.
    """
    cmd = ["git", "diff", "--unified=0", base_ref]
    if files:
        cmd += ["--"] + files
    result = subprocess.run(cmd, capture_output=True, text=True)
    if result.returncode != 0:
        print(f"error: git diff failed: {result.stderr}", file=sys.stderr)
        sys.exit(1)

    ranges: dict[str, list[LineRange]] = {}
    current_file = None

    for line in result.stdout.splitlines():
        # Match diff file header: +++ b/lib/qa_utils.cc
        m = re.match(r"^\+\+\+ b/(.+)$", line)
        if m:
            current_file = m.group(1)
            if current_file not in ranges:
                ranges[current_file] = []
            continue

        # Match hunk header: @@ -old,count +new,count @@
        m = re.match(r"^@@ .+ \+(\d+)(?:,(\d+))? @@", line)
        if m and current_file:
            start = int(m.group(1))
            count = int(m.group(2)) if m.group(2) else 1
            if count > 0:  # skip pure deletions
                ranges[current_file].append(LineRange(start, count))

    return ranges


# Untracked candidates must match one of these to enter changed-line scope (#591).
# It MIRRORS the per-file selectors in the run_* filters below: cpplint /
# clang-format (".cc", ".c", ".h"), clang-tidy / iwyu / compiler (".cc", ".c"),
# cmake-lint ((".cmake", "CMakeLists.txt"), matched with the same endswith() idiom
# run_cmake_lint uses) and ruff / flake8 / bandit / mypy (".py"). codespell and
# cppcheck have no suffix filter of their own (codespell takes the whole changed
# set; cppcheck keys off compile_commands.json), so they INHERIT this set rather
# than widening it — an unfiltered `ls-files --others` would feed codespell a
# target project's build clutter and arbitrary text. Keep in sync with those
# filters: test_untracked_suffixes_each_reach_a_runner asserts every entry here is
# selected by at least one runner.
_UNTRACKED_SOURCE_SUFFIXES = (".cc", ".c", ".h", ".py", ".cmake", "CMakeLists.txt")

# The analyzer's own build-dir convention (#324/#351): analyze-static.sh's fallback
# is <source_dir>/build-<project>-<issue>, and analyze-sanitizers.sh ALWAYS builds
# <source_dir>/build-<project>-<issue>-{asan,ubsan,tsan} at the repo root, whatever
# build_dir was configured. A candidate whose first path component carries this
# hyphenated prefix is never a source file of the target project (devAgent's own
# .gitignore declares the same glob). Deliberately NOT the bare `build*/` proxy —
# `builder/` and `build_tools/` are real source dirs and must survive.
_BUILD_DIR_PREFIX = "build-"


def _is_under(path: Path, directory: Path) -> bool:
    """True when `path` is inside `directory` (both already resolved)."""
    try:
        path.relative_to(directory)
        return True
    except ValueError:
        return False


def get_untracked_ranges(files: Optional[list[str]] = None,
                         exclude_dirs: Optional[list[str]] = None
                         ) -> dict[str, list[LineRange]]:
    """Whole-file ranges for UNTRACKED, non-ignored source files (#591).

    `git diff` lists TRACKED changes only, so a brand-new source file that has
    never been `git add`-ed produced no hunks: every per-file linter skipped it and
    the gate passed vacuously for exactly the file with the least review history.
    Each untracked candidate is therefore scoped as a WHOLE FILE —
    `LineRange(1, <line count>)` — so the per-file tools (cpplint, codespell, ruff,
    flake8, bandit, mypy, cmake-lint) run on it and filter_novel() counts every one
    of its lines as changed.

    Reach (a known limit, not a pass): the compile-database tools (cppcheck,
    clang-tidy, iwyu, compiler warnings) see an untracked file only once CMake
    does, and `git clang-format` diffs the INDEX against base_ref, so none of them
    reaches a file git does not track — they report it clean.

    Enumeration is READ-ONLY: no `git add`, no `git add -N` (intent-to-add would
    change later `git status`/commit behaviour), no temp commit. Staging is step
    12's job.

    `--exclude-standard` honours .gitignore, .git/info/exclude and core.excludesFile
    exactly as `git status` does, so ignored build output stays out. `-z` is what
    keeps a non-ASCII or space-bearing name from arriving QUOTED
    (`"caf\\303\\251.py"`), which would never match normalize_path()'s output in
    filter_novel(); `--full-name` keeps paths repo-root-relative like `git diff`'s
    `+++ b/` names, which ls-files does NOT do by default (it prints relative to the
    caller's cwd).

    files:        the same `--files` pathspecs get_changed_ranges() received, passed
                  after `--`, so a --files run can never widen to untracked files
                  outside the list.
    exclude_dirs: directories whose contents are never candidates — the analyzer's
                  own build_dir and its -asan/-ubsan/-tsan siblings, which a TARGET
                  project's .gitignore may not cover (devAgent's own does). A
                  root-level `build-*` component is excluded UNCONDITIONALLY
                  (_BUILD_DIR_PREFIX): the sanitizer legs build there regardless of
                  an operator-configured build_dir.
    """
    cmd = ["git", "ls-files", "--others", "--exclude-standard", "--full-name", "-z"]
    if files:
        cmd += ["--"] + files
    result = subprocess.run(cmd, capture_output=True, text=True)
    if result.returncode != 0:
        # Fail loud exactly like get_changed_ranges(): a swallowed enumeration
        # failure IS an empty untracked set, i.e. the silent gate this removes.
        print(f"error: git ls-files failed: {result.stderr}", file=sys.stderr)
        sys.exit(1)

    excluded = []
    for d in exclude_dirs or []:
        try:
            excluded.append(Path(d).resolve())
        except OSError:
            continue

    ranges: dict[str, list[LineRange]] = {}
    for path in result.stdout.split("\0"):
        if not path or not path.endswith(_UNTRACKED_SOURCE_SUFFIXES):
            continue
        # Exclude BEFORE reading: a swept build tree is thousands of files, and the
        # read is the cost (resolve is cheap).
        if path.split("/", 1)[0].startswith(_BUILD_DIR_PREFIX):
            continue
        try:
            resolved = Path(path).resolve()
        except OSError:
            print(f"warning: skipping unreadable untracked candidate: {path}",
                  file=sys.stderr)
            continue
        if any(_is_under(resolved, d) for d in excluded):
            continue
        try:
            text = Path(path).read_text(errors="replace")
        except OSError:
            # Listed by git but unreadable now (a race, a broken symlink, a
            # permission error, a mis-decoded name): skip it rather than abort the
            # whole analyze run — but SAY SO, so the skip is evidence, not silence.
            print(f"warning: skipping unreadable untracked candidate: {path}",
                  file=sys.stderr)
            continue
        # An EMPTY file gets LineRange(1, 1): a real (if vacuous) whole-file range
        # keeps the invariant "every untracked file in scope carries exactly one
        # range", and no tool can report a finding on a line that is not there.
        ranges[path] = [LineRange(1, max(1, len(text.splitlines())))]

    return dict(sorted(ranges.items()))


def line_in_ranges(line: int, ranges: list[LineRange]) -> bool:
    """Check if a line number falls within any changed range."""
    return any(r.start <= line <= r.end for r in ranges)


def get_changed_files(ranges: dict[str, list[LineRange]]) -> list[str]:
    """Get list of changed files that exist on disk."""
    return [f for f in ranges if os.path.isfile(f)]


def parse_file_line(text: str) -> tuple[Optional[str], Optional[int]]:
    """Extract file:line from a diagnostic message. Handles multiple formats."""
    # One regex covers both gcc/clang-tidy/cppcheck (file:line:col:) and cpplint
    # (file:line:) — the optional column group `\d*:?` degenerates to the
    # column-less form, so a separate cpplint branch would be unreachable (#267).
    m = re.match(r"^(.+?):(\d+):\d*:?\s", text)
    if m:
        return m.group(1), int(m.group(2))
    return None, None


def normalize_path(filepath: str, repo_root: str) -> str:
    """Convert absolute path to repo-relative path."""
    try:
        return str(Path(filepath).resolve().relative_to(Path(repo_root).resolve()))
    except ValueError:
        return filepath


def run_cppcheck(build_dir: str, changed_files: list[str], repo_root: str) -> ToolResult:
    """Run cppcheck using compile_commands.json, filtered to changed files."""
    result = ToolResult(tool="cppcheck")
    compile_db = os.path.join(build_dir, "compile_commands.json")
    if not os.path.isfile(compile_db):
        result.error = "compile_commands.json not found"
        result.passed = False
        return result

    # Build file filters for changed source files
    # cppcheck needs the paths as they appear in compile_commands.json
    file_filters = []
    for f in changed_files:
        file_filters += ["--file-filter=" + os.path.join(repo_root, f)]

    # Also check if any changed file is a template that generates code in build_dir
    for f in changed_files:
        if f.endswith(".tmpl.c") or f.endswith(".tmpl.h"):
            basename = os.path.basename(f).replace(".tmpl.", ".")
            generated = os.path.join(build_dir, "lib", basename)
            if os.path.isfile(generated):
                file_filters.append(f"--file-filter={generated}")

    if not file_filters:
        result.error = "no compilable files in diff"
        return result

    cmd = [
        "cppcheck",
        "--enable=all",
        "--suppress=missingIncludeSystem",
        "--suppress=unusedFunction",
        f"--project={compile_db}",
    ] + file_filters

    proc = subprocess.run(cmd, capture_output=True, text=True, timeout=300)
    output = proc.stderr  # cppcheck writes diagnostics to stderr

    for line in output.splitlines():
        if any(sev in line for sev in ("error:", "warning:", "style:", "performance:", "portability:")):
            # Skip "note:" continuation lines
            if ": note:" in line:
                continue
            filepath, lineno = parse_file_line(line)
            if filepath and lineno:
                # Extract severity
                sev_match = re.search(r": (error|warning|style|performance|portability):", line)
                severity = sev_match.group(1) if sev_match else "unknown"
                # Extract message (after severity tag)
                msg_match = re.search(r": (?:error|warning|style|performance|portability): (.+)", line)
                message = msg_match.group(1) if msg_match else line
                result.findings.append(Finding(
                    tool="cppcheck",
                    severity=severity,
                    file=normalize_path(filepath, repo_root),
                    line=lineno,
                    message=message.strip(),
                ))

    return result


def run_cpplint(changed_files: list[str], repo_root: str) -> ToolResult:
    """Run cpplint on changed files."""
    result = ToolResult(tool="cpplint")
    src_files = [f for f in changed_files if f.endswith((".cc", ".c", ".h"))]
    if not src_files:
        return result

    cmd = [
        "cpplint",
        "--filter=-legal/copyright,-build/include_order,-build/include_subdir,-readability/casting,-runtime/int",
    ] + src_files

    proc = subprocess.run(cmd, capture_output=True, text=True, timeout=120)
    output = proc.stderr  # cpplint writes to stderr

    for line in output.splitlines():
        filepath, lineno = parse_file_line(line)
        if filepath and lineno:
            # Extract category and severity: [category] [N]
            cat_match = re.search(r"\[(.+?)\]\s+\[(\d+)\]", line)
            category = cat_match.group(1) if cat_match else "unknown"
            severity_num = int(cat_match.group(2)) if cat_match else 0
            # Extract message (between line number and category tag)
            msg_match = re.search(r":\d+:\s+(.+?)\s+\[", line)
            message = msg_match.group(1).strip() if msg_match else line
            severity = "error" if severity_num >= 4 else "warning" if severity_num >= 2 else "style"
            result.findings.append(Finding(
                tool="cpplint",
                severity=severity,
                file=normalize_path(filepath, repo_root),
                line=lineno,
                message=f"{message} [{category}]",
            ))

    return result


def run_clang_tidy(build_dir: str, changed_files: list[str], repo_root: str) -> ToolResult:
    """Run clang-tidy on changed files."""
    result = ToolResult(tool="clang-tidy")
    src_files = [f for f in changed_files if f.endswith((".cc", ".c"))]
    if not src_files:
        return result

    cmd = ["clang-tidy", "-p", build_dir] + src_files
    proc = subprocess.run(cmd, capture_output=True, text=True, timeout=300)
    output = proc.stdout + proc.stderr

    for line in output.splitlines():
        if ": warning:" in line or ": error:" in line:
            filepath, lineno = parse_file_line(line)
            if filepath and lineno:
                sev = "error" if ": error:" in line else "warning"
                msg_match = re.search(r": (?:warning|error): (.+?)(?:\s+\[.+\])?$", line)
                message = msg_match.group(1) if msg_match else line
                check_match = re.search(r"\[(.+?)\]\s*$", line)
                check = check_match.group(1) if check_match else ""
                result.findings.append(Finding(
                    tool="clang-tidy",
                    severity=sev,
                    file=normalize_path(filepath, repo_root),
                    line=lineno,
                    message=f"{message} [{check}]" if check else message,
                ))

    return result


def run_scan_build(build_dir: str) -> ToolResult:
    """Run scan-build-18. Returns pass/fail (not line-filterable)."""
    result = ToolResult(tool="scan-build-18")
    cmd = [
        "scan-build-18",
        "--use-cc=clang-18", "--use-c++=clang++-18",
        "-o", "/tmp/scan-build-out",
        "cmake", "--build", build_dir, "--clean-first", "-j" + str(os.cpu_count() or 4),
    ]
    try:
        proc = subprocess.run(cmd, capture_output=True, text=True, timeout=600)
        output = proc.stderr + proc.stdout
        if "No bugs found" in output:
            result.passed = True
        else:
            result.passed = False
            # Try to extract bug count
            m = re.search(r"(\d+) bugs? found", output)
            if m:
                result.error = f"{m.group(1)} bug(s) found (see /tmp/scan-build-out/)"
            else:
                result.error = "scan-build reported issues (see /tmp/scan-build-out/)"
    except subprocess.TimeoutExpired:
        result.error = "timed out after 600s"
        result.passed = False
    except FileNotFoundError:
        # scan-build-18 (cmd[0]) is absent — not installed on this box. Skip,
        # don't crash: an absent tool is not a failure. (A present scan-build
        # with a missing cmake/clang surfaces via its own nonzero exit above.)
        result.error = "scan-build-18 not found"
        result.skipped = True

    return result


def run_iwyu(build_dir: str, changed_files: list[str], repo_root: str) -> ToolResult:
    """Run include-what-you-use via iwyu_tool."""
    result = ToolResult(tool="iwyu")
    src_files = [f for f in changed_files if f.endswith((".cc", ".c"))]
    if not src_files:
        return result

    cmd = ["iwyu_tool", "-p", build_dir] + src_files
    proc = subprocess.run(cmd, capture_output=True, text=True, timeout=300)
    output = proc.stdout + proc.stderr

    # IWYU reports "should add" and "should remove" per file.
    # Since IWYU doesn't give line numbers, we can't diff-gate findings.
    # Instead, mark all IWYU findings as NOT novel (pre-existing include
    # issues are the norm) and report them separately for awareness.
    current_file = None
    seen = set()  # deduplicate
    for line in output.splitlines():
        # File header: /path/to/file.cc should add these lines:
        m = re.match(r"^(.+?)\s+should (add|remove) these lines:", line)
        if m:
            current_file = normalize_path(m.group(1), repo_root)
            continue
        # Specific include suggestion: - #include <foo>  // for bar
        if current_file and re.match(r"^[+-]\s+#include", line):
            key = (current_file, line.strip())
            if key not in seen:
                seen.add(key)
                result.findings.append(Finding(
                    tool="iwyu",
                    severity="style",
                    file=current_file,
                    line=0,
                    message=line.strip(),
                    novel=False,  # IWYU can't be diff-gated
                ))

        # "(file has correct #includes)" means clean
        m = re.match(r"^\((.+?) has correct #includes", line)
        if m:
            current_file = None

    return result


def run_clang_format(base_ref: str, changed_files: list[str], repo_root: str) -> ToolResult:
    """Run git clang-format to check formatting of changed lines only."""
    result = ToolResult(tool="clang-format")
    src_files = [f for f in changed_files if f.endswith((".cc", ".c", ".h"))]
    if not src_files:
        return result

    # git clang-format shows what would change between base_ref and the working
    # tree (no HEAD endpoint) — so uncommitted edits are checked pre-commit; on a
    # clean committed tree this matches the prior `base_ref HEAD` two-commit form.
    cmd = ["git", "clang-format", "--diff", base_ref, "--"] + src_files
    proc = subprocess.run(cmd, capture_output=True, text=True, timeout=60)
    output = proc.stdout.strip()

    if not output or output == "no modified files to format" or output.startswith("clang-format did not modify"):
        return result

    # Parse unified diff output for changed files/lines
    current_file = None
    for line in output.splitlines():
        m = re.match(r"^diff --git a/(.+) b/", line)
        if m:
            current_file = m.group(1)
            continue
        m = re.match(r"^@@ .+ \+(\d+)(?:,(\d+))? @@", line)
        if m and current_file:
            start = int(m.group(1))
            result.findings.append(Finding(
                tool="clang-format",
                severity="style",
                file=current_file,
                line=start,
                message="formatting differs from .clang-format style",
            ))

    return result


def run_codespell(changed_files: list[str], repo_root: str) -> ToolResult:
    """Run codespell on changed files to catch typos."""
    result = ToolResult(tool="codespell")
    if not changed_files:
        return result

    cmd = ["codespell", "--quiet-level=2"] + changed_files
    proc = subprocess.run(cmd, capture_output=True, text=True, timeout=60)
    output = proc.stdout + proc.stderr

    for line in output.splitlines():
        # codespell format: file:line: word ==> suggestion
        m = re.match(r"^(.+?):(\d+):\s+(.+)", line)
        if m:
            result.findings.append(Finding(
                tool="codespell",
                severity="style",
                file=normalize_path(m.group(1), repo_root),
                line=int(m.group(2)),
                message=m.group(3).strip(),
            ))

    return result


def run_cmake_lint(changed_files: list[str], repo_root: str) -> ToolResult:
    """Run cmake-lint on changed CMake files."""
    result = ToolResult(tool="cmake-lint")
    cmake_files = [f for f in changed_files if f.endswith((".cmake", "CMakeLists.txt"))]
    if not cmake_files:
        return result

    cmake_lint = os.path.expanduser("~/venv/volk-dev/bin/cmake-lint")
    if not os.path.isfile(cmake_lint):
        result.error = "cmake-lint not found at ~/venv/volk-dev/bin/cmake-lint"
        result.skipped = True
        return result

    cmd = [cmake_lint] + cmake_files
    proc = subprocess.run(cmd, capture_output=True, text=True, timeout=60)
    output = proc.stdout + proc.stderr

    for line in output.splitlines():
        # cmake-lint format: file:line: [CODE] message
        # or: file:line,col: [CODE] message
        m = re.match(r"^(.+?):(\d+)[\d,]*:\s+\[(\w+)\]\s+(.+)", line)
        if m:
            result.findings.append(Finding(
                tool="cmake-lint",
                severity="style",
                file=normalize_path(m.group(1), repo_root),
                line=int(m.group(2)),
                message=f"{m.group(4).strip()} [{m.group(3)}]",
            ))

    return result


def run_ruff(changed_files: list[str], repo_root: str) -> ToolResult:
    """Run ruff on changed Python files."""
    result = ToolResult(tool="ruff")
    py_files = [f for f in changed_files if f.endswith(".py")]
    if not py_files:
        return result

    ruff = os.path.expanduser("~/venv/volk-dev/bin/ruff")
    if not os.path.isfile(ruff):
        result.error = "ruff not found at ~/venv/volk-dev/bin/ruff"
        result.skipped = True
        return result

    cmd = [ruff, "check", "--output-format=concise"] + py_files
    proc = subprocess.run(cmd, capture_output=True, text=True, timeout=60)
    output = proc.stdout + proc.stderr

    for line in output.splitlines():
        # ruff concise format: file:line:col: CODE message
        m = re.match(r"^(.+?):(\d+):\d+:\s+(\w+)\s+(.+)$", line)
        if m:
            result.findings.append(Finding(
                tool="ruff",
                severity="style",
                file=normalize_path(m.group(1), repo_root),
                line=int(m.group(2)),
                message=f"{m.group(4)} [{m.group(3)}]",
            ))

    return result


def run_flake8(changed_files: list[str], repo_root: str) -> ToolResult:
    """Run flake8 on changed Python files."""
    result = ToolResult(tool="flake8")
    py_files = [f for f in changed_files if f.endswith(".py")]
    if not py_files:
        return result

    flake8 = os.path.expanduser("~/venv/volk-dev/bin/flake8")
    if not os.path.isfile(flake8):
        result.error = "flake8 not found at ~/venv/volk-dev/bin/flake8"
        result.skipped = True
        return result

    # Use 90-char limit to match project style; suppress E501 if line under 90
    cmd = [flake8, "--max-line-length=90"] + py_files
    proc = subprocess.run(cmd, capture_output=True, text=True, timeout=60)
    output = proc.stdout + proc.stderr

    for line in output.splitlines():
        # flake8 format: file:line:col: CODE message
        m = re.match(r"^(.+?):(\d+):\d+:\s+(\w+)\s+(.+)$", line)
        if m:
            result.findings.append(Finding(
                tool="flake8",
                severity="style",
                file=normalize_path(m.group(1), repo_root),
                line=int(m.group(2)),
                message=f"{m.group(4)} [{m.group(3)}]",
            ))

    return result


def run_bandit(changed_files: list[str], repo_root: str) -> ToolResult:
    """Run bandit security linter on changed Python files."""
    result = ToolResult(tool="bandit")
    py_files = [f for f in changed_files if f.endswith(".py")]
    if not py_files:
        return result

    bandit = os.path.expanduser("~/venv/volk-dev/bin/bandit")
    if not os.path.isfile(bandit):
        result.error = "bandit not found at ~/venv/volk-dev/bin/bandit"
        result.skipped = True
        return result

    cmd = [bandit, "-q", "-f", "custom",
           "--msg-template", "{abspath}:{line}: [{test_id}/{severity}] {msg}"] + py_files
    proc = subprocess.run(cmd, capture_output=True, text=True, timeout=60)
    output = proc.stdout + proc.stderr

    for line in output.splitlines():
        # bandit custom format: /abs/path:line: [TEST_ID/SEVERITY] message
        m = re.match(r"^(.+?):(\d+):\s+\[(\w+)/(\w+)\]\s+(.+)$", line)
        if m:
            result.findings.append(Finding(
                tool="bandit",
                severity=m.group(4).lower(),
                file=normalize_path(m.group(1), repo_root),
                line=int(m.group(2)),
                message=f"{m.group(5)} [{m.group(3)}]",
            ))

    return result


def run_mypy(changed_files: list[str], repo_root: str) -> ToolResult:
    """Run mypy type checker on changed Python files."""
    result = ToolResult(tool="mypy")
    py_files = [f for f in changed_files if f.endswith(".py")]
    if not py_files:
        return result

    mypy = os.path.expanduser("~/venv/volk-dev/bin/mypy")
    if not os.path.isfile(mypy):
        result.error = "mypy not found at ~/venv/volk-dev/bin/mypy"
        result.skipped = True
        return result

    cmd = [mypy, "--ignore-missing-imports", "--no-error-summary"] + py_files
    proc = subprocess.run(cmd, capture_output=True, text=True, timeout=120)
    output = proc.stdout + proc.stderr

    for line in output.splitlines():
        # mypy format: file:line: severity: message
        m = re.match(r"^(.+?):(\d+):\s+(error|warning|note):\s+(.+)$", line)
        if m and m.group(3) != "note":
            result.findings.append(Finding(
                tool="mypy",
                severity=m.group(3),
                file=normalize_path(m.group(1), repo_root),
                line=int(m.group(2)),
                message=m.group(4).strip(),
            ))

    return result


def run_compiler_warnings(build_dir: str, changed_files: list[str], repo_root: str) -> ToolResult:
    """Capture compiler warnings by touching changed files and rebuilding."""
    result = ToolResult(tool="compiler")

    # Touch changed source files to force recompilation of just those files
    for f in changed_files:
        full_path = os.path.join(repo_root, f)
        if os.path.isfile(full_path) and f.endswith((".cc", ".c")):
            os.utime(full_path)

    # Also touch generated files from templates
    for f in changed_files:
        if f.endswith(".tmpl.c") or f.endswith(".tmpl.h"):
            basename = os.path.basename(f).replace(".tmpl.", ".")
            generated = os.path.join(build_dir, "lib", basename)
            if os.path.isfile(generated):
                os.utime(generated)

    cmd = ["cmake", "--build", build_dir, "-j" + str(os.cpu_count() or 4)]
    try:
        proc = subprocess.run(cmd, capture_output=True, text=True, timeout=300)
    except subprocess.TimeoutExpired:
        result.error = "timed out after 300s"
        result.passed = False
        return result
    except FileNotFoundError:
        # cmake (cmd[0]) absent — the build tool isn't installed here. Skip.
        result.error = "cmake not found"
        result.skipped = True
        return result
    output = proc.stderr + proc.stdout

    for line in output.splitlines():
        if ": warning:" in line or ": error:" in line:
            filepath, lineno = parse_file_line(line)
            if filepath and lineno:
                sev = "error" if ": error:" in line else "warning"
                msg_match = re.search(r": (?:warning|error): (.+?)(?:\s+\[-.+\])?$", line)
                message = msg_match.group(1) if msg_match else line
                flag_match = re.search(r"\[(-W.+?)\]\s*$", line)
                flag = flag_match.group(1) if flag_match else ""
                result.findings.append(Finding(
                    tool="compiler",
                    severity=sev,
                    file=normalize_path(filepath, repo_root),
                    line=lineno,
                    message=f"{message} [{flag}]" if flag else message,
                ))

    if proc.returncode != 0 and not result.findings:
        result.error = "build failed"
        result.passed = False

    return result


def _build_sanitizer(repo_root: str, build_dir: str, flags: str,
                     launcher: Optional[list] = None) -> Optional[str]:
    """Configure and build with sanitizer flags. Returns error string or None.

    launcher, if given, is prepended to the `cmake --build` commands — used to
    run the build under `setarch … --addr-no-randomize` for TSan so the
    build-time gtest_discover_tests exec does not FATAL on ASLR (parity with
    #32 in analyze-sanitizers.sh).
    """
    launch = launcher or []
    if os.path.isfile(os.path.join(build_dir, "build.ninja")):
        # Already configured — just rebuild
        try:
            proc = subprocess.run(
                launch + ["cmake", "--build", build_dir, "-j" + str(os.cpu_count() or 4)],
                capture_output=True, text=True, timeout=600,
            )
        except subprocess.TimeoutExpired:
            return "build timed out after 600s"
        except FileNotFoundError:
            return _BUILD_ABSENT
        if proc.returncode != 0:
            return f"build failed: {proc.stderr[-500:]}"
        return None

    os.makedirs(build_dir, exist_ok=True)
    # Configure
    try:
        proc = subprocess.run(
            ["cmake", "-S", repo_root, "-B", build_dir,
             "-DCMAKE_BUILD_TYPE=Debug",
             f"-DCMAKE_C_FLAGS={flags}",
             f"-DCMAKE_CXX_FLAGS={flags}",
             f"-DCMAKE_EXE_LINKER_FLAGS={flags}",
             "-GNinja"],
            capture_output=True, text=True, timeout=120,
        )
    except subprocess.TimeoutExpired:
        return "cmake configure timed out after 120s"
    except FileNotFoundError:
        return "cmake not found" + _SKIP_MARK
    if proc.returncode != 0:
        return f"cmake configure failed: {proc.stderr[-500:]}"

    # Build
    try:
        proc = subprocess.run(
            launch + ["cmake", "--build", build_dir, "-j" + str(os.cpu_count() or 4)],
            capture_output=True, text=True, timeout=600,
        )
    except subprocess.TimeoutExpired:
        return "build timed out after 600s"
    except FileNotFoundError:
        return "cmake not found" + _SKIP_MARK
    if proc.returncode != 0:
        return f"build failed: {proc.stderr[-500:]}"

    return None


def _run_test_kernel(build_dir: str, kernel: str, env: Optional[dict] = None,
                     prefix: Optional[list[str]] = None) -> tuple[int, str, str]:
    """Run volk_profile on a single kernel. Returns (returncode, stdout, stderr)."""
    volk_profile = os.path.join(build_dir, "apps", "volk_profile")
    cmd = (prefix or []) + [volk_profile, "-R", kernel, "--dry-run"]
    full_env = os.environ.copy()
    if env:
        full_env.update(env)
    try:
        proc = subprocess.run(cmd, capture_output=True, text=True, timeout=120, env=full_env)
    except subprocess.TimeoutExpired:
        # 124 = conventional timeout exit code; the marker stderr lets the callers
        # surface "timed out" rather than a misleading "exited with code 124".
        return 124, "", "timed out after 120s"
    except FileNotFoundError:
        # A missing test binary on a *successfully built* project is a real
        # misconfiguration (wrong build dir, wrong project), NOT tool-absence —
        # keep it a distinct error (127 = "command not found"), never a skip.
        # This is unreachable on a box that can't build (cmake absent skips
        # first), but guards against a crash if it ever is reached.
        return 127, "", f"volk_profile not found: {volk_profile}"
    return proc.returncode, proc.stdout, proc.stderr


def _setarch_prefix() -> list[str]:
    """`setarch <machine> --addr-no-randomize` prefix to disable ASLR for the
    TSan build/run, or [] when setarch is unavailable (non-Linux, or absent).

    Guards `os.uname()` — which does not exist on Windows and raises
    AttributeError — behind the setarch presence check, so it is only ever
    evaluated where setarch (a Linux util) is actually installed.
    """
    if not shutil.which("setarch"):
        return []
    return ["setarch", os.uname().machine, "--addr-no-randomize"]


def _build_skipped(result: ToolResult, err: Optional[str]) -> bool:
    """If `err` (a _build_sanitizer return) is the build-tool-absence sentinel,
    record it as skipped on `result` and return True (the caller should then
    return). Otherwise return False so the caller handles a real failure."""
    if err == _BUILD_ABSENT:
        result.error = err.removesuffix(_SKIP_MARK)
        result.skipped = True
        return True
    return False


def run_asan_ubsan(repo_root: str, build_dir: str, kernel: str) -> ToolResult:
    """Build with ASan+UBSan, run a test kernel, check for sanitizer output."""
    result = ToolResult(tool="asan+ubsan")
    flags = "-fsanitize=address,undefined -fno-omit-frame-pointer"

    err = _build_sanitizer(repo_root, build_dir, flags)
    if err:
        if not _build_skipped(result, err):
            result.error = err
            result.passed = False
        return result

    rc, stdout, stderr = _run_test_kernel(build_dir, kernel)
    combined = stdout + stderr

    # ASan/UBSan report to stderr with distinctive markers
    san_errors = []
    for line in combined.splitlines():
        if any(marker in line for marker in (
            "ERROR: AddressSanitizer",
            "ERROR: LeakSanitizer",
            "runtime error:",  # UBSan
            "SUMMARY: AddressSanitizer",
            "SUMMARY: UndefinedBehaviorSanitizer",
        )):
            san_errors.append(line.strip())

    if san_errors:
        result.passed = False
        for err_line in san_errors:
            result.findings.append(Finding(
                tool="asan+ubsan",
                severity="error",
                file="(runtime)",
                line=0,
                message=err_line[:200],
            ))
    elif rc != 0:
        result.passed = False
        if "timed out" in stderr or "volk_profile not found" in stderr:
            # _run_test_kernel crafts these; surface them rather than a generic
            # "exited with code N" that discards the diagnostic.
            result.error = stderr.strip()
        else:
            result.error = f"exited with code {rc} (no sanitizer output captured)"
    else:
        result.passed = True

    return result


def run_tsan(repo_root: str, build_dir: str, kernel: str) -> ToolResult:
    """Build with TSan, run a test kernel, check for data races."""
    result = ToolResult(tool="tsan")
    flags = "-fsanitize=thread -fno-omit-frame-pointer"

    # Parity with #32 (analyze-sanitizers.sh): gtest_discover_tests execs the
    # freshly linked test binary at BUILD time, which FATALs under TSan when
    # ASLR is on (Ubuntu 24.04+), silently dropping that target. Disable ASLR
    # for the TSan build too — not just the test run below. The binary-exists
    # fallback is retained as defense-in-depth.
    build_launcher = _setarch_prefix()
    err = _build_sanitizer(repo_root, build_dir, flags, launcher=build_launcher)
    volk_profile = os.path.join(build_dir, "apps", "volk_profile")
    if _build_skipped(result, err):
        return result
    if err and not os.path.isfile(volk_profile):
        result.error = err
        result.passed = False
        return result

    # TSan can fail with ASLR on some kernels; try with ASLR disabled
    rc, stdout, stderr = _run_test_kernel(
        build_dir, kernel,
        prefix=_setarch_prefix(),
    )
    combined = stdout + stderr

    # Check for TSan FATAL (ASLR issue) — retry is pointless, report as skip
    if "FATAL: ThreadSanitizer: unexpected memory mapping" in combined:
        result.error = "TSan FATAL: ASLR incompatibility (even with --addr-no-randomize)"
        result.passed = False
        return result

    san_errors = []
    for line in combined.splitlines():
        if any(marker in line for marker in (
            "WARNING: ThreadSanitizer:",
            "SUMMARY: ThreadSanitizer:",
        )):
            san_errors.append(line.strip())

    if san_errors:
        result.passed = False
        for err_line in san_errors:
            result.findings.append(Finding(
                tool="tsan",
                severity="error",
                file="(runtime)",
                line=0,
                message=err_line[:200],
            ))
    elif rc != 0:
        result.passed = False
        if "timed out" in stderr or "volk_profile not found" in stderr:
            # _run_test_kernel crafts these; surface them rather than a generic
            # "exited with code N" that discards the diagnostic.
            result.error = stderr.strip()
        else:
            result.error = f"exited with code {rc} (no sanitizer output captured)"
    else:
        result.passed = True

    return result


def filter_novel(findings: list[Finding], ranges: dict[str, list[LineRange]]) -> list[Finding]:
    """Mark findings as novel if they fall within changed line ranges."""
    for f in findings:
        if f.line == 0:
            # Tools like IWYU that don't report line numbers — mark novel
            # if the file is in our diff at all
            f.novel = f.file in ranges
        elif f.file in ranges:
            f.novel = line_in_ranges(f.line, ranges[f.file])
        else:
            # Generated files (from templates) don't have 1:1 line mapping,
            # so we can't reliably determine novelty. Leave as not novel.
            f.novel = False
    return findings


def print_summary(results: list[ToolResult], ranges: dict[str, list[LineRange]]):
    """Print a markdown summary table."""
    print("\n## Static Analysis Summary\n")
    print("| Tool | Total | Novel | Status |")
    print("|------|-------|-------|--------|")

    all_novel: list[Finding] = []

    for r in results:
        if r.skipped:
            # Tool/executable absent — rendered distinctly from a real error so
            # the tee'd table the agent/MR reads isn't a wall of false "error:".
            reason = f" ({r.error})" if r.error else ""
            print(f"| {r.tool} | - | - | skipped{reason} |")
            continue
        if r.error and not r.findings:
            status = f"error: {r.error}"
            print(f"| {r.tool} | - | - | {status} |")
            continue

        novel_count = sum(1 for f in r.findings if f.novel)
        total = len(r.findings)

        if r.tool in ("scan-build-18", "asan+ubsan", "tsan"):
            if r.error:
                status = f"FAIL: {r.error}"
            elif r.findings:
                status = f"**FAIL: {len(r.findings)} issue(s)**"
            else:
                status = "pass" if r.passed else "FAIL"
            print(f"| {r.tool} | - | - | {status} |")
            if r.findings:
                all_novel.extend(r.findings)
            continue

        status = "clean" if novel_count == 0 else f"**{novel_count} novel**"
        print(f"| {r.tool} | {total} | {novel_count} | {status} |")
        all_novel.extend(f for f in r.findings if f.novel)

    if all_novel:
        print("\n## Novel Findings (in changed lines)\n")
        print("| Tool | Severity | File | Line | Message |")
        print("|------|----------|------|------|---------|")
        for f in all_novel:
            line_str = str(f.line) if f.line > 0 else "-"
            print(f"| {f.tool} | {f.severity} | {f.file} | {line_str} | {f.message} |")
    else:
        print("\n**No novel findings in changed lines.**")


def _finalize_pool_result(name, produce, ranges, progress) -> ToolResult:
    """Run one read-only pool tool (`produce()` returns its ToolResult or raises)
    and classify the outcome: FileNotFoundError (the executable is absent —
    subprocess.run only raises it when cmd[0] is missing) → skipped, any other
    exception → FAILED (a real error), success → findings filtered to the diff.
    Extracted from main()'s pool loop so the absence→skip classification is
    unit-testable (#295)."""
    try:
        r = produce()
    except FileNotFoundError:
        print(f"  {name}: skipped (not found)", flush=True, file=progress)
        return ToolResult(tool=name, error=f"{name} not found", passed=True, skipped=True)
    except Exception as e:  # noqa: BLE001 — a tool failing must not abort the run
        print(f"  {name}: FAILED ({e})", flush=True, file=progress)
        return ToolResult(tool=name, error=str(e), passed=False)
    # IWYU findings are pre-marked novel=False (not diff-gatable)
    if r.tool != "iwyu":
        r.findings = filter_novel(r.findings, ranges)
    novel = sum(1 for f in r.findings if f.novel)
    print(f"  {name}: done ({len(r.findings)} total, {novel} novel)", flush=True, file=progress)
    return r


def main():
    parser = argparse.ArgumentParser(
        description="Run static analysis tools filtered to changed lines.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__,
    )
    parser.add_argument("base_ref", help="Git ref to diff against (e.g. origin/main)")
    parser.add_argument("build_dir", help="CMake build directory (must have compile_commands.json)")
    parser.add_argument("--files", nargs="*", help="Limit to specific files (default: all changed)")
    parser.add_argument("--repo", default=None,
                        help="Target project repo (default: ambient CWD's git toplevel). "
                             "Pins all git operations to this repo so analyze is CWD-independent.")
    parser.add_argument("--skip", nargs="*", default=[], help="Tools to skip (e.g. --skip scan-build asan tsan)")
    parser.add_argument("--json", action="store_true", help="Output as JSON instead of markdown")
    parser.add_argument("--test-kernel", default="volk_32f_x2_add_32f",
                        help="Kernel to run for sanitizer tests (default: volk_32f_x2_add_32f)")
    parser.add_argument("--asan-build-dir", default=None,
                        help="ASan+UBSan build dir (default: <build_dir>-asan)")
    parser.add_argument("--tsan-build-dir", default=None,
                        help="TSan build dir (default: <build_dir>-tsan)")
    args = parser.parse_args()

    rev_parse = ["git", "rev-parse", "--show-toplevel"]
    if args.repo:
        rev_parse = ["git", "-C", args.repo] + rev_parse[1:]
    repo_root = subprocess.run(rev_parse, capture_output=True, text=True).stdout.strip()

    if not repo_root:
        target = args.repo or "the current directory"
        print(f"error: {target} is not inside a git repository", file=sys.stderr)
        sys.exit(1)

    os.chdir(repo_root)

    # #119: under --json, stdout must carry only the JSON document, so all human
    # progress goes to stderr. In markdown mode progress stays on stdout.
    progress = sys.stderr if args.json else sys.stdout

    print(f"Base ref: {args.base_ref}", file=progress)
    print(f"Build dir: {args.build_dir}", file=progress)

    # Get changed line ranges
    ranges = get_changed_ranges(args.base_ref, args.files)
    if not ranges:
        print("No changed files found in diff.", file=progress)
        if args.json:
            print(json.dumps([], indent=2))
        sys.exit(0)

    changed_files = get_changed_files(ranges)
    print(f"Changed files: {', '.join(changed_files)}", file=progress)
    for f, rs in ranges.items():
        range_strs = [f"{r.start}-{r.end}" if r.count > 1 else str(r.start) for r in rs]
        print(f"  {f}: lines {', '.join(range_strs)}", file=progress)
    print(file=progress)

    # Run tools: read-only tools in parallel, build tools sequentially after
    results: list[ToolResult] = []

    skip = set(s.lower().replace("-", "").replace("_", "") for s in args.skip)

    # -- Phase 1: read-only tools (parallel) --
    read_only_tasks: list[tuple[str, callable, list]] = []

    if "cppcheck" not in skip:
        read_only_tasks.append(("cppcheck",
            lambda: run_cppcheck(args.build_dir, changed_files, repo_root), []))
    if "cpplint" not in skip:
        read_only_tasks.append(("cpplint",
            lambda: run_cpplint(changed_files, repo_root), []))
    if "clangtidy" not in skip:
        read_only_tasks.append(("clang-tidy",
            lambda: run_clang_tidy(args.build_dir, changed_files, repo_root), []))
    if "iwyu" not in skip:
        read_only_tasks.append(("iwyu",
            lambda: run_iwyu(args.build_dir, changed_files, repo_root), []))
    if "clangformat" not in skip:
        read_only_tasks.append(("clang-format",
            lambda: run_clang_format(args.base_ref, changed_files, repo_root), []))
    if "codespell" not in skip:
        read_only_tasks.append(("codespell",
            lambda: run_codespell(changed_files, repo_root), []))
    if "cmakelint" not in skip:
        read_only_tasks.append(("cmake-lint",
            lambda: run_cmake_lint(changed_files, repo_root), []))
    if "ruff" not in skip:
        read_only_tasks.append(("ruff",
            lambda: run_ruff(changed_files, repo_root), []))
    if "flake8" not in skip:
        read_only_tasks.append(("flake8",
            lambda: run_flake8(changed_files, repo_root), []))
    if "bandit" not in skip:
        read_only_tasks.append(("bandit",
            lambda: run_bandit(changed_files, repo_root), []))
    if "mypy" not in skip:
        read_only_tasks.append(("mypy",
            lambda: run_mypy(changed_files, repo_root), []))

    if read_only_tasks:
        names = ", ".join(name for name, _, _ in read_only_tasks)
        print(f"Running read-only tools in parallel: {names}", flush=True, file=progress)

        with concurrent.futures.ThreadPoolExecutor(max_workers=len(read_only_tasks)) as pool:
            futures = {
                pool.submit(fn): name for name, fn, _ in read_only_tasks
            }
            for future in concurrent.futures.as_completed(futures):
                name = futures[future]
                results.append(_finalize_pool_result(name, future.result, ranges, progress))

    # -- Phase 2: build tools (sequential, no parallel compilation) --
    if "scanbuild" not in skip:
        print("Running scan-build-18 (build pass)...", flush=True, file=progress)
        r = run_scan_build(args.build_dir)
        results.append(r)

    if "compiler" not in skip:
        print("Running compiler warning check (build pass)...", flush=True, file=progress)
        r = run_compiler_warnings(args.build_dir, changed_files, repo_root)
        r.findings = filter_novel(r.findings, ranges)
        results.append(r)

    # -- Phase 3: sanitizer builds (sequential, each needs its own build dir) --
    asan_dir = args.asan_build_dir or (args.build_dir + "-asan")
    tsan_dir = args.tsan_build_dir or (args.build_dir + "-tsan")

    if "asan" not in skip and "asanubsan" not in skip:
        print(f"Running ASan+UBSan (build dir: {asan_dir})...", flush=True, file=progress)
        r = run_asan_ubsan(repo_root, asan_dir, args.test_kernel)
        results.append(r)

    if "tsan" not in skip:
        print(f"Running TSan (build dir: {tsan_dir})...", flush=True, file=progress)
        r = run_tsan(repo_root, tsan_dir, args.test_kernel)
        results.append(r)

    # Sort results into a consistent display order
    tool_order = ["cppcheck", "cpplint", "clang-tidy", "scan-build-18", "iwyu",
                  "clang-format", "cmake-lint", "codespell",
                  "ruff", "flake8", "bandit", "mypy",
                  "compiler", "asan+ubsan", "tsan"]
    results.sort(key=lambda r: tool_order.index(r.tool) if r.tool in tool_order else 99)

    # Output
    if args.json:
        output = []
        for r in results:
            output.append({
                "tool": r.tool,
                "passed": r.passed,
                "skipped": r.skipped,
                "error": r.error,
                "findings": [
                    {"severity": f.severity, "file": f.file, "line": f.line,
                     "message": f.message, "novel": f.novel}
                    for f in r.findings
                ],
            })
        print(json.dumps(output, indent=2))
    else:
        print_summary(results, ranges)


if __name__ == "__main__":
    main()
