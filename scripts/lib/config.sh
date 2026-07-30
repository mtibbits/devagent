#!/usr/bin/env bash
# scripts/lib/config.sh — read ~/.claude/devagent/config.toml.
# Requires paths.sh and io.sh sourced first.

_config_toml() {
  python3 "$(plugin_root)/scripts/lib/_toml.py" "$@"
}

config_load() {
  local f
  f="$(config_path)"
  [[ -f "$f" ]] || die "config not found at $f (run /devagent:init <project>)"
  _config_toml validate "$f" || die "config at $f is not valid TOML"
}

config_get() {
  local key="$1"
  _config_toml get "$(config_path)" "$key"
}

config_get_default() {
  config_get "defaults.$1"
}

config_get_project_field() {
  local project="$1" field="$2"
  [[ -n "$project" && -n "$field" ]] || {
    echo "config_get_project_field: project and field required" >&2
    return 2
  }
  local val
  # Preserve config_get's exit code so callers' `|| true` / `|| echo <fallback>`
  # still fire on a missing field (#82).
  val="$(config_get "project.${project}.${field}")" || return $?
  # #82: path-typed fields are tilde-expanded at the source, so every consumer
  # gets a usable path (previously left literal at 21 call sites). This whitelist
  # is the single source of truth for which project fields are filesystem paths.
  case "$field" in
    source_dir|devdoc_dir|worktree_root|build_dir|paths.*)
      expand_tilde "$val" ;;
    *)
      printf '%s\n' "$val" ;;
  esac
}

config_list_projects() {
  _config_toml list-tables "$(config_path)" \
    | awk -F. '$1=="project" && NF==2 { print $2 }'
}

config_is_project() {
  local target="$1" p
  while IFS= read -r p; do
    [[ "$p" == "$target" ]] && return 0
  done < <(config_list_projects)
  return 1
}

# Guard for entry-point scripts: if the project is unknown, print a recovery
# menu (configured projects + init suggestion) and exit 1. Reusable across
# scripts that take a project as their first argument.
config_require_project() {
  local project="$1"
  if config_is_project "$project"; then return 0; fi

  echo "error: project '$project' not found in config.toml." >&2
  echo "" >&2

  local configured n
  configured="$(config_list_projects 2>/dev/null || true)"
  n="$(echo "$configured" | wc -w)"
  if [ "$n" -eq 1 ]; then
    echo "  hint: did you mean '$configured'?" >&2
  elif [ "$n" -gt 1 ]; then
    echo "  configured projects: $(echo "$configured" | tr '\n' ' ')" >&2
  fi
  echo "" >&2
  echo "  to add '$project': /devagent:init $project" >&2
  exit 1
}

config_active_project() {
  local count=0 only=""
  local p
  while IFS= read -r p; do
    count=$((count + 1))
    only="$p"
  done < <(config_list_projects)
  if (( count == 1 )); then
    echo "$only"
    return 0
  fi
  die "config_active_project: $count projects configured; pass project explicitly"
}

