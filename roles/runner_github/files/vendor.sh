# shellcheck shell=bash
#
# vendor.sh (GitHub Actions) - the hooks <sbin>-admin and the janitor call on
# a GitHub box. Installed by the runner_github role at
# /usr/local/lib/runner-hardening/vendor.sh (0644 root), beside lib.sh, and
# sourced by lib.sh's load_vendor after host.env is loaded. Sourcing it defines
# functions and empty globals, nothing else; each hook reads
# ${RUNNER_CONFIG_DIR}/env (the installer's exact keys) and the admin PAT
# itself, when it is called.
#
#   vendor_verify             does GitHub see these runners, all online?
#   vendor_diagnose [<n>]     with <n>: that runner's wrapper and registration;
#                             without: the runner binary and how to start one by hand
#   vendor_reap               delete the offline registrations this host leaked
#   vendor_janitor [<n>...]   daily: the admin PAT's health, leaked registrations;
#                             <n>... are the runners the janitor found down
#   vendor_registered <n>     always true: see below

GH_API="https://api.github.com"
# The ephemeral wrapper, root-owned and outside every tree a job can write.
GH_WRAPPER="/usr/local/libexec/runner-hardening/gha-run-ephemeral"

# gh_api sets these, and is deliberately NOT used inside a command
# substitution: that would run it in a subshell and the globals would be lost.
GH_CODE=""; GH_BODY=""; GH_PAT_EXPIRY=""
GH_RUNNERS="[]"; GH_RUNNERS_PATH=""

# gh_load -> the answers in ${RUNNER_CONFIG_DIR}/env, and GHA_PAT from the pat
# file when there is one; 1 when this box stores no GitHub configuration.
# The env file keeps the installer's exact keys, RUNNER_BASE among them, so a
# rollback to the installer still finds what it wrote. host.env is where the
# paths come from, so its RUNNER_BASE is the one kept.
gh_load() {
  local base="${RUNNER_BASE:-}"
  [[ -r "${RUNNER_CONFIG_DIR}/env" ]] || return 1
  # shellcheck source=/dev/null
  . "${RUNNER_CONFIG_DIR}/env" || return 1
  RUNNER_BASE="$base"
  GHA_PAT=""
  if [[ -s "${RUNNER_CONFIG_DIR}/pat" ]]; then GHA_PAT="$(< "${RUNNER_CONFIG_DIR}/pat")"; fi
  return 0
}

gh_runners_path() {
  if [[ "${GHA_SCOPE:-}" == "org" ]]; then
    printf '/orgs/%s/actions/runners\n' "${GHA_ORG:-}"
  else
    printf '/repos/%s/%s/actions/runners\n' "${GHA_ORG:-}" "${GHA_REPO:-}"
  fi
}

# gh_api METHOD PATH [BODY] -> GH_CODE, GH_BODY, GH_PAT_EXPIRY
gh_api() {
  local m="$1" p="$2" payload="${3:-}" tmp hdr auth
  tmp=$(mktemp); hdr=$(mktemp); auth=$(mktemp)
  # The PAT must never be a curl ARGUMENT. /proc/<pid>/cmdline is world
  # readable, so for the life of every request any unprivileged account on this
  # box -- the runner users included -- could read the admin token straight out
  # of the process list. `-H @file` takes the header verbatim from a file that
  # mktemp creates 0600.
  #
  # `-K -` (config on stdin) was tried first and rejected: its unquoted value form
  # silently DROPS the header rather than failing, which sends the request
  # unauthenticated and turns a quoting mistake into a 200 nobody investigates.
  printf 'Authorization: Bearer %s\n' "${GHA_PAT:-}" > "$auth"
  local -a args=(-sS -o "$tmp" -D "$hdr" -w '%{http_code}' -X "$m"
    -H @"$auth"
    -H "Accept: application/vnd.github+json"
    -H "X-GitHub-Api-Version: 2022-11-28")
  if [[ -n "$payload" ]]; then args+=(-d "$payload"); fi
  GH_CODE=$(curl "${args[@]}" "${GH_API}${p}" 2>/dev/null || echo 000)
  GH_BODY=$(cat "$tmp" 2>/dev/null || true)
  # GitHub returns the PAT's expiry on every authenticated response.
  GH_PAT_EXPIRY=$(grep -i '^github-authentication-token-expiration:' "$hdr" 2>/dev/null \
                  | cut -d: -f2- | tr -d '\r' | xargs || true)
  rm -f "$tmp" "$hdr" "$auth"
  return 0
}

