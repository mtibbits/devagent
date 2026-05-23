# scripts/lib/depends.sh — dependency CRUD, cycle detection, ship pre-flight.
# Storage: <state_dir>/<project>.depends.toml with one table per dependent issue:
#   [Issue-100]
#   depends_on = ["Issue-101", "Issue-102"]
#
# Plain-text TOML is used (not Python tomllib write) so the file stays git/diff
# friendly and editable by hand. We parse with awk to avoid a Python dep.

depends_state_file() {
  printf '%s/%s.depends.toml\n' "${DEVAGENT_STATE_DIR}" "$1"
}

# depends_list <project> <issue> → prints space-separated dependencies (may be empty)
depends_list() {
  local project="$1" issue="$2"
  local file
  file="$(depends_state_file "${project}")"
  [ -f "${file}" ] || { printf '\n'; return 0; }

  awk -v want="${issue}" '
    BEGIN { in_block = 0 }
    /^\[/ {
      header = $0
      sub(/^\[/, "", header); sub(/\]$/, "", header)
      in_block = (header == want) ? 1 : 0
      next
    }
    in_block && /^depends_on[[:space:]]*=/ {
      line = $0
      sub(/^[^=]*=[[:space:]]*\[/, "", line)
      sub(/\][[:space:]]*$/, "", line)
      gsub(/"/, "", line)
      gsub(/,/, " ", line)
      print line
      exit
    }
  ' "${file}"
}

# depends_add <project> <dependent> <dependency>
depends_add() {
  local project="$1" a="$2" b="$3"
  if [ -z "${project}" ] || [ -z "${a}" ] || [ -z "${b}" ]; then
    printf 'depends_add: usage: depends_add <project> <A> <B>\n' >&2
    return 2
  fi
  if [ "${a}" = "${b}" ]; then
    printf 'depends_add: an issue cannot depend on itself: %s\n' "${a}" >&2
    return 3
  fi

  mkdir -p "${DEVAGENT_STATE_DIR}"
  local file
  file="$(depends_state_file "${project}")"
  [ -f "${file}" ] || : > "${file}"

  local existing
  existing="$(depends_list "${project}" "${a}")"
  local dep
  for dep in ${existing}; do
    if [ "${dep}" = "${b}" ]; then
      return 0
    fi
  done

  if depends_would_cycle "${project}" "${a}" "${b}"; then
    printf 'depends_add: refusing to create cycle: %s depends on %s\n' "${a}" "${b}" >&2
    return 4
  fi

  local new_list="${existing} ${b}"
  new_list="$(printf '%s\n' ${new_list} | sort -u | tr '\n' ' ')"
  depends_write_block "${file}" "${a}" "${new_list}"
}

# depends_write_block <file> <issue> <space-separated-deps>
depends_write_block() {
  local file="$1" issue="$2" deps="$3"
  local tmp
  tmp="$(mktemp)"
  awk -v want="${issue}" -v deps="${deps}" '
    BEGIN { in_block = 0; replaced = 0 }
    /^\[/ {
      header = $0
      sub(/^\[/, "", header); sub(/\]$/, "", header)
      if (header == want) {
        in_block = 1; replaced = 1
        print "[" want "]"
        printf "depends_on = ["
        n = split(deps, arr, " ")
        first = 1
        for (i = 1; i <= n; i++) {
          if (arr[i] == "") continue
          if (!first) printf ", "
          printf "\"%s\"", arr[i]
          first = 0
        }
        printf "]\n"
        next
      } else {
        in_block = 0
        print
        next
      }
    }
    in_block && /^depends_on[[:space:]]*=/ { next }
    in_block && /^[[:space:]]*$/ { in_block = 0; print; next }
    { print }
    END {
      if (!replaced) {
        print "[" want "]"
        printf "depends_on = ["
        n = split(deps, arr, " ")
        first = 1
        for (i = 1; i <= n; i++) {
          if (arr[i] == "") continue
          if (!first) printf ", "
          printf "\"%s\"", arr[i]
          first = 0
        }
        printf "]\n"
      }
    }
  ' "${file}" > "${tmp}"
  mv "${tmp}" "${file}"
}

# depends_would_cycle <project> <new-dependent> <new-dependency>
# Returns 0 (true) if adding the edge would create a cycle.
depends_would_cycle() {
  local project="$1" a="$2" b="$3"
  local visited_file
  visited_file="$(mktemp)"
  _depends_dfs "${project}" "${b}" "${a}" "${visited_file}"
  local rc=$?
  rm -f "${visited_file}"
  return ${rc}
}

_depends_dfs() {
  local project="$1" node="$2" target="$3" visited_file="$4"
  if [ "${node}" = "${target}" ]; then
    return 0
  fi
  if grep -Fxq "${node}" "${visited_file}" 2>/dev/null; then
    return 1
  fi
  printf '%s\n' "${node}" >> "${visited_file}"
  local children child
  children="$(depends_list "${project}" "${node}")"
  for child in ${children}; do
    [ -z "${child}" ] && continue
    if _depends_dfs "${project}" "${child}" "${target}" "${visited_file}"; then
      return 0
    fi
  done
  return 1
}

# depends_all_dependents <project> — print every issue that has a [block].
depends_all_dependents() {
  local project="$1"
  local file
  file="$(depends_state_file "${project}")"
  [ -f "${file}" ] || return 0
  awk '/^\[/ { gsub(/^\[|\]$/, ""); print }' "${file}"
}

# depends_graph <project> — ASCII tree of the dependency graph.
depends_graph() {
  local project="$1"
  local roots="" all
  all="$(depends_all_dependents "${project}")"
  if [ -z "${all}" ]; then
    printf '(no dependencies recorded for project %s)\n' "${project}"
    return 0
  fi

  local node is_child other deps dep
  for node in ${all}; do
    is_child=0
    for other in ${all}; do
      [ "${other}" = "${node}" ] && continue
      deps="$(depends_list "${project}" "${other}")"
      for dep in ${deps}; do
        [ "${dep}" = "${node}" ] && is_child=1 && break
      done
      [ "${is_child}" -eq 1 ] && break
    done
    [ "${is_child}" -eq 0 ] && roots="${roots} ${node}"
  done

  if [ -z "${roots}" ]; then
    roots="${all}"
  fi

  for node in ${roots}; do
    printf '%s\n' "${node}"
    _depends_graph_render "${project}" "${node}" "  "
  done
}

_depends_graph_render() {
  local project="$1" parent="$2" prefix="$3"
  local children child count i
  children="$(depends_list "${project}" "${parent}")"
  count=0
  for child in ${children}; do
    [ -n "${child}" ] && count=$((count + 1))
  done
  [ "${count}" -eq 0 ] && return 0

  i=0
  for child in ${children}; do
    [ -z "${child}" ] && continue
    i=$((i + 1))
    if [ "${i}" -eq "${count}" ]; then
      printf '%s└── %s\n' "${prefix}" "${child}"
      _depends_graph_render "${project}" "${child}" "${prefix}    "
    else
      printf '%s├── %s\n' "${prefix}" "${child}"
      _depends_graph_render "${project}" "${child}" "${prefix}│   "
    fi
  done
}

# Stub — implemented in Task 5.
depends_ship_preflight() { return 0; }
