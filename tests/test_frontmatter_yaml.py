"""#319: every command + skill frontmatter block must parse under strict YAML.

Claude Code's runtime parser is lenient; a strict parser (PyYAML) rejects an
unquoted ``description:`` whose value contains a colon+space, silently dropping
the whole block. This canary keeps the class closed after commands/sync.md and
commands/checklist-init.md were quoted (#319).
"""
import glob
import os

import pytest
import yaml

_REPO = os.path.normpath(os.path.join(os.path.dirname(__file__), ".."))
_FILES = sorted(glob.glob(os.path.join(_REPO, "commands", "*.md"))) + sorted(
    glob.glob(os.path.join(_REPO, "skills", "*", "SKILL.md"))
)


@pytest.mark.parametrize(
    "path", _FILES, ids=[os.path.relpath(p, _REPO) for p in _FILES]
)
def test_frontmatter_is_strict_yaml(path):
    with open(path, encoding="utf-8") as fh:
        text = fh.read()
    if not text.startswith("---"):
        pytest.skip("no frontmatter block")
    frontmatter = text.split("---", 2)[1]
    yaml.safe_load(frontmatter)  # raises yaml.YAMLError on a strict violation


def test_frontmatter_sweep_is_not_vacuous():
    # Fail loud if discovery breaks: an empty glob would make the parametrized
    # sweep collect zero cases and false-green instead of guarding anything.
    assert _FILES, "no commands/*.md or skills/*/SKILL.md discovered — check repo layout"


# #447: `claude plugin validate --strict` (which would reject unrecognized skill
# frontmatter keys) did NOT exist in claude 2.1.75; it exists by 2.1.211 but is
# manifest-only (never opens skill files — #458 probe); it passes since 1.0.0
# put a version in plugin.json (#532 re-take) but still never reaches skill
# frontmatter, so this canary REMAINS the CI regression gate for the whole
# unrecognized-key class. It closed the
# `when-to-use:` (kebab, silently-dropped) → `when_to_use:` (snake, recognized)
# rename. Keys per the documented skill frontmatter reference
# (https://code.claude.com/docs/en/skills.md#frontmatter-reference).
_RECOGNIZED_SKILL_KEYS = frozenset(
    {
        "name",
        "description",
        "when_to_use",
        "argument-hint",
        "arguments",
        "disable-model-invocation",
        "user-invocable",
        "allowed-tools",
        "disallowed-tools",
        "model",
        "effort",
        "context",
        "agent",
        "hooks",
        "paths",
        "shell",
    }
)

_SKILL_FILES = sorted(glob.glob(os.path.join(_REPO, "skills", "*", "SKILL.md")))


@pytest.mark.parametrize(
    "path", _SKILL_FILES, ids=[os.path.relpath(p, _REPO) for p in _SKILL_FILES]
)
def test_skill_frontmatter_keys_are_recognized(path):
    """Every skill frontmatter key must be a recognized Claude Code field.

    Catches the `when-to-use` (kebab) unrecognized-key class the loader silently
    drops — and any future typo'd key — since `--strict` isn't available to.
    """
    with open(path, encoding="utf-8") as fh:
        text = fh.read()
    assert text.startswith("---"), f"{path}: skill missing frontmatter block"
    frontmatter = yaml.safe_load(text.split("---", 2)[1]) or {}
    unknown = sorted(set(frontmatter) - _RECOGNIZED_SKILL_KEYS)
    assert not unknown, (
        f"{os.path.relpath(path, _REPO)}: unrecognized frontmatter key(s) "
        f"{unknown} — silently dropped by the loader (see #447). "
        f"Recognized keys: {sorted(_RECOGNIZED_SKILL_KEYS)}"
    )


def test_skill_key_canary_is_not_vacuous():
    assert _SKILL_FILES, "no skills/*/SKILL.md discovered — canary would false-green"


