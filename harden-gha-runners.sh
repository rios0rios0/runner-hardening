#!/usr/bin/env bash
#
# harden-gha-runners.sh - self-contained installer.
#
# Run it as root on a fresh (ideally reimaged) Ubuntu box. It asks what it
# cannot infer, validates every answer against the GitHub API before touching
# anything, and then builds the whole runner fleet:
#
#   * one dedicated unprivileged UNIX user per runner - no sudo, no docker group
#   * rootless Docker per user (so `container:` jobs and buildx both work, with
#     no root-owned docker socket anywhere on the box)
#   * ephemeral JIT runners: one job per registration, fresh workspace each time
#   * hardened systemd units; the admin PAT is never readable by a job
#   * memory and CPU ceilings derived from this machine's actual capacity
#
# USAGE
#   sudo ./harden-gha-runners.sh              # interactive install
#   sudo ./harden-gha-runners.sh audit        # report only, changes nothing
#   sudo ./harden-gha-runners.sh verify       # post-flight checks
#   sudo ./harden-gha-runners.sh diagnose     # why won't a runner stay up
#   sudo ./harden-gha-runners.sh reap         # delete leaked offline registrations
#   sudo ./harden-gha-runners.sh retune       # reapply CPU/memory policy only
#   sudo ./harden-gha-runners.sh sandbox-probe  # which systemd directive breaks a job?
#   sudo ./harden-gha-runners.sh sandbox-relax  # clear the seccomp filter
#   sudo ./harden-gha-runners.sh sandbox-off    # strip the sandbox (diagnostic)
#   sudo ./harden-gha-runners.sh updates      # unattended security upgrades + safe reboots
#   sudo ./harden-gha-runners.sh rotate-pat   # replace the admin PAT safely
#     unattended: GHA_NEW_PAT='<new-pat>' GHA_YES=1 sudo -E ./harden-gha-runners.sh rotate-pat
#   sudo ./harden-gha-runners.sh reconfigure  # redo the wizard, reinstall
#   sudo ./harden-gha-runners.sh uninstall    # remove everything this created
#
# GHA_COUNT=auto sizes the runner count from the box's own CPU and RAM instead
# of prompting, which is what makes an unattended install possible on a machine
# whose capacity the caller does not know.
#
# NON-INTERACTIVE (handy for every machine after the first - the installer
# prints the exact line to use, prefilled, when it finishes):
#   GHA_ORG=your-org GHA_PAT=<pat> GHA_COUNT=3 GHA_TRUST=internal GHA_YES=1 \
#     sudo -E ./harden-gha-runners.sh
#
# WHOLE FLEET AT ONCE
#   ./fleet.sh install          # every host in fleet.conf, over SSH, in parallel
#   ./fleet.sh verify           # any mode above, fanned out the same way
#
set -Eeuo pipefail
umask 022   # deterministic file modes; anything secret is chmod'd explicitly

# Resolve our own path BEFORE changing directory - otherwise a relative $0
# stops resolving and the self-checksum below silently reports "?".
SCRIPT_PATH="$(readlink -f "$0" 2>/dev/null || echo "$0")"

# Never let the directory the installer happens to be launched from influence
# it. Everything here uses absolute paths; a stray ./run.sh or ./config.sh in
# the CWD must be irrelevant.
cd /

SCRIPT_VERSION="1.0.0"   # bumped on every change; shown on every run

# ---------------------------------------------------------------------------
# constants (paths, not tunables - everything tunable is asked for)
# ---------------------------------------------------------------------------
CONF_DIR="/etc/github-runner"
ENV_FILE="${CONF_DIR}/env"
PAT_FILE="${CONF_DIR}/pat"
RUNNER_BASE="/opt/actions-runner"
USER_PREFIX="gha"
API="https://api.github.com"
STATE_DIR="/var/lib/github-runner"

# ---------------------------------------------------------------------------
# output helpers
# ---------------------------------------------------------------------------
if [[ -t 1 ]]; then
  C_B=$'\033[1m'; C_R=$'\033[0m'; C_BLU=$'\033[1;34m'; C_YEL=$'\033[1;33m'
  C_RED=$'\033[1;31m'; C_GRN=$'\033[1;32m'; C_CYN=$'\033[1;36m'; C_DIM=$'\033[2m'
else
  C_B=""; C_R=""; C_BLU=""; C_YEL=""; C_RED=""; C_GRN=""; C_CYN=""; C_DIM=""
fi
log()  { printf '%s==>%s %s\n' "$C_BLU" "$C_R" "$*"; }
ok()   { printf '%s  ok%s %s\n' "$C_GRN" "$C_R" "$*"; }
warn() { printf '%s [!]%s %s\n' "$C_YEL" "$C_R" "$*"; }
err()  { printf '%s [x]%s %s\n' "$C_RED" "$C_R" "$*" >&2; }
die()  { err "$*"; exit 1; }
hr()   { printf '%s%s%s\n' "$C_DIM" "$(printf '%.0s-' {1..72})" "$C_R"; }
head1(){ echo; hr; printf '%s%s%s\n' "$C_B" "$*" "$C_R"; hr; }

# ---------------------------------------------------------------------------
# input helpers. Every prompt honours a pre-set environment variable, so the
# same script runs fully unattended when the vars are supplied.
# ---------------------------------------------------------------------------
ensure_tty() {
  [[ -t 0 ]] && return 0
  [[ -e /dev/tty ]] && exec < /dev/tty && return 0
  die "no terminal available - supply GHA_* environment variables instead (see header)"
}

ask() { # ask VARNAME "question" ["default"]
  local __v="$1" __q="$2" __d="${3:-}" __in=""
  [[ -n "${!__v:-}" ]] && { ok "${__q}: ${!__v}  ${C_DIM}(from environment)${C_R}"; return; }
  # A default nobody can reach is not a default. Unattended, take it rather
  # than reaching for a terminal an SSH-driven run does not have -- this is
  # only ever hit on a host with no stored answer, so there is nothing here to
  # override; a configured box gets its value from load_config long before.
  if [[ -n "${GHA_YES:-}" && -n "$__d" ]]; then
    printf -v "$__v" '%s' "$__d"
    ok "${__q}: ${__d}  ${C_DIM}(default, unattended)${C_R}"
    return
  fi
  ensure_tty
  if [[ -n "$__d" ]]; then
    read -rp "${C_CYN}?${C_R} ${__q} ${C_DIM}[${__d}]${C_R}: " __in || true
    __in="${__in:-$__d}"
  else
    while [[ -z "$__in" ]]; do read -rp "${C_CYN}?${C_R} ${__q}: " __in || true; done
  fi
  printf -v "$__v" '%s' "$__in"
}

ask_secret() { # ask_secret VARNAME "question"
  local __v="$1" __q="$2" __in=""
  [[ -n "${!__v:-}" ]] && { ok "${__q}: ${C_DIM}(from environment)${C_R}"; return; }
  ensure_tty
  while [[ -z "$__in" ]]; do
    read -rsp "${C_CYN}?${C_R} ${__q}: " __in || true; echo
  done
  printf -v "$__v" '%s' "$__in"
}

ask_yn() { # ask_yn "question" "y|n"  -> returns 0 for yes
  local __q="$1" __d="${2:-n}" __in=""
  [[ -n "${GHA_YES:-}" ]] && return 0
  ensure_tty
  read -rp "${C_CYN}?${C_R} ${__q} ${C_DIM}[$( [[ $__d == y ]] && echo 'Y/n' || echo 'y/N' )]${C_R}: " __in || true
  __in="${__in:-$__d}"
  [[ "${__in,,}" == y* ]]
}

