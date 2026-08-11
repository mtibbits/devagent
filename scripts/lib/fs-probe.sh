# scripts/lib/fs-probe.sh — behavioural filesystem probes (#565).
# shellcheck shell=bash

# Does chmod actually change the mode in <dir>? Returns 0 yes, 1 no, 2 the probe
# file could not be created. Behavioural rather than parsing /etc/fstab for
# `noacl`: the property that matters is what chmod DOES, and fstab syntax is
# specific to one platform. Compares the `ls -l` mode field rather than
# `stat -c '%a'` because stat's format flag is not portable across coreutils and
# BSD stat.
fs_chmod_is_effective() {
  local dir="$1" probe perms
  probe="$(mktemp "${dir%/}/.devagent-chmod-probe.XXXXXX" 2>/dev/null)" || return 2
  chmod 600 "$probe" 2>/dev/null || { rm -f "$probe"; return 1; }
  # shellcheck disable=SC2012  # reading `ls -l`'s mode field is the portable
  # form here; `stat -c` is GNU-only and `stat -f` is BSD-only
  perms="$(ls -l "$probe" | cut -c1-10)"
  rm -f "$probe"
  [ "$perms" = "-rw-------" ]
}