# #448: every `allowed-tools` Bash grant must be SCOPED (`Bash(...)`), not
# a blanket `Bash` that auto-approves arbitrary shell for the turn — a trust
# problem for a distributed plugin. This canary pins the class so a new command
# can't re-introduce an unscoped grant.
# #452: sweep skills/ too. next/capture/ship carry the only Bash grants in
# skills/, and they arrived by moving OUT of commands/ — a commands-only glob
# would have silently dropped all three subjects the moment they converted.
_COMMAND_FILES = sorted(glob.glob(os.path.join(_REPO, "commands", "*.md")))
_GRANT_BEARING_FILES = _COMMAND_FILES + _SKILL_FILES


@pytest.mark.parametrize(
    "path",
    _GRANT_BEARING_FILES,
    ids=[os.path.relpath(p, _REPO) for p in _GRANT_BEARING_FILES],
)
def test_bash_grant_is_scoped(path):
    with open(path, encoding="utf-8") as fh:
        text = fh.read()
    if not text.startswith("---"):
        pytest.skip("no frontmatter block")
    fm = yaml.safe_load(text.split("---", 2)[1]) or {}
    grant = fm.get("allowed-tools")
    if grant is None:
        return
    # allowed-tools is a comma-separated scalar; a bare `Bash` token (not
    # `Bash(...)`) is an unscoped grant.
    tokens = [t.strip() for t in str(grant).split(",")]
    assert "Bash" not in tokens, (
        f"{os.path.relpath(path, _REPO)}: unscoped `Bash` grant — scope it to "
        f"the canonical pair {_PLUGIN_SCRIPT_GRANT!r} (see #448, #548). "
        f"Got: {grant!r}"
    )


# #548: matching is a LITERAL PREFIX MATCH, so the grant must be byte-exact —
# quoted like the body invocations, two tokens (the argless glob token plus the
# arg-wildcard token; probe cells Q6/Q7 proved each alone misses one call
# shape). The pre-#548 unquoted form was CI-green for months while silently
# never matching. Single source for the string; every Bash-grant carrier must
# carry the pair verbatim. NOTE: the yaml loader (test_bash_grant_is_scoped
# above) sees the frontmatter value; a naive comma-split would cut INSIDE the
# pair, so this canary asserts substring presence on the raw value instead.
_PLUGIN_SCRIPT_GRANT = (
    'Bash(bash "${CLAUDE_PLUGIN_ROOT}/scripts/*"), '
    'Bash(bash "${CLAUDE_PLUGIN_ROOT}/scripts/*" *)'
)


@pytest.mark.parametrize(
    "path",
    _GRANT_BEARING_FILES,
    ids=[os.path.relpath(p, _REPO) for p in _GRANT_BEARING_FILES],
)
def test_bash_grant_is_the_canonical_pair(path):
    with open(path, encoding="utf-8") as fh:
        text = fh.read()
    if not text.startswith("---"):
        pytest.skip("no frontmatter block")
    fm = yaml.safe_load(text.split("---", 2)[1]) or {}
    grant = fm.get("allowed-tools")
    if grant is None or "Bash" not in str(grant):
        return
    assert _PLUGIN_SCRIPT_GRANT in str(grant), (
        f"{os.path.relpath(path, _REPO)}: Bash grant drifted from the canonical "
        f"#548 pair — a non-byte-exact form silently never auto-matches "
        f"(literal prefix matching). Expected the verbatim substring "
        f"{_PLUGIN_SCRIPT_GRANT!r}. Got: {grant!r}"
    )


def test_canonical_pair_canary_is_not_vacuous():
    # The canary above returns early on grant-less files; prove the subject
    # set is the full 67 Bash-grant carriers (54 commands + 3 user-invocable
    # skills + the 10 call-bearing core-* skills, #584), so a glob/layout
    # change cannot silently empty it (#439). DELIBERATE EQUALITY PIN, not a
    # floor — update the count when adding/removing a grant carrier.
    n = 0
    for path in _GRANT_BEARING_FILES:
        with open(path, encoding="utf-8") as fh:
            text = fh.read()
        if not text.startswith("---"):
            continue
        fm = yaml.safe_load(text.split("---", 2)[1]) or {}
        if "Bash" in str(fm.get("allowed-tools") or ""):
            n += 1
    assert n == 67, (
        f"expected 67 Bash-grant carriers, found {n} — deliberate pin: if you "
        f"added/removed a grant-carrying command or skill on purpose, update "
        f"this count (see #548)"
    )


