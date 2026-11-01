#!/usr/bin/env python3
"""trust_policy.py — load, validate and key the #711 trust policy (#713).

Run as `python3 -I -X utf8 trust_policy.py <verb> …` (scripts/lib/trust.sh).

    load <dir> [--forbid <dir>]…   validate <dir>/policy.toml; print its facts
    get  <dir> <key>               one key's normalised value, as JSON
    key  <backend> <repo> [<num>] [--host <h>]
                                   the canonical repo key, or issue key with <num>
    keys                           every legal key and its type (the spec §3.8
                                   table is held equal to it)

Exit 0 ok · 2 usage · 3 policy defect. A defect prints a one-line reason on
stderr and nothing on stdout, so a caller can never read a half-validated
policy. `load` prints `<kind>\\t<name>\\t<value>` lines, no field empty:

    digest  -      sha256:<hex>
    file    -      <path>
    scope   -      <repo-key>
    id      <set>  <backend>:<id>
    val     <key>  <json>

Every machine-read byte goes through sys.stdout.buffer with b"\\n": text-mode
stdout on Windows writes CRLF, and a CR reaching bash would corrupt a key
(trust.sh refuses any CR as a second guard).
"""

from __future__ import annotations

import hashlib
import json
import os
import re
import sys

try:
    import tomllib          # stdlib, Python >= 3.11
except ModuleNotFoundError:  # Python 3.8-3.10: the same parser, packaged
    import tomli as tomllib  # apt install python3-tomli / pip install tomli


class Defect(Exception):
    """The policy is unusable; rc 3."""


class Usage(Exception):
    """Bad arguments; rc 2."""


BACKENDS = ("github", "gitlab", "jira")
ID_SETS = ("trusted_approvers", "trusted_reporters", "trusted_reviewers",
           "worker_identities", "code_host_workers")
TRUSTED_SETS = ("trusted_approvers", "trusted_reporters", "trusted_reviewers")
GATES = ("push_mr", "commit_devdoc", "merge_to_all_prs", "merge_mr", "file")
HARDENINGS = ("signatures", "separate_identity", "system_policy")

# KEYS is the single key list: name -> type. Siblings (#714-#721) amend only
# this table; an unknown key or a wrong type is a defect.
KEYS = {
    **{k: "idlist" for k in ID_SETS},
    "scopes": "repolist",
    "authorized_repos": "repolist",
    "trackers": "trackers",
    **{k: "str" for k in ("in_progress", "claim", "quarantine", "devdoc_remote",
                          "screen_model", "keyring", "ssh_keygen")},
    "provenance": "provenance",
    **{k: "strlist" for k in ("later_stages", "revoking", "allowed_steering",
                              "paths_deny", "paths_allow", "fixture_paths",
                              "outward_actions", "attested_keys")},
    "allowed_chars": "charlist",
    "approval": "approval",
    "size_classes": "size_classes",
    "size_cap": "int",
    **{k: "bool" for k in ("approver_not_author", "require_trusted_reporter",
                           "require_user_verification", "test_seams",
                           "single_identity") + GATES},
    "required_hardening": "hardening",
}

DEFAULTS = {
    "revoking": [],
    "require_user_verification": True,
    "test_seams": False,
    "single_identity": False,
    "required_hardening": [],
    **{g: False for g in GATES},
}

TRACKER_KEYS = {
    "github": ("host",),
    "gitlab": ("api_url",),
    "jira": ("base_url", "project_key"),
}

ID_SHAPES = {
    "github": re.compile(r"[1-9][0-9]{0,19}"),
    "gitlab": re.compile(r"[1-9][0-9]{0,19}"),
    "jira": re.compile(r"([0-9a-f]{24}|[0-9]{1,10}:[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12})"),
}

JIRA_KEY = re.compile(r"[A-Z][A-Z0-9_]*")


# ---------------------------------------------------------------- keys


def _strip_scheme(h: str) -> str:
    h = re.sub(r"^[a-z][a-z0-9+.-]*://", "", h.strip().lower())
    return h.rstrip("/")


def _issue_suffix(backend: str, num: str | None) -> str:
    if num is None:
        return ""
    if not re.fullmatch(r"[0-9]+", num) or int(num) == 0:
        raise Usage(f"issue number '{num}' is not a positive integer")
    return ("-" if backend == "jira" else "#") + str(int(num))