# Collect EVERY runner at the configured scope into GH_RUNNERS (a JSON array).
# GitHub defaults to per_page=30, so an unpaginated fetch silently truncates -
# which is how a cleanup pass reports success while leaving orphans on page 2.
gh_list_runners() {
  local page=1 chunk n acc='[]'
  GH_RUNNERS_PATH=$(gh_runners_path)
  while (( page <= 50 )); do
    gh_api GET "${GH_RUNNERS_PATH}?per_page=100&page=${page}"
    [[ "$GH_CODE" == "200" ]] || { GH_RUNNERS="$acc"; return 1; }
    chunk=$(jq -c '.runners // []' <<<"$GH_BODY" 2>/dev/null || echo '[]')
    n=$(jq 'length' <<<"$chunk" 2>/dev/null || echo 0)
    (( n == 0 )) && break
    acc=$(jq -c -s 'add' <<<"${acc}"$'\n'"${chunk}" 2>/dev/null || echo "$acc")
    (( n < 100 )) && break
    page=$(( page + 1 ))
  done
  GH_RUNNERS="$acc"
  return 0
}

# This box's own runners, as jq picks them out of GH_RUNNERS: named exactly the
# host (an old static runner) or <host>-<anything> (gha-jitconfig mints
# <host>-<n>-<epoch>). Never "contains": with it build-1 took build-10's runners
# for its own, counted them in verify, and reaped one that build-10 had minted
# seconds earlier and was still connecting.
# shellcheck disable=SC2016  # jq's variables, not the shell's
GH_OF_HOST='select(.name == $h or (.name | startswith($h + "-")))'
# The epoch a JIT name ends in; 0 for a name without one.
# shellcheck disable=SC2016  # jq's variables, not the shell's
GH_MINTED='((.name | capture("-(?<e>[0-9]{9,})$") | .e | tonumber) // 0)'

# gh_host -> the prefix this box names its runners with
gh_host() { printf '%s\n' "${RUNNER_NAME_PREFIX:-$(hostname -s)}"; }

# gh_count <host> [<status>] -> how many of GH_RUNNERS are <host>'s, with <status>
gh_count() {
  jq --arg h "$1" --arg s "${2:-}" "[.[] | ${GH_OF_HOST} | select(\$s == \"\" or .status == \$s)] | length" \
    <<<"$GH_RUNNERS" 2>/dev/null || echo 0
}

# gh_doomed <host> <now> -> "<id><TAB><name>" for each registration of <host>'s
# that is offline and was not minted in the last five minutes: a younger one is
# still connecting, whichever of this host's runners minted it
gh_doomed() {
  jq -r --arg h "$1" --argjson now "$2" \
    ".[] | select(.status == \"offline\") | ${GH_OF_HOST} | select(${GH_MINTED} < (\$now - 300)) | [.id, .name] | @tsv" \
    <<<"$GH_RUNNERS" 2>/dev/null || true
}

# gh_orphans <host> <now> -> the id of each JIT registration of <host>'s that is
# offline and older than five minutes. The janitor's, which asks nobody: a
# name without an epoch (an old static runner) is left to reap, which asks first.
gh_orphans() {
  jq -r --arg h "$1" --argjson now "$2" \
    ".[] | select(.status == \"offline\") | ${GH_OF_HOST} | select((.name | capture(\"-(?<e>[0-9]{9,})\$\") | .e | tonumber) < (\$now - 300)) | .id" \
    <<<"$GH_RUNNERS" 2>/dev/null || true
}

