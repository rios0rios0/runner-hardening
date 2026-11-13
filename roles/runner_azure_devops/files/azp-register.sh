#!/usr/bin/env bash
#
# azp-register <n>          registers agent <n> with the pool
# azp-register remove <n>   removes agent <n> from the pool
#
# Root-only (0700), installed by the runner_azure_devops role at
# /usr/local/sbin/azp-register from roles/runner_azure_devops/files/, and run
# by that role alone, with the PAT in /run/azp-register.pat for the length of
# the run. Both modes are idempotent: an agent already registered is not
# registered again, and one that is not registered has nothing to remove.
#
# The agent's own config.sh does the work, as the agent's user, never as root:
# it refuses root, and the tree it runs from is one that agent's jobs can
# write. It is driven unattended, with every answer an argument -- except the
# PAT, which is never one. /proc/<pid>/cmdline is readable by every account
# on the box, the agent users included, so config.sh finds it in its
# environment as VSTS_AGENT_INPUT_TOKEN, which the agent reads in place of
# --token and then removes from its own environment block.
set -Eeuo pipefail

# shellcheck source=../../runner_host/files/lib.sh
. "${RUNNER_LIB_DIR:-/usr/local/lib/runner-hardening}/lib.sh"

# Both overridable for the test suite only; on a box they are always these.
AZP_ENV_FILE="${AZP_ENV_FILE:-/etc/azure-pipelines-agent/env}"
AZP_PAT_FILE="${AZP_PAT_FILE:-/run/azp-register.pat}"

# What /etc/azure-pipelines-agent/env sets. Cleared first, so nothing inherited
# from whatever started this can stand in for a key the file lacks.
AZP_ENV_KEYS=(AZP_URL AZP_POOL AZP_SYSTEM_PATH)

load_azp_env() {
  local k
  for k in "${AZP_ENV_KEYS[@]}"; do unset "$k"; done
  [[ -r "$AZP_ENV_FILE" ]] || die "cannot read ${AZP_ENV_FILE}"
  # shellcheck source=/dev/null
  . "$AZP_ENV_FILE"
  [[ -n "${AZP_URL:-}" && -n "${AZP_POOL:-}" && -n "${AZP_SYSTEM_PATH:-}" ]] \
    || die "${AZP_ENV_FILE} lacks AZP_URL, AZP_POOL or AZP_SYSTEM_PATH"
}

# The PAT file must be this process's own and readable by nobody else: a token
# anyone else could have read is one to refuse, and one anyone else could have
# WRITTEN is not the operator's.
pat_file_ok() {
  local st
  [[ -f "$AZP_PAT_FILE" && ! -L "$AZP_PAT_FILE" ]] || return 1
  st=$(stat -c '%u %a' "$AZP_PAT_FILE" 2>/dev/null) || return 1
  [[ "$st" =~ ^${EUID}\ [4-7]00$ ]]
}

# config.sh snapshots its environment into the agent. env.sh, which it sources
# first, writes PATH to .path and appends LANG, JAVA_HOME, LD_LIBRARY_PATH,
# AGENT_TOOLSDIRECTORY and a dozen more to .env, which the agent then applies
# OVER its unit's environment at every start. This process inherits root's
# environment from Ansible, so it is cleared, and config.sh gets only the agent
# user's own. PATH stays: it is what finds setpriv and env, as root.
scrub_environment() {
  local v
  while IFS= read -r v; do
    if [[ "$v" != "PATH" ]]; then unset "$v" 2>/dev/null || true; fi
  done < <(compgen -e)
}

# run_config <n> <config.sh argument...> - as agent <n>'s user, in its tree
run_config() {
  local n="$1" u home token=""
  shift
  u=$(runner_user "$n"); home=$(runner_home "$n")
  pat_file_ok || die "${AZP_PAT_FILE} is missing, or readable by someone other than its owner"
  IFS= read -r token < "$AZP_PAT_FILE" || true
  [[ -n "$token" ]] || die "${AZP_PAT_FILE} is empty"

  scrub_environment
  # A builtin: no process, so no argv, ever holds the token.
  export VSTS_AGENT_INPUT_TOKEN="$token"
  token=""
  cd "$(runner_dir "$n")"
  # The agent user's PATH goes to config.sh alone, through env: in this
  # process, as root, ~/.local/bin first would let a job choose what root runs.
  setpriv --reuid="$u" --regid="$u" --init-groups -- \
    env HOME="$home" USER="$u" LOGNAME="$u" LANG="C.UTF-8" \
        PATH="${home}/.local/bin:${AZP_SYSTEM_PATH}" \
    ./config.sh "$@"
}

register() { # register <n>
  local n="$1" d name_key name
  d=$(runner_dir "$n")
  # config.sh refuses a tree that holds .agent at all; an agent that does is
  # registered, or needs a person to look at it.
  if [[ -e "${d}/.agent" ]]; then
    log "agent ${n} is already registered"
    return 0
  fi
  [[ -x "${d}/config.sh" ]] || die "no agent to register at ${d}"
  name_key="AZP_AGENT_NAME_${n}"
  name="${!name_key:-}"
  [[ -n "$name" ]] || die "${AZP_ENV_FILE} names no agent ${n} (${name_key})"
  # --replace takes over a registration of the same name that a failed earlier
  # run left in the pool, so registering again after a failure just works.
  # --acceptTeeEula is left out: unattended, the agent takes it as declined,
  # and only TFVC checkouts need it.
  run_config "$n" --unattended --url "$AZP_URL" --auth pat --pool "$AZP_POOL" \
    --agent "$name" --work _work --replace
}

deregister() { # deregister <n>
  local n="$1" d
  d=$(runner_dir "$n")
  if [[ ! -e "${d}/.agent" ]]; then
    log "agent ${n} is not registered: nothing to remove"
    return 0
  fi
  [[ -x "${d}/config.sh" ]] || die "no agent at ${d} to remove"
  run_config "$n" remove --unattended --auth pat
}

main() {
  local mode="register" n
  if [[ "${1:-}" == "remove" ]]; then mode="deregister"; shift; fi
  n="${1:-}"
  [[ "$n" =~ ^[1-9][0-9]*$ ]] || die "usage: ${0##*/} [remove] <agent-number>"
  load_host_env || die "cannot read ${RUNNER_HOST_ENV:-/etc/runner-hardening/host.env}"
  load_azp_env
  "$mode" "$n"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