@pytest.mark.parametrize(
    "path",
    _GRANT_BEARING_FILES,
    ids=[os.path.relpath(p, _REPO) for p in _GRANT_BEARING_FILES],
)
def test_no_bash_grant_beyond_the_canonical_pair(path):
    # #548 review minor 4: the pair canary is substring-presence, so a rider
    # grant (`Bash(git *), <pair>`) would pass it AND pass the bare-Bash test.
    # Token-level closure: every Bash(...) token in allowed-tools must be one
    # of the two canonical tokens — the grants are load-bearing now.
    with open(path, encoding="utf-8") as fh:
        text = fh.read()
    if not text.startswith("---"):
        pytest.skip("no frontmatter block")
    fm = yaml.safe_load(text.split("---", 2)[1]) or {}
    grant = fm.get("allowed-tools")
    if grant is None or "Bash" not in str(grant):
        return
    canonical = {t.strip() for t in _PLUGIN_SCRIPT_GRANT.split(", ")}
    bash_tokens = [
        t.strip() for t in str(grant).split(",") if t.strip().startswith("Bash")
    ]
    assert set(bash_tokens) == canonical, (
        f"{os.path.relpath(path, _REPO)}: Bash token set beyond/besides the "
        f"canonical #548 pair. Got: {bash_tokens!r}"
    )


# #584: a core-* skill whose BODY emits a plugin-script invocation must CARRY the
# grant, or that call raises a prompt mid-chain — an --auto hard stop. The sweep
# globs already reach skills/core-*/SKILL.md (#452/#531); what was unguarded is the
# body-call -> grant IMPLICATION. Matches only the canonical quoted, bash-prefixed
# emission (the only form the #548 literal-prefix matcher can match), so prose
# merely NAMING a bare `scripts/x.sh` is not a false positive — the same
# discrimination tests/lib/skill-fixture-check.sh guard (b) makes.
# DO NOT spell this literal inside any SKILL.md comment (#561, fleet Issue-73): the
# scan subject IS those files, and an explanatory comment would self-satisfy the
# guard. Body-only by construction (frontmatter is split off first), so a grant line
# cannot satisfy it either.
# COST OF ADDING A CORE SKILL: a core-* skill that grows an operative call reddens
# the set pin below and the 67 pin above; the implication canary reddens only if
# the new skill LACKS the grant. Budget a two-line update, plus the
# tests/skills-no-bang-exec.bats @test 4 set pin that adding any skill already reddens.
_CORE_SKILL_FILES = [
    p for p in _SKILL_FILES if os.path.basename(os.path.dirname(p)).startswith("core-")
]
_BODY_CALL = 'bash "${CLAUDE_PLUGIN_ROOT}/scripts/'
NL = chr(10)


def _has_operative_call(path):
    return _BODY_CALL in _split_fm(path)[1]


def _assert_core_grant(path):
    # The guard proper. Both the parametrized test and the mutation control enter
    # through THIS function, so a regression here reddens the control too
    # (lawFirm Issue-8: a control that only exercises the helper is unarmed).
    grant = str(_load_fm(path).get("allowed-tools") or "")
    assert _PLUGIN_SCRIPT_GRANT in grant, (
        f"{os.path.relpath(path, _REPO)}: emits a plugin-script call but carries no "
        f"#548 grant — the call prompts mid-chain (--auto hard stop, #584). "
        f"Got: {grant!r}"
    )


@pytest.mark.parametrize(
    "path", _CORE_SKILL_FILES,
    ids=[os.path.relpath(p, _REPO) for p in _CORE_SKILL_FILES],
)
def test_core_skill_with_operative_call_carries_grant(path):
    if not _has_operative_call(path):
        pytest.skip("no operative body call — grant not required (#584)")
    _assert_core_grant(path)