vendor_verify() {
  local fail=0 host cnt online offline up n
  if [[ "$(stat -c '%a %U' "${RUNNER_CONFIG_DIR}/pat" 2>/dev/null)" == "600 root" ]]; then
    ok "PAT is 0600 root:root"
  else
    err "PAT file permissions are wrong"; fail=1
  fi
  gh_load || { err "no GitHub configuration at ${RUNNER_CONFIG_DIR}/env"; return 1; }
  [[ -n "${GHA_PAT:-}" ]] || return "$fail"

  # Does GitHub actually see the runners? Paginated, or the counts are fiction.
  if ! gh_list_runners; then
    warn "could not list runners (HTTP ${GH_CODE})"
    return "$fail"
  fi
  host=$(gh_host)
  cnt=$(gh_count "$host")
  online=$(gh_count "$host" online)
  offline=$(( cnt - online ))

  # How many units are actually up? Extra registrations mean completely
  # different things depending on this; an earlier version ignored it and
  # announced "run.sh is dying" while every unit was active. Counted through
  # runner_unit_healthy for the same reason the unit check uses it: a runner
  # waiting out RestartSec between jobs is up, and calling it down is what made
  # the restart-loop test below fire on a busy box.
  up=0
  for n in $(seq 1 "$RUNNER_COUNT"); do
    runner_unit_healthy "$n" && up=$(( up + 1 )) || true
  done

  if (( cnt == 0 )); then
    warn "GitHub sees no runner from ${host} yet - give it ~30s, then re-run verify"
  elif (( up < RUNNER_COUNT && offline > RUNNER_COUNT )); then
    err "${up}/${RUNNER_COUNT} units up, and ${offline} offline registrations for ${host}."
    err "  That is a live restart loop: gha-jitconfig succeeds, run.sh dies."
    err "  Read the journal above - most often a CHDIR/exit-200 permission fault."
    fail=1
  elif (( offline > 0 )); then
    # Units are healthy, so these are leftovers from an earlier problem -
    # untidy, not a fault. Do not fail the run over them.
    warn "${online} runner(s) online; ${offline} leftover offline registration(s) from an earlier run."
    warn "  Not a current fault. Clear them with: ${0##*/} reap"
  else
    ok "GitHub sees ${cnt} runner(s) from ${host}, all ${online} online"
  fi
  return "$fail"
}

vendor_diagnose() {
  local n="${1:-}" u
  if [[ -n "$n" ]]; then
    printf '    wrapper : %s\n' "$(stat -c '%a %U:%G' "$GH_WRAPPER" 2>/dev/null || echo MISSING)"
    printf '    jit file: %s\n' "$(stat -c '%a %U:%G' "$(run_dir)/${n}.jit" 2>/dev/null || echo '(none - normal when stopped)')"
    return 0
  fi
  u=$(runner_user 1)
  echo
  echo "${C_B}runner binary${C_R}"
  # In the runner's own tree, which a job can write: read as its user, never
  # through a link (read_untrusted, lib.sh), or diagnose would print whatever
  # root-only file a job pointed it at.
  printf '    %s\n' "$(read_untrusted "$(runner_dir 1)/bin/runnerversion" 2>/dev/null || echo '?')"
  echo "${C_B}manual JIT mint (root path, proves the PAT still works)${C_R}"
  echo "    /usr/local/sbin/gha-jitconfig 1 && echo OK"
  echo "${C_B}run one by hand, outside the systemd sandbox${C_R}"
  echo "    /usr/local/sbin/gha-jitconfig 1"
  # The registration is group-readable by that runner's user and nobody else,
  # so the user reads it itself: it holds no sudo to read it with. Handed over
  # in the environment, as gha-run-ephemeral does, never on a command line.
  echo "    sudo -u ${u} -i bash -c 'cd $(runner_dir 1) && ACTIONS_RUNNER_INPUT_JITCONFIG=\"\$(cat $(run_dir)/1.jit)\" ./run.sh'"
  echo "    ${C_DIM}works by hand but not under systemd => the unit sandbox is the cause${C_R}"
  return 0
}

