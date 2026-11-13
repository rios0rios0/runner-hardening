#!/usr/bin/env bash
#
# azp-run-once <n> - the unit's ExecStart, as agent <n>'s own user. One job,
# then exit: systemd starts it again (Restart=always), and azp-cycle counts
# what the cycle did.
#
# Installed 0755 root by the runner_azure_devops role at
# /usr/local/libexec/runner-hardening/azp-run-once, from
# roles/runner_azure_devops/files/azp-run-once.sh: outside the agent's tree,
# which its jobs can write, so a job cannot edit the wrapper the next job runs
# in.
#
# The unit's drop-in sets what a job sees (DOCKER_HOST, XDG_RUNTIME_DIR,
# CODEQL_RAM, the heavy capability, and AGENT_TOOLSDIRECTORY when
# trust=internal). The one thing this sets is PATH, from the agent's .path.
set -euo pipefail

# shellcheck source=../../runner_host/files/lib.sh
. "${RUNNER_LIB_DIR:-/usr/local/lib/runner-hardening}/lib.sh"

# Resolved before .path is applied, from the unit's own PATH: a docker that a
# job dropped into ~/.local/bin, first on .path, must not be what cleans up
# after that job.
DOCKER="docker"

# What a job leaves behind that the agent does not clean: containers and
# volumes its scripts started (`docker run -d`, `docker compose up`). The agent
# removes only what it started itself -- a container job's container, service
# containers, their network. Left running, a job's container would run beside
# every later job, as the GitHub wrapper prevents in the same way.
#
# The work directory is NOT touched, unlike on GitHub: under the lru work
# policy the sources, the task cache and the tool cache stay warm on purpose,
# and the disk guard evicts what goes cold. trust=internal keeps the image
# layer cache too; anything else wipes Docker state whole. The disk guard's
# reset before the next job is what an untrusted agent really relies on: this
# runs as the job's own user, and a job can kill it before it fires.
cleanup() {
  "$DOCKER" ps -aq       2>/dev/null | xargs -r "$DOCKER" rm -f        >/dev/null 2>&1 || true
  "$DOCKER" volume ls -q 2>/dev/null | xargs -r "$DOCKER" volume rm -f >/dev/null 2>&1 || true
  if runner_trusted; then
    "$DOCKER" image prune -f                                        >/dev/null 2>&1 || true
  else
    "$DOCKER" system prune -af --volumes                            >/dev/null 2>&1 || true
  fi
}

main() {
  local n="${1:-}" rc=0 pid entry
  [[ "$n" =~ ^[1-9][0-9]*$ ]] || die "usage: ${0##*/} <agent-number>"
  load_host_env || die "cannot read ${RUNNER_HOST_ENV:-/etc/runner-hardening/host.env}"
  cd "$(runner_dir "$n")"
  DOCKER=$(command -v docker || echo docker)

  # run.sh does not read .path. Only the agent's own service wrapper does
  # (runsvc.sh, which svc.sh installs and these units replace), so without
  # this a job would get systemd's bare PATH: not the agent user's
  # ~/.local/bin, where jobs install their own tools, nor what an operator put
  # in .path, the file the agent documents for exactly that.
  if [[ -s .path ]]; then
    IFS= read -r entry < .path || true
    if [[ -n "$entry" ]]; then export PATH="$entry"; fi
  fi

  trap cleanup EXIT

  # Deliberately NOT exec: exec replaces this shell, which discards the EXIT
  # trap and silently skips the cleanup above. Run it as a child, forward
  # SIGTERM so the agent finishes its job, then let the trap fire.
  ./run.sh --once &
  pid=$!
  trap 'kill -TERM "$pid" 2>/dev/null || true' TERM INT
  wait "$pid" || rc=$?
  # A trapped signal ends that wait at once, with the agent still shutting
  # down; wait for it, so the cleanup runs after it and the status is its own.
  while kill -0 "$pid" 2>/dev/null; do
    rc=0
    wait "$pid" || rc=$?
  done
  exit "$rc"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