# step_models_tier <project> <step-num> [issue_dir]
# #150 surfacing + #151 dispatch consumer. Echoes the model tier for a workflow
# step from the optional [project.<name>.step_models] table, or returns nonzero
# (prints nothing) when no tier
# resolves — so an absent table yields byte-identical output to before.
#
# Exit codes (#458) — the three no-tier states are DISTINCT, because they are
# not interchangeable for a caller whose fallback is not "inherit":
#   0  a tier resolved; it is on stdout.
#   2  the reserved per-issue `inherit` marker: the operator explicitly asked
#      for session-model inheritance, escaping a project pin.
#   3  nothing resolved: no marker, no table entry.
#   1  error (bad/unreadable marker, missing args) — via die, message on stderr.
# Steps whose fallback IS "inherit" may keep treating every nonzero alike
# (`$(... || true)` yields empty for 2 and 3, which is correct for them). Steps
# bound to a dedicated agent (#458/#527: 5 improve, 16 redmr, 17 preship) fall back to the
# agent's pinned model, for which 2 and 3 mean opposite things — 2 must inherit,
# 3 takes the agent default — so they discriminate on the exit code rather than
# parsing the stderr prose.
# Resolution: a per-issue marker wins over the whole table; then a per-step
# override (step_models.<N>) wins over the step's class. The step→class map is
# fixed (canonical step numbers):
# thinking = 2 9 10 11 14, checking = 5 15 16 17, everything else = default.
# A class with no tier set falls back to the default tier.
#
# Per-issue marker — TWO FORMS, discriminated by content, never by filename:
#
#   BARE token (#291, legacy):  `fable`
#     One tier token. CHECKING-CLASS ONLY — invisible to thinking steps, which
#     fall through to the config chain silently. Like .devagent-baseline (#162)
#     it must not fall back silently: an empty or multi-token marker dies.
#
#   KEYED lines (#561):  `checking: fable` / `thinking: sonnet`
#     One line per steered class, either or both. Applies to the CHECKING and
#     THINKING classes. A keyed marker with no line for the resolving step's
#     class is NOT an error — it falls through to the config rungs exactly as an
#     absent marker would, so `checking: fable` alone leaves step 9 on the
#     table. A malformed line, or two lines for the same class, dies.
#     Written by pull.sh at first scaffold from the `## Workflow flags` keys
#     `checking-model:` / `implementation-model:`, the `tier: <model>-checking`
#     shim, or recognized `tier:*` forge labels; hand-editing is the documented
#     post-scaffold path.
#
# Both forms: the reserved token `inherit` forces session-model inheritance
# (return 2, distinct stderr note), escaping a project pin. Provenance goes to
# stderr; stdout stays a bare tier.
#
# TOKEN LEGALITY IS NOT CHECKED HERE. pull.sh validates against
# flags.sh's model_token_allowlist at WRITE time; this resolver enforces only
# the one-token charset, so a hand-edited marker keeps the contract it always
# had. A marker holding a token the Agent tool's closed enum rejects therefore
# resolves rc 0 and fails at dispatch, by design.
#
# STRUCTURAL vs CONTENT validity are scoped differently, deliberately (#561):
# structural checks (exists but is not a regular file / not readable) apply to
# BOTH classes, because "the operator left something unreadable here" is a
# fault regardless of which step asks. Bare-form CONTENT checks (empty,
# multi-token) stay checking-only, because the bare form itself is
# checking-only — so an empty marker + a thinking step still falls through
# silently, byte-identically to before #561.
step_models_tier() {
  local project="$1" step="$2" issue_dir="${3:-}" tier=""
  [[ -n "$project" && -n "$step" ]] || return 1
  # Fixed step→class map — computed once; the per-issue layer is gated on it.
  local class="default"
  # shellcheck disable=SC2194 # constant subject; space-padded membership test
  case " 2 9 10 11 14 " in *" $step "*) class="thinking" ;; esac
  # shellcheck disable=SC2194 # constant subject; space-padded membership test
  case " 5 15 16 17 " in *" $step "*) class="checking" ;; esac
  # 0. per-issue marker. Two forms:
  #      BARE token  (#291) — one tier token, CHECKING class only (legacy);
  #      KEYED lines (#561) — `checking: <tok>` / `thinking: <tok>`, BOTH classes.
  #    The `default` class never reads the marker in either form.
  local marker="${issue_dir%/}/.devagent-step-models"
  # #561: ONE predicate computed once, so the structural dies below and the read
  # block can never disagree about whether the marker applies to this step
  # (register: Issue-558 — enumerate BOTH branches of new logic; a split
  # predicate is how a fail-closed check becomes a fail-open read).
  local marker_applies=0
  [[ "$class" == "checking" || "$class" == "thinking" ]] && marker_applies=1
  if [[ "$marker_applies" == 1 && -n "$issue_dir" && -e "$marker" ]]; then
    # An existing marker that cannot be read as a file must not silently
    # fall back to the project tier (AC3's silent-wrong-tier class).
    # #561 U3 DELIBERATE DELTA: this now fires for the THINKING class too, where
    # it previously fell through to the config chain. Asserted explicitly by
    # tests/step-model.bats so it can never regress silently.
    [[ -f "$marker" ]] || die "step_models_tier: $marker exists but is not a regular file"
    [[ -r "$marker" ]] || die "step_models_tier: $marker exists but is not readable"
  fi
  # #561: ONE regex, used by BOTH the form detector and the line validator, so a
  # line like `  checking: fable` can never be keyed by one rule and malformed by
  # the other.
  local _keyed_re='^[[:space:]]*(thinking|checking)[[:space:]]*:'
  # Read the marker ONCE into an array when it applies: the form detector and the
  # keyed parser then share one read and spawn no subprocess, and the bare branch
  # below still sees the file exactly as it always did.
  local -a _mlines=()
  local _keyed=0 _l
  if [[ "$marker_applies" == 1 && -n "$issue_dir" && -r "$marker" ]]; then
    mapfile -t _mlines < "$marker"
    for _l in "${_mlines[@]}"; do
      if [[ "$_l" =~ $_keyed_re ]]; then _keyed=1; break; fi
    done
  fi
  if [[ "$_keyed" == 1 ]]; then
    # --- KEYED form (#561) ------------------------------------------------
    # Legality of the TOKEN is a write-time concern (pull.sh validates against
    # model_token_allowlist); the resolver keeps the bare form's charset-only
    # contract so a hand-edited marker behaves the same way it always has.
    # Keyed by class, so the duplicate check and its message exist ONCE rather
    # than once per class.
    local _lkey _lval
    local -A _v=()
    for _l in "${_mlines[@]}"; do
      [[ "$_l" =~ ^[[:space:]]*$ ]] && continue
      [[ "$_l" =~ $_keyed_re ]] \
        || die "step_models_tier: $marker: not a valid keyed-marker line: '$_l' (expected 'thinking: <token>' or 'checking: <token>')"
      _lkey="${_l%%:*}"; _lkey="${_lkey//[[:space:]]/}"
      _lval="${_l#*:}"
      # One token, nothing else — the bare form's charset, per class. The `+`
      # makes the accepted value non-empty, which is why presence alone is a
      # sufficient duplicate test below.
      [[ "$_lval" =~ ^[[:space:]]*[A-Za-z0-9._-]+[[:space:]]*$ ]] \
        || die "step_models_tier: $marker: '$_lkey' must hold exactly one token (allowed: A-Za-z0-9 . _ -), got: '$_lval'"
      _lval="${_lval//[[:space:]]/}"
      [[ -z "${_v[$_lkey]:-}" ]] \
        || die "step_models_tier: $marker: duplicate '$_lkey' lines ('${_v[$_lkey]}' and '$_lval') — one line per class"
      _v[$_lkey]="$_lval"
    done
    local _want="${_v[$class]:-}"
    if [[ -n "$_want" ]]; then
      if [[ "$_want" == "inherit" ]]; then
        echo "step_models_tier: per-issue 'inherit' from $marker — forcing session-model inheritance" >&2
        return 2
      fi
      echo "step_models_tier: per-issue tier '$_want' from $marker" >&2
      printf '%s\n' "$_want"
      return 0
    fi
    # A keyed marker with NO line for this class is not an error: fall through
    # to the config rungs below, exactly as an absent marker would.
  elif [[ "$class" == "checking" && -n "$issue_dir" && -r "$marker" ]]; then
    # --- BARE token (#291) — legacy path, left TEXTUALLY UNTOUCHED -------
    # Equivalence by construction (register: Issue-94): the bare form's
    # semantics are preserved by not editing its code, not by a test promising
    # they match. Still checking-class only: a bare marker is invisible to
    # thinking steps, which fall through to the config chain silently.
    local raw
    raw="$(cat "$marker")"
    # One token, nothing else: reject BEFORE stripping so `fable opus` cannot
    # collapse into a plausible-looking `fableopus`.
    tier="$(tr -d '[:space:]' <<<"$raw")"
    [[ -n "$tier" ]] || die "step_models_tier: $marker is empty (no tier token)"
    [[ "$raw" =~ ^[[:space:]]*[A-Za-z0-9._-]+[[:space:]]*$ ]] \
      || die "step_models_tier: $marker must hold exactly one tier token (allowed: A-Za-z0-9 . _ -), got: '$raw'"
    if [[ "$tier" == "inherit" ]]; then
      echo "step_models_tier: per-issue 'inherit' from $marker — forcing session-model inheritance" >&2
      return 2
    fi
    echo "step_models_tier: per-issue tier '$tier' from $marker" >&2
    printf '%s\n' "$tier"
    return 0
  fi
  # 1. per-step override wins
  tier="$(config_get_project_field "$project" "step_models.${step}" 2>/dev/null || true)"
  if [[ -z "$tier" ]]; then
    # 2. class tier
    tier="$(config_get_project_field "$project" "step_models.${class}" 2>/dev/null || true)"
    # 3. fall back to the default tier when the class tier is unset
    if [[ -z "$tier" && "$class" != "default" ]]; then
      tier="$(config_get_project_field "$project" "step_models.default" 2>/dev/null || true)"
    fi
  fi
  [[ -n "$tier" ]] || return 3
  # #458 redmr r2: the reserved token is symmetric — 'inherit' arriving via the
  # CONFIG TABLE (step_models.<N>/.class/.default) forces session-model
  # inheritance exactly like the per-issue marker, rather than resolving rc 0
  # and flowing into an Agent-tool dispatch as a model name the closed enum
  # rejects. Distinct stderr note: no 'per-issue' word, so callers can stamp
  # plain 'inherit' vs 'inherit (per-issue)' by provenance.
  if [[ "$tier" == "inherit" ]]; then
    echo "step_models_tier: config tier 'inherit' — forcing session-model inheritance" >&2
    return 2
  fi
  printf '%s\n' "$tier"
}

