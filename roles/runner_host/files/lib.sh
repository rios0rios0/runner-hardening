# shellcheck shell=bash
#
# lib.sh - what the runtime scripts on a runner box share.
#
# Installed by the runner_host role at /usr/local/lib/runner-hardening/lib.sh
# (0644 root) from roles/runner_host/files/lib.sh, and sourced -- never run --
# by the disk guard, the janitor, the reboot guard, <sbin>-admin and each
# flavour's own helpers:
#
#   . "${RUNNER_LIB_DIR:-/usr/local/lib/runner-hardening}/lib.sh"
#
# Sourcing it defines functions and a few empty globals, and reads nothing:
# load_host_env is what reads the box's configuration. Nothing here knows which
# service the runners register with. Every name and path comes from
# /etc/runner-hardening/host.env, which the runner_host role writes from the
# flavour's facts, so this one file serves every flavour on every box.
#
# Each function runs under its caller's shell options -- errexit in some scripts
# and not in others, nounset in all -- so each is written for both: nothing
# expands an unset variable, and a command allowed to fail says so.

# ---------------------------------------------------------------------------
# output
#
# Colour only when the stream a line goes to is a terminal, decided line by
# line: a caller may redirect one stream and not the other, and an escape
# sequence in a log file is noise. warn is deliberately stdout, unlike err: a
# script's stdout is the log somebody reads (the journal, an Ansible task's
# output), and a warning split onto stderr lands out of order with the steps it
# belongs to. Nothing here builds a payload on stdout, so there is no hazard in
# that -- call warn as a statement, never inside a command substitution.
# ---------------------------------------------------------------------------
_say() { # _say <fd> <colour> <tag> <message...>
  local fd="$1" colour="$2" tag="$3"
  shift 3
  if [[ -t "$fd" ]]; then
    printf '%s%s\033[0m %s\n' "$colour" "$tag" "$*" >&"$fd"
  else
    printf '%s %s\n' "$tag" "$*" >&"$fd"
  fi
}
log()  { _say 1 $'\033[1;34m' '==>' "$@"; }
ok()   { _say 1 $'\033[1;32m' '  ok' "$@"; }
warn() { _say 1 $'\033[1;33m' ' [!]' "$@"; }
err()  { _say 2 $'\033[1;31m' ' [x]' "$@"; }
die()  { err "$@"; exit 1; }

# For text a script formats itself: section titles, dimmed hints. Empty until
# use_colour finds stdout is a terminal, so they are safe to expand anywhere.
# C_CYN is only ever read by the scripts that source this file.
# shellcheck disable=SC2034
C_B="" C_R="" C_DIM="" C_CYN=""
# shellcheck disable=SC2034
use_colour() {
  if [[ -t 1 ]]; then
    C_B=$'\033[1m' C_R=$'\033[0m' C_DIM=$'\033[2m' C_CYN=$'\033[1;36m'
  else
    C_B="" C_R="" C_DIM="" C_CYN=""
  fi
}
hr()    { printf '%s%s%s\n' "$C_DIM" "$(printf '%.0s-' {1..72})" "$C_R"; }
head1() { echo; hr; printf '%s%s%s\n' "$C_B" "$*" "$C_R"; hr; }

# confirm <question> <y|n> -> 0 for yes. ASSUME_YES=1 (a mode's --yes) answers
# yes to everything. Otherwise the question is asked on the terminal, and with
# no terminal -- a run driven by Ansible has none -- its own default is taken: a
# run nobody can answer must neither hang waiting for an answer nor take one
# the question does not default to.
confirm() {
  local q="$1" d="${2:-n}" in=""
  [[ "${ASSUME_YES:-0}" == "1" ]] && return 0
  if [[ -t 0 ]]; then
    read -rp "? ${q} [$([[ "$d" == "y" ]] && echo 'Y/n' || echo 'y/N')]: " in || true
    in="${in:-$d}"
  else
    in="$d"
  fi
  [[ "${in,,}" == y* ]]
}

# ---------------------------------------------------------------------------
# configuration
# ---------------------------------------------------------------------------

