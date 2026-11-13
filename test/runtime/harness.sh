# shellcheck shell=bash
#
# harness.sh - what every test/runtime/*_test.sh shares. A test file starts with
#
#   . "$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")/harness.sh"
#
# and ends with `finish`. In between: it_* cases, each defined and then invoked
# on the very next line, each in # given / # when / # then blocks. The output is
# the suite's protocol, which run.sh counts:
#
#   "  ok  <name>"          one line per assertion that held
#   "FAIL  <name>: <why>"   one line per assertion that did not
#
# and finish exits 1 when anything failed.
#
# The runtime scripts are driven as they are, against a scratch box (new_box)
# laid out like a real one. A case may substitute only what a box has and a
# test run does not:
#   - root-only steps, overridden after sourcing a script: the setpriv drop
#     (as_runner), the runner users themselves (runner_uid), and the chown to
#     root (ensure_root_dir, which ensure_run_dir calls);
#   - what a box talks to, as stand-ins in the box's bin/, first on PATH, each
#     recording how it was called: systemctl, logger (the box's journal),
#     docker (a runner's rootless daemon: a test must never reach the
#     developer's own) and curl (the network: a test must never reach it).
# A unit's cgroup is a scratch directory under the box's cgroup root, and the
# processes in it are real ones, named the way a runner's worker and listener
# show in /proc (see unit_state and set_busy).
# No network, no root, a few seconds.
#
# Several names here are set for the test files and the scripts they drive,
# never read in this file, which ShellCheck cannot see across the `source`.
# shellcheck disable=SC2034

set -uo pipefail

ROOT="$(cd -- "$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")/../.." && pwd)"
HOST_FILES="${ROOT}/roles/runner_host/files"
GITHUB_FILES="${ROOT}/roles/runner_github/files"
AZP_FILES="${ROOT}/roles/runner_azure_devops/files"
ORIG_PATH="$PATH"
WORK="$(mktemp -d)"
BOX="${WORK}/box"
# The flavour the current box was made for (new_box).
BOX_PREFIX="gha"; BOX_UNIT="gha-runner"; BOX_SLICE="gha.slice"; BOX_WORKER="Runner.Worker"

# The processes spawn_named started go first, then the scratch tree. chmod
# first: the disk-guard cases build a read-only Go module cache, which rm -rf
# cannot remove from under a directory it cannot write.
harness_cleanup() {
  local pid
  if [[ -f "${WORK}/pids" ]]; then
    while read -r pid; do kill "$pid" 2>/dev/null; done < "${WORK}/pids"
  fi
  chmod -R u+w "$WORK" 2>/dev/null; rm -rf "$WORK"
}
trap harness_cleanup EXIT

PASS=0; FAIL=0
pass() { PASS=$(( PASS + 1 )); printf '  ok  %s\n' "$1"; }
fail() { FAIL=$(( FAIL + 1 )); printf 'FAIL  %s: %s\n' "$1" "$2"; }

# assert_eq <name> <expected> <actual>
assert_eq() {
  if [[ "$2" == "$3" ]]; then pass "$1"; else fail "$1" "expected [$2], got [$3]"; fi
}
# assert_contains <name> <haystack> <needle>
assert_contains() {
  if [[ "$2" == *"$3"* ]]; then pass "$1"; else fail "$1" "[$3] not found in [$2]"; fi
}
# assert_not_contains <name> <haystack> <needle>
assert_not_contains() {
  if [[ "$2" != *"$3"* ]]; then pass "$1"; else fail "$1" "[$3] should not be in [$2]"; fi
}

finish() {
  printf '%d passed, %d failed\n' "$PASS" "$FAIL"
  if (( FAIL == 0 )); then exit 0; fi
  exit 1
}

exists() { if [[ -e "$1" || -L "$1" ]]; then echo yes; else echo no; fi; }

# put <file> [<days since a job last read it>] - nothing reads a fixture after
# this, so the atime it is given is the one the guard sees
put() {
  mkdir -p "$(dirname "$1")"; printf 'x' > "$1"
  [[ -z "${2:-}" ]] || touch -a -d "$2 days ago" "$1"
}

