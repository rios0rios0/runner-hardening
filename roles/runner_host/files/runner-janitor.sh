#!/usr/bin/env bash
#
# <sbin>-janitor - Docker trim + health, daily, from <sbin>-janitor.timer.
# Installed by the runner_host role from roles/runner_host/files/runner-janitor.sh.
#
# trust=internal deliberately keeps the layer cache warm, which means the
# per-user rootless daemons accumulate images forever. This trims them daily,
# but it is only a backstop: it runs once a day, prunes Docker and nothing else,
# and every prune races jobs that are running. What actually bounds the disk is
# the disk guard, between jobs. The same timer notices runners that have died
# instead of letting them sit in `failed` unobserved, and hands over to the
# flavour's vendor_janitor for what only it can check (GitHub: the admin PAT,
# and the registrations a restart loop leaks).
set -uo pipefail

# shellcheck source=lib.sh
. "${RUNNER_LIB_DIR:-/usr/local/lib/runner-hardening}/lib.sh" || exit 0

# To the journal under this script's own name, and to whoever ran it by hand.
# vendor_janitor logs through this too.
log() { logger -t "${0##*/}" -- "$*"; echo "${0##*/}: $*"; }

# Measured where the rootless data roots are, each in its runner's $HOME: that
# is the filesystem every prune below frees.
usage() { df --output=pcent "$RUNNER_HOME_ROOT" 2>/dev/null | tail -1 | tr -dc '0-9'; }

prune_user() { # prune_user <n> <aggressive?>
  local n="$1" hard="$2" uid
  uid=$(runner_uid "$n") || return 0
  [[ -S "/run/user/${uid}/docker.sock" ]] || return 0
  if [[ "$hard" == "1" ]]; then
    as_runner "$n" docker system prune -af --volumes  >/dev/null 2>&1
    as_runner "$n" docker builder prune -af           >/dev/null 2>&1
  else
    # week-old only: never rips the cache out from under a running build
    as_runner "$n" docker image   prune -af --filter until=168h >/dev/null 2>&1
    as_runner "$n" docker builder prune -af --filter unused-for=168h >/dev/null 2>&1
  fi
  return 0
}

main() {
  local soft hard u n
  local -a dead=()
  load_host_env || exit 0
  load_vendor
  soft="$RUNNER_DISK_SOFT"    # start trimming week-old cache
  hard="$RUNNER_DISK_HARD"    # drop everything not in use

  # ---- disk ----
  u=$(usage); u=${u:-0}
  if (( u >= soft )); then
    log "disk at ${u}% (soft threshold ${soft}%) - trimming caches older than 7 days"
    for n in $(seq 1 "$RUNNER_COUNT"); do prune_user "$n" 0; done
    u=$(usage); u=${u:-0}
    if (( u >= hard )); then
      log "still at ${u}% (hard threshold ${hard}%) - full prune"
      for n in $(seq 1 "$RUNNER_COUNT"); do prune_user "$n" 1; done
      log "after full prune: $(usage)%"
    else
      log "recovered to ${u}%"
    fi
  fi

  # ---- health ----
  # An ephemeral runner exits after every job and systemd restarts it, so a unit
  # caught in auto-restart after a clean run is between jobs, not down. Counting
  # it as dead put a daily "RUNNERS DOWN" line in the journal naming healthy
  # runners and blaming an expired PAT. runner_unit_healthy is the one verify
  # uses. An instance the flavour has not registered yet has nothing to run,
  # which is not down either.
  for n in $(seq 1 "$RUNNER_COUNT"); do
    if has_hook vendor_registered && ! vendor_registered "$n"; then continue; fi
    runner_unit_healthy "$n" || dead+=("$n")
  done
  if (( ${#dead[@]} )); then
    log "RUNNERS DOWN: ${dead[*]} - check 'journalctl -u $(unit_of "${dead[0]}")'."
  fi

  # The flavour's own checks, told which runners are down so it can say what
  # most often takes them down on its side.
  if has_hook vendor_janitor; then vendor_janitor ${dead[@]+"${dead[@]}"}; fi
  exit 0
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