# The keys host.env carries. Cleared before the file is read, so what a script
# sees is what this box's file says, never something inherited from whatever
# started the script. The last five are never written on a box: see below.
HOST_ENV_KEYS=(RUNNER_FLAVOR RUNNER_USER_PREFIX RUNNER_BASE RUNNER_UNIT RUNNER_SLICE
               RUNNER_SBIN_PREFIX RUNNER_CONFIG_DIR RUNNER_COUNT RUNNER_TRUST
               RUNNER_WORKER_PATTERN RUNNER_WORK_POLICY RUNNER_TOOLCACHE_PREFIX
               RUNNER_DISK_SOFT RUNNER_DISK_HARD RUNNER_STALE_DAYS RUNNER_DRAIN_TIMEOUT
               RUNNER_HEAVY_RUNNERS RUNNER_HOME_KEEP RUNNER_OLD_USERS
               RUNNER_HOME_ROOT RUNNER_RUN_ROOT RUNNER_SYSTEMD_DIR
               RUNNER_STATE_DIR RUNNER_CGROUP_ROOT)

# load_host_env -> 1 when this box has no usable host.env. RUNNER_HOST_ENV
# names another file; only the test suite does that.
load_host_env() {
  local f="${RUNNER_HOST_ENV:-/etc/runner-hardening/host.env}" k
  [[ -r "$f" ]] || return 1
  for k in "${HOST_ENV_KEYS[@]}"; do unset "$k"; done
  # shellcheck source=/dev/null
  . "$f" || return 1

  # Five roots a box's host.env never names, so on a box they are always the
  # real ones. The test suite names them, to run these scripts as non-root
  # against a scratch tree laid out like a box.
  RUNNER_HOME_ROOT="${RUNNER_HOME_ROOT:-/home}"
  RUNNER_RUN_ROOT="${RUNNER_RUN_ROOT:-/run}"
  RUNNER_SYSTEMD_DIR="${RUNNER_SYSTEMD_DIR:-/etc/systemd/system}"
  RUNNER_STATE_DIR="${RUNNER_STATE_DIR:-/var/lib/runner-hardening}"
  RUNNER_CGROUP_ROOT="${RUNNER_CGROUP_ROOT:-/sys/fs/cgroup}"

  RUNNER_FLAVOR="${RUNNER_FLAVOR:-}"
  RUNNER_SLICE="${RUNNER_SLICE:-}"
  RUNNER_SBIN_PREFIX="${RUNNER_SBIN_PREFIX:-}"
  RUNNER_CONFIG_DIR="${RUNNER_CONFIG_DIR:-}"
  RUNNER_TOOLCACHE_PREFIX="${RUNNER_TOOLCACHE_PREFIX:-/opt/hostedtoolcache-}"
  RUNNER_WORKER_PATTERN="${RUNNER_WORKER_PATTERN:-}"
  RUNNER_WORK_POLICY="${RUNNER_WORK_POLICY:-wipe}"
  RUNNER_HOME_KEEP="${RUNNER_HOME_KEEP:-}"
  RUNNER_OLD_USERS="${RUNNER_OLD_USERS:-}"
  # No default, on purpose: see runner_trusted.
  RUNNER_TRUST="${RUNNER_TRUST:-}"
  # Leading zeros are refused, not trimmed: bash arithmetic reads 08 as octal
  # and dies on it far from here.
  [[ "${RUNNER_COUNT:-}" =~ ^(0|[1-9][0-9]*)$ ]] || RUNNER_COUNT=0
  [[ "${RUNNER_DISK_SOFT:-}" =~ ^(0|[1-9][0-9]*)$ ]] || RUNNER_DISK_SOFT=75
  [[ "${RUNNER_DISK_HARD:-}" =~ ^(0|[1-9][0-9]*)$ ]] || RUNNER_DISK_HARD=90
  [[ "${RUNNER_STALE_DAYS:-}" =~ ^[1-9][0-9]*$ ]] || RUNNER_STALE_DAYS=7
  [[ "${RUNNER_DRAIN_TIMEOUT:-}" =~ ^(0|[1-9][0-9]*)$ ]] || RUNNER_DRAIN_TIMEOUT=1800
  [[ "${RUNNER_HEAVY_RUNNERS:-}" =~ ^(0|[1-9][0-9]*)$ ]] || RUNNER_HEAVY_RUNNERS=1

  [[ -n "${RUNNER_USER_PREFIX:-}" && -n "${RUNNER_BASE:-}" && -n "${RUNNER_UNIT:-}" ]]
}

