#!/usr/bin/env bash
#
# gha-run-ephemeral <n> - the unit's ExecStart, as runner <n>'s user. One job
# per registration: systemd restarts us, and ExecStartPre mints a new JIT
# config each time, so no credential and no workspace ever survives a job.
#
# Installed 0755 root by the runner_github role at
# /usr/local/libexec/runner-hardening/gha-run-ephemeral, from
# roles/runner_github/files/gha-run-ephemeral.sh: outside every tree a job can
# write, so a job can no longer edit the wrapper the next job runs in.
#
# The unit's drop-in sets everything a job sees (DOCKER_HOST, XDG_RUNTIME_DIR,
# CODEQL_RAM, and AGENT_TOOLSDIRECTORY when trust=internal); this sets nothing.
set -euo pipefail

# shellcheck source=../../runner_host/files/lib.sh
. "${RUNNER_LIB_DIR:-/usr/local/lib/runner-hardening}/lib.sh"

# What every job leaves behind goes, whatever the trust level: its containers
# and its volumes. trust=internal keeps the layer cache warm and only drops
# dangling images; anything else wipes Docker state whole. The disk guard's
# reset before the next job is what an untrusted runner really relies on: this
# runs as the job's own user, and a job can kill it before it fires.
cleanup() {
  docker ps -aq       2>/dev/null | xargs -r docker rm -f          >/dev/null 2>&1 || true
  docker volume ls -q 2>/dev/null | xargs -r docker volume rm -f   >/dev/null 2>&1 || true
  if runner_trusted; then
    docker image prune -f                                          >/dev/null 2>&1 || true
  else
    docker system prune -af --volumes                              >/dev/null 2>&1 || true
  fi
  rm -rf "${RUNNER_DIR}/_work"
}

main() {
  local n="${1:-}" jit rc=0
  [[ "$n" =~ ^[1-9][0-9]*$ ]] || die "usage: ${0##*/} <runner-number>"
  load_host_env || die "cannot read ${RUNNER_HOST_ENV:-/etc/runner-hardening/host.env}"
  # A global: cleanup runs from the EXIT trap, after main has returned.
  RUNNER_DIR=$(runner_dir "$n")
  cd "$RUNNER_DIR"
  jit="$(< "$(run_dir)/${n}.jit")"

  rm -rf ./_work
  install -d -m 0700 ./_work

  trap cleanup EXIT

  # Deliberately NOT exec: exec replaces this shell, which discards the EXIT
  # trap and silently skips every post-job cleanup above. Run it as a child,
  # forward SIGTERM so the runner drains its job, then let the trap fire.
  ./run.sh --jitconfig "$jit" &
  RUNNER_PID=$!
  trap 'kill -TERM "$RUNNER_PID" 2>/dev/null || true' TERM INT
  wait "$RUNNER_PID" || rc=$?
  exit "$rc"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