def test_core_skill_operative_call_subject_set_is_pinned():
    # #439/#337: a guard whose glob stops selecting its subjects passes SILENTLY.
    # DELIBERATE EQUALITY PIN on the matched SET (names, not just a count), so a
    # swap of one skill for another cannot net out invisibly.
    have = sorted(
        os.path.basename(os.path.dirname(p))
        for p in _CORE_SKILL_FILES if _has_operative_call(p)
    )
    expected = [
        "core-document-actual-work", "core-draft-mr", "core-impact",
        "core-improve", "core-lessons-learned", "core-preship",
        "core-prune", "core-redmr", "core-scope", "core-tighten",
    ]
    assert have == expected, (
        f"core-* skills emitting an operative call changed: {have} — if a skill "
        f"gained or lost one on purpose, sweep its grant and update this pin (#584)"
    )


def test_core_call_guard_can_fire(tmp_path):
    # Mutation control (#582/lawFirm Issue-5): an inverse mutation that leaves the
    # suite green means the guard is unpinned. Planted under tmp_path — no repo
    # mutation (the #425/#531 self-test shape). Enters through _assert_core_grant,
    # the same door as the parametrized guard.
    p = tmp_path / "skills" / "core-x" / "SKILL.md"
    p.parent.mkdir(parents=True)
    p.write_text(
        "---\nname: core-x\nuser-invocable: false\n---\n"
        'run: ' + _BODY_CALL + 'a1b2c3nonce.sh" p\n',
        encoding="utf-8",
    )
    assert _has_operative_call(str(p))
    with pytest.raises(AssertionError):
        _assert_core_grant(str(p))
    # ...and the negative half: a prose-only mention must NOT enroll a skill.
    q = tmp_path / "skills" / "core-y" / "SKILL.md"
    q.parent.mkdir(parents=True)
    q.write_text(
        "---\nname: core-y\nuser-invocable: false\n---\n"
        "the lint `scripts/lessons-lint.sh` rejects ad-hoc tags\n",
        encoding="utf-8",
    )
    assert not _has_operative_call(str(q))
    # ...and the positive half: a granted call-bearing file passes the same door.
    r = tmp_path / "skills" / "core-z" / "SKILL.md"
    r.parent.mkdir(parents=True)
    r.write_text(
        "---" + NL + "name: core-z" + NL + "user-invocable: false" + NL
        + "allowed-tools: " + _PLUGIN_SCRIPT_GRANT + NL + "---" + NL
        + "run: " + _BODY_CALL + "a1b2c3nonce.sh\" p" + NL,
        encoding="utf-8",
    )
    assert _has_operative_call(str(r))
    _assert_core_grant(str(r))


def test_command_bash_canary_is_not_vacuous():
    assert _COMMAND_FILES, "no commands/*.md discovered — canary would false-green"


# #449: invocation-control invariants.
def _split_fm(path):
    """(frontmatter_text, body) — frontmatter_text is None when there is no block."""
    with open(path, encoding="utf-8") as fh:
        text = fh.read()
    if not text.startswith("---"):
        return None, text
    parts = text.split("---", 2)
    assert len(parts) == 3, f"{os.path.relpath(path, _REPO)}: unterminated frontmatter block"
    return parts[1], parts[2]


def _load_fm(path):
    fm_text, _ = _split_fm(path)
    if fm_text is None:
        return {}
    return yaml.safe_load(fm_text) or {}


def test_all_core_skills_are_not_user_invocable():
    """The 14 internal core-* skills must be hidden from the user / menu."""
    core = _CORE_SKILL_FILES
    assert core, "no core-* skills discovered — canary would false-green"
    missing = [
        os.path.relpath(p, _REPO)
        for p in core
        if _load_fm(p).get("user-invocable") is not False
    ]
    assert not missing, f"core-* skills missing `user-invocable: false` (#449): {missing}"


