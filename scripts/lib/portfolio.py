#!/usr/bin/env python3
"""portfolio.py — #726. Build the portfolio document (schema v1.0, #725) over
every configured project's WBS.md, with a parse report that drops nothing
silently, and write it only when it passes both the structural checker
(portfolio-check.py) and this module's own cross-field invariants I1–I15.

    portfolio.py build --out PATH

The project manifest arrives as indexed environment variables, set by
scripts/portfolio.sh from config.toml (this module reads no TOML):
PORTFOLIO_PROJECT_COUNT, and per project i (0-based) PORTFOLIO_NAME_<i>,
PORTFOLIO_DEVDOC_<i>, PORTFOLIO_SOURCE_<i> and PORTFOLIO_WORKTREE_<i>, each
path variable set only when configured (it may be empty).

Standard library only (3.10+), like portfolio-check.py. docs/portfolio-schema.md
is the contract; commands/portfolio.md is the user doc.
"""
from __future__ import annotations

import importlib.util
import re
import sys
from decimal import Decimal
from pathlib import Path

LIB = Path(__file__).resolve().parent


def _load(name: str, path: Path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    # Registered before exec: a frozen dataclass under `from __future__ import
    # annotations` looks its module up in sys.modules while it is being built.
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


wbs_parser = _load("_portfolio_wbs_parser", LIB / "wbs-parser.py")
pc = _load("_portfolio_check", LIB / "portfolio-check.py")

USAGE = "usage: portfolio.py build --out PATH"

# --- per-node derivations ------------------------------------------------------

# Interim estimate classifier (D16), built from #737's drafted table. The
# factors are WORKING-time hours and provisional: #737's helper replaces this
# classifier when it lands. Every match is a fullmatch on the value as written.
HOUR_FACTORS: dict[str, int] = {"h": 1, "d": 8, "w": 40}
PLACEHOLDER_RE = re.compile(r"\?[A-Za-z]*")
# Digit caps keep every number finite and small: no inf or huge-int path.
QUANTITY_RE = re.compile(r"(?P<q>[0-9]{1,9}(?:\.[0-9]{1,6})?)(?P<u>[A-Za-z]+)")
H_RE = re.compile(r"[0-4]")
EST_SRC_VALUES = ("confirmed", "derived")
# Keys this producer consumes. The parser does not know them yet (#888), so
# they sit in `meta_unknown_keys`; the unknown-key report skips them.
PRODUCER_KEYS: frozenset[str] = frozenset({"est_src", "satisfies", "h"})


def _num(d: Decimal) -> int | float:
    """An exact decimal as JSON wants it: an int when integral (D14)."""
    return int(d) if d == d.to_integral_value() else float(d)


def classify_est(raw) -> dict:
    """`meta.est` as the schema's Est fields (without `src`)."""
    out = {"raw": raw, "class": "unparseable", "low_hours": None,
           "high_hours": None, "quantity": None, "unit": None}
    if raw is None:
        out["class"] = "absent"
    elif isinstance(raw, str):
        if PLACEHOLDER_RE.fullmatch(raw):
            out["class"] = "placeholder"
        elif m := QUANTITY_RE.fullmatch(raw):
            q, unit = Decimal(m.group("q")), m.group("u")
            if unit in HOUR_FACTORS:
                hours = _num(q * HOUR_FACTORS[unit])
                out.update({"class": "time", "low_hours": hours, "high_hours": hours})
            else:
                out.update({"class": "non-time", "quantity": _num(q), "unit": unit})
    return out


def est_src(meta: dict) -> tuple[str | None, bool]:
    """(`est.src`, invalid): a value other than confirmed/derived reads as null."""
    if "est_src" not in meta:
        return None, False
    v = meta["est_src"]
    if isinstance(v, str) and v in EST_SRC_VALUES:
        return v, False
    return None, True


def read_h(meta: dict) -> tuple[int | None, bool]:
    """(`h`, malformed): one digit 0–4 as written, else null."""
    if "h" not in meta:
        return None, False
    v = meta["h"]
    if isinstance(v, str) and H_RE.fullmatch(v):
        return int(v), False
    return None, True


def node_issue(meta: dict) -> tuple[str | None, bool]:
    """(`issue`, malformed): a non-empty string passes; a non-string is malformed."""
    v = meta.get("issue")
    if v is None or v == "":
        return None, False
    if isinstance(v, str):
        return v, False
    return None, True


def as_list(v) -> list:
    """Falsy gives [], a list stays a list, a scalar gives [v]."""
    if not v:
        return []
    return v if isinstance(v, list) else [v]


def split_dep(raw: str, project: str) -> dict:
    """One `depends_on` entry by #887's split rule (schema doc, Dependency split)."""
    left, sep, right = raw.partition(":")
    if (sep and ":" not in right and wbs_parser.ID_TOKEN_RE.fullmatch(left)
            and wbs_parser.ID_TOKEN_RE.fullmatch(right)):
        scope = "local" if left == project else "foreign"
        return {"raw": raw, "scope": scope, "project": left, "issue": right,
                "resolved": None}
    return {"raw": raw, "scope": "local", "project": project, "issue": raw,
            "resolved": None}


def node_deps(meta: dict, project: str) -> list[dict]:
    """A node's `depends_on`, read exactly as the parser's `_dep_ids` reads it."""
    return [split_dep(raw, project) for raw in wbs_parser._dep_ids(meta)]


# --- CLI -----------------------------------------------------------------------

def main(argv: list[str]) -> int:
    if argv[:1] in (["-h"], ["--help"]):
        sys.stdout.write(USAGE + "\n")
        return 0
    sys.stderr.write(USAGE + "\n")
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
