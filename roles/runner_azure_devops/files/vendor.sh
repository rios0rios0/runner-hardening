# shellcheck shell=bash
#
# vendor.sh (Azure Pipelines) - the hooks <sbin>-admin, the janitor and
# azp-cycle call on an Azure DevOps box. Installed by the runner_azure_devops
# role at /usr/local/lib/runner-hardening/vendor.sh (0644 root), beside lib.sh,
# and sourced by lib.sh's load_vendor after host.env is loaded. Sourcing it
# defines functions and nothing else.
#
#   vendor_registered <n>     agent <n> holds a registration (.agent, .credentials)
#   vendor_verify             every agent registered, its credentials 0600 and its
#                             own, its binaries in place, its PATH in its own home
#   vendor_diagnose [<n>]     with <n>: that agent's registration and environment;
#                             without: how to run one by hand
#   vendor_reap               nothing to reap, and why
#
# No vendor_janitor, on purpose: there is no PAT on the box whose expiry to
# watch, and no per-job registration to leak. The agent prunes its own _diag
# logs after 30 days, and the disk guard evicts stale ones sooner under
# pressure.

# The files an agent's identity lives in. .agent names it (id, pool, server);
# .credentials and .credentials_rsaparams are its OAuth client and RSA private
# key, which is all the agent needs to talk to the pool. None of them holds a
# path, a user or a host, which is why a registered agent survives being moved
# to another directory and another owner.
AZP_CREDENTIAL_FILES=(.credentials .credentials_rsaparams)

vendor_registered() { # vendor_registered <n>
  local d
  d=$(runner_dir "$1")
  [[ -f "${d}/.agent" && -f "${d}/.credentials" ]]
}

# azp_foreign_homes <user> - the home of every account a person or root logs in
# with (uid 0, or the regular range 1000-59999), but <user>'s own: where an
# agent's PATH must never reach. Adopted agents come out of such a home, with
# a .path written there, and a tool found in another account's home runs with
# whatever that account left in it.
azp_foreign_homes() {
  getent passwd 2>/dev/null \
    | awk -F: -v u="$1" '($3 == 0 || ($3 >= 1000 && $3 < 60000)) && $1 != u && $6 != "" && $6 != "/" { print $6 }'
  return 0
}

# azp_foreign_path_entries <user> <PATH> - the entries of PATH inside another
# account's home, one per line
azp_foreign_path_entries() {
  local user="$1" entry home
  local -a homes=() entries=()
  mapfile -t homes < <(azp_foreign_homes "$user")
  IFS=: read -r -a entries <<< "$2"
  for entry in ${entries[@]+"${entries[@]}"}; do
    for home in ${homes[@]+"${homes[@]}"}; do
      if [[ "$entry" == "$home" || "$entry" == "${home%/}/"* ]]; then
        printf '%s\n' "$entry"
        break
      fi
    done
  done
  return 0
}

# azp_read_first_line <n> <file> - the file's first line, read as agent <n>'s
# user. Everything in an agent's tree is job-writable, so a job can replace any
# of it with a link to a root-only file; read as root, verify and diagnose
# would print that file's contents.
azp_read_first_line() {
  as_runner "$1" head -n 1 -- "$2" 2>/dev/null || true
}

# azp_check_agent <n> -> 1 on any failure, each one printed
azp_check_agent() {
  local n="$1" d u uid f st bad fail=0
  d=$(runner_dir "$n"); u=$(runner_user "$n"); uid=$(runner_uid "$n" || echo "?")
  if ! vendor_registered "$n"; then
    err "agent ${n}: not registered - ${d} holds no .agent and .credentials; converge with runner_azp_pat to register it, or adopt one"
    return 1
  fi
  for f in "${AZP_CREDENTIAL_FILES[@]}"; do
    # Not followed: a link where a key should be is a failure in itself.
    if [[ -L "${d}/${f}" ]]; then
      st="link"
    else
      st=$(stat -c '%a %u' "${d}/${f}" 2>/dev/null || echo "missing")
    fi
    if [[ "$st" != "600 ${uid}" ]]; then
      err "agent ${n}: ${f} is ${st} (mode uid), not 0600 owned by ${u}"
      fail=1
    fi
  done
  # A self-update leaves bin and externals as links to bin.<version> by
  # ABSOLUTE path; moved without re-pointing them, an agent cannot start.
  if [[ ! -x "${d}/bin/Agent.Listener" ]]; then
    err "agent ${n}: ${d}/bin/Agent.Listener is missing - a bin link still pointing at the agent's old place?"
    fail=1
  fi
  bad=$(azp_foreign_path_entries "$u" "$(azp_read_first_line "$n" "${d}/.path")")
  if [[ -n "$bad" ]]; then
    err "agent ${n}: .path reaches into another account's home: ${bad//$'\n'/ }"
    fail=1
  fi
  return "$fail"
}

vendor_verify() {
  local n fail=0
  for n in $(seq 1 "$RUNNER_COUNT"); do
    azp_check_agent "$n" || fail=1
  done
  if (( fail == 0 )); then
    ok "all ${RUNNER_COUNT} agent(s) registered, with 0600 credentials of their own and a PATH in their own home"
  fi
  return "$fail"
}

vendor_diagnose() {
  local n="${1:-}" d keys
  if [[ -z "$n" ]]; then
    echo
    echo "${C_B}run one agent by hand, outside the unit's sandbox${C_R}"
    echo "    systemctl stop $(unit_of 1)"
    echo "    sudo -u $(runner_user 1) -i bash -c 'cd $(runner_dir 1) && ./run.sh --once'"
    echo "    ${C_DIM}works by hand but not under systemd => the unit sandbox is the cause${C_R}"
    return 0
  fi
  d=$(runner_dir "$n")
  if vendor_registered "$n"; then
    # The agent writes .agent with a UTF-8 byte-order mark, which not every jq skips.
    printf '    agent   : %s\n' "$(as_runner "$n" cat -- "${d}/.agent" 2>/dev/null | sed '1s/^\xEF\xBB\xBF//' \
      | jq -r '"\(.agentName) (id \(.agentId)) in pool \(.poolName) at \(.serverUrl), work folder \(.workFolder)"' \
      2>/dev/null || echo 'unreadable .agent')"
  else
    printf '    agent   : %s\n' "not registered (${d} holds no .agent and .credentials)"
  fi
  printf '    version : %s\n' "$(readlink "${d}/bin" 2>/dev/null | sed -n 's/.*bin\.//p' | grep . || echo 'as unpacked (no self-update yet)')"
  printf '    PATH    : %s\n' "$(azp_read_first_line "$n" "${d}/.path" | grep . || echo '(no .path: the unit default)')"
  # Keys only: a value can be a proxy password. The agent applies .env OVER
  # the unit's environment, so a key the unit sets showing up here wins.
  keys=$(as_runner "$n" cut -d= -f1 -- "${d}/.env" 2>/dev/null | paste -sd' ' - || true)
  printf '    .env    : %s\n' "${keys:-(empty)}"
  return 0
}

vendor_reap() {
  ok "nothing to reap: an Azure Pipelines agent keeps one registration for as long as its instance exists, so no cycle leaves one behind"
  log "An instance retired by lowering runner_count is removed from the pool when the converge has runner_azp_pat."
  log "Without it the agent stays in the pool, offline, until it is deleted there (Organization settings > Agent pools > the pool > Agents)."
  return 0
}