# ask_menu VARNAME "question" "value:label" ...
ask_menu() {
  local __v="$1" __q="$2"; shift 2
  local -a opts=("$@") vals=() labels=()
  local o
  for o in "${opts[@]}"; do vals+=("${o%%:*}"); labels+=("${o#*:}"); done
  if [[ -n "${!__v:-}" ]]; then
    ok "${__q}: ${!__v}  ${C_DIM}(from environment)${C_R}"; return
  fi
  # Unattended: take option 1, which is what the interactive prompt defaults to
  # ([1]). warn rather than ok -- an alternative was chosen on the operator's
  # behalf, and for GHA_TRUST that choice decides whether state is wiped
  # between jobs, so it belongs in the log.
  if [[ -n "${GHA_YES:-}" ]]; then
    printf -v "$__v" '%s' "${vals[0]}"
    warn "${__q}: ${vals[0]}  (first option, unattended -- set ${__v} to choose)"
    return
  fi
  ensure_tty
  echo "${C_CYN}?${C_R} ${__q}"
  local i
  for i in "${!vals[@]}"; do printf '    %s%d)%s %s\n' "$C_B" $((i+1)) "$C_R" "${labels[$i]}"; done
  local pick=""
  while :; do
    read -rp "    choice [1]: " pick || true
    pick="${pick:-1}"
    [[ "$pick" =~ ^[0-9]+$ ]] && (( pick >= 1 && pick <= ${#vals[@]} )) && break
    echo "    ${C_YEL}pick 1-${#vals[@]}${C_R}"
  done
  printf -v "$__v" '%s' "${vals[$((pick-1))]}"
}

# gh_api METHOD PATH [BODY]
# Sets the globals GH_CODE and GH_BODY. Deliberately NOT used inside a command
# substitution: that would run it in a subshell and the globals would be lost.
GH_CODE=""; GH_BODY=""; GH_PAT_EXPIRY=""
GH_RUNNERS="[]"; GH_RUNNERS_PATH=""

# Collect EVERY runner at the configured scope into GH_RUNNERS (a JSON array).
# GitHub defaults to per_page=30, so an unpaginated fetch silently truncates -
# which is how a cleanup pass reports success while leaving orphans on page 2.
gh_list_runners() {
  local page=1 chunk n acc='[]'
  [[ "$GHA_SCOPE" == "org" ]] && GH_RUNNERS_PATH="/orgs/${GHA_ORG}/actions/runners" \
                              || GH_RUNNERS_PATH="/repos/${GHA_ORG}/${GHA_REPO}/actions/runners"
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
gh_api() {
  local m="$1" p="$2" payload="${3:-}" tmp hdr auth
  tmp=$(mktemp); hdr=$(mktemp); auth=$(mktemp)
  # The PAT must never be a curl ARGUMENT. /proc/<pid>/cmdline is world
  # readable, so for the life of every request any unprivileged account on this
  # box -- including the runner users this installer creates -- can read the admin
  # token straight out of the process list. `-H @file` takes the header verbatim
  # from a file that mktemp creates 0600.
  #
  # `-K -` (config on stdin) was tried first and rejected: its unquoted value form
  # silently DROPS the header rather than failing, which sends the request
  # unauthenticated and turns a quoting mistake into a 200 nobody investigates.
  printf 'Authorization: Bearer %s\n' "$GHA_PAT" > "$auth"
  local -a args=(-sS -o "$tmp" -D "$hdr" -w '%{http_code}' -X "$m"
    -H @"$auth"
    -H "Accept: application/vnd.github+json"
    -H "X-GitHub-Api-Version: 2022-11-28")
  [[ -n "$payload" ]] && args+=(-d "$payload") || true
  GH_CODE=$(curl "${args[@]}" "${API}${p}" 2>/dev/null || echo 000)
  GH_BODY=$(cat "$tmp" 2>/dev/null || true)
  # GitHub returns the PAT's expiry on every authenticated response.
  GH_PAT_EXPIRY=$(grep -i '^github-authentication-token-expiration:' "$hdr" 2>/dev/null \
                  | cut -d: -f2- | tr -d '\r' | xargs || true)
  rm -f "$tmp" "$hdr" "$auth"
  return 0
}

# ===========================================================================
# PREFLIGHT
# ===========================================================================
preflight() {
  head1 "Preflight"
  [[ $EUID -eq 0 ]] || die "run as root"

  . /etc/os-release 2>/dev/null || die "cannot read /etc/os-release"
  [[ "${ID:-}" == "ubuntu" ]] || warn "tested on Ubuntu; found ${ID:-unknown} ${VERSION_ID:-}"
  ok "os: ${PRETTY_NAME:-unknown}"

  [[ "$(uname -m)" == "x86_64" ]] || die "this installer pulls the x64 runner; found $(uname -m)"

  local kmaj kmin; IFS=. read -r kmaj kmin _ < <(uname -r | cut -d- -f1)
  if (( kmaj < 5 || (kmaj == 5 && kmin < 11) )); then
    die "kernel $(uname -r) is too old for rootless overlayfs (need >= 5.11)"
  fi
  ok "kernel: $(uname -r)"

  [[ "$(stat -fc %T /sys/fs/cgroup 2>/dev/null)" == "cgroup2fs" ]] \
    || die "cgroup v2 required (this box is on cgroup v1)"
  ok "cgroup v2 active"

  SYSTEMD_VER=$(systemctl --version 2>/dev/null | awk 'NR==1{print $2}' | tr -dc '0-9' || echo 0)
  SYSTEMD_VER=${SYSTEMD_VER:-0}
  ok "systemd ${SYSTEMD_VER}"

  CPU_COUNT=$(nproc)
  MEM_MB=$(awk '/MemTotal/{printf "%d", $2/1024}' /proc/meminfo)
  SWAP_MB=$(awk '/SwapTotal/{printf "%d", $2/1024}' /proc/meminfo)
  DISK_GB=$(df -BG --output=avail /opt 2>/dev/null | tail -1 | tr -dc '0-9' || true)
  DISK_GB=${DISK_GB:-0}
  ok "capacity: ${CPU_COUNT} vCPU, ${MEM_MB} MB RAM, ${SWAP_MB} MB swap, ${DISK_GB} GB free on /opt"
  (( DISK_GB < 20 )) && warn "under 20 GB free - image layers will fill this fast" || true
  (( SWAP_MB < 1024 )) && warn "little or no swap: MemoryHigh throttling has nowhere to reclaim to, so a runaway job gets OOM-killed instead of slowed down" || true

  # The wizard talks to the GitHub API before phase_prereqs runs, so curl and
  # jq have to exist NOW. Neither is guaranteed on a fresh Ubuntu image.
  local b missing=()
  for b in curl jq; do command -v "$b" >/dev/null || missing+=("$b"); done
  if (( ${#missing[@]} )); then
    log "installing bootstrap tools: ${missing[*]}"
    export NEEDRESTART_MODE=a NEEDRESTART_SUSPEND=1
    DEBIAN_FRONTEND=noninteractive apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${missing[@]}" >/dev/null \
      || die "could not install ${missing[*]} - fix apt first"
  fi
  ok "bootstrap tools present (curl, jq)"

  curl -fsS --max-time 10 -o /dev/null "${API}/rate_limit" 2>/dev/null \
    && ok "api.github.com reachable" \
    || die "cannot reach api.github.com - fix networking first"
}

# ===========================================================================
# ACCOUNT PROTECTION
#
# The de-privileging step locks an account and kills its processes. Run it on
# the box's admin user and you lock yourself out. Cloud images ship a NOPASSWD
# sudo user at uid 1000 with the only authorized_keys on the system, and it
# looks exactly like an "over-privileged user" to a naive scan.
# ===========================================================================
PROTECTED_USERS=()

build_protected_list() {
  local -A p=() u f owner
  # the account invoking us through sudo
  [[ -n "${SUDO_USER:-}" ]] && p["$SUDO_USER"]=1 || true
  # owners of live login sessions
  while read -r u; do [[ -n "$u" && "$u" != "root" ]] && p["$u"]=1 || true; done \
    < <(loginctl list-sessions --no-legend 2>/dev/null | awk '{print $3}' || true)
  # the conventional first human account
  u=$(getent passwd 1000 2>/dev/null | cut -d: -f1 || true)
  [[ -n "$u" ]] && p["$u"]=1 || true
  # anyone holding SSH keys - locking them removes the way back in
  while read -r f; do
    [[ -n "$f" ]] || continue
    owner=$(stat -c %U "$f" 2>/dev/null || true)
    [[ -n "$owner" && "$owner" != "root" ]] && p["$owner"]=1 || true
  done < <(find /home -maxdepth 3 -name authorized_keys -type f 2>/dev/null || true)
  # anyone granted NOPASSWD by cloud-init
  while read -r u; do
    [[ -n "$u" && "$u" != "root" ]] && p["$u"]=1 || true
  done < <(grep -rhoE '^[a-z_][a-z0-9_-]*[[:space:]]+ALL=\(ALL\)[[:space:]]+NOPASSWD' \
           /etc/sudoers.d/ 2>/dev/null | awk '{print $1}' || true)
  PROTECTED_USERS=("${!p[@]}")
}

is_protected_user() {
  local want="$1" u
  for u in ${PROTECTED_USERS[@]+"${PROTECTED_USERS[@]}"}; do
    [[ "$u" == "$want" ]] && return 0
  done
  return 1
}

# ===========================================================================
# DISCOVERY - work out what is already on this box
# ===========================================================================
discover() {
  head1 "Discovering existing setup"

  # Existing runner services and the users behind them.
  mapfile -t OLD_SERVICES < <(systemctl list-units --all --plain --no-legend 'actions.runner.*' \
    | awk '{print $1}' | grep -v '^$' || true)
  if (( ${#OLD_SERVICES[@]} )); then
    log "existing runner services: ${#OLD_SERVICES[@]}"
    printf '      %s\n' "${OLD_SERVICES[@]}"
  fi

  local -A cand=()
  local s u
  for s in "${OLD_SERVICES[@]}"; do
    u=$(systemctl show -p User --value "$s" 2>/dev/null || true)
    [[ -n "$u" && "$u" != "root" ]] && cand["$u"]=1 || true
  done
  # Anyone sitting in a root-equivalent group is a candidate too.
  for g in docker sudo lxd; do
    for u in $(getent group "$g" 2>/dev/null | cut -d: -f4 | tr ',' ' ' || true); do
      [[ -n "$u" && "$u" != "root" && "$u" != ${USER_PREFIX}* ]] && cand["$u"]=1 || true
    done
  done
  build_protected_list

  # Split candidates into "safe to dismantle" and "this is how you get back in".
  DETECTED_OLD_USERS=(); local skipped=()
  for u in "${!cand[@]}"; do
    if is_protected_user "$u"; then skipped+=("$u"); else DETECTED_OLD_USERS+=("$u"); fi
  done

  if (( ${#DETECTED_OLD_USERS[@]} )); then
    warn "over-privileged / runner users found: ${DETECTED_OLD_USERS[*]}"
  else
    ok "no over-privileged runner user detected"
  fi
  if (( ${#skipped[@]} )); then
    ok "protected from de-privileging: ${skipped[*]}  ${C_DIM}(admin account / holds SSH keys / active session)${C_R}"
  fi

  # Existing service names encode the scope they were registered to:
  #   actions.runner.<scope>.<runner-name>.service
  DETECTED_OLD_SCOPE=""
  if (( ${#OLD_SERVICES[@]} )); then
    DETECTED_OLD_SCOPE=$(sed -E 's/^actions\.runner\.([^.]+)\..*/\1/' <<<"${OLD_SERVICES[0]}" || true)
    [[ -n "$DETECTED_OLD_SCOPE" ]] && log "existing runners were registered to: ${DETECTED_OLD_SCOPE}" || true
  fi

  systemctl is-active --quiet docker.service 2>/dev/null \
    && warn "rootful docker.service is running (jobs can reach a root socket)" \
    || ok "no rootful docker daemon running"
}

# ===========================================================================
# WIZARD
# ===========================================================================
wizard() {
  head1 "Configuration"
  echo "Answers are saved to ${ENV_FILE}. Re-running skips these questions."
  echo

  # --- scope ---------------------------------------------------------------
  ask_menu GHA_SCOPE "Register runners at which level?" \
    "org:Organisation  ${C_DIM}(recommended - lets you use runner groups)${C_R}" \
    "repo:A single repository"

  if [[ "$GHA_SCOPE" == "org" ]]; then
    ask GHA_ORG "GitHub organisation login"
    # Clear any repository left over from a previous repo-scoped install.
    # Nothing reads it while the scope is org, but save_config would carry it
    # forward and the reproduce line printed at the end would then show a
    # GHA_REPO that contradicts the scope beside it.
    GHA_REPO=""
  else
    local slug=""
    [[ -n "${GHA_ORG:-}" && -n "${GHA_REPO:-}" ]] && slug="${GHA_ORG}/${GHA_REPO}" || true
    ask slug "Repository (owner/name)"
    GHA_ORG="${slug%%/*}"; GHA_REPO="${slug##*/}"
    [[ -n "$GHA_ORG" && -n "$GHA_REPO" && "$GHA_ORG" != "$GHA_REPO" ]] \
      || die "expected owner/name, got '${slug}'"
  fi

  # --- token, validated before anything destructive happens ----------------
  if [[ -z "${GHA_PAT:-}" && -s "$PAT_FILE" ]]; then
    if ask_yn "Reuse the PAT already stored in ${PAT_FILE}?" y; then
      GHA_PAT="$(< "$PAT_FILE")"
    fi
  fi
  if [[ -z "${GHA_PAT:-}" ]]; then
    echo
    echo "  Needs one of:"
    echo "    - classic PAT with scope ${C_B}admin:org${C_R} (org) or ${C_B}repo${C_R} (single repo)"
    echo "    - fine-grained PAT with ${C_B}Self-hosted runners: Read and write${C_R}"
    echo "  It is stored 0600 root:root and is never readable by a job."
    echo
    ask_secret GHA_PAT "Admin PAT"
  fi
  validate_token

  # --- does this match where the old runners pointed? ----------------------
  if [[ -n "${DETECTED_OLD_SCOPE:-}" ]]; then
    local want="${GHA_ORG}"
    [[ "$GHA_SCOPE" == "repo" ]] && want="${GHA_ORG}-${GHA_REPO}" || true
    if [[ "${DETECTED_OLD_SCOPE,,}" != "${want,,}" ]]; then
      echo
      warn "The runners already on this box were registered to '${DETECTED_OLD_SCOPE}',"
      warn "but you just entered '${want}'. If that is a deliberate migration, fine."
      warn "If it is a typo, the runners will come up attached to the wrong place."
      ask_yn "Continue with '${want}'?" n || die "aborted - re-run and enter the right scope"
    else
      ok "scope matches the runners already on this box"
    fi
  fi

  # --- runner group --------------------------------------------------------
  choose_runner_group

  # --- trust level, which drives the cache policy --------------------------
  ask_menu GHA_TRUST "What kind of code will these runners execute?" \
    "internal:Internal / trusted repos only  ${C_DIM}(keeps layer cache warm)${C_R}" \
    "untrusted:Public repos or fork PRs  ${C_DIM}(wipes all state between jobs)${C_R}"

  if [[ "$GHA_TRUST" == "untrusted" ]]; then
    WIPE_DOCKER_AFTER_JOB=true; SHARE_TOOLCACHE=false
    echo
    warn "Self-hosted runners executing fork PRs is a losing position regardless"
    warn "of hardening. Set 'Require approval for all external contributors' under"
    warn "Settings > Actions > General, or keep public repos on GitHub-hosted runners."
  else
    WIPE_DOCKER_AFTER_JOB=false; SHARE_TOOLCACHE=true
  fi

  # --- how many runners ----------------------------------------------------
  local by_cpu=$CPU_COUNT by_mem=$(( (MEM_MB - 1500) / 2000 )) suggested
  suggested=$(( by_cpu < by_mem ? by_cpu : by_mem )); (( suggested < 1 )) && suggested=1
  echo
  echo "  ${CPU_COUNT} vCPU and ${MEM_MB} MB RAM. Reserving ~1500 MB for the OS and"
  echo "  the rootless daemons leaves room for about ${C_B}${suggested}${C_R} concurrent jobs."
  # `runners = auto` in fleet.conf, or GHA_COUNT=auto directly, is how a caller
  # says "size this from the machine". Every other unattended answer is a
  # literal the caller already knows; this one depends on the box, so the box
  # has to be the one to answer it. Left unset entirely, the suggestion below
  # is taken as the unattended default anyway -- `auto` is the way to ask for
  # that explicitly, and to keep asking for it if the default ever changes.
  if [[ "${GHA_COUNT:-}" == "auto" ]]; then
    GHA_COUNT="$suggested"
    ok "Runners on this machine: ${GHA_COUNT}  ${C_DIM}(sized from this box's capacity)${C_R}"
  fi
  ask GHA_COUNT "Runners on this machine" "$suggested"
  [[ "$GHA_COUNT" =~ ^[0-9]+$ ]] && (( GHA_COUNT >= 1 )) || die "runner count must be a positive integer"
  (( GHA_COUNT > CPU_COUNT * 2 )) && warn "${GHA_COUNT} runners on ${CPU_COUNT} vCPU will thrash" || true

  # --- labels --------------------------------------------------------------
  ask GHA_LABELS "Runner labels (comma separated)" "self-hosted,linux,x64,${GHA_TRUST}"

  # --- old user ------------------------------------------------------------
  if [[ -z "${GHA_OLD_USER:-}" ]]; then
    if (( ${#DETECTED_OLD_USERS[@]} == 1 )); then
      GHA_OLD_USER="${DETECTED_OLD_USERS[0]}"
      ok "old runner user: ${GHA_OLD_USER}  ${C_DIM}(detected)${C_R}"
    elif (( ${#DETECTED_OLD_USERS[@]} > 1 )) && [[ -n "${GHA_YES:-}" ]]; then
      # Option 1 here would be an arbitrary account to lock out and kill the
      # processes of. There is no safe guess; make the operator name it.
      die "several over-privileged users found (${DETECTED_OLD_USERS[*]}) - set GHA_OLD_USER to the one that runs the jobs, or to 'none'"
    elif (( ${#DETECTED_OLD_USERS[@]} > 1 )); then
      local -a menu=(); local u
      for u in "${DETECTED_OLD_USERS[@]}"; do menu+=("${u}:${u}"); done
      menu+=("none:none of these")
      ask_menu GHA_OLD_USER "Which user currently runs the jobs?" "${menu[@]}"
    elif [[ -n "${GHA_YES:-}" ]]; then
      # Unattended, and the scan found nothing to de-privilege. Prompting here
      # would reach for a terminal an SSH-driven run does not have, to ask a
      # question with exactly one possible answer.
      GHA_OLD_USER="none"
      ok "old runner user: none  ${C_DIM}(nothing over-privileged detected)${C_R}"
    else
      ask GHA_OLD_USER "Old over-privileged runner user (or 'none')" "none"
    fi
  fi

  save_config
  confirm_plan
}

validate_token() {
  log "validating token"
  local path
  [[ "$GHA_SCOPE" == "org" ]] && path="/orgs/${GHA_ORG}/actions/runners" \
                              || path="/repos/${GHA_ORG}/${GHA_REPO}/actions/runners"
  gh_api GET "$path"
  local body="$GH_BODY"
  case "$GH_CODE" in
    200) ok "token can administer runners on ${GHA_ORG}${GHA_REPO:+/$GHA_REPO}" ;;
    401) die "token rejected (401). It is invalid, expired, or revoked." ;;
    403) err "token authenticated but lacks runner-admin permission (403)."
         err "  classic PAT: add scope 'admin:org' (or 'repo' for a single repo)"
         err "  fine-grained: add 'Self-hosted runners: Read and write' and authorise SSO"
         die "fix the token and re-run" ;;
    404) die "${GHA_ORG}${GHA_REPO:+/$GHA_REPO} not found, or the token cannot see it (404)" ;;
    000) die "network failure talking to the GitHub API" ;;
    *)   die "unexpected API response ${GH_CODE}: $(jq -r '.message // .' <<<"$body" 2>/dev/null || echo "$body")" ;;
  esac
  local n; n=$(jq -r '.total_count // 0' <<<"$body" 2>/dev/null || echo 0)
  (( n > 0 )) && log "GitHub currently lists ${n} runner(s) at this scope" || true

  # Every runner registration goes through this PAT. When it expires every
  # unit restart-loops into `failed` and CI stops with no obvious cause.
  if [[ -n "${GH_PAT_EXPIRY:-}" ]]; then
    local exp_s now_s days
    exp_s=$(date -d "$GH_PAT_EXPIRY" +%s 2>/dev/null || echo 0)
    now_s=$(date +%s)
    if (( exp_s > 0 )); then
      days=$(( (exp_s - now_s) / 86400 ))
      if (( days < 0 )); then
        die "this PAT expired ${days#-} day(s) ago"
      elif (( days <= 30 )); then
        warn "this PAT expires in ${days} day(s) (${GH_PAT_EXPIRY})."
        warn "When it lapses every runner on every box in the fleet stops registering."
        warn "Rotate it with: sudo tee /etc/github-runner/pat <<< '<new-pat>' >/dev/null"
      else
        ok "PAT valid for another ${days} day(s)"
      fi
    fi
  else
    ok "PAT has no expiry set  ${C_DIM}(never expires - convenient, but rotate it deliberately)${C_R}"
  fi
}

choose_runner_group() {
  if [[ -n "${GHA_GROUP_ID:-}" ]]; then
    ok "runner group id: ${GHA_GROUP_ID}  ${C_DIM}(from environment)${C_R}"; return
  fi
  if [[ "$GHA_SCOPE" != "org" ]]; then
    GHA_GROUP_ID=1; ok "repo-scoped runners always land in group 1 (Default)"; return
  fi

  log "fetching runner groups"
  gh_api GET "/orgs/${GHA_ORG}/actions/runner-groups"
  local body="$GH_BODY"
  if [[ "$GH_CODE" != "200" ]]; then
    warn "cannot list runner groups (HTTP ${GH_CODE}) - typically a Free-plan org."
    warn "Falling back to group 1 (Default). Separate your trusted and untrusted"
    warn "fleets with distinct labels instead, and keep public repos off self-hosted."
    GHA_GROUP_ID=1; return
  fi

  # Unattended and nothing pinned: group 1 (Default) is where a runner lands if
  # nobody says otherwise, and it is already the fallback for a Free-plan org
  # above. Picking it from the menu instead would depend on API ordering.
  if [[ -n "${GHA_YES:-}" ]]; then
    GHA_GROUP_ID=1
    warn "no runner group pinned; using group 1 (Default). Set 'group_id' to choose."
    return
  fi

  local -a menu=()
  while IFS=$'\t' read -r id name vis; do
    [[ -n "$id" ]] && menu+=("${id}:${name}  ${C_DIM}(id ${id}, visibility: ${vis})${C_R}") || true
  done < <(jq -r '.runner_groups[] | [.id, .name, (.visibility // "?")] | @tsv' <<<"$body")

  if (( ${#menu[@]} == 0 )); then
    warn "the API returned no runner groups - defaulting to group 1"
    GHA_GROUP_ID=1; return
  fi
  echo
  echo "  Put trusted and untrusted fleets in ${C_B}different${C_R} groups, then restrict each"
  echo "  group to the repositories that are allowed to use it."
  ask_menu GHA_GROUP_ID "Runner group for this machine" "${menu[@]}"
}

save_config() {
  # umask 077 protects the window between creating these files and chmod'ing
  # them. It MUST be restored: leaking it makes every later file 0600 root:root,
  # including the runner tarball that a non-root user has to read.
  local old_umask; old_umask=$(umask)
  install -d -m 0700 "$CONF_DIR" "$STATE_DIR"
  umask 077
  cat > "$ENV_FILE" <<EOF
# written by harden-gha-runners.sh on $(date -Is)
GHA_SCOPE="${GHA_SCOPE}"
GHA_ORG="${GHA_ORG}"
GHA_REPO="${GHA_REPO:-}"
GHA_GROUP_ID="${GHA_GROUP_ID}"
GHA_LABELS="${GHA_LABELS}"
GHA_COUNT="${GHA_COUNT}"
GHA_TRUST="${GHA_TRUST}"
GHA_OLD_USER="${GHA_OLD_USER:-none}"
WIPE_DOCKER_AFTER_JOB="${WIPE_DOCKER_AFTER_JOB}"
SHARE_TOOLCACHE="${SHARE_TOOLCACHE}"
RUNNER_NAME_PREFIX="$(hostname -s)"
USER_PREFIX="${USER_PREFIX}"
RUNNER_BASE="${RUNNER_BASE}"
EOF
  chown root:root "$ENV_FILE"; chmod 0600 "$ENV_FILE"
  printf '%s' "$GHA_PAT" > "$PAT_FILE"
  chown root:root "$PAT_FILE"; chmod 0600 "$PAT_FILE"
  umask "$old_umask"
  ok "configuration saved to ${ENV_FILE}"
}

# The answers save_config writes. Sourcing the env file would assign all of
# them unconditionally, so these are the ones a caller has to be protected from.
CONFIG_ANSWERS=(GHA_SCOPE GHA_ORG GHA_REPO GHA_GROUP_ID GHA_LABELS GHA_COUNT
                GHA_TRUST GHA_OLD_USER)

load_config() {
  [[ -s "$ENV_FILE" ]] || return 1

  # The stored file is a DEFAULT, not an override. Whatever the caller put in
  # the environment is what this box is being asked to become, and a plain
  # `. "$ENV_FILE"` would silently overwrite exactly that -- which made
  # `GHA_LABELS=... ./harden-gha-runners.sh` (and every fleet.sh install)
  # report success while changing nothing, because the install dispatch runs
  # this function inside an && chain for its side effect.
  local -A supplied=()
  local v
  for v in "${CONFIG_ANSWERS[@]}"; do
    [[ -n "${!v+set}" && -n "${!v}" ]] && supplied["$v"]="${!v}" || true
  done

  # shellcheck disable=SC1090
  . "$ENV_FILE"

  for v in "${!supplied[@]}"; do printf -v "$v" '%s' "${supplied[$v]}"; done

  # Same rule for the credential: an explicitly supplied PAT wins, so a token
  # can be replaced by an install. Only fall back to the stored one when the
  # caller sent none -- which is what makes an unattended re-deploy possible
  # without handing the admin token to whatever is driving it.
  [[ -z "${GHA_PAT:-}" && -s "$PAT_FILE" ]] && GHA_PAT="$(< "$PAT_FILE")" || true
  return 0
}

confirm_plan() {
  local budget=$(( (MEM_MB - 1500) / GHA_COUNT ))
  head1 "Plan"
  cat <<EOF
  target        ${GHA_ORG}${GHA_REPO:+/$GHA_REPO}  (group ${GHA_GROUP_ID})
  labels        ${GHA_LABELS}
  runners       ${GHA_COUNT}, as users ${USER_PREFIX}1 .. ${USER_PREFIX}${GHA_COUNT}
  per runner    ~${budget} MB memory ceiling, 130% CPU quota
  trust level   ${GHA_TRUST}
                wipe docker state after every job: ${WIPE_DOCKER_AFTER_JOB}
                share hosted-tool cache across jobs: ${SHARE_TOOLCACHE}

  ${C_B}Destructive actions:${C_R}
   - stop and remove every existing actions.runner.* service
   - strip ${GHA_OLD_USER:-none} from sudo / docker / lxd / adm, lock the account
   - disable the rootful docker daemon and prune all its images and volumes
   - delete every _work directory found under /opt and /home

  ${C_DIM}The old user's home directory is left alone. You delete it yourself.${C_R}
EOF
  echo
  ask_yn "Proceed?" n || die "aborted, nothing changed"
}

# ===========================================================================
# AUDIT
# ===========================================================================
phase_audit() {
  head1 "Audit - persistence surfaces a root-capable job could have used"
  # Purely informational. Every probe here is allowed to come back empty or
  # non-zero (no sudoers.d, no cron, no out-of-tree modules), and under
  # `set -e -o pipefail` any of those would otherwise abort the installer.
  set +e +o pipefail
  local f shown

  echo "${C_B}privileged group membership${C_R}"
  local g m
  for g in sudo admin wheel adm docker lxd disk shadow; do
    m=$(getent group "$g" 2>/dev/null | cut -d: -f4 || true)
    [[ -n "${m:-}" ]] && printf '    %-8s %s\n' "$g:" "$m" || true
  done

  echo "${C_B}sudoers drop-ins${C_R}"
  shown=0
  while read -r f; do
    [[ -n "$f" ]] || continue
    [[ "$(basename "$f")" == "README" ]] && continue    # stock, ships with sudo
    printf '    %s\n' "$f"; sed 's/^/        /' "$f"; shown=1
  done < <(grep -rIl . /etc/sudoers.d/ 2>/dev/null || true)
  (( shown )) || echo "    (none beyond the stock README)"

  echo "${C_B}root-owned cron (excluding distro-packaged files)${C_R}"
  shown=0
  while read -r f; do
    [[ -n "$f" ]] || continue
    [[ "$(basename "$f")" == .* ]] && continue          # .placeholder etc
    dpkg -S "$f" &>/dev/null && continue                # shipped by a package
    printf '    %s\n' "$f"; shown=1
  done < <(find /etc/cron.d /etc/cron.daily /etc/cron.hourly /etc/cron.weekly \
                -type f 2>/dev/null || true)
  (( shown )) || echo "    (nothing outside the distro baseline)"
  local u c
  for u in root ${GHA_OLD_USER:-}; do
    [[ -z "$u" || "$u" == "none" ]] && continue
    id "$u" &>/dev/null || continue
    c=$(crontab -u "$u" -l 2>/dev/null || true)
    [[ -n "$c" ]] && { echo "    crontab(${u}):"; sed 's/^/        /' <<<"$c"; } || true
  done

  echo "${C_B}non-distro systemd units${C_R}"
  # -type f skips every .wants/ symlink (all of cloud-init's noise), and the
  # dpkg check drops anything a package owns. What remains was hand-placed.
  shown=0
  while read -r f; do
    [[ -n "$f" ]] || continue
    dpkg -S "$f" &>/dev/null && continue
    printf '    %s  (mtime %s)\n' "$f" "$(stat -c %y "$f" 2>/dev/null | cut -d. -f1)"; shown=1
  done < <(find /etc/systemd/system -maxdepth 1 -name '*.service' -type f 2>/dev/null || true)
  (( shown )) || echo "    (none)"

  echo "${C_B}user-level systemd units (survive reboot via lingering)${C_R}"
  find /home /root -path '*/.config/systemd/user/*' -type f 2>/dev/null | sed 's/^/    /'

  echo "${C_B}authorized_keys${C_R}"
  find /home /root -name authorized_keys 2>/dev/null | while read -r f; do
    printf '    %s\n' "$f"; sed 's/^/        /' "$f"
  done

  echo "${C_B}setuid binaries outside the distro baseline${C_R}"
  # Prune container image stores: every layer carries its own su/mount/passwd,
  # which flooded the last run with 11 false positives. Pruning is faster too.
  shown=0
  while read -r f; do
    [[ -n "$f" ]] || continue
    dpkg -S "$f" &>/dev/null && continue
    printf '    %s\n' "$f"; shown=1
  done < <(find / -xdev \
             \( -path /var/lib/docker -o -path /var/lib/containerd \
                -o -path /var/lib/rancher -o -path /snap \
                -o -path '*/overlay2' -o -path '*/snapshots' \
                -o -path '/home/*/.local/share/docker' \) -prune -o \
             -perm -4000 -type f -print 2>/dev/null \
           | grep -vE '^/(usr/bin|usr/sbin|bin|sbin|usr/lib|usr/libexec)/' || true)
  (( shown )) || echo "    (none)"

  echo "${C_B}out-of-tree kernel modules${C_R}"
  if command -v lsmod >/dev/null && command -v modinfo >/dev/null; then
    lsmod | awk 'NR>1{print $1}' | while read -r m; do
      modinfo "$m" 2>/dev/null | grep -q '^filename:.*/kernel/' || echo "    $m"
    done
  else
    echo "    (lsmod/modinfo unavailable - skipped)"
  fi

  echo
  warn "None of this is conclusive. A job with root could have hidden from all of it."
  warn "Reimaging is the only clean remediation; this installer is what you run after."
  set -eo pipefail
  return 0
}

# ===========================================================================
# TEARDOWN OF THE OLD SETUP
# ===========================================================================
phase_stop_existing() {
  head1 "Removing the old runner setup"
  local u
  while read -r u; do
      [[ -n "$u" ]] || continue
      log "disabling ${u}"
      systemctl stop "$u" 2>/dev/null || true
      systemctl disable "$u" 2>/dev/null || true
      rm -f "/etc/systemd/system/${u}"
  done < <(systemctl list-units --all --plain --no-legend 'actions.runner.*' \
           | awk '{print $1}' || true)
  systemctl daemon-reload
  ok "old runner services removed"
}

phase_deprivilege() {
  local u="${GHA_OLD_USER:-none}"
  head1 "De-privileging ${u}"
  [[ "$u" == "none" ]] && { ok "nothing to do"; return; }
  id "$u" &>/dev/null || { warn "${u} does not exist"; return; }

  # Last line of defence. Locking the admin account removes your way back in.
  build_protected_list
  if is_protected_user "$u"; then
    err "REFUSING to de-privilege '${u}'."
    err "  It is the admin account for this box (uid 1000, sudo NOPASSWD,"
    err "  owner of an authorized_keys file, or an active login session)."
    err "  Locking it would cut off your access."
    if [[ "${SUDO_USER:-}" == "$u" ]] || [[ "$(logname 2>/dev/null || true)" == "$u" ]]; then
      die "'${u}' is the account running this installer. Refusing outright."
    fi
    if [[ -z "${GHA_FORCE_DEPRIVILEGE:-}" ]]; then
      warn "Skipping. If '${u}' really is the runner account, re-run with"
      warn "GHA_FORCE_DEPRIVILEGE=1 and make sure root SSH still works first."
      return 0
    fi
    warn "GHA_FORCE_DEPRIVILEGE is set - proceeding against advice"
  fi

  local g
  for g in sudo admin wheel adm docker lxd disk shadow; do
    if id -nG "$u" 2>/dev/null | tr ' ' '\n' | grep -qx "$g"; then
      log "removing ${u} from group ${g}"
      gpasswd -d "$u" "$g" >/dev/null
    fi
  done

  local stamp; stamp=$(date +%Y%m%d%H%M%S)
  while read -r f; do
    [[ -n "$f" ]] || continue
    log "disabling sudoers drop-in ${f}"
    mv "$f" "${STATE_DIR}/$(basename "$f").disabled-${stamp}"
    chmod 0400 "${STATE_DIR}/$(basename "$f").disabled-${stamp}"
  done < <(grep -rIl "$u" /etc/sudoers.d/ 2>/dev/null || true)

  grep -qE "^[[:space:]]*${u}[[:space:]]" /etc/sudoers 2>/dev/null \
    && warn "${u} has an inline rule in /etc/sudoers - remove it with visudo" || true

  log "locking the account"
  usermod -L -s /usr/sbin/nologin "$u"
  crontab -u "$u" -r 2>/dev/null || true
  loginctl disable-linger "$u" 2>/dev/null || true
  pkill -KILL -u "$u" 2>/dev/null || true
  ok "${u} holds no privileged groups and cannot log in"
}

phase_wipe() {
  head1 "Destroying poisoned build state"

  if command -v docker &>/dev/null && docker info &>/dev/null 2>&1; then
    log "pruning the rootful docker daemon"
    docker system prune -af --volumes >/dev/null 2>&1 || true
    docker builder prune -af >/dev/null 2>&1 || true
  fi

  # Disable the whole rootful stack, not just docker.service. containerd is a
  # root daemon holding root-owned image layers; with rootless Docker running
  # per user, nothing on this box needs it any more.
  local before after freed
  before=$(df -BM --output=avail / 2>/dev/null | tail -1 | tr -dc '0-9' || echo 0)
  log "disabling the rootful container stack"
  systemctl disable --now docker.service docker.socket containerd.service 2>/dev/null || true

  local dir
  for dir in /var/lib/docker /var/lib/containerd; do
    if [[ -d "$dir" ]]; then
      log "removing ${dir} (root-owned image layers from the old setup)"
      rm -rf "${dir:?}"
    fi
  done
  after=$(df -BM --output=avail / 2>/dev/null | tail -1 | tr -dc '0-9' || echo 0)
  freed=$(( after - before ))
  (( freed > 0 )) && ok "reclaimed ${freed} MB from the old root-owned image store" || true
  ok "no root-owned docker socket or containerd daemon remains"

  local u="${GHA_OLD_USER:-none}" h
  if [[ "$u" != "none" ]] && id "$u" &>/dev/null; then
    h=$(getent passwd "$u" | cut -d: -f6 || true)
    log "clearing caches under ${h}"
    rm -rf "${h:?}"/.cache "${h:?}"/.npm "${h:?}"/.docker "${h:?}"/.gradle "${h:?}"/.m2 \
           "${h:?}"/.cargo/registry "${h:?}"/.nuget "${h:?}"/.gem "${h:?}"/.yarn \
           "${h:?}"/.pnpm-store "${h:?}"/.local/share/virtualenvs "${h:?}"/.config/gh \
           "${h:?}"/.config/systemd/user 2>/dev/null || true
  fi

  local d
  while read -r d; do
    [[ -n "$d" ]] || continue
    log "rm -rf ${d}"; rm -rf "${d:?}"
  done < <(find /opt /home -maxdepth 4 -type d -name '_work' 2>/dev/null)
  rm -rf /opt/hostedtoolcache 2>/dev/null || true
  ok "build state destroyed"
}

# ===========================================================================
# SWAP
#
# MemoryHigh throttles by reclaiming pages. With zero swap there is nothing to
# reclaim to, so the ceiling degrades into a hard OOM kill and a job dies with
# a useless error instead of just running slowly.
# ===========================================================================
maybe_add_swap() {
  (( SWAP_MB >= 1024 )) && { ok "swap: ${SWAP_MB} MB"; return 0; }
  head1 "Swap"
  if [[ -e /swapfile ]]; then
    warn "/swapfile already exists but is not active - leaving it alone"; return 0
  fi
  local want=4096
  (( DISK_GB < 40 )) && want=2048 || true
  if (( DISK_GB < 12 )); then
    warn "only ${DISK_GB} GB free - skipping swap creation"; return 0
  fi
  echo "  This box has no swap, so the per-runner MemoryHigh ceiling cannot"
  echo "  throttle a heavy job; it just gets OOM-killed instead."
  ask_yn "Create a ${want} MB swapfile at /swapfile?" y || { warn "skipped"; return 0; }

  log "allocating ${want} MB"
  fallocate -l "${want}M" /swapfile 2>/dev/null \
    || dd if=/dev/zero of=/swapfile bs=1M count="$want" status=none \
    || { warn "could not allocate the swapfile"; rm -f /swapfile; return 0; }
  chmod 0600 /swapfile
  mkswap /swapfile >/dev/null 2>&1 || { warn "mkswap failed"; rm -f /swapfile; return 0; }
  swapon /swapfile 2>/dev/null || { warn "swapon failed"; rm -f /swapfile; return 0; }
  grep -q '^/swapfile ' /etc/fstab 2>/dev/null || echo '/swapfile none swap sw 0 0' >> /etc/fstab
  # Only reach for it under real pressure; this is a build box, not a desktop.
  echo 'vm.swappiness=10' > /etc/sysctl.d/99-gha-swappiness.conf
  sysctl -q -w vm.swappiness=10 2>/dev/null || true
  SWAP_MB=$want
  ok "swap active: ${want} MB, persisted in /etc/fstab, swappiness 10"
}

# ===========================================================================
# HOST PREREQUISITES
# ===========================================================================
phase_prereqs() {
  head1 "Installing prerequisites"
  export DEBIAN_FRONTEND=noninteractive
  # needrestart's interactive service-restart prompt will hang GHA_YES=1 runs
  export NEEDRESTART_MODE=a NEEDRESTART_SUSPEND=1
  apt-get update -qq
  # unzip is not optional: actions/cache, actions/download-artifact and every
  # action that ships a .zip release shell out to it, and a fresh Ubuntu server
  # image does not have it. Without it those steps fail mid-job with a bare
  # "unzip: command not found" that reads like a broken action.
  apt-get install -y -qq curl jq unzip ca-certificates gnupg uidmap dbus-user-session \
    fuse-overlayfs slirp4netns iptables acl libicu-dev util-linux >/dev/null
  ok "base packages (including unzip, required by actions/cache and friends)"

  if ! command -v dockerd-rootless-setuptool.sh &>/dev/null; then
    log "installing docker-ce and the rootless extras"
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
      | gpg --dearmor -o /etc/apt/keyrings/docker.gpg --yes
    chmod a+r /etc/apt/keyrings/docker.gpg
    . /etc/os-release
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu ${VERSION_CODENAME} stable" \
      > /etc/apt/sources.list.d/docker.list
    chmod 0644 /etc/apt/sources.list.d/docker.list
    apt-get update -qq
    apt-get install -y -qq docker-ce docker-ce-cli containerd.io \
      docker-buildx-plugin docker-compose-plugin docker-ce-rootless-extras >/dev/null
  fi
  # We only ever want the rootless daemon.
  systemctl disable --now docker.service docker.socket 2>/dev/null || true
  ok "docker packages present, rootful daemon disabled"

  # Ubuntu 24.04 blocks unprivileged user namespaces via AppArmor, which breaks
  # rootlesskit. Relaxing it is a genuine (small) reduction in 24.04's default
  # posture; the alternative is a per-binary AppArmor profile.
  : > /etc/sysctl.d/99-gha-rootless.conf
  if [[ -e /proc/sys/kernel/apparmor_restrict_unprivileged_userns ]]; then
    echo 'kernel.apparmor_restrict_unprivileged_userns=0' >> /etc/sysctl.d/99-gha-rootless.conf
    warn "relaxing kernel.apparmor_restrict_unprivileged_userns (required by rootlesskit)"
  fi
  echo 'net.ipv4.ip_unprivileged_port_start=80' >> /etc/sysctl.d/99-gha-rootless.conf
  chmod 0644 /etc/sysctl.d/99-gha-rootless.conf
  sysctl -q -p /etc/sysctl.d/99-gha-rootless.conf
  ok "kernel settings applied"
}

# ===========================================================================
# PER-RUNNER USERS + ROOTLESS DOCKER
# ===========================================================================
create_runner_user() {
  local n="$1" u="${USER_PREFIX}${1}" uid sub
  if ! id "$u" &>/dev/null; then
    log "creating user ${u}"
    useradd --create-home --shell /bin/bash --user-group "$u"
  fi
  uid=$(id -u "$u")

  sub=$(( 200000 + n * 65536 ))
  grep -q "^${u}:" /etc/subuid || echo "${u}:${sub}:65536" >> /etc/subuid
  grep -q "^${u}:" /etc/subgid || echo "${u}:${sub}:65536" >> /etc/subgid

  loginctl enable-linger "$u"
  local i
  for i in {1..30}; do [[ -d "/run/user/${uid}" ]] && break; sleep 0.5; done
  [[ -d "/run/user/${uid}" ]] || die "lingering never produced /run/user/${uid} for ${u}"
  ok "${u} (uid ${uid}, subuid ${sub})"
}

as_user() { # as_user USER cmd...
  local u="$1"; shift; local uid; uid=$(id -u "$u")
  sudo -u "$u" \
    XDG_RUNTIME_DIR="/run/user/${uid}" \
    DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/${uid}/bus" \
    DOCKER_HOST="unix:///run/user/${uid}/docker.sock" \
    PATH="/usr/bin:/usr/sbin:/bin:/sbin:/home/${u}/bin" \
    HOME="/home/${u}" \
    "$@"
}

install_rootless_docker() {
  local u="$1" uid; uid=$(id -u "$u")
  if [[ -S "/run/user/${uid}/docker.sock" ]]; then ok "${u}: rootless docker already up"; return; fi

  log "installing rootless docker for ${u}"
  as_user "$u" dockerd-rootless-setuptool.sh install --force >/dev/null 2>&1 \
    || die "rootless docker setup failed for ${u} (try: journalctl --user -u docker -M ${u}@)"
  as_user "$u" systemctl --user enable --now docker.service >/dev/null 2>&1 || true

  local i
  for i in {1..40}; do [[ -S "/run/user/${uid}/docker.sock" ]] && break; sleep 1; done
  [[ -S "/run/user/${uid}/docker.sock" ]] || die "rootless docker socket never appeared for ${u}"

  as_user "$u" docker buildx create --name gha --driver docker-container --use >/dev/null 2>&1 || true
  ok "${u}: rootless docker + buildx ready"
}

# ===========================================================================
# ROOT-ONLY JIT HELPER
# ===========================================================================
phase_token_helper() {
  head1 "Installing the root-only JIT helper"
  cat > /usr/local/sbin/gha-jitconfig <<'HELPER'
#!/usr/bin/env bash
# Runs as root via systemd ExecStartPre=+. Mints a single-use JIT runner config
# and drops it where exactly one runner user can read it. The PAT never leaves
# this process.
set -euo pipefail
N="$1"
. /etc/github-runner/env
PAT="$(< /etc/github-runner/pat)"
U="${USER_PREFIX}${N}"

# See the note on gh_api in the installer: a PAT passed as `-H "Authorization:
# ..."` is readable by every local user through /proc/<pid>/cmdline. This runs
# on every runner start, with the unprivileged runner users already on the box.
AUTH=$(mktemp)
trap 'rm -f "$AUTH"' EXIT
printf 'Authorization: Bearer %s\n' "$PAT" > "$AUTH"

if [[ "$GHA_SCOPE" == "org" ]]; then
  URL="https://api.github.com/orgs/${GHA_ORG}/actions/runners/generate-jitconfig"
else
  URL="https://api.github.com/repos/${GHA_ORG}/${GHA_REPO}/actions/runners/generate-jitconfig"
fi

BODY=$(jq -nc \
  --arg n "${RUNNER_NAME_PREFIX}-${N}-$(date +%s)" \
  --argjson g "$GHA_GROUP_ID" \
  --argjson l "$(jq -Rc 'split(",")' <<<"$GHA_LABELS")" \
  '{name:$n, runner_group_id:$g, labels:$l, work_folder:"_work"}')

RESP=$(curl -fsS -X POST "$URL" \
  -H @"$AUTH" \
  -H "Accept: application/vnd.github+json" \
  -H "X-GitHub-Api-Version: 2022-11-28" \
  -d "$BODY") || { echo "gha-jitconfig: API request failed" >&2; exit 1; }

JIT=$(jq -er '.encoded_jit_config' <<<"$RESP") || {
  echo "gha-jitconfig: $(jq -r '.message // "no jit config returned"' <<<"$RESP")" >&2; exit 1; }

install -d -m 0711 -o root -g root /run/gha-runner
F="/run/gha-runner/${N}.jit"
(umask 077; printf '%s' "$JIT" > "$F")
chown "root:${U}" "$F"
chmod 0040 "$F"   # group-read only: this runner's user, and no other

# Record the registration id so ExecStopPost can delete it. Without this, a
# runner that never comes online leaves an offline registration behind on
# every single start attempt.
jq -er '.runner.id' <<<"$RESP" > "/run/gha-runner/${N}.id" 2>/dev/null || true
chmod 0600 "/run/gha-runner/${N}.id" 2>/dev/null || true
HELPER
  chmod 0700 /usr/local/sbin/gha-jitconfig

  cat > /usr/local/sbin/gha-jitreap <<'REAP'
#!/usr/bin/env bash
# Runs as root via ExecStopPost=+. Deletes the registration this unit minted.
# If the runner finished a job normally GitHub already retired it and this
# 404s harmlessly; if it crashed on start, this is what stops the leak.
set -uo pipefail
N="$1"
. /etc/github-runner/env 2>/dev/null || exit 0
IDF="/run/gha-runner/${N}.id"
if [[ -s "$IDF" ]]; then
  RID="$(< "$IDF")"
  PAT="$(< /etc/github-runner/pat)"
  # Keeps the PAT out of argv; see the note on gh_api in the installer.
  AUTH=$(mktemp)
  trap 'rm -f "$AUTH"' EXIT
  printf 'Authorization: Bearer %s\n' "$PAT" > "$AUTH"
  if [[ "$GHA_SCOPE" == "org" ]]; then
    RPATH="/orgs/${GHA_ORG}/actions/runners"
  else
    RPATH="/repos/${GHA_ORG}/${GHA_REPO}/actions/runners"
  fi
  [[ "$RID" =~ ^[0-9]+$ ]] && curl -fsS -X DELETE \
    -H @"$AUTH" \
    -H "Accept: application/vnd.github+json" \
    "https://api.github.com${RPATH}/${RID}" >/dev/null 2>&1 || true
fi
rm -f "/run/gha-runner/${N}.jit" "$IDF"
exit 0
REAP
  chmod 0700 /usr/local/sbin/gha-jitreap
  ok "/usr/local/sbin/gha-jitconfig + gha-jitreap"
}

# ===========================================================================
# RUNNER BINARIES + ONE-JOB WRAPPER
# ===========================================================================
phase_runners() {
  head1 "Installing runner instances"
  local ver tarball
  ver=$(curl -fsSL "${API}/repos/actions/runner/releases/latest" | jq -r .tag_name | sed 's/^v//' || true)
  [[ -n "$ver" && "$ver" != "null" ]] || die "could not determine the latest runner version"
  log "actions/runner ${ver}"

  tarball="/var/cache/actions-runner-${ver}.tar.gz"
  if [[ ! -s "$tarball" ]]; then
    curl -fsSL --retry 3 -o "$tarball" \
      "https://github.com/actions/runner/releases/download/v${ver}/actions-runner-linux-x64-${ver}.tar.gz" \
      || die "runner download failed"
  fi
  # Unconditional, not just after a download: a cached copy from an earlier run
  # may already be 0600 and would fail the same way.
  chmod 0644 "$tarball"
  tar -tzf "$tarball" >/dev/null 2>&1 || { rm -f "$tarball"; die "runner tarball is corrupt"; }

  # systemd chdirs into WorkingDirectory as the runner user. Every component
  # of the path must be traversable by that user or the unit dies at step
  # CHDIR with exit=200 and restart-loops. Normalise the base explicitly
  # instead of relying on whatever `install -d` inherited.
  install -d "$RUNNER_BASE"
  chown root:root "$RUNNER_BASE"
  chmod 0755 "$RUNNER_BASE"

  local n
  for n in $(seq 1 "$GHA_COUNT"); do
    local u="${USER_PREFIX}${n}" d="${RUNNER_BASE}/${n}" uid
    uid=$(id -u "$u")
    log "runner ${n} -> ${d} (${u})"

    rm -rf "${d:?}"; install -d -m 0750 -o "$u" -g "$u" "$d"
    # Extract as root then hand the tree over, rather than `sudo -u "$u" tar`:
    # that made extraction depend on the tarball being readable by the runner
    # user, which is an avoidable coupling.
    tar -xzf "$tarball" -C "$d" || die "could not extract the runner into ${d}"
    chown -R "$u:$u" "$d"
    # tar restores the archive's mode onto the target dir; pin it rather than
    # inherit it.
    chmod 0755 "$d"
    "$d/bin/installdependencies.sh" >/dev/null 2>&1 || warn "  installdependencies.sh complained"

    # --- the wrapper: exactly one job, then exit --------------------------
    cat > "${d}/run-ephemeral.sh" <<EOF
#!/usr/bin/env bash
# One job per registration. systemd restarts us; ExecStartPre mints a new
# JIT config each time, so no credential and no workspace ever survives a job.
set -euo pipefail
cd "${d}"
JIT="\$(< /run/gha-runner/${n}.jit)"

rm -rf ./_work
install -d -m 0700 ./_work
EOF
    [[ "$SHARE_TOOLCACHE" == "true" ]] && cat >> "${d}/run-ephemeral.sh" <<EOF
export AGENT_TOOLSDIRECTORY="/opt/hostedtoolcache-${u}"
EOF

    cat >> "${d}/run-ephemeral.sh" <<'EOF'

cleanup() {
  docker ps -aq       2>/dev/null | xargs -r docker rm -f          >/dev/null 2>&1 || true
  docker volume ls -q 2>/dev/null | xargs -r docker volume rm -f   >/dev/null 2>&1 || true
EOF
    if [[ "$WIPE_DOCKER_AFTER_JOB" == "true" ]]; then
      cat >> "${d}/run-ephemeral.sh" <<'EOF'
  docker system prune -af --volumes                                >/dev/null 2>&1 || true
EOF
    else
      cat >> "${d}/run-ephemeral.sh" <<'EOF'
  docker image prune -f                                            >/dev/null 2>&1 || true
EOF
    fi
    cat >> "${d}/run-ephemeral.sh" <<EOF
  rm -rf "${d}/_work"
}
trap cleanup EXIT

# Deliberately NOT exec: exec replaces this shell, which discards the EXIT
# trap and silently skips every post-job cleanup above. Run it as a child,
# forward SIGTERM so the runner drains its job, then let the trap fire.
rc=0
./run.sh --jitconfig "\$JIT" &
RUNNER_PID=\$!
trap 'kill -TERM "\$RUNNER_PID" 2>/dev/null || true' TERM INT
wait "\$RUNNER_PID" || rc=\$?
exit "\$rc"
EOF
    chmod 0700 "${d}/run-ephemeral.sh"; chown "$u:$u" "${d}/run-ephemeral.sh"
    bash -n "${d}/run-ephemeral.sh" || die "generated wrapper for runner ${n} is malformed"

    cat > "${d}/.env" <<EOF
DOCKER_HOST=unix:///run/user/${uid}/docker.sock
XDG_RUNTIME_DIR=/run/user/${uid}
DOCKER_BUILDKIT=1
EOF
    chown "$u:$u" "${d}/.env"; chmod 0600 "${d}/.env"
    assert_can_chdir "$u" "$d"
    ok "runner ${n} installed"
  done
}

# ===========================================================================
# JANITOR - disk pressure + health, on a daily timer
#
# trust=internal deliberately keeps the layer cache warm, which means the
# per-user rootless daemons accumulate images forever. Without this the box hits
# "no space left on device" in a few months. The same timer notices runners
# that have died (expired PAT, revoked token) instead of letting them sit
# in `failed` unobserved.
# ===========================================================================
phase_janitor() {
  head1 "Installing the disk/health janitor"

  cat > /usr/local/sbin/gha-janitor <<'JAN'
#!/usr/bin/env bash
set -uo pipefail
. /etc/github-runner/env 2>/dev/null || exit 0
SOFT=${GHA_DISK_SOFT:-75}    # start trimming week-old cache
HARD=${GHA_DISK_HARD:-90}    # drop everything not in use
log() { logger -t gha-janitor -- "$*"; echo "gha-janitor: $*"; }

usage() { df --output=pcent /opt 2>/dev/null | tail -1 | tr -dc '0-9'; }

prune_user() { # prune_user <user> <aggressive?>
  local u="$1" hard="$2" uid
  uid=$(id -u "$u" 2>/dev/null) || return 0
  [[ -S "/run/user/${uid}/docker.sock" ]] || return 0
  local -a env=(sudo -u "$u" XDG_RUNTIME_DIR="/run/user/${uid}"
                DOCKER_HOST="unix:///run/user/${uid}/docker.sock")
  if [[ "$hard" == "1" ]]; then
    "${env[@]}" docker system prune -af --volumes  >/dev/null 2>&1
    "${env[@]}" docker builder prune -af           >/dev/null 2>&1
  else
    # week-old only: never rips the cache out from under a running build
    "${env[@]}" docker image   prune -af --filter until=168h >/dev/null 2>&1
    "${env[@]}" docker builder prune -af --filter unused-for=168h >/dev/null 2>&1
  fi
}

# ---- disk ----
u=$(usage); u=${u:-0}
if (( u >= SOFT )); then
  log "disk at ${u}% (soft threshold ${SOFT}%) - trimming caches older than 7 days"
  for n in $(seq 1 "${GHA_COUNT}"); do prune_user "${USER_PREFIX}${n}" 0; done
  u=$(usage); u=${u:-0}
  if (( u >= HARD )); then
    log "still at ${u}% (hard threshold ${HARD}%) - full prune"
    for n in $(seq 1 "${GHA_COUNT}"); do prune_user "${USER_PREFIX}${n}" 1; done
    log "after full prune: $(usage)%"
  else
    log "recovered to ${u}%"
  fi
fi

# ---- orphan JIT registrations ----
# A restart loop leaks one registration per attempt. Left alone they pile up
# in the org's runner list forever.
if [[ -s /etc/github-runner/pat ]]; then
  PAT="$(< /etc/github-runner/pat)"
  # Keeps the PAT out of argv; see the note on gh_api in the installer.
  AUTH=$(mktemp)
  trap 'rm -f "$AUTH"' EXIT
  printf 'Authorization: Bearer %s\n' "$PAT" > "$AUTH"
  if [[ "$GHA_SCOPE" == "org" ]]; then
    RPATH="/orgs/${GHA_ORG}/actions/runners"
  else
    RPATH="/repos/${GHA_ORG}/${GHA_REPO}/actions/runners"
  fi
  HOSTS=$(hostname -s)

  # ---- PAT health ----
  # This token is used on EVERY runner start. If it dies, the whole fleet
  # stops registering, and nothing else on the box would notice.
  HDR=$(mktemp)
  CODE=$(curl -sS -o /dev/null -D "$HDR" -w '%{http_code}' \
    -H @"$AUTH" -H "Accept: application/vnd.github+json" \
    "https://api.github.com${RPATH}?per_page=1" 2>/dev/null || echo 000)
  case "$CODE" in
    200)
      EXP=$(grep -i '^github-authentication-token-expiration:' "$HDR" 2>/dev/null \
            | cut -d: -f2- | tr -d '\r' | xargs || true)
      if [[ -n "${EXP:-}" ]]; then
        EXP_S=$(date -d "$EXP" +%s 2>/dev/null || echo 0)
        if [ "$EXP_S" -gt 0 ]; then
          DAYS=$(( (EXP_S - $(date +%s)) / 86400 ))
          [ "$DAYS" -le 14 ] && log "ADMIN PAT EXPIRES IN ${DAYS} DAY(S) (${EXP}) - rotate it or every runner here stops registering"
        fi
      fi ;;
    401) log "ADMIN PAT REJECTED (401): expired or revoked. Runners will stop registering. Fix: harden-gha-runners.sh rotate-pat" ;;
    403) log "ADMIN PAT LACKS RUNNER-ADMIN PERMISSION (403). Fix: harden-gha-runners.sh rotate-pat" ;;
    000) log "could not reach api.github.com to check the admin PAT" ;;
    *)   log "unexpected HTTP ${CODE} checking the admin PAT" ;;
  esac
  rm -f "$HDR"
  # Page through: per_page=100 alone still stops at the first 100.
  ALL='[]'; PAGE=1
  while [ "$PAGE" -le 50 ]; do
    BODY=$(curl -fsS -H @"$AUTH" \
            -H "Accept: application/vnd.github+json" \
            "https://api.github.com${RPATH}?per_page=100&page=${PAGE}" 2>/dev/null)
    [ -n "${BODY:-}" ] || break
    CHUNK=$(jq -c '.runners // []' <<<"$BODY" 2>/dev/null || echo '[]')
    N=$(jq 'length' <<<"$CHUNK" 2>/dev/null || echo 0)
    [ "$N" -eq 0 ] && break
    ALL=$(jq -c -s 'add' <<<"${ALL}"$'\n'"${CHUNK}" 2>/dev/null || echo "$ALL")
    [ "$N" -lt 100 ] && break
    PAGE=$((PAGE+1))
  done
  if [[ "$ALL" != "[]" ]]; then
    NOW=$(date +%s)
    ORPHANS=$(jq -r --arg h "$HOSTS" --argjson now "$NOW" \
      '.[] | select(.status=="offline") | select(.name|startswith($h+"-"))
           | select((.name|capture("-(?<e>[0-9]{9,})$").e|tonumber) < ($now - 300))
           | .id' <<<"$ALL" 2>/dev/null)
    COUNT=0
    for rid in ${ORPHANS:-}; do
      curl -fsS -X DELETE -H @"$AUTH" \
        -H "Accept: application/vnd.github+json" \
        "https://api.github.com${RPATH}/${rid}" >/dev/null 2>&1 && COUNT=$((COUNT+1))
    done
    (( COUNT > 0 )) && log "reaped ${COUNT} orphan JIT registration(s)"
  fi
fi

# ---- health ----
dead=()
for n in $(seq 1 "${GHA_COUNT}"); do
  systemctl is-active --quiet "gha-runner@${n}.service" || dead+=("${n}")
done
if (( ${#dead[@]} )); then
  log "RUNNERS DOWN: ${dead[*]} - check 'journalctl -u gha-runner@${dead[0]}'."
  log "Most common cause: the admin PAT in /etc/github-runner/pat expired or was revoked."
fi
exit 0
JAN
  chmod 0700 /usr/local/sbin/gha-janitor

  cat > /etc/systemd/system/gha-janitor.service <<'EOF'
[Unit]
Description=GitHub Actions runner disk and health janitor
[Service]
Type=oneshot
ExecStart=/usr/local/sbin/gha-janitor
EOF

  cat > /etc/systemd/system/gha-janitor.timer <<'EOF'
[Unit]
Description=Run the GitHub Actions runner janitor daily
[Timer]
OnCalendar=daily
RandomizedDelaySec=1h
Persistent=true
[Install]
WantedBy=timers.target
EOF

  chmod 0644 /etc/systemd/system/gha-janitor.service /etc/systemd/system/gha-janitor.timer
  systemctl daemon-reload
  systemctl enable --now gha-janitor.timer >/dev/null 2>&1 || true
  ok "gha-janitor.timer enabled (daily; trims at 75% disk, full prune at 90%)"
}

# ===========================================================================
# STALE REGISTRATIONS
#
# The previous non-ephemeral runner keeps its GitHub registration after its
# service is removed - it just sits there permanently offline, cluttering the
# runner list and the org's runner count.
# ===========================================================================
phase_cleanup_stale() {
  head1 "Cleaning up stale runner registrations"
  # Delegates to phase_reap so there is exactly ONE implementation. The old
  # inline copy fetched without pagination and therefore only ever cleaned
  # the first 30 runners GitHub returned.
  phase_reap quiet
}

# ===========================================================================
# WORKING-DIRECTORY PRECONDITION
#
# This is exactly what systemd does at step CHDIR. Checking it here turns a
# silent restart loop (which leaks a runner registration per attempt) into a
# clear error before any unit is enabled.
# ===========================================================================
assert_can_chdir() {
  local u="$1" d="$2"
  if runuser -u "$u" -- test -x "$d" 2>/dev/null \
     && runuser -u "$u" -- test -r "${d}/run.sh" 2>/dev/null; then
    return 0
  fi
  err "${u} cannot enter ${d} - systemd would fail at step CHDIR (exit 200)."
  err "Every component of the path must be traversable by ${u}:"
  if command -v namei >/dev/null; then
    namei -l "${d}/run.sh" 2>/dev/null | sed 's/^/      /' >&2
  else
    local comp="$d"
    while [[ "$comp" != "/" ]]; do
      printf '      %s  %s\n' "$(stat -c '%A %U:%G' "$comp" 2>/dev/null)" "$comp" >&2
      comp=$(dirname "$comp")
    done
  fi
  err "Look for the first component above without o+x (or not owned by ${u})."
  die "refusing to start the runners into a restart loop"
}

# ===========================================================================
# SYSTEMD
# ===========================================================================
phase_systemd() {
  head1 "Writing hardened systemd units"

  # systemd 254+ can back a failing unit off exponentially. A healthy runner
  # restarting between jobs still waits only RestartSec; a crash-looping one
  # stretches out to RestartMaxDelaySec instead of hammering every 10s.
  local backoff=""
  if (( ${SYSTEMD_VER:-0} >= 254 )); then
    backoff=$'RestartSteps=6\nRestartMaxDelaySec=300'
  fi

  cat > /etc/systemd/system/gha-runner@.service <<EOF
[Unit]
Description=Ephemeral GitHub Actions runner %i
After=network-online.target
Wants=network-online.target
# Start limit DISABLED on purpose. An ephemeral runner restarts after every
# job, and systemd's start limit counts attempts rather than failures - so a
# healthy runner completing 20 quick jobs in 10 minutes would trip a burst
# limit and be stopped for doing its job correctly. Broken units are handled
# by the restart backoff below plus gha-jitreap, not by a start cap.
StartLimitIntervalSec=0

[Service]
Type=simple
User=${USER_PREFIX}%i
Group=${USER_PREFIX}%i
WorkingDirectory=${RUNNER_BASE}/%i

# Root-only: mints the single-use JIT config. The runner user never sees the PAT.
ExecStartPre=+/usr/local/sbin/gha-jitconfig %i
ExecStart=${RUNNER_BASE}/%i/run-ephemeral.sh
ExecStopPost=+/usr/local/sbin/gha-jitreap %i

Restart=always
RestartSec=10
${backoff}
# control-group, not mixed: the wrapper is now the main PID, and run.sh is a
# child. mixed would signal only the wrapper and leave the runner to be killed.
KillMode=control-group
TimeoutStopSec=300

# --- hardening -------------------------------------------------------------
NoNewPrivileges=yes
# PrivateTmp isolates /tmp per job. Caveat: the rootless daemon has its own
# /tmp, so a job doing 'docker run -v /tmp/x:/x' binds an empty dir. If a build
# fails in a way that smells like a missing bind mount, drop this first.
PrivateTmp=yes
ProtectSystem=strict
ProtectHome=no
ProtectProc=invisible
# NOT ProcSubset=pid - it hides /proc/cpuinfo and /proc/meminfo, breaking nproc,
# JVM ergonomics, Node, and most build-parallelism autodetection.
ProtectKernelTunables=yes
ProtectControlGroups=yes
RemoveIPC=yes
CapabilityBoundingSet=
AmbientCapabilities=

# --- syscall filtering: deliberately OFF ------------------------------------
# ProtectKernelModules, ProtectKernelLogs, ProtectClock, ProtectHostname,
# RestrictSUIDSGID, RestrictRealtime and LockPersonality each install a seccomp
# filter. On current systemd a filtered syscall returns ENOSYS, which reaches
# build tooling as "Function not implemented" - GNU tar fails outright on it
# while unpacking a composite action, before the job even starts.
#
# The confinement that actually contains a hostile job is above: an
# unprivileged dedicated user, a read-only filesystem outside ReadWritePaths,
# no capabilities, and no new privileges. Syscall filtering added little of
# that and broke real builds, so it is off by default.
#
# If anything IS ever filtered, fail with EPERM rather than ENOSYS - "Permission
# denied" is diagnosable, "Function not implemented" gets misread as a kernel
# problem and sends you looking in the wrong place.
SystemCallFilter=
SystemCallErrorNumber=EPERM
# NOT set on purpose: RestrictNamespaces, PrivateUsers, SystemCallFilter.
# Rootless containers need user/mount/net namespaces and a broad syscall
# surface; blocking them breaks 'container:' jobs and every docker build.

# No CPUQuota. A ceiling here throttles a lone job to a fraction of the box.
# Fair sharing under contention comes from CPUWeight in the drop-in.
TasksMax=4096

# ReadWritePaths, DOCKER_HOST and the memory ceilings arrive from a per-instance
# drop-in, because they embed the runner user's numeric uid.

[Install]
WantedBy=multi-user.target
EOF

  # Memory budgeting.
  #
  # The runner process lives in system.slice/gha-runner@N.service. Containers
  # live in user.slice/user-<uid>.slice, because they are children of the
  # rootless daemon, not of the runner unit. Two separate cgroup trees, so the
  # ceilings do NOT stack into one another - each path is capped independently
  # at the same per-runner budget.
  #
  # A given job is almost always one or the other: a `container:` job spends its
  # memory in the slice, a bare-steps job in the service. Capping both at the
  # full budget therefore gives each job its whole allowance whichever path it
  # takes. MemoryHigh sits below MemoryMax so the kernel reclaims and throttles
  # before anything gets OOM-killed.
  chmod 0644 /etc/systemd/system/gha-runner@.service

  compute_resource_policy
  local n u tc
  for n in $(seq 1 "$GHA_COUNT"); do
    u="${USER_PREFIX}${n}"; tc="/opt/hostedtoolcache-${u}"
    install -d -m 0700 -o "$u" -g "$u" "$tc"
    install -d -m 0755 "/etc/systemd/system/gha-runner@${n}.service.d"
    # Drop-ins from earlier sandbox experiments outrank the base unit and would
    # silently persist across a reinstall.
    rm -f "/etc/systemd/system/gha-runner@${n}.service.d/20-sandbox-relax.conf" \
          "/etc/systemd/system/gha-runner@${n}.service.d/30-sandbox-off.conf"
  done

  write_resource_policy

  for n in $(seq 1 "$GHA_COUNT"); do
    ok "runner ${n}: >=${RP_FAIR} MB guaranteed, up to ${RP_CEILING} MB, CPU weight 100"
  done
  log "one busy runner may use all ${CPU_COUNT} cores and up to ${RP_CEILING} MB"
  log "all ${GHA_COUNT} together are capped at ${RP_AGGREGATE} MB by ${GHA_SLICE}"

  systemctl daemon-reload
  for n in $(seq 1 "$GHA_COUNT"); do
    systemctl enable --now "gha-runner@${n}.service"
  done
  ok "${GHA_COUNT} runner unit(s) enabled and started"
}

# ===========================================================================
# VERIFY
# ===========================================================================
phase_verify() {
  head1 "Verification"
  local fail=0 n u uid

  if [[ "${GHA_OLD_USER:-none}" != "none" ]] && id "${GHA_OLD_USER}" &>/dev/null; then
    local g bad=0
    for g in sudo docker lxd adm; do
      if id -nG "${GHA_OLD_USER}" | tr ' ' '\n' | grep -qx "$g"; then
        err "${GHA_OLD_USER} is STILL in group ${g}"; bad=1; fail=1
      fi
    done
    (( bad )) || ok "${GHA_OLD_USER} holds no privileged groups"
  fi

  systemctl is-active --quiet docker.service 2>/dev/null \
    && { err "rootful docker.service is running - jobs can still find a root socket"; fail=1; } \
    || ok "no rootful docker daemon"

  [[ "$(stat -c '%a %U' "$PAT_FILE" 2>/dev/null)" == "600 root" ]] \
    && ok "PAT is 0600 root:root" \
    || { err "PAT file permissions are wrong"; fail=1; }

  for n in $(seq 1 "${GHA_COUNT}"); do
    u="${USER_PREFIX}${n}"; uid=$(id -u "$u" 2>/dev/null || echo "")
    [[ -z "$uid" ]] && { err "${u} missing"; fail=1; continue; }
    if id -nG "$u" | tr ' ' '\n' | grep -qxE 'sudo|docker|lxd'; then
      err "${u} sits in a privileged group"; fail=1
    fi
    [[ -S "/run/user/${uid}/docker.sock" ]] \
      && ok "${u}: rootless docker socket present" \
      || { err "${u}: no rootless docker socket"; fail=1; }
    if systemctl is-active --quiet "gha-runner@${n}"; then
      ok "gha-runner@${n}: active"
    else
      # Report what systemd actually says. "inactive", "failed" and
      # "activating (auto-restart)" are three different diagnoses.
      local st sub res code
      st=$(systemctl show -p ActiveState   --value "gha-runner@${n}" 2>/dev/null || echo "?")
      sub=$(systemctl show -p SubState     --value "gha-runner@${n}" 2>/dev/null || echo "?")
      res=$(systemctl show -p Result       --value "gha-runner@${n}" 2>/dev/null || echo "?")
      code=$(systemctl show -p ExecMainStatus --value "gha-runner@${n}" 2>/dev/null || echo "?")
      err "gha-runner@${n}: ${st}/${sub}  result=${res}  exit=${code}"
      fail=1
      echo "${C_DIM}      --- last 15 journal lines ---${C_R}"
      journalctl -u "gha-runner@${n}" -n 15 --no-pager -o cat 2>/dev/null \
        | sed 's/^/      /' || echo "      (no journal)"
      echo "${C_DIM}      -----------------------------${C_R}"
    fi
  done

  # Prove the socket is genuinely rootless: uid 0 inside must not be root outside.
  u="${USER_PREFIX}1"; uid=$(id -u "$u" 2>/dev/null || echo "")
  if [[ -n "$uid" && -S "/run/user/${uid}/docker.sock" ]]; then
    log "escape test: writing to /etc from inside a container"
    local out
    out=$(as_user "$u" timeout 120 docker run --rm -v /etc:/host-etc:ro alpine:latest \
          sh -c 'touch /host-etc/pwned 2>&1 || echo DENIED' 2>&1 || true)
    if grep -qiE 'denied|read-only' <<<"$out"; then
      ok "container root cannot write to the host filesystem"
    elif grep -qi 'unable to find image\|pull access\|timeout' <<<"$out"; then
      warn "escape test inconclusive (image pull failed) - re-run 'verify' later"
    else
      err "a container reached the host filesystem - do not use this box"; fail=1
    fi
  fi

  # Does GitHub actually see the runners? Paginated, or the counts are fiction.
  if [[ -n "${GHA_PAT:-}" ]]; then
    if gh_list_runners; then
      local host cnt online offline up n2
      host=$(hostname -s)
      cnt=$(jq --arg h "$host" '[.[]|select(.name|contains($h))]|length' <<<"$GH_RUNNERS" 2>/dev/null || echo 0)
      online=$(jq --arg h "$host" '[.[]|select(.name|contains($h))|select(.status=="online")]|length' <<<"$GH_RUNNERS" 2>/dev/null || echo 0)
      offline=$(( cnt - online ))

      # How many units are actually up? Extra registrations mean completely
      # different things depending on this. The previous version ignored it and
      # announced "run.sh is dying" while every unit was active.
      up=0
      for n2 in $(seq 1 "${GHA_COUNT}"); do
        systemctl is-active --quiet "gha-runner@${n2}" && up=$(( up + 1 )) || true
      done

      if (( cnt == 0 )); then
        warn "GitHub sees no runner from ${host} yet - give it ~30s, then re-run verify"
      elif (( up < GHA_COUNT && offline > GHA_COUNT )); then
        err "${up}/${GHA_COUNT} units up, and ${offline} offline registrations for ${host}."
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
    else
      warn "could not list runners (HTTP ${GH_CODE})"
    fi
  fi

  echo
  (( fail == 0 )) && ok "${C_B}all checks passed${C_R}" || err "${C_B}checks failed - see above${C_R}"
  return $fail
}

# ===========================================================================
# REAP - delete offline JIT registrations this host has leaked
# ===========================================================================
phase_reap() {
  local quiet="${1:-}"
  [[ "$quiet" == "quiet" ]] || head1 "Reaping orphan runner registrations"
  local host now; host=$(hostname -s); now=$(date +%s)

  gh_list_runners || { warn "could not list runners (HTTP ${GH_CODE})"; return 0; }

  local -a doomed=(); local id name
  while IFS=$'\t' read -r id name; do
    [[ -n "$id" ]] || continue
    # spare a JIT registration minted in the last 5 minutes: still connecting
    if [[ "$name" =~ ^${host}-[0-9]{1,3}-([0-9]{9,})$ ]]; then
      (( now - BASH_REMATCH[1] < 300 )) && continue
    fi
    doomed+=("${id}:${name}")
  done < <(jq -r --arg h "$host" \
    '.[] | select(.status=="offline") | select(.name|contains($h)) | [.id,.name] | @tsv' \
    <<<"$GH_RUNNERS" 2>/dev/null || true)

  if (( ${#doomed[@]} == 0 )); then
    ok "nothing to reap for ${host}"
    return 0
  fi

  local seen; seen=$(jq 'length' <<<"$GH_RUNNERS" 2>/dev/null || echo '?')
  echo "  ${#doomed[@]} offline registration(s) from ${host} (scanned ${seen} runners, all pages):"
  local e
  for e in "${doomed[@]:0:8}"; do echo "    - ${e#*:}"; done
  (( ${#doomed[@]} > 8 )) && echo "    ... and $(( ${#doomed[@]} - 8 )) more"
  echo
  ask_yn "Delete all ${#doomed[@]} from GitHub?" y || { warn "left in place"; return 0; }

  local done_n=0 failed=0
  for e in "${doomed[@]}"; do
    gh_api DELETE "${GH_RUNNERS_PATH}/${e%%:*}"
    if [[ "$GH_CODE" == "204" ]]; then done_n=$(( done_n + 1 )); else failed=$(( failed + 1 )); fi
    printf '\r  deleted %d/%d' "$done_n" "${#doomed[@]}"
  done
  echo
  (( failed )) && warn "${failed} deletion(s) failed" || true

  # Re-list and prove the job is actually finished, rather than assuming it.
  gh_list_runners || { ok "reaped ${done_n}"; return 0; }
  local left
  left=$(jq -r --arg h "$host" \
    '[.[] | select(.status=="offline") | select(.name|contains($h))] | length' \
    <<<"$GH_RUNNERS" 2>/dev/null || echo 0)
  if (( left == 0 )); then
    ok "reaped ${done_n}; verified none remain for ${host}"
  else
    warn "reaped ${done_n}; ${left} still offline (minted in the last 5 min, or deletion failed)"
  fi
}

# ===========================================================================
# RESOURCE POLICY
#
# Per-runner ceilings are generous on purpose (a lone job should get the whole
# machine). That means the ceilings SUM to more than the box has. The aggregate
# is bounded one level up instead, by a parent slice - so five busy runners
# cannot exhaust the host, and when something must die it dies inside CI rather
# than being chosen by the global OOM killer from every process on the system.
# ===========================================================================
GHA_SLICE="gha.slice"

compute_resource_policy() {   # sets RP_FAIR RP_CEILING RP_AGGREGATE RP_SYSMIN
  local reserve
  reserve=$(( 1024 + 200 * GHA_COUNT ))          # OS + one rootless daemon each
  RP_FAIR=$(( (MEM_MB - reserve) / GHA_COUNT ))
  (( RP_FAIR < 512 )) && RP_FAIR=512 || true
  RP_CEILING=$(( (MEM_MB - reserve) * 85 / 100 ))
  (( RP_CEILING < RP_FAIR )) && RP_CEILING=$RP_FAIR || true
  # Everything CI, added together, must still leave the OS a working set.
  RP_AGGREGATE=$(( MEM_MB - 1024 - 100 * GHA_COUNT ))
  (( RP_AGGREGATE < RP_FAIR )) && RP_AGGREGATE=$RP_FAIR || true
  RP_SYSMIN=512
  (( MEM_MB >= 8000 )) && RP_SYSMIN=768 || true
}

write_resource_policy() {
  compute_resource_policy

  # Parent slice: one aggregate ceiling for all runner units.
  cat > "/etc/systemd/system/${GHA_SLICE}" <<EOF
[Unit]
Description=GitHub Actions runners (aggregate resource boundary)
Before=slices.target

[Slice]
# Individual runners are deliberately uncapped so a lone job can use the whole
# machine. THIS is what stops all of them together from exhausting the host,
# and it keeps any OOM kill inside CI instead of letting the global OOM killer
# choose a victim from every process on the box.
MemoryAccounting=yes
MemoryMax=${RP_AGGREGATE}M
CPUAccounting=yes
CPUWeight=100
IOAccounting=yes
IOWeight=100
# Kill the worst-offending runner on sustained memory pressure, before the
# machine starts swap-thrashing. A clean job failure beats a locked-up host.
ManagedOOMMemoryPressure=kill
ManagedOOMMemoryPressureLimit=60%
ManagedOOMSwap=kill
EOF
  chmod 0644 "/etc/systemd/system/${GHA_SLICE}"

  # Protect the OS so the box stays reachable no matter what CI does.
  install -d -m 0755 /etc/systemd/system/system.slice.d
  cat > /etc/systemd/system/system.slice.d/10-gha-protect.conf <<EOF
[Slice]
# sshd, journald and systemd itself are never reclaimed below this. You keep
# your shell even while CI is fighting for the last megabyte.
MemoryAccounting=yes
MemoryMin=${RP_SYSMIN}M
EOF
  chmod 0644 /etc/systemd/system/system.slice.d/10-gha-protect.conf

  local n u uid tc
  for n in $(seq 1 "${GHA_COUNT}"); do
    u="${USER_PREFIX}${n}"; uid=$(id -u "$u" 2>/dev/null) || continue
    tc="/opt/hostedtoolcache-${u}"
    install -d -m 0755 "/etc/systemd/system/gha-runner@${n}.service.d"
    cat > "/etc/systemd/system/gha-runner@${n}.service.d/10-instance.conf" <<EOF
[Service]
Slice=${GHA_SLICE}
ReadWritePaths=${RUNNER_BASE}/${n} /home/${u} ${tc} /run/user/${uid}
Environment=DOCKER_HOST=unix:///run/user/${uid}/docker.sock
Environment=XDG_RUNTIME_DIR=/run/user/${uid}
# Non-container job steps run as children of this unit, so this is the cgroup
# that governs most builds. Weight, not quota: no ceiling on a lone job.
CPUWeight=100
IOWeight=100
MemoryLow=${RP_FAIR}M
MemoryMax=${RP_CEILING}M
EOF
    install -d -m 0755 "/etc/systemd/system/user-${uid}.slice.d"
    cat > "/etc/systemd/system/user-${uid}.slice.d/10-gha-limits.conf" <<EOF
[Slice]
# Containers started by rootless Docker land here rather than in the unit.
CPUWeight=100
IOWeight=100
MemoryLow=${RP_FAIR}M
MemoryMax=${RP_CEILING}M
TasksMax=8192
ManagedOOMMemoryPressure=kill
ManagedOOMMemoryPressureLimit=60%
EOF
    chmod 0644 "/etc/systemd/system/gha-runner@${n}.service.d/10-instance.conf" \
               "/etc/systemd/system/user-${uid}.slice.d/10-gha-limits.conf"
  done

  systemctl daemon-reload
  # oomd is what turns "box thrashes for five minutes" into "one job fails".
  systemctl enable --now systemd-oomd.service >/dev/null 2>&1 \
    && ok "systemd-oomd active (kills the worst CI cgroup under pressure)" \
    || warn "systemd-oomd unavailable - the kernel OOM killer is the fallback"
}

# ===========================================================================
# RETUNE - reapply only the CPU/memory policy
#
# A full install would wipe _work and re-extract the runner, interrupting any
# job in flight. This only rewrites the resource drop-ins.
# ===========================================================================
phase_retune() {
  head1 "Retuning CPU and memory policy"
  compute_resource_policy
  echo "  ${CPU_COUNT} vCPU, ${MEM_MB} MB RAM, ${GHA_COUNT} runners"
  echo "    per runner guaranteed : ${RP_FAIR} MB   (MemoryLow, protected from reclaim)"
  echo "    per runner ceiling    : ${RP_CEILING} MB  (a lone job may take this much)"
  echo "    ALL runners together  : ${RP_AGGREGATE} MB  (${GHA_SLICE} aggregate cap)"
  echo "    OS floor              : ${RP_SYSMIN} MB   (system.slice MemoryMin - keeps sshd alive)"
  echo "    CPU                   : weight 100, no quota - a lone job gets all ${CPU_COUNT} cores"
  echo

  write_resource_policy
  local n
  for n in $(seq 1 "${GHA_COUNT}"); do ok "runner ${n} retuned"; done

  # Push what can be applied live; Slice= needs a restart, which each ephemeral
  # runner does anyway after its next job.
  for n in $(seq 1 "${GHA_COUNT}"); do
    systemctl set-property --runtime "gha-runner@${n}.service" \
      CPUQuota= CPUWeight=100 MemoryLow="${RP_FAIR}M" MemoryMax="${RP_CEILING}M" MemoryHigh=infinity \
      >/dev/null 2>&1 || true
  done
  ok "applied to running units"
  warn "the ${GHA_SLICE} grouping takes effect as each runner restarts (after its next job)"
  echo "  ${C_DIM}force it now with: systemctl restart 'gha-runner@*'${C_R}"
  echo
  echo "  ${C_DIM}Verify: systemctl show gha-runner@1 -p Slice -p CPUWeight -p MemoryMax -p MemoryHigh${C_R}"
  echo "  ${C_DIM}        systemctl show ${GHA_SLICE} -p MemoryMax${C_R}"
  echo "  ${C_DIM}        systemd-cgtop  - watch the aggregate under load${C_R}"
}

# ===========================================================================
# SANDBOX PROBE
#
# When a job fails with an errno that smells like the sandbox (ENOSYS
# "Function not implemented", EPERM, EROFS), this reproduces the unit's exact
# property set with systemd-run and then bisects it leave-one-out, so the
# offending directive is named rather than guessed at.
# ===========================================================================
SANDBOX_PROPS=()

# Read the sandbox settings OFF THE LIVE UNIT rather than from a fixed list.
# A hardcoded list can only ever prove that some property set breaks tar; it
# cannot tell you whether the unit you are actually running is affected.
build_sandbox_props_from_unit() {
  local unit="gha-runner@1" pr v
  SANDBOX_PROPS=()

  # Booleans: only carry over the ones that are switched on.
  for pr in NoNewPrivileges PrivateTmp ProtectKernelTunables ProtectKernelModules \
            ProtectKernelLogs ProtectControlGroups ProtectClock ProtectHostname \
            RestrictSUIDSGID RestrictRealtime LockPersonality RemoveIPC; do
    v=$(systemctl show -p "$pr" --value "$unit" 2>/dev/null || true)
    [[ "$v" == "yes" ]] && SANDBOX_PROPS+=("${pr}=yes") || true
  done

  # Enumerated settings: carry over anything that is not the permissive default.
  for pr in ProtectSystem ProtectHome ProtectProc; do
    v=$(systemctl show -p "$pr" --value "$unit" 2>/dev/null || true)
    case "$v" in
      ""|no|default) ;;
      *) SANDBOX_PROPS+=("${pr}=${v}") ;;
    esac
  done

  # An empty capability set means every capability was dropped - that is a
  # restriction worth testing, so include it.
  v=$(systemctl show -p CapabilityBoundingSet --value "$unit" 2>/dev/null || true)
  [[ -z "$v" ]] && SANDBOX_PROPS+=("CapabilityBoundingSet=") || true
  v=$(systemctl show -p AmbientCapabilities --value "$unit" 2>/dev/null || true)
  [[ -z "$v" ]] && SANDBOX_PROPS+=("AmbientCapabilities=") || true

  v=$(systemctl show -p SystemCallFilter --value "$unit" 2>/dev/null || true)
  [[ -n "$v" && "$v" != "~" ]] && SANDBOX_PROPS+=("SystemCallFilter=${v}") || true
}

# Runs the payload under systemd-run with the given properties. 0 = worked.
_probe_run() {
  local u="$1" dir="$2"; shift 2
  local -a args=(--quiet --wait --pipe --collect
                 --property=User="$u" --property=Group="$u"
                 --property=WorkingDirectory="$dir"
                 --property=ReadWritePaths="$dir")
  local pr
  for pr in "$@"; do args+=(--property="$pr"); done
  systemd-run "${args[@]}" -- /bin/bash -c \
    "rm -rf '${dir}/out' && mkdir -p '${dir}/out' && tar -xzf '${dir}/payload.tar.gz' -C '${dir}/out'" \
    >/dev/null 2>&1
}

phase_sandbox_probe() {
  head1 "Sandbox probe"
  command -v systemd-run >/dev/null || die "systemd-run not available"
  local u="${USER_PREFIX}1" dir="${RUNNER_BASE}/1/.probe"
  id "$u" &>/dev/null || die "${u} does not exist - run the installer first"

  # A payload shaped like the archive that failed: a dot-directory, nested
  # dot-directories, and files inside them.
  rm -rf "${dir:?}"; install -d -m 0755 -o "$u" -g "$u" "$dir"
  local build="${dir}/src/sample-action/.docs/examples/sample/.github/workflows"
  install -d -m 0755 "$build"
  echo "x" > "${build}/ci.yaml"
  echo "y" > "${dir}/src/sample-action/.docs/readme.md"
  tar -czf "${dir}/payload.tar.gz" -C "${dir}/src" sample-action
  rm -rf "${dir}/src"
  chown -R "$u:$u" "$dir"
  ok "payload built (mirrors the failing action tarball)"

  echo
  log "what the LIVE unit is actually enforcing right now"
  local prop
  for prop in SystemCallFilter SystemCallErrorNumber RestrictSUIDSGID ProtectClock \
              ProtectKernelModules ProtectKernelLogs LockPersonality ProtectSystem \
              ReadWritePaths NoNewPrivileges CapabilityBoundingSet; do
    printf '    %-24s %s\n' "$prop" \
      "$(systemctl show -p "$prop" --value "gha-runner@1" 2>/dev/null | cut -c1-90)"
  done
  echo "    ${C_DIM}If SystemCallFilter is non-empty, a seccomp filter IS active.${C_R}"

  build_sandbox_props_from_unit
  if (( ${#SANDBOX_PROPS[@]} == 0 )); then
    ok "the live unit applies no sandbox restrictions - nothing to test"
    rm -rf "${dir:?}"; return 0
  fi
  echo
  log "testing the ${#SANDBOX_PROPS[@]} settings this unit REALLY applies"
  printf '    %s\n' "${SANDBOX_PROPS[@]}"

  echo
  log "extraction OUTSIDE systemd entirely (plain sudo -u)"
  if sudo -u "$u" bash -c "rm -rf '${dir}/out2' && mkdir -p '${dir}/out2' && tar -xzf '${dir}/payload.tar.gz' -C '${dir}/out2'" 2>/dev/null; then
    ok "  works outside systemd -> the filesystem is fine, the unit is the problem"
  else
    err "  FAILS outside systemd too -> this is NOT the sandbox."
    err "  It is the filesystem or the kernel. Capture:"
    err "    sudo -u ${u} strace -f -e trace=mkdir,mkdirat,openat,openat2 tar -xzf ${dir}/payload.tar.gz -C /tmp 2>&1 | grep -i enosys"
    err "    mount | grep -E ' / | /opt '"
    err "    findmnt -no FSTYPE,OPTIONS --target ${RUNNER_BASE}"
    rm -rf "${dir:?}"; return 1
  fi

  echo
  log "baseline: systemd-run with no sandbox properties"
  if _probe_run "$u" "$dir"; then ok "  extracts cleanly"; else
    err "  FAILS even with no sandbox - this is not the unit, it is the filesystem"
    err "  check: mount | grep -E ' /opt| / '"
    rm -rf "${dir:?}"; return 1
  fi

  log "the live unit's property set"
  if _probe_run "$u" "$dir" "${SANDBOX_PROPS[@]}"; then
    ok "  extracts cleanly - THIS UNIT IS FINE, nothing to fix here"
    echo
    echo "  ${C_DIM}If a job still fails, the sandbox is not the cause. Capture the exact${C_R}"
    echo "  ${C_DIM}error and check disk (df -h /opt) and for a stale workspace.${C_R}"
    rm -rf "${dir:?}"; return 0
  fi
  err "  reproduced the failure with the settings this unit really uses"

  echo
  log "bisecting leave-one-out (${#SANDBOX_PROPS[@]} runs)"
  local -a culprits=() keep=()
  local i j
  for i in "${!SANDBOX_PROPS[@]}"; do
    keep=()
    for j in "${!SANDBOX_PROPS[@]}"; do
      (( i == j )) || keep+=("${SANDBOX_PROPS[$j]}")
    done
    if _probe_run "$u" "$dir" "${keep[@]}"; then
      err "  CULPRIT: ${SANDBOX_PROPS[$i]}   (removing it fixes the extraction)"
      culprits+=("${SANDBOX_PROPS[$i]}")
    else
      printf '    ok (still fails without %s)\n' "${SANDBOX_PROPS[$i]}"
    fi
  done

  echo
  if (( ${#culprits[@]} == 0 )); then
    warn "no single directive is responsible - the combination is. Relax with:"
    warn "  ${0##*/} sandbox-relax"
  else
    err "offending directive(s) IN THE LIVE UNIT: ${culprits[*]}"
    echo
    echo "  Fix on every machine:"
    echo "    ${C_CYN}${0##*/} sandbox-relax${C_R}   (drop-in override)"
    echo "    ${C_CYN}${0##*/}${C_R}                 (plain install - rewrites the base unit)"
  fi
  rm -rf "${dir:?}"
}

# Drop a per-instance override neutralising the seccomp-bearing directives,
# keeping the filesystem isolation (which is what actually contains a job).
phase_sandbox_relax() {
  head1 "Relaxing the seccomp directives"
  local n
  for n in $(seq 1 "${GHA_COUNT}"); do
    install -d -m 0755 "/etc/systemd/system/gha-runner@${n}.service.d"
    cat > "/etc/systemd/system/gha-runner@${n}.service.d/20-sandbox-relax.conf" <<'EOF'
[Service]
# Clearing the individual Protect*/Restrict* directives is not enough on its
# own: each of them IMPLIES a seccomp filter, and an implied filter can still
# be applied. So reset the filter set outright, and make anything that does
# still get blocked return EPERM - which is at least diagnosable, unlike
# ENOSYS ("Function not implemented"), which tools misread as "old kernel".
# RestrictSUIDSGID is the confirmed culprit: it filters mkdir/mkdirat/open/
# openat by inspecting the mode argument, and on this systemd+kernel the
# blocked call returns ENOSYS - which GNU tar reports as "Cannot mkdir:
# Function not implemented" while unpacking a composite action.
#
# It does NOT go through SystemCallFilter; systemd applies it as its own
# seccomp program, so clearing SystemCallFilter has no effect on it.
#
# These are BOOLEANS. "RestrictSUIDSGID=" is not a reset - systemd cannot
# parse an empty boolean and keeps the inherited value. They need =no.
RestrictSUIDSGID=no
ProtectKernelModules=no
ProtectKernelLogs=no
ProtectClock=no
ProtectHostname=no
RestrictRealtime=no
LockPersonality=no

# List settings, where an empty value IS the documented reset.
SystemCallFilter=
SystemCallArchitectures=
# Report EPERM rather than ENOSYS for anything still filtered - "Permission
# denied" is diagnosable; "Function not implemented" reads as a kernel fault.
SystemCallErrorNumber=EPERM

# KEPT in the base unit, and still enforced: User=/Group= (unprivileged
# dedicated account), ProtectSystem=strict + ReadWritePaths (read-only
# filesystem outside the runner directory), NoNewPrivileges, PrivateTmp,
# ProtectProc=invisible, and the empty capability sets.
EOF
    chmod 0644 "/etc/systemd/system/gha-runner@${n}.service.d/20-sandbox-relax.conf"
  done
  systemctl daemon-reload
  for n in $(seq 1 "${GHA_COUNT}"); do
    systemctl restart "gha-runner@${n}.service" 2>/dev/null || true
  done
  sleep 6
  local up=0
  for n in $(seq 1 "${GHA_COUNT}"); do
    systemctl is-active --quiet "gha-runner@${n}" && up=$(( up + 1 )) || true
  done
  ok "${up}/${GHA_COUNT} runners back up"

  # Verify the drop-in actually landed. An unparseable line is ignored in
  # silence, which is exactly how the previous version appeared to succeed
  # while changing nothing.
  local bad=0 d v
  for d in RestrictSUIDSGID ProtectClock ProtectKernelModules LockPersonality; do
    v=$(systemctl show -p "$d" --value "gha-runner@1" 2>/dev/null)
    if [[ "$v" == "yes" ]]; then err "  ${d} is STILL yes - the override did not apply"; bad=1
    else ok "  ${d}=${v:-no}"; fi
  done
  if (( bad )); then
    err "Run '${0##*/}' (plain install) instead - it rewrites the base unit without these."
    return 1
  fi
  echo
  echo "  ${C_DIM}Still enforced: unprivileged user, read-only filesystem outside${C_R}"
  echo "  ${C_DIM}ReadWritePaths, no capabilities, no new privileges, private /tmp.${C_R}"
}

# Strip the sandbox down to the unprivileged user. This is a diagnostic and an
# emergency unblock, not a destination: if CI works after this, the fault is
# definitively in the unit's hardening, and sandbox-probe will name which part.
phase_sandbox_off() {
  head1 "Disabling the systemd sandbox (diagnostic)"
  warn "This keeps ONLY: dedicated unprivileged user, no sudo, no docker group,"
  warn "rootless Docker, ephemeral runners, fresh workspace per job."
  warn "It drops the filesystem and syscall confinement. Use it to confirm the"
  warn "cause, then put the sandbox back with: ${0##*/} sandbox-relax"
  echo
  ask_yn "Proceed?" n || { warn "aborted"; return 0; }

  local n
  for n in $(seq 1 "${GHA_COUNT}"); do
    local u="${USER_PREFIX}${n}" uid tc
    uid=$(id -u "$u"); tc="/opt/hostedtoolcache-${u}"
    install -d -m 0755 "/etc/systemd/system/gha-runner@${n}.service.d"
    cat > "/etc/systemd/system/gha-runner@${n}.service.d/30-sandbox-off.conf" <<EOF
[Service]
# Booleans need an explicit =no; an empty value is not a reset.
ProtectSystem=no
ProtectHome=no
PrivateTmp=no
ProtectProc=default
ProtectKernelTunables=no
ProtectKernelModules=no
ProtectKernelLogs=no
ProtectControlGroups=no
ProtectClock=no
ProtectHostname=no
RestrictSUIDSGID=no
RestrictRealtime=no
RestrictNamespaces=no
LockPersonality=no
RemoveIPC=no
NoNewPrivileges=no
# List settings - empty IS the reset here.
SystemCallFilter=
SystemCallArchitectures=
CapabilityBoundingSet=~
ReadWritePaths=
Environment=DOCKER_HOST=unix:///run/user/${uid}/docker.sock
Environment=XDG_RUNTIME_DIR=/run/user/${uid}
EOF
    chmod 0644 "/etc/systemd/system/gha-runner@${n}.service.d/30-sandbox-off.conf"
  done
  systemctl daemon-reload
  for n in $(seq 1 "${GHA_COUNT}"); do systemctl restart "gha-runner@${n}" 2>/dev/null || true; done
  sleep 6
  local up=0
  for n in $(seq 1 "${GHA_COUNT}"); do
    systemctl is-active --quiet "gha-runner@${n}" && up=$(( up + 1 )) || true
  done
  ok "${up}/${GHA_COUNT} runners up with the sandbox disabled"
  echo
  echo "  Re-run the failing job now."
  echo "    ${C_CYN}still fails${C_R} -> not the sandbox; it is the filesystem or kernel"
  echo "    ${C_CYN}now passes${C_R}  -> it IS the sandbox; run sandbox-probe to name the directive"
  echo
  echo "  Undo with: ${C_CYN}rm -f /etc/systemd/system/gha-runner@*.service.d/30-sandbox-off.conf${C_R}"
  echo "             ${C_CYN}systemctl daemon-reload && systemctl restart 'gha-runner@*'${C_R}"
}

# ===========================================================================
# UNATTENDED SECURITY UPGRADES
#
# The default Ubuntu setup reboots on its own schedule. On a CI box that means
# killing whatever job is running at 03:00 and producing a "flaky" build no
# one can reproduce. So: patch automatically, but never reboot blindly -
# ask GitHub whether any runner on this host is busy first.
# ===========================================================================
phase_unattended() {
  head1 "Unattended security upgrades"
  export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a NEEDRESTART_SUSPEND=1
  apt-get install -y -qq unattended-upgrades >/dev/null
  ok "unattended-upgrades installed"

  cat > /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Download-Upgradeable-Packages "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF
  chmod 0644 /etc/apt/apt.conf.d/20auto-upgrades

  # 52* sorts after the shipped 50unattended-upgrades, so these win.
  cat > /etc/apt/apt.conf.d/52gha-unattended <<'EOF'
// Security pockets only. The Docker repo is deliberately absent: a docker-ce
// upgrade restarts the rootless daemons and would kill containers mid-job.
// Update Docker deliberately, during the reboot window below.
Unattended-Upgrade::Allowed-Origins {
    "${distro_id}:${distro_codename}-security";
    "${distro_id}ESMApps:${distro_codename}-apps-security";
    "${distro_id}ESM:${distro_codename}-infra-security";
};

// /boot fills up and then apt breaks - on an unattended fleet this is the
// single most common way these boxes die.
Unattended-Upgrade::Remove-Unused-Kernel-Packages "true";
Unattended-Upgrade::Remove-New-Unused-Dependencies "true";

// NEVER blind-reboot a CI box. gha-reboot-if-idle does it safely instead.
Unattended-Upgrade::Automatic-Reboot "false";

// Apply in small steps so a shutdown mid-run leaves dpkg consistent.
Unattended-Upgrade::MinimalSteps "true";
EOF
  chmod 0644 /etc/apt/apt.conf.d/52gha-unattended
  ok "security-only origins, kernel cleanup on, automatic reboot OFF"

  # needrestart must not restart services under a running job.
  if [[ -d /etc/needrestart ]]; then
    printf '# managed by harden-gha-runners\n$nrconf{restart} = %s;\n' "'l'" \
      > /etc/needrestart/conf.d/90-gha.conf 2>/dev/null || true
    chmod 0644 /etc/needrestart/conf.d/90-gha.conf 2>/dev/null || true
    ok "needrestart set to list-only (no mid-job service restarts)"
  fi

  install_reboot_guard
  systemctl enable --now unattended-upgrades.service >/dev/null 2>&1 || true
  ok "unattended-upgrades enabled"
  echo
  echo "  ${C_DIM}dry run:  sudo unattended-upgrade --dry-run --debug${C_R}"
  echo "  ${C_DIM}log:      /var/log/unattended-upgrades/${C_R}"
}

install_reboot_guard() {
  cat > /usr/local/sbin/gha-reboot-if-idle <<'RB'
#!/usr/bin/env bash
# Reboot ONLY when no runner on this host is executing a job. Anything other
# than a confident "zero busy" defers - a missed reboot is cheap, a killed
# job is a flaky build somebody has to chase.
set -uo pipefail
log() { logger -t gha-reboot -- "$*"; }

[ -f /run/reboot-required ] || [ -f /var/run/reboot-required ] || exit 0
. /etc/github-runner/env 2>/dev/null || exit 0
[ -s /etc/github-runner/pat ] || exit 0
PAT="$(< /etc/github-runner/pat)"
HOST=$(hostname -s)

# Keeps the PAT out of argv; see the note on gh_api in the installer.
AUTH=$(mktemp)
trap 'rm -f "$AUTH"' EXIT
printf 'Authorization: Bearer %s\n' "$PAT" > "$AUTH"

if [ "$GHA_SCOPE" = "org" ]; then
  RPATH="/orgs/${GHA_ORG}/actions/runners"
else
  RPATH="/repos/${GHA_ORG}/${GHA_REPO}/actions/runners"
fi

ALL='[]'; PAGE=1
while [ "$PAGE" -le 20 ]; do
  BODY=$(curl -fsS -H @"$AUTH"           -H "Accept: application/vnd.github+json"           "https://api.github.com${RPATH}?per_page=100&page=${PAGE}" 2>/dev/null) || {
    log "cannot reach the GitHub API - deferring reboot"; exit 0; }
  CHUNK=$(jq -c '.runners // []' <<<"$BODY" 2>/dev/null || echo '[]')
  N=$(jq 'length' <<<"$CHUNK" 2>/dev/null || echo 0)
  [ "$N" -eq 0 ] && break
  ALL=$(jq -c -s 'add' <<<"${ALL}"$'
'"${CHUNK}" 2>/dev/null || echo "$ALL")
  [ "$N" -lt 100 ] && break
  PAGE=$((PAGE+1))
done

BUSY=$(jq -r --arg h "$HOST"   '[.[]|select(.name|contains($h))|select(.busy==true)]|length' <<<"$ALL" 2>/dev/null || echo "?")
case "$BUSY" in
  0) ;;
  ?*) log "reboot pending, but ${BUSY} runner(s) busy on ${HOST} - deferring"; exit 0 ;;
esac

log "reboot required and all runners idle - draining and rebooting"
systemctl stop 'gha-runner@*' 2>/dev/null || true
sleep 5
systemctl reboot
RB
  chmod 0700 /usr/local/sbin/gha-reboot-if-idle

  cat > /etc/systemd/system/gha-reboot.service <<'EOF'
[Unit]
Description=Reboot the runner host if updates require it and no job is running
[Service]
Type=oneshot
ExecStart=/usr/local/sbin/gha-reboot-if-idle
EOF
  cat > /etc/systemd/system/gha-reboot.timer <<'EOF'
[Unit]
Description=Check hourly for a safe reboot window
[Timer]
OnCalendar=*-*-* 02..05:00:00
RandomizedDelaySec=20m
Persistent=true
[Install]
WantedBy=timers.target
EOF
  chmod 0644 /etc/systemd/system/gha-reboot.service /etc/systemd/system/gha-reboot.timer
  systemctl daemon-reload
  systemctl enable --now gha-reboot.timer >/dev/null 2>&1 || true
  ok "gha-reboot.timer: checks 02:00-05:00, reboots only when every runner is idle"
}

# ===========================================================================
# ROTATE-PAT
#
# The stored PAT is a live dependency: gha-jitconfig exchanges it for a JIT
# config every time a runner starts, which is after every job. If it expires
# or is revoked, every runner on the box stops registering. Validate the
# replacement against the API BEFORE it touches disk, so a typo cannot take
# the fleet down.
# ===========================================================================
phase_rotate_pat() {
  head1 "Rotating the admin PAT"

  # Is the one currently on disk still good? Tells them whether they are
  # already broken or merely rotating ahead of expiry.
  if [[ -s "$PAT_FILE" ]]; then
    GHA_PAT="$(< "$PAT_FILE")"
    gh_list_runners >/dev/null 2>&1 || true
    case "${GH_CODE:-}" in
      200) ok "the PAT currently on disk still works${GH_PAT_EXPIRY:+ (expires ${GH_PAT_EXPIRY})}" ;;
      401) err "the PAT currently on disk is REJECTED (401) - runners stop registering on their next cycle" ;;
      403) err "the PAT currently on disk lacks runner-admin permission (403)" ;;
      *)   warn "could not check the current PAT (HTTP ${GH_CODE:-?})" ;;
    esac
  else
    warn "no PAT stored at ${PAT_FILE}"
  fi

  echo
  echo "  Needs one of:"
  echo "    - classic PAT with scope ${C_B}admin:org${C_R} (org) or ${C_B}repo${C_R} (single repo)"
  echo "    - fine-grained PAT with ${C_B}Self-hosted runners: Read and write${C_R}"
  echo
  # NOT `local GHA_NEW_PAT=""` - that would shadow the environment variable and
  # break unattended rotation across the fleet.
  ask_secret GHA_NEW_PAT "New admin PAT"

  # Validate BEFORE writing. validate_token dies on failure, and nothing has
  # been modified at this point, so a bad token leaves the old one intact.
  GHA_PAT="$GHA_NEW_PAT"
  validate_token

  install -d -m 0700 "$CONF_DIR"
  local tmp; tmp=$(mktemp -p "$CONF_DIR" .pat.XXXXXX)
  printf '%s' "$GHA_NEW_PAT" > "$tmp"
  chown root:root "$tmp"; chmod 0600 "$tmp"
  mv -f "$tmp" "$PAT_FILE"          # atomic swap, never a half-written file
  ok "stored at ${PAT_FILE} (0600 root:root)"

  # gha-jitconfig re-reads the file on every start, so a restart is not
  # strictly required - but it proves the new token works right now.
  echo
  if ask_yn "Restart the runners now to pick it up? (interrupts any running job)" y; then
    local n
    for n in $(seq 1 "${GHA_COUNT}"); do
      systemctl restart "gha-runner@${n}.service" 2>/dev/null || true
    done
    sleep 8
    local up=0
    for n in $(seq 1 "${GHA_COUNT}"); do
      systemctl is-active --quiet "gha-runner@${n}" && up=$(( up + 1 )) || true
    done
    (( up == GHA_COUNT )) && ok "${up}/${GHA_COUNT} runners back up on the new PAT" \
      || { err "${up}/${GHA_COUNT} up - check: ${0##*/} diagnose"; return 1; }
  else
    warn "not restarted; the new PAT takes effect the next time each runner cycles"
  fi

  echo
  echo "  ${C_B}Do the same on every other machine in the fleet:${C_R}"
  echo "    ${C_CYN}GHA_NEW_PAT='<new-pat>' GHA_YES=1 sudo -E ./${0##*/} rotate-pat${C_R}"
  echo "  Then revoke the old token in GitHub so it cannot be used again."
}

# ===========================================================================
# DIAGNOSE - everything needed to work out why a runner will not stay up
# ===========================================================================
phase_diagnose() {
  head1 "Diagnostics"
  set +e +o pipefail
  local n u uid d

  echo "${C_B}host${C_R}"
  printf '    %s | kernel %s | %s\n' "$(hostname -s)" "$(uname -r)" \
    "$( . /etc/os-release 2>/dev/null; echo "${PRETTY_NAME:-?}" )"
  printf '    runner binary: %s\n' "$(cat "${RUNNER_BASE}/1/bin/runnerversion" 2>/dev/null || echo '?')"

  for n in $(seq 1 "${GHA_COUNT}"); do
    u="${USER_PREFIX}${n}"; uid=$(id -u "$u" 2>/dev/null); d="${RUNNER_BASE}/${n}"
    echo
    echo "${C_B}gha-runner@${n}${C_R}"
    printf '    state   : %s / %s   result=%s exit=%s restarts=%s\n' \
      "$(systemctl show -p ActiveState --value "gha-runner@${n}" 2>/dev/null)" \
      "$(systemctl show -p SubState --value "gha-runner@${n}" 2>/dev/null)" \
      "$(systemctl show -p Result --value "gha-runner@${n}" 2>/dev/null)" \
      "$(systemctl show -p ExecMainStatus --value "gha-runner@${n}" 2>/dev/null)" \
      "$(systemctl show -p NRestarts --value "gha-runner@${n}" 2>/dev/null)"
    printf '    user    : %s (uid %s)\n' "$u" "${uid:-MISSING}"
    printf '    socket  : %s\n' "$( [[ -S /run/user/${uid}/docker.sock ]] && echo present || echo MISSING )"
    printf '    wrapper : %s\n' "$(stat -c '%a %U:%G' "${d}/run-ephemeral.sh" 2>/dev/null || echo MISSING)"
    printf '    runner  : %s\n' "$(stat -c '%a %U:%G' "${d}/run.sh" 2>/dev/null || echo MISSING)"
    printf '    jit file: %s\n' "$(stat -c '%a %U:%G' "/run/gha-runner/${n}.jit" 2>/dev/null || echo '(none - normal when stopped)')"
    printf '    chdir as %s: %s\n' "$u" \
      "$(runuser -u "$u" -- test -x "$d" 2>/dev/null && echo OK || echo "DENIED  <-- this is a CHDIR/exit-200 failure")"
    echo "    ${C_DIM}path components (first one without o+x is the culprit):${C_R}"
    if command -v namei >/dev/null; then
      namei -l "${d}/run.sh" 2>/dev/null | sed 's/^/      /'
    else
      local pp="$d"
      while [[ "$pp" != "/" ]]; do
        printf '      %s  %s\n' "$(stat -c '%A %U:%G' "$pp" 2>/dev/null)" "$pp"; pp=$(dirname "$pp")
      done
    fi

    echo "    ${C_DIM}last 25 journal lines:${C_R}"
    journalctl -u "gha-runner@${n}" -n 25 --no-pager -o cat 2>/dev/null | sed 's/^/      /'

    # The runner writes its real errors here, not to the journal.
    local diag
    diag=$(ls -t "${d}"/_diag/*.log 2>/dev/null | head -1)
    if [[ -n "$diag" ]]; then
      echo "    ${C_DIM}tail of $(basename "$diag"):${C_R}"
      tail -n 25 "$diag" 2>/dev/null | sed 's/^/      /'
    else
      echo "    ${C_DIM}no _diag logs - the runner never got far enough to write one${C_R}"
    fi
  done

  echo
  echo "${C_B}manual JIT mint (root path, proves the PAT still works)${C_R}"
  echo "    /usr/local/sbin/gha-jitconfig 1 && echo OK"
  echo "${C_B}run one by hand, outside the systemd sandbox${C_R}"
  echo "    /usr/local/sbin/gha-jitconfig 1"
  echo "    sudo -u ${USER_PREFIX}1 -i bash -c 'cd ${RUNNER_BASE}/1 && ./run.sh --jitconfig \"\$(sudo cat /run/gha-runner/1.jit)\"'"
  echo "    ${C_DIM}works by hand but not under systemd => the unit sandbox is the cause${C_R}"
  set -eo pipefail
  return 0
}

# ===========================================================================
# UNINSTALL
# ===========================================================================
phase_uninstall() {
  head1 "Uninstall"
  load_config || die "no configuration at ${ENV_FILE}"
  ask_yn "Remove all runners, users and homes created by this installer?" n || die "aborted"

  local n u uid
  for n in $(seq 1 "${GHA_COUNT}"); do
    u="${USER_PREFIX}${n}"; uid=$(id -u "$u" 2>/dev/null || echo "")
    systemctl disable --now "gha-runner@${n}.service" 2>/dev/null || true
    rm -rf "/etc/systemd/system/gha-runner@${n}.service.d"   # includes 20-sandbox-relax.conf
    [[ -n "$uid" ]] && rm -rf "/etc/systemd/system/user-${uid}.slice.d" || true
    if [[ -n "$uid" ]]; then
      as_user "$u" systemctl --user disable --now docker.service 2>/dev/null || true
      loginctl disable-linger "$u" 2>/dev/null || true
      pkill -KILL -u "$u" 2>/dev/null || true
      userdel -r "$u" 2>/dev/null || true
      sed -i "/^${u}:/d" /etc/subuid /etc/subgid 2>/dev/null || true
    fi
    rm -rf "${RUNNER_BASE:?}/${n:?}" "/opt/hostedtoolcache-${u:?}"
    ok "removed runner ${n}"
  done
  systemctl disable --now gha-janitor.timer gha-reboot.timer 2>/dev/null || true
  rm -rf /etc/systemd/system/system.slice.d/10-gha-protect.conf
  rm -f "/etc/systemd/system/${GHA_SLICE:-gha.slice}"
  rm -f /etc/systemd/system/gha-runner@.service /usr/local/sbin/gha-jitconfig \
        /etc/systemd/system/gha-janitor.service /etc/systemd/system/gha-janitor.timer \
        /usr/local/sbin/gha-janitor /usr/local/sbin/gha-jitreap \
        /usr/local/sbin/gha-reboot-if-idle /etc/sysctl.d/99-gha-rootless.conf \
        /etc/systemd/system/gha-reboot.service /etc/systemd/system/gha-reboot.timer \
        /etc/apt/apt.conf.d/52gha-unattended /etc/needrestart/conf.d/90-gha.conf
  rm -rf /run/gha-runner
  systemctl daemon-reload
  warn "left in place: ${CONF_DIR} (contains your PAT). Remove it with: rm -rf ${CONF_DIR}"
  [[ -e /swapfile ]] && warn "left in place: /swapfile and its /etc/fstab entry" || true
  ok "uninstalled"
}

# ===========================================================================
# SUMMARY
# ===========================================================================
summary() {
  head1 "Done"
  cat <<EOF
  ${GHA_COUNT} ephemeral runner(s) on $(hostname -s), targeting
  ${GHA_ORG}${GHA_REPO:+/$GHA_REPO} in group ${GHA_GROUP_ID} with labels: ${GHA_LABELS}

  ${C_B}This script has other modes${C_R} (a bare run means "install"):
    ${0##*/} verify | diagnose | retune | reap | rotate-pat | updates
    ${0##*/} sandbox-probe | sandbox-relax | sandbox-off | uninstall

  ${C_B}Watch them:${C_R}
    journalctl -fu 'gha-runner@*'
    systemctl status 'gha-runner@*'

  ${C_B}Housekeeping runs itself:${C_R}
    gha-janitor.timer  daily - trims caches at 75% disk, full prune at 90%,
                       checks the admin PAT, and logs if a runner has died
    gha-reboot.timer   02:00-05:00 - applies a pending reboot ONLY when no
                       runner on this host is executing a job
    systemctl list-timers gha-janitor.timer
    sudo /usr/local/sbin/gha-janitor      # run it now

  ${C_B}Use them in a workflow:${C_R}
    jobs:
      build:
        runs-on: [${GHA_LABELS//,/, }]
        container:
          image: node:22-bookworm
          options: --user 1000:1000 --cap-drop ALL --security-opt no-new-privileges
        steps:
          - uses: actions/checkout@v4
          - run: npm ci && npm test

EOF

  if [[ "${GHA_OLD_USER:-none}" != "none" ]] && id "${GHA_OLD_USER}" &>/dev/null; then
    cat <<EOF
  ${C_B}The old user is locked but still present.${C_R} Nothing depends on it now.
  Delete it and its home when you are satisfied:

    ${C_CYN}sudo pkill -u ${GHA_OLD_USER}; sudo userdel -r ${GHA_OLD_USER}${C_R}

EOF
  fi

  cat <<EOF
  ${C_B}For the remaining machines${C_R}, either drive them all from your workstation
  with ${C_CYN}./fleet.sh install${C_R} (see fleet.conf), or run this line on each box:

    ${C_CYN}GHA_SCOPE=${GHA_SCOPE} GHA_ORG=${GHA_ORG}${GHA_REPO:+ GHA_REPO=${GHA_REPO}} \\
    GHA_GROUP_ID=${GHA_GROUP_ID} GHA_LABELS='${GHA_LABELS}' GHA_TRUST=${GHA_TRUST} \\
    GHA_COUNT=${GHA_COUNT} GHA_OLD_USER=${GHA_OLD_USER:-none} GHA_YES=1 GHA_PAT='<your-pat>' \\
    sudo -E ./harden-gha-runners.sh${C_R}

  ${C_B}Still worth doing, outside this box:${C_R}
    - restrict the runner group to the repositories allowed to use it
    - Settings > Actions > General: require approval for outside contributors
    - rotate the PAT you just pasted if it has ever been used elsewhere
EOF
}

# ===========================================================================
# MAIN
# ===========================================================================
main() {
  local mode="${1:-install}"

  # Print identity before anything else. If the output you are reading does not
  # match the file you think you are running, this line says so immediately.
  local sum="?"
  if [[ -r "${SCRIPT_PATH:-}" ]]; then
    sum=$(sha256sum "$SCRIPT_PATH" 2>/dev/null | cut -c1-12) \
      || sum=$(openssl dgst -sha256 "$SCRIPT_PATH" 2>/dev/null | awk '{print substr($NF,1,12)}') \
      || sum="?"
    [[ -n "$sum" ]] || sum="?"
  fi
  printf '%s%s v%s%s  sha256:%s  mode:%s\n' \
    "$C_DIM" "${0##*/}" "$SCRIPT_VERSION" "$C_R" "$sum" "$mode"

  case "$mode" in
    audit)
      [[ $EUID -eq 0 ]] || die "run as root"
      load_config || true
      phase_audit ;;
    verify)
      [[ $EUID -eq 0 ]] || die "run as root"
      load_config || die "no configuration found - run the installer first"
      CPU_COUNT=$(nproc); MEM_MB=$(awk '/MemTotal/{printf "%d",$2/1024}' /proc/meminfo)
      phase_verify ;;
    diagnose)
      [[ $EUID -eq 0 ]] || die "run as root"
      load_config || die "no configuration found - run the installer first"
      phase_diagnose ;;
    retune)
      [[ $EUID -eq 0 ]] || die "run as root"
      load_config || die "no configuration found - run the installer first"
      CPU_COUNT=$(nproc); MEM_MB=$(awk '/MemTotal/{printf "%d",$2/1024}' /proc/meminfo)
      phase_retune ;;
    version)
      echo "${SCRIPT_VERSION}"; return 0 ;;
    reap)
      [[ $EUID -eq 0 ]] || die "run as root"
      load_config || die "no configuration found - run the installer first"
      phase_reap ;;
    sandbox-probe)
      [[ $EUID -eq 0 ]] || die "run as root"
      load_config || die "no configuration found - run the installer first"
      phase_sandbox_probe ;;
    sandbox-off)
      [[ $EUID -eq 0 ]] || die "run as root"
      load_config || die "no configuration found - run the installer first"
      phase_sandbox_off ;;
    sandbox-relax)
      [[ $EUID -eq 0 ]] || die "run as root"
      load_config || die "no configuration found - run the installer first"
      phase_sandbox_relax ;;
    updates)
      [[ $EUID -eq 0 ]] || die "run as root"
      load_config || die "no configuration found - run the installer first"
      phase_unattended ;;
    rotate-pat|rotate)
      [[ $EUID -eq 0 ]] || die "run as root"
      load_config || die "no configuration found - run the installer first"
      phase_rotate_pat ;;
    uninstall)
      [[ $EUID -eq 0 ]] || die "run as root"
      phase_uninstall ;;
    install|reconfigure)
      preflight
      discover
      if [[ "$mode" == "install" ]] && load_config && [[ -z "${GHA_YES:-}" ]]; then
        log "existing configuration found at ${ENV_FILE}"
        ask_yn "Reuse it?" y || { unset GHA_SCOPE GHA_ORG GHA_REPO GHA_GROUP_ID \
                                        GHA_LABELS GHA_COUNT GHA_TRUST GHA_OLD_USER; wizard; }
        [[ -n "${GHA_SCOPE:-}" ]] && confirm_plan || true
      else
        wizard
      fi
      phase_audit
      phase_stop_existing
      phase_deprivilege
      phase_wipe
      phase_prereqs
      local n
      for n in $(seq 1 "$GHA_COUNT"); do
        create_runner_user "$n"
        install_rootless_docker "${USER_PREFIX}${n}"
      done
      maybe_add_swap
      phase_token_helper
      phase_runners
      phase_systemd
      phase_janitor
      phase_unattended
      phase_cleanup_stale
      sleep 5
      phase_verify || warn "some checks failed - review before sending real traffic"
      summary ;;
    -h|--help|help)
      sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//' ;;
    *)
      die "unknown mode '${mode}' - try: install | audit | verify | diagnose | retune | sandbox-probe | sandbox-relax | sandbox-off | reap | rotate-pat | updates | reconfigure | uninstall" ;;
  esac
}

# Only auto-run when executed, not when sourced (lets the functions be tested).
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
