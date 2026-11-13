#!/usr/bin/env bash
#
# azp-cycle pre|post <n> - runs as root, from azp-agent@<n>'s ExecStartPre=+
# (pre) and ExecStopPost=+ (post): the two halves of one agent cycle, as
# gha-jitconfig and gha-jitreap are on a GitHub box. Installed 0700 root by the
# runner_azure_devops role from roles/runner_azure_devops/files/azp-cycle.sh.
#
# An Azure Pipelines agent keeps one registration for good, so a cycle mints
# nothing and deletes nothing. What is left is the restart backoff (RESTART
# BACKOFF in lib.sh): a healthy agent runs one job per cycle and comes straight
# back, while one whose starts keep running no job waits 10 s, 20 s ... 5 min
# before the next. Without it, an agent the pool rejects -- deleted there, a
# revoked registration -- would restart every second, for good.
#
#   pre   wait out the backoff, refuse an agent that is not registered, then
#         write the cycle's marker
#   post  count the cycle as one that ran no job, or clear the count -- unless
#         the stop was asked for (a drain, a reboot, a converge)
#
# Never fails in post: an ExecStopPost that fails marks the unit's result
# failed, and an agent that just finished a job cleanly would then read as a
# broken one.
set -uo pipefail

# shellcheck source=../../runner_host/files/lib.sh
. "${RUNNER_LIB_DIR:-/usr/local/lib/runner-hardening}/lib.sh" || exit 0

# Written when the cycle starts, and compared with the worker logs the cycle's
# job leaves in _diag: the role the .jit file plays on a GitHub box.
cycle_marker() { printf '%s/%s.start\n' "$(run_dir)" "$1"; }
cycle_fails()  { printf '%s/%s.fails\n' "$(run_dir)" "$1"; }

cycle_pre() { # cycle_pre <n>
  local n="$1"
  ensure_run_dir || return 1
  # First, so a `systemctl stop` cuts the wait short, as it does on GitHub.
  wait_out_backoff "$(cycle_fails "$n")"
  if ! has_hook vendor_registered; then
    echo "${0##*/}: no Azure DevOps vendor.sh in ${RUNNER_LIB_DIR:-/usr/local/lib/runner-hardening} - converge the host again" >&2
    return 1
  fi
  # run.sh would only fail on it, with "agent is not configured" in a log the
  # journal never shows; this says what to do. The failed start still counts,
  # so an unregistered instance retries every 5 minutes, not every second.
  if ! vendor_registered "$n"; then
    echo "${0##*/}: agent ${n} is not registered ($(runner_dir "$n") holds no .agent and .credentials)." >&2
    echo "${0##*/}: register it by converging with runner_azp_pat, or adopt an agent with runner_azp_adopt." >&2
    return 1
  fi
  touch "$(cycle_marker "$n")"
}

cycle_post() { # cycle_post <n>
  local n="$1"
  ensure_run_dir || return 0
  record_cycle "$(unit_of "$n")" "$(runner_dir "$n")" "$(cycle_marker "$n")" "$(cycle_fails "$n")"
  # The next post must not find this cycle's marker: a start that fails before
  # pre writes a new one ran no job, and has to count as such.
  rm -f "$(cycle_marker "$n")"
  return 0
}

main() {
  local step="${1:-}" n="${2:-}"
  if [[ ! "$step" =~ ^(pre|post)$ || ! "$n" =~ ^[1-9][0-9]*$ ]]; then
    echo "usage: ${0##*/} pre|post <agent-number>" >&2
    [[ "$step" == "post" ]] && return 0
    return 64
  fi
  if ! load_host_env; then
    echo "${0##*/}: cannot read ${RUNNER_HOST_ENV:-/etc/runner-hardening/host.env}" >&2
    [[ "$step" == "post" ]] && return 0
    return 1
  fi
  load_vendor
  # Two steps, fixed by the unit: not worth a dispatch table.
  if [[ "$step" == "pre" ]]; then
    cycle_pre "$n"
  else
    cycle_post "$n"
  fi
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