# Trust is internal only when host.env says exactly that. Anything else -- the
# key missing, misspelt, empty -- is taken as untrusted: a reset before every
# job costs a warm cache, while the opposite mistake hands one fork PR's state
# to the next job.
runner_trusted() { [[ "${RUNNER_TRUST:-}" == "internal" ]]; }

# The flavour's optional hooks, from vendor.sh beside this file: vendor_verify,
# vendor_diagnose, vendor_reap, vendor_janitor, vendor_registered. A hook is
# called only when has_hook finds it, so a flavour defines only what it has.
load_vendor() {
  local dir="${BASH_SOURCE[0]%/*}"
  [[ "$dir" != "${BASH_SOURCE[0]}" ]] || dir="."
  [[ -r "${dir}/vendor.sh" ]] || return 0
  # shellcheck source=/dev/null
  . "${dir}/vendor.sh"
}
has_hook() { declare -F "$1" >/dev/null 2>&1; }

# ---------------------------------------------------------------------------
# names and paths, per instance
# ---------------------------------------------------------------------------
runner_user()      { printf '%s%s\n' "$RUNNER_USER_PREFIX" "$1"; }
runner_dir()       { printf '%s/%s\n' "$RUNNER_BASE" "$1"; }
# The same literal paths the unit's ReadWritePaths name, not getent's answer:
# whatever a reset clears must be the tree this runner's jobs could write.
runner_home()      { printf '%s/%s\n' "${RUNNER_HOME_ROOT:-/home}" "$(runner_user "$1")"; }
runner_toolcache() { printf '%s%s\n' "${RUNNER_TOOLCACHE_PREFIX:-/opt/hostedtoolcache-}" "$(runner_user "$1")"; }
runner_uid()       { id -u "$(runner_user "$1")" 2>/dev/null; }
unit_of()          { printf '%s@%s.service\n' "$RUNNER_UNIT" "$1"; }
dropin_dir()       { printf '%s/%s.d\n' "${RUNNER_SYSTEMD_DIR:-/etc/systemd/system}" "$(unit_of "$1")"; }
# Per-instance state that must not outlive a boot: the registration markers and
# the count of cycles that ran no job. tmpfs, root-only, one directory per unit
# name (/run/gha-runner, /run/azp-agent).
run_dir()          { printf '%s/%s\n' "${RUNNER_RUN_ROOT:-/run}" "$RUNNER_UNIT"; }
# What must survive a reboot, root-only: /var/lib/runner-hardening.
state_dir()        { printf '%s\n' "${RUNNER_STATE_DIR:-/var/lib/runner-hardening}"; }
# ensure_root_dir <dir> <mode> - root:root, whatever was there before
ensure_root_dir()  { install -d -m "$2" -o root -g root "$1"; }
ensure_run_dir()   { ensure_root_dir "$(run_dir)" 0711; }

# as_runner <n> cmd... - runs cmd as runner <n>'s user, never as root, with the
# environment its jobs have. Everything these scripts delete is job-writable,
# so a job can plant a symlink anywhere in it; as the runner user, the most a
# planted link can make rm reach is what the job could already delete itself.
as_runner() {
  local n="$1" u uid
  shift
  u=$(runner_user "$n")
  uid=$(runner_uid "$n") || return 1
  setpriv --reuid="$u" --regid="$u" --init-groups -- \
    env HOME="$(runner_home "$n")" XDG_RUNTIME_DIR="/run/user/${uid}" \
        DOCKER_HOST="unix:///run/user/${uid}/docker.sock" "$@"
}

# A file under a runner's home, its tree or its tool cache is one a job can
# have written - or replaced with a link to any file root can read, the admin
# PAT among them. Printed by a root `cat`, that link would put the file in the
# output of verify, diagnose or audit, which every converge shows. So such a
# file is only ever read as its runner's user, and never through a link at its
# end; find it with `find -type f`, which does not follow links either.