# issue_dir_for <project> <issue> — derive an issue's devdoc directory (#240).
# Byte-matches pull.sh's stored value: ${devdoc%/}/<issue>. Dies loudly via
# project_devdoc_dir when devdoc_dir is unresolvable; display readers that
# must tolerate misconfiguration wrap with 2>/dev/null || true (their existing
# idiom). Pinned sessions derive instead of reading the shared issue_dir slot.
issue_dir_for() {
  local project="$1" issue="$2" devdoc
  [ -n "$issue" ] || die "issue_dir_for: issue required"
  devdoc="$(project_devdoc_dir "$project")"
  printf '%s/%s\n' "${devdoc%/}" "$issue"
}

# project_devdoc_dir <project> — resolve a project's devdoc directory, or die
# loudly (#246; logic moved here from the former depends.sh:_depends_devdoc_dir).
# The DEVAGENT_TEST_DEVDOC override is the one legitimately-optional (tolerant)
# leg; otherwise the path is genuinely required by every caller (ship preflight,
# grep.sh, history.sh), so #78 fails loud instead of the old silent $HOME/devdoc
# fallback. config_get_project_field already returns non-zero on a missing field
# (#82), which we no longer mask. Requires io.sh (die) sourced by the caller.
project_devdoc_dir() {
  local project="$1"
  if [ -n "${DEVAGENT_TEST_DEVDOC:-}" ]; then
    printf '%s\n' "${DEVAGENT_TEST_DEVDOC}"
    return 0
  fi
  local devdoc
  devdoc="$(config_get_project_field "${project}" "devdoc_dir")" \
    || die "cannot resolve devdoc_dir for project '${project}' — set it in config.toml (or export DEVAGENT_TEST_DEVDOC)"
  [ -n "${devdoc}" ] \
    || die "devdoc_dir for project '${project}' resolved empty — check config.toml"
  printf '%s\n' "${devdoc}"
}
