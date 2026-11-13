#!/usr/bin/env bash
#
# <sbin>-reboot-if-idle - from <sbin>-reboot.timer, whose calendar is the
# reboot window (02:00-05:00). Installed by the runner_host role from
# roles/runner_host/files/runner-reboot-if-idle.sh.
#
# unattended-upgrades patches the box but never reboots it: on a CI box a
# blind reboot kills whatever job is running and produces a "flaky" build no
# one can reproduce. This applies a pending reboot instead, and ONLY when no
# runner on this host is executing a job. Anything other than a confident
# "zero busy" defers - a missed reboot is cheap, a killed job is a flaky build
# somebody has to chase.
#
# "Busy" is judged on the box, per runner, by the worker process every job
# runs in (runner_busy in lib.sh, the check drain uses too): it needs no
# credential, so it works for every flavour, and no API outage can answer it.
set -uo pipefail

# shellcheck source=lib.sh
. "${RUNNER_LIB_DIR:-/usr/local/lib/runner-hardening}/lib.sh" || exit 0

log() { logger -t "${0##*/}" -- "$*"; }

# /var/run is /run on every Ubuntu this supports; both are asked, as before.
reboot_required() {
  [[ -f "${RUNNER_RUN_ROOT}/reboot-required" || -f "${RUNNER_RUN_ROOT%/run}/var/run/reboot-required" ]]
}

# all_idle -> 0 only when every instance is confidently idle
all_idle() {
  local n rc
  while read -r n; do
    rc=0; runner_busy "$n" || rc=$?
    case "$rc" in
      1) ;;
      0) log "reboot pending, but runner ${n} is busy - deferring"; return 1 ;;
      *) log "reboot pending, but whether runner ${n} is busy cannot be told - deferring"; return 1 ;;
    esac
  done < <(existing_instances)
  return 0
}

main() {
  load_host_env || exit 0
  reboot_required || exit 0
  all_idle || exit 0
  # Two looks, a moment apart: a runner handed a job an instant ago may not
  # have started its worker yet at the first.
  sleep 2
  all_idle || exit 0

  log "reboot required and all runners idle - draining and rebooting"
  systemctl stop "${RUNNER_UNIT}@*" 2>/dev/null || true
  sleep 5
  systemctl reboot
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