# instance_of_path <path> -> the instance whose home, tree or tool cache <path>
# lies in; status 1 when it lies in none of them
instance_of_path() {
  local p="$1" root rest n
  [[ -n "${RUNNER_USER_PREFIX:-}" && -n "${RUNNER_BASE:-}" ]] || return 1
  for root in "${RUNNER_HOME_ROOT:-/home}/${RUNNER_USER_PREFIX}" "${RUNNER_BASE}/" \
              "${RUNNER_TOOLCACHE_PREFIX:-/opt/hostedtoolcache-}${RUNNER_USER_PREFIX}"; do
    [[ "$p" == "$root"* ]] || continue
    rest="${p#"$root"}"; n="${rest%%/*}"
    if [[ "$n" =~ ^[1-9][0-9]*$ && "$rest" == "${n}/"* ]]; then
      printf '%s\n' "$n"; return 0
    fi
  done
  return 1
}

# read_untrusted <file> -> its content: read as the runner whose home, tree or
# tool cache it lies in (as the caller only outside all of them), and not at all
# when its last component is a link
read_untrusted() {
  local n
  if n=$(instance_of_path "$1"); then
    as_runner "$n" dd if="$1" iflag=nofollow status=none
  else
    dd if="$1" iflag=nofollow status=none
  fi
}

# ---------------------------------------------------------------------------
# instances and their state
# ---------------------------------------------------------------------------

# Every instance this box has: a <unit>@<n> systemd knows about, or a tree
# under RUNNER_BASE. Enumerated rather than counted off RUNNER_COUNT: a converge
# that LOWERS the count still has to drain and retire the runners the box is
# actually running, and those are the ones the count no longer names. Both
# sources, because a converge that failed half way can leave either without the
# other. Numeric, not lexical: runner 10 comes after runner 9.
existing_instances() {
  local d
  {
    systemctl list-units --all --plain --no-legend "${RUNNER_UNIT}@*" 2>/dev/null \
      | awk '{print $1}' \
      | sed -n "s/^${RUNNER_UNIT}@\([1-9][0-9]*\)\.service\$/\1/p" || true
    for d in "${RUNNER_BASE}"/*; do
      if [[ -d "$d" && ! -L "$d" && "${d##*/}" =~ ^[1-9][0-9]*$ ]]; then printf '%s\n' "${d##*/}"; fi
    done
  } | sort -nu
  return 0
}

# Is runner <n> executing a job? Its listener runs the whole time a unit is up,
# so that proves nothing; the worker (RUNNER_WORKER_PATTERN: Runner.Worker,
# Agent.Worker) exists only while a job is actually running. That is answerable
# per instance without asking the service the runner is registered with.
#
# Looked for in the unit's own cgroup, and nowhere else. Matching every process
# of the runner's user (pgrep -u) counted whatever a job left behind under a
# worker's name - in a rootless container, or a service of its user manager -
# so a job could make its runner look busy for good, and hold every reboot off
# and every drain to its full budget. Nothing in the unit's cgroup outlives the
# unit: a job's processes there end with the job.
#
# runner_busy <n> -> 0 busy, 1 idle, 2 cannot tell. Whatever acts on "idle" -- a
# reboot, a restart -- has to see a 1, not merely "not 0".
runner_busy() {
  local cg dir pid cmd
  [[ -n "${RUNNER_WORKER_PATTERN:-}" ]] || return 2
  cg=$(systemctl show -p ControlGroup --value "$(unit_of "$1")" 2>/dev/null) || return 2
  # No cgroup is a unit that runs nothing at all: a stopped one, or one that is
  # not there. Nothing of it can be busy.
  [[ -n "$cg" ]] || return 1
  dir="${RUNNER_CGROUP_ROOT:-/sys/fs/cgroup}${cg}"
  [[ -d "$dir" ]] || return 1
  [[ -r "${dir}/cgroup.procs" ]] || return 2
  while read -r pid; do
    [[ "$pid" =~ ^[0-9]+$ ]] || continue
    # The command line as pgrep -f matches it: the arguments, space-separated.
    cmd=$( { tr '\0' ' ' < "/proc/${pid}/cmdline"; } 2>/dev/null ) || continue
    if [[ "$cmd" =~ $RUNNER_WORKER_PATTERN ]]; then return 0; fi
  done < <(find "$dir" -name cgroup.procs -type f -exec cat {} + 2>/dev/null)
  return 1
}

# unit_prop <n> <Property> -> what systemd says, "?" when it cannot say
unit_prop() {
  local v
  v=$(systemctl show -p "$2" --value "$(unit_of "$1")" 2>/dev/null) || v="?"
  printf '%s\n' "$v"
}