def canonical_key(backend: str, repo: str, num: str | None = None,
                  host: str | None = None) -> str:
    """`<backend>:<host>/<path>` plus `#<n>` (github/gitlab) or `-<n>` (jira).

    The host never comes from GH_HOST: a bare repo takes the --host given
    (trackers.github.host / gitlab.api_url / jira.base_url) or the public
    default, so the key cannot follow an ambient variable.
    """
    if backend == "jira":
        if not host:
            raise Usage("a jira key needs --host (trackers.jira.base_url)")
        key = repo.strip().upper()
        if not JIRA_KEY.fullmatch(key):
            raise Usage(f"jira project key '{repo}' is not a project KEY")
        return f"jira:{_strip_scheme(host)}/{key}" + _issue_suffix(backend, num)
    if backend not in ("github", "gitlab"):
        raise Usage(f"backend '{backend}' has no canonical key")
    r = repo.strip().lower()
    url_host = None
    m = re.fullmatch(r"[a-z][a-z0-9+.-]*://([^/]+)/(.*)", r)
    if m:
        url_host, r = m.group(1), m.group(2)
    else:
        m = re.fullmatch(r"[^@/]+@([^:/]+):(.*)", r)
        if m:
            url_host, r = m.group(1), m.group(2)
    r = r.rstrip("/")
    if r.endswith(".git"):
        r = r[:-4]
    parts = [p for p in r.split("/") if p]
    if backend == "github":
        if url_host is None and len(parts) == 3:
            url_host, parts = parts[0], parts[1:]
        if len(parts) != 2:
            raise Usage(f"repo '{repo}' is not OWNER/REPO")
        h = url_host or (_strip_scheme(host) if host else "github.com")
    else:
        if len(parts) < 2:
            raise Usage(f"repo '{repo}' is not GROUP/PROJECT")
        h = url_host or (re.sub(r"/api/v4$", "", _strip_scheme(host)) if host else "gitlab.com")
    return f"{backend}:{h}/{'/'.join(parts)}" + _issue_suffix(backend, num)


def canonical_scope(s: str) -> str:
    """Normalise a policy repo key; owner-level prefixes are not legal."""
    m = re.fullmatch(r"(github|gitlab|jira):([^/]+)/(.+)", s.strip()) if isinstance(s, str) else None
    if not m:
        raise Defect(f"scope '{s}' is not an exact repo key (<backend>:<host>/<path>)")
    backend, host, path = m.groups()
    try:
        if backend == "jira":
            *base, key = path.split("/")
            return canonical_key("jira", key, host="/".join([host] + base))
        return canonical_key(backend, f"https://{host}/{path}")
    except Usage:
        raise Defect(f"scope '{s}' is not an exact repo key (owner-level scopes are not legal)") from None


# ---------------------------------------------------------------- load


def _realpath(p: str) -> str:
    return os.path.normcase(os.path.realpath(p))


def _under(path: str, root: str) -> bool:
    try:
        return os.path.commonpath([_realpath(path), _realpath(root)]) == _realpath(root)
    except ValueError:      # different drives on Windows
        return False


def _type_check(key: str, kind: str, v):
    def need(cond, what):
        if not cond:
            raise Defect(f"key '{key}' must be {what}")

    def str_list(x):
        return isinstance(x, list) and all(isinstance(e, str) for e in x)

    if kind == "bool":
        need(isinstance(v, bool), "a boolean")
    elif kind == "str":
        need(isinstance(v, str), "a string")
    elif kind == "int":
        need(isinstance(v, int) and not isinstance(v, bool) and v >= 0, "a non-negative integer")
    elif kind in ("strlist", "idlist", "repolist"):
        need(str_list(v), "a list of strings")
    elif kind == "charlist":
        need(str_list(v) and all(len(e) == 1 for e in v), "a list of single characters")
    elif kind == "provenance":
        need(v in ("required", "optional"), "'required' or 'optional'")
    elif kind == "hardening":
        need(str_list(v), "a list of strings")
        for e in v:
            if e not in HARDENINGS:
                raise Defect(f"required_hardening member '{e}' is not one of {', '.join(HARDENINGS)}")
    elif kind == "approval":
        need(isinstance(v, dict) and set(v) == {"kind", "id"}
             and v.get("kind") in ("label", "status") and isinstance(v.get("id"), str),
             '{kind = "label"|"status", id = "<name>"}')
    elif kind == "size_classes":
        need(isinstance(v, dict) and all(isinstance(n, int) and not isinstance(n, bool) and n >= 0
                                         for n in v.values()),
             "a table of non-negative integers")
    elif kind == "trackers":
        need(isinstance(v, dict), "a table")
        for b, sub in v.items():
            if b not in TRACKER_KEYS:
                raise Defect(f"unknown key 'trackers.{b}'")
            need(isinstance(sub, dict), "a table of tables")
            for k, s in sub.items():
                if k not in TRACKER_KEYS[b]:
                    raise Defect(f"unknown key 'trackers.{b}.{k}'")
                if not isinstance(s, str):
                    raise Defect(f"key 'trackers.{b}.{k}' must be a string")


def _identity(e: str) -> str:
    b, sep, ident = e.partition(":")
    if not sep or b not in BACKENDS:
        raise Defect(f"identity entry '{e}' names no backend of {', '.join(BACKENDS)}")
    if not ID_SHAPES[b].fullmatch(ident):
        raise Defect(f"identity entry '{e}' is not an immutable {b} id")
    return e