# Delete offline JIT registrations this host has leaked.
vendor_reap() {
  local host now id name e seen left done_n=0 failed=0
  local -a doomed=()
  head1 "Reaping orphan runner registrations"
  gh_load || { warn "no GitHub configuration at ${RUNNER_CONFIG_DIR}/env"; return 0; }
  [[ -n "${GHA_PAT:-}" ]] || { warn "no admin PAT stored at ${RUNNER_CONFIG_DIR}/pat"; return 0; }
  host=$(gh_host); now=$(date +%s)

  gh_list_runners || { warn "could not list runners (HTTP ${GH_CODE})"; return 0; }

  while IFS=$'\t' read -r id name; do
    [[ -n "$id" ]] || continue
    doomed+=("${id}:${name}")
  done < <(gh_doomed "$host" "$now")

  if (( ${#doomed[@]} == 0 )); then
    ok "nothing to reap for ${host}"
    return 0
  fi

  seen=$(jq 'length' <<<"$GH_RUNNERS" 2>/dev/null || echo '?')
  echo "  ${#doomed[@]} offline registration(s) from ${host} (scanned ${seen} runners, all pages):"
  for e in "${doomed[@]:0:8}"; do echo "    - ${e#*:}"; done
  (( ${#doomed[@]} > 8 )) && echo "    ... and $(( ${#doomed[@]} - 8 )) more"
  echo
  confirm "Delete all ${#doomed[@]} from GitHub?" y || { warn "left in place"; return 0; }

  for e in "${doomed[@]}"; do
    gh_api DELETE "${GH_RUNNERS_PATH}/${e%%:*}"
    if [[ "$GH_CODE" == "204" ]]; then done_n=$(( done_n + 1 )); else failed=$(( failed + 1 )); fi
    printf '\r  deleted %d/%d' "$done_n" "${#doomed[@]}"
  done
  echo
  (( failed )) && warn "${failed} deletion(s) failed"

  # Re-list and prove the job is actually finished, rather than assuming it.
  gh_list_runners || { ok "reaped ${done_n}"; return 0; }
  left=$(gh_count "$host" offline)
  if (( left == 0 )); then
    ok "reaped ${done_n}; verified none remain for ${host}"
  else
    warn "reaped ${done_n}; ${left} still offline (minted in the last 5 min, or deletion failed)"
  fi
  return 0
}

# The janitor's GitHub half. Logs through the janitor's own `log`, which
# reaches the journal under the janitor's name.
vendor_janitor() {
  local path exp_s days orphans count=0 rid
  if (( $# )); then
    log "Most common cause: the admin PAT in ${RUNNER_CONFIG_DIR}/pat expired or was revoked."
  fi
  gh_load || return 0
  [[ -n "${GHA_PAT:-}" ]] || return 0
  path=$(gh_runners_path)

  # ---- PAT health ----
  # This token is used on EVERY runner start. If it dies, the whole fleet
  # stops registering, and nothing else on the box would notice.
  gh_api GET "${path}?per_page=1"
  case "$GH_CODE" in
    200)
      if [[ -n "${GH_PAT_EXPIRY:-}" ]]; then
        exp_s=$(date -d "$GH_PAT_EXPIRY" +%s 2>/dev/null || echo 0)
        if (( exp_s > 0 )); then
          days=$(( (exp_s - $(date +%s)) / 86400 ))
          (( days <= 14 )) && log "ADMIN PAT EXPIRES IN ${days} DAY(S) (${GH_PAT_EXPIRY}) - rotate it or every runner here stops registering"
        fi
      fi ;;
    401) log "ADMIN PAT REJECTED (401): expired or revoked. Runners will stop registering. Fix: playbooks/rotate_github_pat.yaml" ;;
    403) log "ADMIN PAT LACKS RUNNER-ADMIN PERMISSION (403). Fix: playbooks/rotate_github_pat.yaml" ;;
    000) log "could not reach api.github.com to check the admin PAT" ;;
    *)   log "unexpected HTTP ${GH_CODE} checking the admin PAT" ;;
  esac

  # ---- orphan JIT registrations ----
  # A restart loop leaks one registration per attempt. Left alone they pile up
  # in the org's runner list forever. Only this host's, only offline ones, and
  # only those minted more than five minutes ago: a younger one is still
  # connecting.
  gh_list_runners || true
  if [[ "$GH_RUNNERS" != "[]" ]]; then
    orphans=$(gh_orphans "$(gh_host)" "$(date +%s)")
    for rid in ${orphans:-}; do
      [[ "$rid" =~ ^[0-9]+$ ]] || continue
      gh_api DELETE "${GH_RUNNERS_PATH}/${rid}"
      [[ "$GH_CODE" == 2* ]] && count=$(( count + 1 ))
    done
    (( count > 0 )) && log "reaped ${count} orphan JIT registration(s)"
  fi
  return 0
}

# A GitHub runner registers itself at every start with a single-use JIT config
# (gha-jitconfig), so there is no standing registration to be missing: an
# instance that is not registered right now is one between two jobs.
vendor_registered() { return 0; }