# new_box [github|azure_devops] [KEY=VALUE...] - a fresh scratch box at $BOX:
#   host.env    the flavour's host.env, every path in it inside $BOX; each
#               KEY=VALUE is appended, so it wins over the default
#   lib/        lib.sh and the flavour's vendor.sh, linked from the repository,
#               the way they sit side by side on a box
#   bin/        the stand-ins, first on PATH
#   state/      what the stand-ins answer from, and what they record:
#               calls.log (systemctl), journal.log (logger), docker.log,
#               curl.log; see unit_state and set_busy
#   cgroup/     the units' cgroups (RUNNER_CGROUP_ROOT)
#   var/lib/runner-hardening   the state directory (RUNNER_STATE_DIR)
# and exports RUNNER_LIB_DIR, RUNNER_HOST_ENV, STANDIN_STATE and PATH for it.
new_box() {
  local flavor="github" kv vendor unit
  if [[ "${1:-}" == "github" || "${1:-}" == "azure_devops" ]]; then flavor="$1"; shift; fi
  chmod -R u+w "$BOX" 2>/dev/null; rm -rf "$BOX"
  mkdir -p "$BOX"/{lib,bin,home,systemd,etc,opt,cgroup,var/lib/runner-hardening,state/props,state/jobs}
  : > "$BOX/state/calls.log"
  ln -s "${HOST_FILES}/lib.sh" "$BOX/lib/lib.sh"

  if [[ "$flavor" == "github" ]]; then
    unit="gha-runner"; vendor="${GITHUB_FILES}/vendor.sh"
    BOX_PREFIX="gha"; BOX_UNIT="gha-runner"; BOX_SLICE="gha.slice"; BOX_WORKER="Runner.Worker"
    mkdir -p "$BOX/opt/actions-runner" "$BOX/etc/github-runner"
    cat > "$BOX/host.env" <<EOF
RUNNER_FLAVOR="github"
RUNNER_USER_PREFIX="gha"
RUNNER_BASE="${BOX}/opt/actions-runner"
RUNNER_UNIT="gha-runner"
RUNNER_SLICE="gha.slice"
RUNNER_SBIN_PREFIX="gha"
RUNNER_CONFIG_DIR="${BOX}/etc/github-runner"
RUNNER_WORKER_PATTERN="Runner\.Worker"
RUNNER_WORK_POLICY="wipe"
EOF
  else
    unit="azp-agent"; vendor="${AZP_FILES}/vendor.sh"
    BOX_PREFIX="azp"; BOX_UNIT="azp-agent"; BOX_SLICE="azp.slice"; BOX_WORKER="Agent.Worker"
    mkdir -p "$BOX/opt/azure-pipelines-agent" "$BOX/etc/azure-pipelines-agent"
    cat > "$BOX/host.env" <<EOF
RUNNER_FLAVOR="azure_devops"
RUNNER_USER_PREFIX="azp"
RUNNER_BASE="${BOX}/opt/azure-pipelines-agent"
RUNNER_UNIT="azp-agent"
RUNNER_SLICE="azp.slice"
RUNNER_SBIN_PREFIX="azp"
RUNNER_CONFIG_DIR="${BOX}/etc/azure-pipelines-agent"
RUNNER_WORKER_PATTERN="Agent\.Worker"
RUNNER_WORK_POLICY="lru"
EOF
  fi
  cat >> "$BOX/host.env" <<EOF
RUNNER_COUNT="3"
RUNNER_TRUST="internal"
RUNNER_TOOLCACHE_PREFIX="${BOX}/opt/hostedtoolcache-"
RUNNER_DISK_SOFT="75"
RUNNER_DISK_HARD="90"
RUNNER_STALE_DAYS="7"
RUNNER_DRAIN_TIMEOUT="1800"
RUNNER_HEAVY_RUNNERS="1"
RUNNER_HOME_KEEP=".config/systemd/user/docker.service .config/systemd/user/default.target.wants/docker.service .local/share/docker"
RUNNER_HOME_ROOT="${BOX}/home"
RUNNER_RUN_ROOT="${BOX}/run"
RUNNER_SYSTEMD_DIR="${BOX}/systemd"
RUNNER_STATE_DIR="${BOX}/var/lib/runner-hardening"
RUNNER_CGROUP_ROOT="${BOX}/cgroup"
EOF
  for kv in "$@"; do printf '%s="%s"\n' "${kv%%=*}" "${kv#*=}" >> "$BOX/host.env"; done
  mkdir -p "$BOX/run/${unit}"
  if [[ -r "$vendor" ]]; then ln -s "$vendor" "$BOX/lib/vendor.sh"; fi
  write_stand_ins
  export RUNNER_LIB_DIR="$BOX/lib" RUNNER_HOST_ENV="$BOX/host.env" STANDIN_STATE="$BOX/state"
  export PATH="$BOX/bin:$ORIG_PATH"
}