# Does what systemd reports describe a runner between jobs, rather than a
# broken one? Pure - it asks nothing - so the decision itself is testable
# without a systemd to ask.
runner_state_between_jobs() { # <ActiveState> <Result> <ExecMainStatus>
  [[ "$1" == "activating" && "$2" == "success" && "$3" == "0" ]]
}

# "active" is the obvious yes. "activating" is the surprising one, and it is
# why this function exists instead of a bare `systemctl is-active`: these
# runners are ephemeral, so the unit exits after every single job and
# Restart=always brings it back RestartSec later with a fresh registration.
# activating/auto-restart with a clean result is therefore where a healthy
# runner spends the moment between jobs - a window `verify` lands in
# constantly on a busy box. A restart that follows a *failed* run (Result is
# not success, or a non-zero exit) is a genuine restart loop and still fails.
runner_unit_healthy() { # runner_unit_healthy <n>
  systemctl is-active --quiet "$(unit_of "$1")" && return 0
  runner_state_between_jobs "$(unit_prop "$1" ActiveState)" "$(unit_prop "$1" Result)" \
                            "$(unit_prop "$1" ExecMainStatus)"
}

# ===========================================================================
# RESTART BACKOFF - for runners that are failing, and only for them
#
# Restart=always brings a runner back after every job: that is the ephemeral
# loop working. A runner that cannot start comes back just as fast, and each
# attempt registers it again - API calls every RestartSec, on a credential the
# whole fleet shares. That one has to back off; the healthy one must not.
#
# systemd's RestartSteps/RestartMaxDelaySec cannot tell them apart: it counts
# every auto-restart, so once a runner had finished six jobs it sat out the
# full five minutes before registering for each next one. The exit status
# cannot either, because the runner's run-helper maps even a terminated error
# to 0. What can is whether a job ran: the worker writes one
# _diag/Worker_*.log per job. The unit's ExecStopPost helper counts the cycles
# in a row that ran none (record_cycle), and its ExecStartPre helper waits on
# that count before registering (wait_out_backoff). Every flavour's helpers
# source these from here, so there is one definition and the test suite
# exercises it.
# ===========================================================================

# restart_backoff_delay <cycles in a row that ran no job> -> seconds to wait
restart_backoff_delay() {
  local n="$1"
  [[ "$n" =~ ^[0-9]+$ ]] || n=0
  if (( n == 0 )); then
    echo 0
  elif (( n >= 6 )); then
    echo 300
  else
    echo $(( 10 << (n - 1) ))
  fi
}

# cycle_ran_a_job <runner dir> <file written when the cycle's registration was minted>
cycle_ran_a_job() {
  [[ -e "$2" ]] || return 1
  [[ -n "$(find "$1/_diag" -maxdepth 1 -name 'Worker_*.log' -newer "$2" -print -quit 2>/dev/null)" ]]
}

# record_cycle <unit> <runner dir> <cycle marker> <fails file> - ExecStopPost's
# half. Counts the cycles in a row that ran no job, and clears the count after
# one that did. A stop somebody asked for - a drain, a reboot, a credential
# rotation - is no failure even though that cycle ran no job either, and its
# stop or restart job is still running while this does, which is how it is
# told apart.
record_cycle() {
  local unit="$1" dir="$2" marker="$3" fails="$4" n
  [[ -z "$(systemctl list-jobs --no-legend "$unit" 2>/dev/null)" ]] || return 0
  if cycle_ran_a_job "$dir" "$marker"; then
    rm -f "$fails"
  else
    n=$(cat "$fails" 2>/dev/null || echo 0)
    [[ "$n" =~ ^[0-9]+$ ]] || n=0
    echo $(( n + 1 )) > "$fails"
  fi
  return 0
}

# wait_out_backoff <fails file> - ExecStartPre's half: wait before registering
# only if the last cycles ran no job. Waiting there, before any registration
# exists, also means a `systemctl stop` cuts the wait short instead of sitting
# it out.
wait_out_backoff() {
  local fails wait
  fails=$(cat "$1" 2>/dev/null || echo 0)
  wait=$(restart_backoff_delay "$fails")
  if (( wait > 0 )); then
    echo "${0##*/}: the last ${fails} start(s) ran no job - waiting ${wait}s before registering again"
    sleep "$wait"
  fi
  return 0
}
