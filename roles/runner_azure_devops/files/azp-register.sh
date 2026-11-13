#!/usr/bin/env bash
#
# azp-register <n>          registers a fresh agent for instance <n> with the pool
# azp-register remove <n>   removes agent <n> from the pool
#
# Root-only (0700), installed by the runner_azure_devops role at
# /usr/local/sbin/azp-register from roles/runner_azure_devops/files/, and run
# by that role alone, with the PAT in /run/azp-register.pat for the length of
# the run.
#
# The PAT never meets code an agent's jobs control. A job can write all of its
# agent's tree -- config.sh, env.sh, bin/ -- and its user's ~/.local/bin, so:
#
#   - registration runs only in the PRISTINE unpack the role has just made
#     beside the instance (<base>/.<n>.new: root's, 0700, nothing in it owned
#     by anyone else), as root, with a clean environment and a system-only
#     PATH. The role then hands the tree to the agent user and swaps it in.
#   - removal never runs the agent at all, and never reads the instance's
#     .agent, which a job can rewrite to name another agent in the pool: it
#     deletes, through the REST API, the agent recorded root-side when this
#     host registered or adopted it (<state>/<n>.json).
#
# The token is never an argument: /proc/<pid>/cmdline is readable by every
# account on the box. config.sh finds it in its environment as
# VSTS_AGENT_INPUT_TOKEN, which the agent reads in place of --token and then
# removes from its own environment block; curl reads it from a 0600 header
# file.
set -Eeuo pipefail

# shellcheck source=../../runner_host/files/lib.sh
. "${RUNNER_LIB_DIR:-/usr/local/lib/runner-hardening}/lib.sh"

# All three overridable for the test suite only; on a box they are always these.
AZP_ENV_FILE="${AZP_ENV_FILE:-/etc/azure-pipelines-agent/env}"
AZP_PAT_FILE="${AZP_PAT_FILE:-/run/azp-register.pat}"
AZP_STATE_DIR="${AZP_STATE_DIR:-/var/lib/runner-hardening/azp}"
# This script's settings, never config.sh's environment, which is cleared.
declare +x AZP_ENV_FILE AZP_PAT_FILE AZP_STATE_DIR

# config.sh's whole environment. Root-owned directories only: nothing a job
# can write may be where config.sh, env.sh or the agent look for a program.
AZP_CONFIG_PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

# What /etc/azure-pipelines-agent/env sets. Cleared first, so nothing inherited
# from whatever started this can stand in for a key the file lacks.
AZP_ENV_KEYS=(AZP_URL AZP_POOL)