def test_user_invocable_yaml_truth(tmp_path):
    """#526: pin the YAML-truth semantics the guard relies on, so a future
    `_load_fm`->literal/grep regression reds loudly. Capital-`False` and an
    inline-comment `false  # c` must both resolve to Python `False` (guard treats
    HIDDEN — matching the bats classifier); an absent marker must resolve to a
    value that `is not False` (flagged / user-invocable). Both directions."""

    def fm(body):
        p = tmp_path / "SKILL.md"
        p.write_text(body, encoding="utf-8")
        return _load_fm(p)

    assert fm("---\nname: x\nuser-invocable: False\n---\nbody\n").get("user-invocable") is False
    assert fm("---\nname: x\nuser-invocable: false  # c\n---\nbody\n").get("user-invocable") is False
    assert fm("---\nname: x\n---\nbody\n").get("user-invocable") is not False


def test_disable_model_invocation_only_on_operator_verbs():
    """CHAIN-safety invariant: `disable-model-invocation: true` may appear ONLY on
    auth/init/use — NEVER on a workflow-step command, or /devagent:next --auto's
    model-invocation of that step silently dies (#449)."""
    allowed = {"auth.md", "init.md", "use.md"}
    # #452: sweep skills/ too — `next` is a skill now, and the flag would break
    # the CHAIN from skills/next/SKILL.md exactly as it would from the former
    # command-form doc.
    # Skills share the basename SKILL.md, so it can never match the allow-list:
    # any skill carrying the flag is an offender, reported by its readable path.
    offenders = sorted(
        os.path.relpath(p, _REPO)
        for p in _COMMAND_FILES + _SKILL_FILES
        if _load_fm(p).get("disable-model-invocation") is True
        and os.path.basename(p) not in allowed
    )
    assert not offenders, (
        f"`disable-model-invocation: true` on non-operator command(s)/skill(s) {offenders} "
        f"— this breaks the /devagent:next --auto CHAIN. Allowed only on {sorted(allowed)}."
    )
    # And the three operator verbs MUST carry it (both directions of the invariant).
    # Commands-only by construction: all three are commands, and the offenders
    # sweep above already forbids the flag anywhere in skills/.
    have = {
        os.path.basename(p)
        for p in _COMMAND_FILES
        if _load_fm(p).get("disable-model-invocation") is True
    }
    assert have == allowed, f"disable-model-invocation set = {sorted(have)}, expected {sorted(allowed)}"


# #450: every slash command carries an `argument-hint` (autocomplete grammar).
# All devAgent commands take at least an optional [project]; the field was a
# closed gap of 19 commands. This canary keeps the coverage at 100% so a new
# command surfaces its grammar in / menu autocomplete.
# #452: "slash command" spans both layouts — commands/*.md AND the user-invocable
# skills (next/capture/ship), which appear in the / menu identically. core-*
# skills are `user-invocable: false` and never reach the menu, so they carry no
# grammar and are correctly out of scope. Resolved by YAML truth rather than a
# grep so `user-invocable: False` cannot slip past.
_USER_INVOCABLE_SKILL_FILES = [
    p for p in _SKILL_FILES if _load_fm(p).get("user-invocable") is not False
]
_SLASH_COMMAND_FILES = _COMMAND_FILES + _USER_INVOCABLE_SKILL_FILES


@pytest.mark.parametrize(
    "path",
    _SLASH_COMMAND_FILES,
    ids=[os.path.relpath(p, _REPO) for p in _SLASH_COMMAND_FILES],
)
def test_slash_command_has_argument_hint(path):
    hint = _load_fm(path).get("argument-hint")
    assert isinstance(hint, str) and hint.strip(), (
        f"{os.path.relpath(path, _REPO)}: missing/empty `argument-hint` "
        f"(copy the usage grammar up into frontmatter — see #450)"
    )


