#!/usr/bin/env bash
#
# docker <args...> - what an Azure Pipelines agent, and every job it runs, finds
# first on its PATH (each agent's .path). Every call goes on to the next docker
# on PATH as it came, except one: the agent's own `docker exec` of a container
# job's step, which runs as container root.
#
# Installed 0755 root by the runner_azure_devops role at
# /usr/local/libexec/runner-hardening/azp-bin/docker, from
# roles/runner_azure_devops/files/azp-docker.sh: outside every tree a job can
# write. It sources nothing, lib.sh included: it stands in front of every
# docker call an agent or a job makes, so it needs nothing else to work.
#
# The agent runs each step of a container job as `docker exec -u <uid>`, <uid>
# being its own host uid (StepHost.cs), as a user it adds to the container with
# that uid: with rootful Docker, what a step writes is then the agent's. With
# rootless Docker that uid is somebody else. Container uid 0 is the agent's own
# user there, and container uid U is host uid S + U - 1, S where the agent
# user's range starts in /etc/subuid: a user that owns nothing of the agent's.
# So the step could not read what the agent made for it on the host -- its task
# key in /__w/_temp, the checkout ("detected dubious ownership"), a Cache@2
# restore, which keeps its archive's 0700 and 0600 modes -- and what it left
# behind, the agent, its cleanup and the disk guard could not delete. ACLs do
# not close that gap: a file made 0700 masks every named entry out. No agent
# knob makes it use root, so this does: the step runs as container root, the
# agent's own user, the way GitHub's runner runs a container job's steps.
#
# It grants nothing. Root in the container is still only the agent's user on
# the host, and the agent gives its container user passwordless sudo anyway.
# Only the agent's worker is rewritten (the call's parent is Agent.Worker),
# and in it only an exec's -u <the agent's own uid>: a job's own
# `docker exec -u`, and every other call, go through as they came.
set -Eeuo pipefail

ARGS=()

# next_docker - the docker this one stands in front of: the first on PATH that
# is not in this file's own directory
next_docker() {
  local src="${BASH_SOURCE[0]}" self entry dir
  local -a entries
  [[ "$src" == */* ]] || src="./${src}"
  self=$(cd -P -- "${src%/*}" && pwd -P)
  IFS=: read -r -a entries <<< "$PATH"
  for entry in "${entries[@]}"; do
    [[ -n "$entry" ]] || continue
    dir=$(cd -P -- "$entry" 2>/dev/null && pwd -P) || continue
    [[ "$dir" != "$self" ]] || continue
    if [[ -f "${dir}/docker" && -x "${dir}/docker" ]]; then
      printf '%s\n' "${dir}/docker"
      return 0
    fi
  done
  return 1
}

# called_by_agent - true when the agent's job worker made this call: the
# parent's executable is Agent.Worker. By its executable, which the caller
# cannot rename, and by its name only where that cannot be read.
called_by_agent() {
  local exe='' comm=''
  if exe=$(readlink -- "/proc/${PPID}/exe" 2>/dev/null); then
    exe="${exe% (deleted)}"
    [[ "${exe##*/}" == "Agent.Worker" ]]
    return
  fi
  { read -r comm < "/proc/${PPID}/comm"; } 2>/dev/null || return 1
  [[ "$comm" == "Agent.Worker" ]]
}

# step_as_root <exec arguments...> - sets ARGS: the arguments of a
# `docker exec`, with its -u <this user's own uid> made -u 0. The options end
# at the container: what follows is the command, never rewritten.
step_as_root() {
  ARGS=()
  while (( $# > 0 )); do
    case "$1" in
      -u|--user)
        (( $# >= 2 )) || break
        if [[ "$2" == "$EUID" ]]; then ARGS+=("$1" '0'); else ARGS+=("$1" "$2"); fi
        shift 2
        ;;
      --user="$EUID")
        ARGS+=('--user=0')
        shift
        ;;
      -w|--workdir|-e|--env|--env-file|--detach-keys)
        (( $# >= 2 )) || break
        ARGS+=("$1" "$2")
        shift 2
        ;;
      -*)
        ARGS+=("$1")
        shift
        ;;
      *)
        break
        ;;
    esac
  done
  ARGS+=("$@")
}

main() {
  local docker
  if ! docker=$(next_docker); then
    echo "${0##*/}: no docker on PATH after ${BASH_SOURCE[0]%/*}" >&2
    exit 127
  fi
  if [[ "${1:-}" == "exec" ]] && called_by_agent; then
    shift
    step_as_root "$@"
    exec "$docker" exec "${ARGS[@]}"
  fi
  exec "$docker" "$@"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