# unit_state <unit> <ActiveState> <SubState> [<Result> [<ExecMainStatus>]] -
# what the stand-in systemctl reports for <unit>, which it then also lists. A
# unit that is up gets its cgroup, empty but for what set_busy puts in it; one
# that is down has none, as on a box.
unit_state() {
  local p="$BOX/state/props/$1"
  printf '%s\n' "$2" > "${p}.ActiveState"
  printf '%s\n' "$3" > "${p}.SubState"
  printf '%s\n' "${4:-success}" > "${p}.Result"
  printf '%s\n' "${5:-0}" > "${p}.ExecMainStatus"
  case "$2" in
    active|activating|deactivating|reloading) unit_cgroup "$1" >/dev/null ;;
    *) printf '\n' > "${p}.ControlGroup" ;;
  esac
  grep -qxF "$1" "$BOX/state/units" 2>/dev/null || printf '%s\n' "$1" >> "$BOX/state/units"
}

# unit_cgroup <unit> -> the scratch directory standing for <unit>'s cgroup,
# made on first use and reported as the unit's ControlGroup
unit_cgroup() {
  local cg="/${BOX_SLICE}/$1"
  printf '%s\n' "$cg" > "$BOX/state/props/$1.ControlGroup"
  mkdir -p "$BOX/cgroup${cg}"
  [[ -e "$BOX/cgroup${cg}/cgroup.procs" ]] || : > "$BOX/cgroup${cg}/cgroup.procs"
  printf '%s\n' "$BOX/cgroup${cg}"
}

# spawn_named <argv0> - starts a real process that /proc names <argv0>, the way
# a runner's worker or listener shows there; SPAWNED is its pid. Each is killed
# when the test file ends.
spawn_named() {
  bash -c 'exec -a "$1" sleep 60' _ "$1" >/dev/null 2>&1 &
  SPAWNED=$!
  printf '%s\n' "$SPAWNED" >> "${WORK}/pids"
}

# in_cgroup <unit> <argv0> - a process named <argv0> in <unit>'s cgroup
in_cgroup() {
  local dir; dir=$(unit_cgroup "$1")
  spawn_named "$2"
  printf '%s\n' "$SPAWNED" >> "${dir}/cgroup.procs"
}

# set_busy <user>... - each runner's unit has a job's worker in its cgroup
set_busy() {
  local u
  for u in "$@"; do in_cgroup "${BOX_UNIT}@${u#"$BOX_PREFIX"}.service" "$BOX_WORKER"; done
}

write_stand_ins() {
  cat > "$BOX/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
# stand-in systemctl: answers from $STANDIN_STATE, records every call
state="${STANDIN_STATE:?}"
printf 'systemctl %s\n' "$*" >> "${state}/calls.log"
prop() { cat "${state}/props/${1}.${2}" 2>/dev/null || printf '%s\n' "$3"; }
default_of() {
  case "$1" in
    ActiveState) echo inactive ;; SubState) echo dead ;; Result) echo success ;;
    ExecMainStatus|NRestarts) echo 0 ;; *) echo "" ;;
  esac
}
verb="${1:-}"; shift || true
last="${*: -1}"
case "$verb" in
  list-units)
    pattern="$last"
    [[ -f "${state}/units" ]] || exit 0
    while read -r u; do
      # shellcheck disable=SC2053  # a glob match, as systemctl's own pattern
      [[ "$u" == $pattern ]] || continue
      printf '%s loaded %s %s stand-in\n' "$u" "$(prop "$u" ActiveState inactive)" "$(prop "$u" SubState dead)"
    done < "${state}/units" ;;
  show)
    p=""
    while (( $# )); do [[ "$1" == "-p" ]] && { p="$2"; shift; }; shift; done
    prop "$last" "$p" "$(default_of "$p")" ;;
  is-active)
    [[ "$(prop "$last" ActiveState inactive)" == "active" ]] || exit 3 ;;
  list-jobs)
    cat "${state}/jobs/${last}" 2>/dev/null || true ;;
esac
exit 0
EOF
  cat > "$BOX/bin/logger" <<'EOF'
#!/usr/bin/env bash
# stand-in logger: the journal this box would write to
tag=""
while (( $# )); do
  case "$1" in -t) tag="$2"; shift 2 ;; --) shift; break ;; *) break ;; esac
done
printf '%s: %s\n' "$tag" "$*" >> "${STANDIN_STATE:?}/journal.log"
EOF
  cat > "$BOX/bin/docker" <<'EOF'
#!/usr/bin/env bash
# stand-in docker: a runner's rootless daemon, holding two containers and a volume
printf 'docker %s\n' "$*" >> "${STANDIN_STATE:?}/docker.log"
case "${1:-} ${2:-}" in
  "ps -aq")    printf 'c1\nc2\n' ;;
  "volume ls") printf 'v1\n' ;;
esac
exit 0
EOF
  cat > "$BOX/bin/curl" <<'EOF'
#!/usr/bin/env bash
# stand-in curl: a test never reaches the network, and every attempt is recorded
printf 'curl %s\n' "$*" >> "${STANDIN_STATE:?}/curl.log"
exit 7
EOF
  chmod 0755 "$BOX"/bin/*
}