load_azp_env() {
  local k
  for k in "${AZP_ENV_KEYS[@]}"; do unset "$k"; done
  [[ -r "$AZP_ENV_FILE" ]] || die "cannot read ${AZP_ENV_FILE}"
  # shellcheck source=/dev/null
  . "$AZP_ENV_FILE"
  [[ -n "${AZP_URL:-}" && -n "${AZP_POOL:-}" ]] || die "${AZP_ENV_FILE} lacks AZP_URL or AZP_POOL"
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

# read_pat -> PAT, a global; a builtin read, so no process ever holds it in argv
read_pat() {
  PAT=""
  pat_file_ok || die "${AZP_PAT_FILE} is missing, or readable by someone other than its owner"
  IFS= read -r PAT < "$AZP_PAT_FILE" || true
  [[ -n "$PAT" ]] || die "${AZP_PAT_FILE} is empty"
}

staging_dir() { printf '%s/.%s.new\n' "$RUNNER_BASE" "$1"; }
record_of()   { printf '%s/%s.json\n' "$AZP_STATE_DIR" "$1"; }

# A tree is pristine when it is a real directory, 0700, and every file in it is
# this process's own -- root's, on a box: then no job has ever been able to
# reach it, and what config.sh runs is what the verified package holds.
staging_pristine() {
  local s="$1"
  [[ -d "$s" && ! -L "$s" ]] || return 1
  [[ "$(stat -c '%u %a' "$s" 2>/dev/null)" == "${EUID} 700" ]] || return 1
  [[ -z "$(find "$s" ! -uid "$EUID" -print -quit 2>/dev/null)" ]]
}

# This process inherits root's environment from Ansible. config.sh's env.sh
# snapshots PATH into .path and a dozen variables (LANG, JAVA_HOME,
# LD_LIBRARY_PATH, AGENT_TOOLSDIRECTORY, ...) into .env, which the agent
# applies over its unit's environment at every start; so everything goes, and
# config.sh gets only what it needs.
scrub_environment() {
  local v
  while IFS= read -r v; do
    unset "$v" 2>/dev/null || true
  done < <(compgen -e)
}

# record <n> <.agent> - which agent this host registered, kept where no job can
# write it, for removal to read instead of the instance's .agent
record() {
  local rec tmp
  rec=$(record_of "$1")
  jq -e '(.poolId | type) == "number" and (.agentId | type) == "number"' "$2" >/dev/null 2>&1 \
    || die "$2 names no pool and agent id"
  mkdir -p "$AZP_STATE_DIR"
  chmod 0700 "$AZP_STATE_DIR"
  tmp="${rec}.new"
  (umask 077; jq -c '{poolId, agentId, agentName}' "$2" > "$tmp")
  mv -f "$tmp" "$rec"
}

register() { # register <n>
  local n="$1" s name_key name
  s=$(staging_dir "$n")
  staging_pristine "$s" || die "${s} is not a fresh unpack of the agent (a real 0700 directory, every file root's)"
  [[ -x "${s}/config.sh" ]] || die "no agent to register at ${s}"
  # config.sh refuses a tree that holds .agent; the role unpacks afresh first.
  [[ ! -e "${s}/.agent" ]] || die "${s} already holds a registration"
  name_key="AZP_AGENT_NAME_${n}"
  name="${!name_key:-}"
  [[ -n "$name" ]] || die "${AZP_ENV_FILE} names no agent ${n} (${name_key})"
  read_pat

  scrub_environment
  # Builtins: no process, so no argv, ever holds the token. Root, because the
  # agent user is whom the jobs run as; config.sh and run.sh refuse root
  # unless AGENT_ALLOW_RUNASROOT says otherwise, and nothing else in the agent
  # checks. umask 077: config.sh writes the credentials as it goes.
  export PATH="$AZP_CONFIG_PATH" HOME="/root" LANG="C.UTF-8" AGENT_ALLOW_RUNASROOT="1"
  export VSTS_AGENT_INPUT_TOKEN="$PAT"
  PAT=""
  umask 077
  cd "$s"
  # --replace takes over a registration of the same name, the one a failed
  # earlier run left in the pool or this instance's own, so registering again
  # just works. --acceptTeeEula is left out: unattended, the agent takes it as
  # declined, and only TFVC checkouts need it.
  ./config.sh --unattended --url "$AZP_URL" --auth pat --pool "$AZP_POOL" \
    --agent "$name" --work _work --replace
  unset VSTS_AGENT_INPUT_TOKEN
  record "$n" "${s}/.agent"
  log "agent ${n} registered as ${name}"
}

deregister() { # deregister <n>
  local n="$1" rec pool id hdr code
  rec=$(record_of "$n")
  if [[ ! -f "$rec" || -L "$rec" ]]; then
    warn "no record of agent ${n} on this host (${rec}): nothing it can remove safely"
    return 3
  fi
  pool=$(jq -r '.poolId' "$rec" 2>/dev/null || true)
  id=$(jq -r '.agentId' "$rec" 2>/dev/null || true)
  [[ "$pool" =~ ^[0-9]+$ && "$id" =~ ^[0-9]+$ ]] || die "${rec} names no pool and agent id"
  read_pat

  # The header goes through a file curl reads (-H @file, which mktemp makes
  # 0600), never an argument. `-K -` was rejected for the GitHub API: its
  # unquoted form drops a malformed header silently instead of failing. A
  # global, so the trap still finds it should anything below fail.
  HDR=$(mktemp)
  trap 'rm -f "$HDR"' EXIT
  hdr="$HDR"
  printf 'Authorization: Basic %s\n' "$(printf ':%s' "$PAT" | base64 -w 0)" > "$hdr"
  PAT=""
  code=$(curl -sS -o /dev/null -w '%{http_code}' -X DELETE -H @"$hdr" \
    "${AZP_URL%/}/_apis/distributedtask/pools/${pool}/agents/${id}?api-version=7.1" 2>/dev/null) || true
  rm -f "$hdr"
  case "${code:-000}" in
    200|204) rm -f "$rec"; ok "agent ${n} (pool ${pool}, agent ${id}) removed from the pool" ;;
    404)     rm -f "$rec"; ok "agent ${n} (pool ${pool}, agent ${id}) was no longer in the pool" ;;
    *)       err "the pool refused to remove agent ${n} (pool ${pool}, agent ${id}): HTTP ${code:-000}"; return 1 ;;
  esac
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
