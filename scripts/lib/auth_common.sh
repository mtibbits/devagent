#!/usr/bin/env bash
# scripts/lib/auth_common.sh
#
# Shared argument parsing and exec-runner for all auth/<backend>.sh
# scripts. Backends source this and supply their own create/store/
# rotate/destroy/status implementations.
#
# Public globals after auth_parse_args:
#   AUTH_VERB         — create|store|rotate|destroy|status|exec
#   AUTH_PROJECT      — project name
#   AUTH_TOKEN_FILE   — set only for `store`
#   AUTH_EXEC_CMD     — array; set only for `exec`
#
# Public functions:
#   auth_parse_args  VERB ARGS...
#   auth_run_exec    PROJECT BACKEND ENV_VAR_NAME CMD ARGS...

AUTH_VERB=""
AUTH_PROJECT=""
AUTH_TOKEN_FILE=""
AUTH_EXEC_CMD=()

auth_parse_args() {
  AUTH_VERB=""
  AUTH_PROJECT=""
  AUTH_TOKEN_FILE=""
  AUTH_EXEC_CMD=()

  if [ "$#" -eq 0 ]; then
    echo "auth: verb required (create|store|rotate|destroy|status|exec)" >&2
    return 1
  fi
  AUTH_VERB="$1"; shift

  case "${AUTH_VERB}" in
    create|rotate|destroy|status)
      if [ "$#" -lt 1 ]; then
        echo "auth: project required for '${AUTH_VERB}'" >&2
        return 1
      fi
      AUTH_PROJECT="$1"; shift
      ;;
    store)
      if [ "$#" -lt 2 ]; then
        echo "auth: project and token-file required for 'store'" >&2
        return 1
      fi
      AUTH_PROJECT="$1"; shift
      AUTH_TOKEN_FILE="$1"; shift
      ;;
    exec)
      if [ "$#" -lt 1 ]; then
        echo "auth: project required for 'exec'" >&2
        return 1
      fi
      AUTH_PROJECT="$1"; shift
      if [ "$#" -lt 1 ] || [ "$1" != "--" ]; then
        echo "auth: 'exec' requires '--' separator before command" >&2
        return 1
      fi
      shift
      if [ "$#" -lt 1 ]; then
        echo "auth: 'exec' requires a command after '--'" >&2
        return 1
      fi
      AUTH_EXEC_CMD=("$@")
      ;;
    *)
      echo "auth: unknown verb '${AUTH_VERB}'" >&2
      return 1
      ;;
  esac
  return 0
}

# auth_run_exec PROJECT BACKEND ENV_VAR_NAME CMD ARGS...
# Reads the secret, exports it under ENV_VAR_NAME, and execs CMD.
# Token is never passed via argv.
auth_run_exec() {
  local proj="$1" backend="$2" envvar="$3"; shift 3
  local val
  if ! val="$(secret_read "${proj}" "${backend}")"; then
    echo "auth: no token stored for ${proj}.${backend}" >&2
    return 2
  fi
  export "${envvar}=${val}"
  unset val
  exec "$@"
}