def normalise(raw: dict) -> dict:
    """Validate a parsed policy and return it with defaults applied."""
    for k in raw:
        if k not in KEYS:
            raise Defect(f"unknown key '{k}'")
    for k, v in raw.items():
        _type_check(k, KEYS[k], v)
    pol = {**DEFAULTS, **raw}
    for k, kind in KEYS.items():
        if k not in pol:
            continue
        if kind == "idlist":
            pol[k] = sorted({_identity(e) for e in pol[k]})
        elif kind == "repolist":
            pol[k] = sorted({canonical_scope(e) for e in pol[k]})
        elif kind in ("strlist", "charlist", "hardening"):
            pol[k] = sorted(set(pol[k]))
    if not pol.get("worker_identities"):
        raise Defect("worker_identities must be non-empty")
    if not pol.get("scopes"):
        raise Defect("scopes must be non-empty")
    if not pol["single_identity"]:
        workers = set(pol["worker_identities"])
        for s in TRUSTED_SETS:
            for e in sorted(workers & set(pol.get(s, []))):
                raise Defect(f"{e} is in worker_identities and {s}; "
                             "set single_identity = true only if one account is both")
        for e in sorted(set(pol.get("code_host_workers", [])) & set(pol.get("trusted_reviewers", []))):
            raise Defect(f"{e} is in code_host_workers and trusted_reviewers; "
                         "set single_identity = true only if one account is both")
    return pol


def load(d: str, forbid: list[str]) -> tuple[str, dict]:
    f = d.rstrip("/\\") + "/policy.toml"   # "/" on every platform: the path is shown to bash
    for root in forbid:
        if _under(d, root) or _under(f, root):
            raise Defect(f"{f} is under a forbidden root ({root}): a policy must not live where the agent writes")
    if os.path.islink(f) and not os.path.exists(f):
        raise Defect(f"{f} is a dangling link")
    try:
        others = sorted(n for n in os.listdir(d) if n.endswith(".toml") and n != "policy.toml")
    except OSError as e:
        raise Defect(f"cannot read {d}: {e.strerror}") from None
    if others:
        raise Defect(f"another policy file {others[0]} beside policy.toml")
    try:
        with open(f, "rb") as fh:
            raw = fh.read()
    except OSError as e:
        raise Defect(f"cannot read {f}: {e.strerror}") from None
    try:
        parsed = tomllib.loads(raw.decode("utf-8"))
    except (UnicodeDecodeError, tomllib.TOMLDecodeError) as e:
        raise Defect(f"invalid TOML: {e}".splitlines()[0]) from None
    return f, normalise(parsed)


def digest(pol: dict) -> str:
    blob = json.dumps(pol, sort_keys=True, separators=(",", ":"), ensure_ascii=False)
    return "sha256:" + hashlib.sha256(blob.encode("utf-8")).hexdigest()


def _json(v) -> str:
    return json.dumps(v, sort_keys=True, separators=(",", ":"), ensure_ascii=False)


def _emit(lines: list[str]) -> None:
    out = sys.stdout.buffer
    for ln in lines:
        out.write(ln.encode("utf-8") + b"\n")
    out.flush()


def load_lines(f: str, pol: dict) -> list[str]:
    lines = [f"digest\t-\t{digest(pol)}", f"file\t-\t{f}"]
    lines += [f"scope\t-\t{s}" for s in pol["scopes"]]
    for s in ID_SETS:
        lines += [f"id\t{s}\t{e}" for e in pol.get(s, [])]
    for k in sorted(pol):
        if KEYS[k] not in ("idlist",) and k != "scopes":
            lines.append(f"val\t{k}\t{_json(pol[k])}")
    return lines


# ---------------------------------------------------------------- CLI


def main(argv: list[str]) -> int:
    if not argv:
        raise Usage("usage: trust_policy.py load|get|key …")
    verb, args = argv[0], argv[1:]
    if verb == "load":
        forbid, rest = [], []
        while args:
            a = args.pop(0)
            if a == "--forbid":
                if not args:
                    raise Usage("--forbid needs a directory")
                forbid.append(args.pop(0))
            else:
                rest.append(a)
        if len(rest) != 1:
            raise Usage("usage: trust_policy.py load <dir> [--forbid <dir>]…")
        f, pol = load(rest[0], forbid)
        _emit(load_lines(f, pol))
        return 0
    if verb == "get":
        if len(args) != 2:
            raise Usage("usage: trust_policy.py get <dir> <key>")
        if args[1] not in KEYS:
            raise Usage(f"unknown key '{args[1]}'")
        _f, pol = load(args[0], [])
        if args[1] not in pol:
            return 1
        _emit([_json(pol[args[1]])])
        return 0
    if verb == "key":
        host = None
        if "--host" in args:
            i = args.index("--host")
            if i + 1 >= len(args):
                raise Usage("--host needs a value")
            host = args[i + 1]
            args = args[:i] + args[i + 2:]
        if len(args) not in (2, 3):
            raise Usage("usage: trust_policy.py key <backend> <repo> [<num>] [--host <h>]")
        _emit([canonical_key(args[0], args[1], args[2] if len(args) == 3 else None, host)])
        return 0
    if verb == "keys":
        _emit([f"{k}	{t}" for k, t in KEYS.items()])
        return 0
    raise Usage(f"unknown verb '{verb}'")


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except Defect as e:
        sys.stderr.write(f"{e}\n")
        sys.exit(3)
    except Usage as e:
        sys.stderr.write(f"{e}\n")
        sys.exit(2)
