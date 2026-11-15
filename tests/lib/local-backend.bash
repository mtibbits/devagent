# tests/lib/local-backend.bash — #1016: the local code backend's reference and
# record path, built by an independent encoder (Python's urllib), for
# tests/backend-local.bats and tests/local-callers.bats.

. "$(dirname "${BASH_SOURCE[0]}")/hermetic-env.bash"   # idempotent (#322)

# _enc <value>: <value> percent-encoded as D-ref encodes it.
_enc() { python3 -X utf8 -c 'import sys,urllib.parse as u; print(u.quote(sys.argv[1], safe="~"))' "$1"; }

# _cdir <repo>: git's own common-dir line for <repo>, CR stripped.
_cdir() { git -C "$1" rev-parse --path-format=absolute --git-common-dir | tr -d '\r'; }

# _ref <repo> <branch>: the reference D-ref builds.
_ref() { printf 'local:%s#%s\n' "$(_enc "$(_cdir "$1")")" "$(_enc "$2")"; }

# _rec <repo> <branch>: the record's path.
_rec() { printf '%s/devagent/local-mr/%s' "$(_cdir "$1")" "$(_enc "$2")"; }

# _snap <repo>: refs, index and working tree as git reports them.
_snap() { git -C "$1" status --porcelain=v2 --branch; git -C "$1" for-each-ref; }