# #531: the allowed-tools sweep (`test_bash_grant_is_scoped`, parametrized over
# `_GRANT_BEARING_FILES` = commands/*.md + skills/*/SKILL.md — one-level globs) is guarded by
# NOTHING against a carrier that lives OUTSIDE those globs: a nested
# `skills/*/*/SKILL.md`, or a future `allowed-tools` carrier in a new top-level
# dir (agents/ carry only disallowedTools today). Enumerate carriers via an
# oracle INDEPENDENT of the sweep's globs (a recursive walk that PARSES the
# frontmatter — a string grep would count prose mentions in docs/CHANGELOG/README)
# and assert every carrier is in the swept set. Reusing `_FILES`' globs as the
# oracle would be vacuous by construction. Both helpers take a `root` so the
# #425-style self-test can drive them against a planted tmp tree (no repo
# mutation). The walk is scoped to agents/+commands/+skills/ and built in-body,
# NOT at import, so an unrelated tree `.md` with a bad `---` block cannot error
# collection.

# NOTE (#531 review nit): this tuple is itself a staleable allowlist — a carrier
# in a genuinely NEW top-level dir (e.g. a future hooks/) would be missed by BOTH
# the one-level sweep and this oracle. The two concretely-named residuals (nested
# skills/*/*/SKILL.md + an agents/ carrier) ARE covered; widen this tuple the day
# a new carrier-bearing top-level dir is introduced.
_GRANT_SCAN_DIRS = ("agents", "commands", "skills")


def _grant_carriers(root):
    """Files under agents/+commands/+skills/ whose FRONTMATTER declares an
    `allowed-tools` key. Independent of the one-level sweep globs."""
    carriers = set()
    for d in _GRANT_SCAN_DIRS:
        base = os.path.join(root, d)
        for dirpath, _dirs, files in os.walk(base):
            for fn in files:
                if not fn.endswith(".md"):
                    continue
                p = os.path.join(dirpath, fn)
                if "allowed-tools" in _load_fm(p):
                    carriers.add(os.path.normpath(p))
    return carriers


def _swept_one_level(root):
    """The set `test_bash_grant_is_scoped` actually iterates
    (`_GRANT_BEARING_FILES`, == `_FILES`'s globs), parameterized by root:
    commands/*.md + skills/*/SKILL.md (one level deep)."""
    swept = glob.glob(os.path.join(root, "commands", "*.md"))
    swept += glob.glob(os.path.join(root, "skills", "*", "SKILL.md"))
    return {os.path.normpath(p) for p in swept}


def test_allowed_tools_sweep_covers_all_carriers():
    """Every allowed-tools carrier must be in the swept set — else its unscoped
    Bash grant is never checked (#531; #439 silent-coverage-loss on the grant
    axis)."""
    carriers = _grant_carriers(_REPO)
    swept = _swept_one_level(_REPO)
    uncovered = sorted(os.path.relpath(p, _REPO) for p in carriers - swept)
    assert not uncovered, (
        "allowed-tools carrier(s) outside the `test_bash_grant_is_scoped` sweep "
        f"({', '.join(uncovered)}) — a nested skills/*/*/SKILL.md or a new "
        "top-level carrier dir escapes the one-level globs. Widen _FILES."
    )


def test_allowed_tools_oracle_catches_nested_carrier(tmp_path):
    """#425-style self-test: the independent oracle finds an out-of-glob carrier
    the one-level sweep misses — proving the coverage assertion is non-vacuous.
    No repo tree mutation (planted under tmp_path)."""
    fm = "---\nname: x\nallowed-tools: Bash(bash foo)\n---\nbody\n"
    nested = tmp_path / "skills" / "x" / "y" / "SKILL.md"      # escapes skills/*/SKILL.md
    nested.parent.mkdir(parents=True)
    nested.write_text(fm, encoding="utf-8")
    normal = tmp_path / "skills" / "a" / "SKILL.md"            # a swept carrier
    normal.parent.mkdir(parents=True)
    normal.write_text(fm, encoding="utf-8")

    carriers = _grant_carriers(str(tmp_path))
    swept = _swept_one_level(str(tmp_path))
    nested_n = os.path.normpath(str(nested))
    normal_n = os.path.normpath(str(normal))
    # the oracle sees BOTH; the one-level sweep sees only the normal one
    assert nested_n in carriers and normal_n in carriers
    assert normal_n in swept and nested_n not in swept
    # ⇒ the coverage assertion would fire on the nested carrier
    assert (carriers - swept) == {nested_n}
