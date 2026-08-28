#!/usr/bin/env bash
#
# fleet.sh - run harden-gha-runners.sh on every machine listed in fleet.conf,
# over SSH, in parallel, from one command on your workstation.
#
# The installer is idempotent, so every mode below is safe to re-run against
# the whole fleet: hosts that are already in the desired state converge to it
# again instead of being rebuilt.
#
# USAGE
#   ./fleet.sh install                  # the full setup on every host
#   ./fleet.sh verify                   # post-flight checks, changes nothing
#   ./fleet.sh audit                    # report only
#   ./fleet.sh rotate-pat               # replace the admin PAT fleet-wide
#   ./fleet.sh --limit build-01 install # one host
#   ./fleet.sh --dry-run install        # print the plan, connect to nothing
#
#   Any mode harden-gha-runners.sh accepts is accepted here and fanned out
#   unchanged: install, audit, verify, diagnose, retune, reap, rotate-pat,
#   updates, sandbox-probe, sandbox-relax, sandbox-off, reconfigure,
#   uninstall, version.
#
# HOW IT TALKS TO A HOST
#   One SSH connection per host. The installer and the per-host GHA_* answers
#   are streamed base64-encoded on that connection's STDIN into a 0700 temp
#   directory, and the elevated shell sources them from there. Nothing secret
#   is ever an argument to ssh, sudo or the installer, so no credential appears
#   in any process list on either side, and the temp directory is removed by an
#   EXIT trap whether the run succeeds or fails.
#
# WHAT THE REMOTE ACCOUNT NEEDS
#   Key-based SSH (BatchMode is on: no password prompts), and either root or
#   passwordless sudo. Nothing else is installed on your workstation beyond
#   ssh and base64.
#
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
FLEET_VERSION="1.0.0"

# ---------------------------------------------------------------------------
# output helpers
# ---------------------------------------------------------------------------
if [[ -t 1 ]]; then
  C_B=$'\033[1m'; C_R=$'\033[0m'; C_BLU=$'\033[1;34m'
  C_RED=$'\033[1;31m'; C_GRN=$'\033[1;32m'; C_CYN=$'\033[1;36m'; C_DIM=$'\033[2m'
else
  C_B=""; C_R=""; C_BLU=""; C_RED=""; C_GRN=""; C_CYN=""; C_DIM=""
fi
# warn and err write to fd 2, so their colour has to follow fd 2. Gating them
# on the fd 1 palette put escape sequences into `2> warn.log` and stripped them
# from a run whose stdout was redirected but whose stderr was still a terminal.
if [[ -t 2 ]]; then
  E_YEL=$'\033[1;33m'; E_RED=$'\033[1;31m'; E_R=$'\033[0m'
else
  E_YEL=""; E_RED=""; E_R=""
fi
log()  { printf '%s==>%s %s\n' "$C_BLU" "$C_R" "$*"; }
ok()   { printf '%s  ok%s %s\n' "$C_GRN" "$C_R" "$*"; }
# stderr, not stdout. build_env's STDOUT is the environment file that gets
# base64'd into the remote host and sourced there, so a diagnostic printed to
# stdout from anywhere inside it becomes a line the remote shell executes --
# and never reaches the operator it was written for.
warn() { printf '%s [!]%s %s\n' "$E_YEL" "$E_R" "$*" >&2; }
err()  { printf '%s [x]%s %s\n' "$E_RED" "$E_R" "$*" >&2; }
die()  { err "$*"; exit 1; }
hr()   { printf '%s%s%s\n' "$C_DIM" "$(printf '%.0s-' {1..72})" "$C_R"; }
head1(){ echo; hr; printf '%s%s%s\n' "$C_B" "$*" "$C_R"; hr; }

# ---------------------------------------------------------------------------
# defaults, all overridable on the command line
# ---------------------------------------------------------------------------
CONFIG="${GHA_FLEET_CONFIG:-${SCRIPT_DIR}/fleet.conf}"
INSTALLER="${SCRIPT_DIR}/harden-gha-runners.sh"
PARALLEL=4
LIMIT=""
LOG_DIR=""
DRY_RUN=0
ASSUME_YES=0
PAT_FILE=""
NEW_PAT_FILE=""
NO_PAT=0
MODE=""
ADMIN_PAT=""
NEW_PAT=""
INSTALLER_B64=""

usage() {
  sed -n '2,/^set -Eeuo/p' "${BASH_SOURCE[0]}" | sed '$d' | sed 's/^# \{0,1\}//'
  cat <<EOF
OPTIONS
  -c, --config FILE       fleet definition (default: ./fleet.conf)
  -f, --installer FILE    installer to ship (default: ./harden-gha-runners.sh)
  -l, --limit LIST        comma-separated host names from the config
  -p, --parallel N        hosts to work on at once (default: ${PARALLEL})
  -L, --log-dir DIR       where per-host logs go (default: ./.fleet-logs/<ts>)
  -n, --dry-run           print the plan and exit without connecting
  -y, --yes               do not ask for confirmation
      --pat-file FILE     read the admin PAT from FILE instead of prompting
      --no-pat            send no admin PAT; each host reuses the one already
                          stored at /etc/github-runner/pat. Affects install and
                          reconfigure only. It does not govern rotate-pat's
                          replacement token, which still needs --new-pat-file.
      --new-pat-file FILE read the replacement PAT from FILE (rotate-pat)
  -h, --help              this text
  -V, --version           print the fleet driver version

EXIT STATUS
  0 when every selected host succeeded, 1 otherwise. Each host's full output
  is kept in the log directory regardless.
EOF
}

# ---------------------------------------------------------------------------
# fleet.conf parsing
#
# Deliberately a hand-rolled INI reader rather than `source`: a fleet
# definition is a data file, and sourcing it would execute whatever is in it
# with your workstation's privileges. Every key is validated against the list
# below, so a typo is a startup error instead of a silently ignored setting.
# ---------------------------------------------------------------------------
declare -A CFG=()
HOSTS=()

KNOWN_KEYS=(
  enabled host port user ssh_key ssh_options become
  scope org repo group_id labels trust runners old_user force_deprivilege
)

is_known_key() {
  local k="$1" v
  for v in "${KNOWN_KEYS[@]}"; do [[ "$v" == "$k" ]] && return 0; done
  return 1
}

trim() { # trim <string>
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

parse_config() {
  local file="$1" line section="" key val lineno=0
  [[ -r "$file" ]] || die "cannot read ${file} - copy fleet.conf.example and edit it"
  while IFS= read -r line || [[ -n "$line" ]]; do
    lineno=$(( lineno + 1 ))
    line="${line%$'\r'}"                       # tolerate CRLF
    line="$(trim "$line")"
    [[ -z "$line" || "$line" == '#'* || "$line" == ';'* ]] && continue
    # Inline comment: a '#' or ';' that FOLLOWS whitespace. '%%' strips the
    # longest matching suffix, which is the one starting at the first such
    # marker - so 'a # b # c' becomes 'a', not 'a # b'. A marker glued to the
    # value ('tag#1') is data and survives, because a value has no escape
    # syntax and silently truncating one would be worse than not supporting it.
    line="${line%%[[:space:]][#;]*}"
    line="$(trim "$line")"
    [[ -n "$line" ]] || continue

    if [[ "$line" == '['*']' ]]; then
      section="$(trim "${line:1:${#line}-2}")"
      [[ "$section" =~ ^[A-Za-z0-9._-]+$ ]] \
        || die "${file}:${lineno}: invalid section name '[${section}]'"
      if [[ "$section" != "defaults" ]]; then
        local h
        for h in ${HOSTS[@]+"${HOSTS[@]}"}; do
          [[ "$h" == "$section" ]] && die "${file}:${lineno}: duplicate host '[${section}]'"
        done
        HOSTS+=("$section")
      fi
      continue
    fi

    [[ -n "$section" ]] || die "${file}:${lineno}: '${line}' appears before any [section]"
    [[ "$line" == *=* ]] || die "${file}:${lineno}: expected 'key = value', got '${line}'"
    key="$(trim "${line%%=*}")"; key="${key,,}"
    val="$(trim "${line#*=}")"
    is_known_key "$key" || die "${file}:${lineno}: unknown key '${key}' (see fleet.conf.example)"
    CFG["${section}.${key}"]="$val"
  done < "$file"

  (( ${#HOSTS[@]} )) || die "${file}: no host sections found (a '[name]' block per machine)"
}

# Config smells worth one line before anything is contacted. Deliberately NOT
# in build_env: that runs twice per host -- once to validate, once to build the
# bootstrap that is actually sent -- so a warning there would either double up
# or land on the stream that becomes the host's environment file.
warn_config_smells() { # warn_config_smells <host-section>
  local h="$1" repo scope
  repo="$(cfg "$h" repo)"; scope="$(cfg "$h" scope)"
  # Not fatal: a host already stored as scope = repo is legitimately changing
  # only its repository. Anywhere else the key does nothing -- a host stored as
  # org ignores it, and one with nothing stored falls to the default of org,
  # where the wizard actively clears it.
  [[ -n "$repo" && -z "$scope" ]] \
    && warn "${h}: 'repo' is set but 'scope' is not; it is ignored unless this host is already stored as scope = repo"
  return 0
}

# cfg <host> <key> [default] - host value, else [defaults] value, else default
cfg() {
  local name="$1" key="$2" def="${3-}"
  if [[ -n "${CFG["${name}.${key}"]+set}" ]]; then printf '%s' "${CFG["${name}.${key}"]}"; return; fi
  if [[ -n "${CFG["defaults.${key}"]+set}" ]]; then printf '%s' "${CFG["defaults.${key}"]}"; return; fi
  printf '%s' "$def"
}

# ---------------------------------------------------------------------------
# argument parsing
# ---------------------------------------------------------------------------
VALID_MODES=(install audit verify diagnose retune reap rotate-pat updates
             sandbox-probe sandbox-relax sandbox-off reconfigure uninstall version)

parse_args() {
  while (( $# )); do
    case "$1" in
      -c|--config)        CONFIG="${2:?--config needs a path}"; shift 2 ;;
      -f|--installer)     INSTALLER="${2:?--installer needs a path}"; shift 2 ;;
      -l|--limit)         LIMIT="${2:?--limit needs a list}"; shift 2 ;;
      -p|--parallel)      PARALLEL="${2:?--parallel needs a number}"; shift 2 ;;
      -L|--log-dir)       LOG_DIR="${2:?--log-dir needs a path}"; shift 2 ;;
      --pat-file)         PAT_FILE="${2:?--pat-file needs a path}"; shift 2 ;;
      --no-pat)           NO_PAT=1; shift ;;
      --new-pat-file)     NEW_PAT_FILE="${2:?--new-pat-file needs a path}"; shift 2 ;;
      -n|--dry-run)       DRY_RUN=1; shift ;;
      -y|--yes)           ASSUME_YES=1; shift ;;
      -h|--help)          usage; exit 0 ;;
      -V|--version)       echo "$FLEET_VERSION"; exit 0 ;;
      -*)                 die "unknown option '$1' (try --help)" ;;
      *)
        [[ -z "$MODE" ]] || die "only one mode at a time, got '${MODE}' and '$1'"
        MODE="$1"; shift ;;
    esac
  done

  MODE="${MODE:-install}"
  local m found=0
  for m in "${VALID_MODES[@]}"; do [[ "$m" == "$MODE" ]] && found=1; done
  (( found )) || die "unknown mode '${MODE}' - one of: ${VALID_MODES[*]}"

  [[ "$PARALLEL" =~ ^[0-9]+$ ]] && (( PARALLEL >= 1 )) \
    || die "--parallel must be a positive integer, got '${PARALLEL}'"

  if (( NO_PAT )); then
    [[ -z "$PAT_FILE" ]] || die "--no-pat and --pat-file contradict each other"
    case "$MODE" in
      install|reconfigure)
        [[ -z "${GHA_PAT:-}" ]] \
          || warn "--no-pat given: ignoring the GHA_PAT in your environment" ;;
      rotate-pat)
        # Inert here, but saying "never sends a PAT" would read as "you will not
        # be asked for a credential" -- and rotate-pat still needs the NEW one.
        warn "--no-pat governs the admin PAT only; rotate-pat still needs --new-pat-file" ;;
      *)
        warn "--no-pat has no effect on '${MODE}': that mode never sends a PAT anyway" ;;
    esac
  fi
}

# ---------------------------------------------------------------------------
# host selection
# ---------------------------------------------------------------------------
SELECTED=()

select_hosts() {
  local h want matched
  if [[ -z "$LIMIT" ]]; then
    for h in "${HOSTS[@]}"; do
      [[ "$(cfg "$h" enabled true)" == "true" ]] && SELECTED+=("$h") \
        || warn "skipping ${h} (enabled = false)"
    done
  else
    local -a wants=()
    IFS=',' read -r -a wants <<<"$LIMIT"
    for want in "${wants[@]}"; do
      want="$(trim "$want")"
      [[ -n "$want" ]] || continue
      matched=0
      for h in "${HOSTS[@]}"; do
        [[ "$h" == "$want" ]] && { SELECTED+=("$h"); matched=1; break; }
      done
      (( matched )) || die "--limit names '${want}', which is not a host in ${CONFIG}"
    done
  fi
  (( ${#SELECTED[@]} )) || die "no hosts selected"
}

# ---------------------------------------------------------------------------
# per-host environment for the installer
# ---------------------------------------------------------------------------
shq() { printf "'%s'" "${1//\'/\'\\\'\'}"; }   # single-quote for a shell literal

# Emits the `export GHA_*=...` block sourced by the elevated remote shell.
# Everything the wizard would otherwise ask for is answered here, because an
# SSH session without a pty has no terminal for the installer to prompt on.
build_env() { # build_env <host-section>
  local h="$1" scope org repo group labels trust runners old_user force

  # No invented defaults. Since the installer treats its stored answers as
  # defaults rather than overrides, anything emitted here WINS over what the
  # host already has -- so substituting a value fleet.conf never mentioned
  # would silently rewrite that host's configuration. The worst case is
  # `trust`: defaulting it to `internal` would take a box that runs fork PRs
  # and stop it wiping Docker state between jobs, with GHA_YES suppressing
  # every confirmation on the way. An omitted key must therefore mean "leave
  # this alone", which it can only mean by not being sent at all.
  #
  # The corollary: a host that has never been installed needs fleet.conf to
  # answer everything, because the installer has no stored file to fall back
  # to and no terminal to ask on. fleet.conf.example spells out that full set.
  scope="$(cfg "$h" scope)"
  org="$(cfg "$h" org)"
  repo="$(cfg "$h" repo)"
  group="$(cfg "$h" group_id)"
  labels="$(cfg "$h" labels)"
  trust="$(cfg "$h" trust)"
  runners="$(cfg "$h" runners)"
  old_user="$(cfg "$h" old_user)"
  force="$(cfg "$h" force_deprivilege)"

  # Validate what IS set. An unset key is not an error here; it is a decision.
  [[ -z "$scope" ]] || case "$scope" in org|repo) ;;
    *) die "${h}: scope must be 'org' or 'repo', got '${scope}'" ;; esac
  [[ -z "$trust" ]] || case "$trust" in internal|untrusted) ;;
    *) die "${h}: trust must be 'internal' or 'untrusted', got '${trust}'" ;; esac
  [[ -z "$runners" || "$runners" == "auto" || "$runners" =~ ^[0-9]+$ ]] \
    || die "${h}: runners must be a positive integer or 'auto', got '${runners}'"
  [[ -z "$group" || "$group" =~ ^[0-9]+$ ]] \
    || die "${h}: group_id must be a number, got '${group}'"

  # Only `install` and `reconfigure` build a configuration. Every other mode
  # reads the one already on the box, and sending answers would be a lie about
  # what that box is actually configured for.
  if [[ "$MODE" == "install" || "$MODE" == "reconfigure" ]]; then
    # `org` is the one key with no fallback: it is the fleet's identity, and a
    # host cannot be re-registered somewhere the config does not name.
    [[ -n "$org" ]] || die "${h}: 'org' is required for ${MODE}"
    [[ "$scope" == "repo" && -z "$repo" ]] && die "${h}: scope = repo also needs 'repo'"

    printf 'export GHA_ORG=%s\n' "$(shq "$org")"
    [[ -n "$scope" ]]    && printf 'export GHA_SCOPE=%s\n'    "$(shq "$scope")"
    [[ -n "$repo" ]]     && printf 'export GHA_REPO=%s\n'     "$(shq "$repo")"
    [[ -n "$group" ]]    && printf 'export GHA_GROUP_ID=%s\n' "$(shq "$group")"
    [[ -n "$labels" ]]   && printf 'export GHA_LABELS=%s\n'   "$(shq "$labels")"
    [[ -n "$trust" ]]    && printf 'export GHA_TRUST=%s\n'    "$(shq "$trust")"
    [[ -n "$runners" ]]  && printf 'export GHA_COUNT=%s\n'    "$(shq "$runners")"
    [[ -n "$old_user" ]] && printf 'export GHA_OLD_USER=%s\n' "$(shq "$old_user")"
    [[ -n "$force" ]]    && printf 'export GHA_FORCE_DEPRIVILEGE=%s\n' "$(shq "$force")"
    # With --no-pat we send no credential and the host uses the one it stores.
    # Every unattended run reaches it the same way -- should_preload_config
    # returns true for both modes, so load_config reads /etc/github-runner/pat.
    # The wizard's own "Reuse the PAT already stored?" prompt only matters to
    # someone running the installer by hand on the box.
    (( NO_PAT )) || printf 'export GHA_PAT=%s\n' "$(shq "$ADMIN_PAT")"
  fi

  [[ "$MODE" == "rotate-pat" ]] && printf 'export GHA_NEW_PAT=%s\n' "$(shq "$NEW_PAT")"

  # Answers every confirmation the installer would otherwise stop on.
  printf 'export GHA_YES=1\n'
  return 0
}

# ---------------------------------------------------------------------------
# the remote bootstrap
#
# One heredoc-delimited stream, so the installer and the answers travel on the
# connection's stdin rather than in anyone's argv. `bash -c '...' "$d" "$mode"`
# hands the temp path and the mode through $0 and $1, which is what keeps the
# elevated command free of nested quoting.
# ---------------------------------------------------------------------------
build_bootstrap() { # build_bootstrap <host-section>
  local h="$1" become elevate
  become="$(cfg "$h" become auto)"
  case "$become" in
    auto)  [[ "$(cfg "$h" user root)" == "root" ]] && elevate="" || elevate="sudo -n" ;;
    sudo)  elevate="sudo -n" ;;
    none)  elevate="" ;;
    *)     die "${h}: become must be 'auto', 'sudo' or 'none', got '${become}'" ;;
  esac

  cat <<BOOTSTRAP_HEAD
set -eu
umask 077
d=\$(mktemp -d /tmp/.runner-hardening.XXXXXXXX) || exit 1
trap 'rm -rf "\$d"' EXIT INT TERM HUP
base64 -d > "\$d/env" <<'__RH_ENV__'
$(build_env "$h" | base64)
__RH_ENV__
base64 -d > "\$d/harden-gha-runners.sh" <<'__RH_INSTALLER__'
${INSTALLER_B64}
__RH_INSTALLER__
chmod 0600 "\$d/env"
chmod 0700 "\$d/harden-gha-runners.sh"
[ -s "\$d/harden-gha-runners.sh" ] || { echo "fleet: installer did not survive the transfer" >&2; exit 1; }
${elevate} /bin/bash -c '. "\$0/env"; exec "\$0/harden-gha-runners.sh" "\$1"' "\$d" '${MODE}'
BOOTSTRAP_HEAD
}

ssh_args_for() { # ssh_args_for <host-section> -> prints one argument per line
  local h="$1" port key opts
  port="$(cfg "$h" port 22)"
  key="$(cfg "$h" ssh_key)"
  opts="$(cfg "$h" ssh_options)"

  # BatchMode keeps a missing key from turning a 40-host run into 40 password
  # prompts; ConnectTimeout keeps one unreachable box from stalling the batch.
  printf '%s\n' -o BatchMode=yes -o ConnectTimeout=15 -o ServerAliveInterval=30 \
                -o ServerAliveCountMax=6 -p "$port"
  [[ -n "$key" ]] && printf '%s\n' -i "${key/#\~/$HOME}"
  # Word-split on purpose: this is a list of ssh flags, written by the operator.
  [[ -n "$opts" ]] && printf '%s\n' $opts
  return 0
}

# ---------------------------------------------------------------------------
# execution
# ---------------------------------------------------------------------------
run_host() { # run_host <host-section>; writes <log> and <status>
  local h="$1" user host started ended rc=0
  local log="${LOG_DIR}/${h}.log" st="${LOG_DIR}/${h}.status"

  user="$(cfg "$h" user root)"
  host="$(cfg "$h" host "$h")"

  local -a ssh_args=()
  mapfile -t ssh_args < <(ssh_args_for "$h")

  started=$(date +%s)
  {
    echo "=== ${h} (${user}@${host}) mode=${MODE} at $(date -Is) ==="
    echo
  } > "$log"

  ssh "${ssh_args[@]}" "${user}@${host}" bash -s >> "$log" 2>&1 \
    <<<"$(build_bootstrap "$h")" || rc=$?

  ended=$(date +%s)
  printf '%s %s\n' "$rc" "$(( ended - started ))" > "$st"
  return 0
}

main() {
  parse_args "$@"
  parse_config "$CONFIG"
  select_hosts

  [[ -r "$INSTALLER" ]] || die "installer not found at ${INSTALLER} (use --installer)"
  # Ship nothing that would not even parse. A syntax error found here costs one
  # second; found on the far side it costs one broken box per host.
  bash -n "$INSTALLER" || die "${INSTALLER} has a syntax error - refusing to ship it"
  command -v ssh   >/dev/null || die "ssh is not installed"
  command -v base64 >/dev/null || die "base64 is not installed"

  head1 "Fleet ${MODE}"
  printf '  config      %s\n' "$CONFIG"
  printf '  installer   %s  %s\n' "$INSTALLER" \
    "$(sha256sum "$INSTALLER" 2>/dev/null | cut -c1-12 || echo '')"
  printf '  hosts       %d selected, %d at a time\n' "${#SELECTED[@]}" "$PARALLEL"
  echo
  local h
  for h in "${SELECTED[@]}"; do
    printf '    %-18s %s@%s:%s\n' "$h" \
      "$(cfg "$h" user root)" "$(cfg "$h" host "$h")" "$(cfg "$h" port 22)"
  done

  # Validate every host up front. build_bootstrap dies on a bad scope, trust,
  # runner count, group id or become mode - and doing that here means a typo in
  # host 40 is caught before host 1 is touched, instead of half way through a
  # fleet-wide install.
  INSTALLER_B64="$(base64 < "$INSTALLER")"
  for h in "${SELECTED[@]}"; do
    build_bootstrap "$h" >/dev/null
    # Only install/reconfigure send answers, so only they can act on a scope.
    [[ "$MODE" == "install" || "$MODE" == "reconfigure" ]] && warn_config_smells "$h"
  done
  ok "configuration valid for all ${#SELECTED[@]} host(s)"

  if (( DRY_RUN )); then
    echo
    ok "dry run - nothing was contacted"
    return 0
  fi

  # --- secrets, read once and reused for every host ------------------------
  if [[ "$MODE" == "install" || "$MODE" == "reconfigure" ]] && (( ! NO_PAT )); then
    if [[ -n "$PAT_FILE" ]]; then
      [[ -r "$PAT_FILE" ]] || die "cannot read ${PAT_FILE}"
      ADMIN_PAT="$(< "$PAT_FILE")"
    else
      ADMIN_PAT="${GHA_PAT:-}"
    fi
    if [[ -z "$ADMIN_PAT" ]]; then
      echo
      echo "  Needs one of:"
      echo "    - classic PAT with scope ${C_B}admin:org${C_R} (org) or ${C_B}repo${C_R} (single repo)"
      echo "    - fine-grained PAT with ${C_B}Self-hosted runners: Read and write${C_R}"
      read -rsp "${C_CYN}?${C_R} Admin PAT: " ADMIN_PAT; echo
    fi
    # Trailing newlines are the usual result of `gh auth token > file`, and a
    # PAT with one is rejected by the API in a way that reads as "bad token".
    ADMIN_PAT="${ADMIN_PAT%%$'\n'*}"
    [[ -n "$ADMIN_PAT" ]] || die "no PAT supplied"
  fi
  if [[ "$MODE" == "rotate-pat" ]]; then
    if [[ -n "$NEW_PAT_FILE" ]]; then
      [[ -r "$NEW_PAT_FILE" ]] || die "cannot read ${NEW_PAT_FILE}"
      NEW_PAT="$(< "$NEW_PAT_FILE")"
    else
      NEW_PAT="${GHA_NEW_PAT:-}"
    fi
    if [[ -z "$NEW_PAT" ]]; then
      read -rsp "${C_CYN}?${C_R} New admin PAT: " NEW_PAT; echo
    fi
    NEW_PAT="${NEW_PAT%%$'\n'*}"
    [[ -n "$NEW_PAT" ]] || die "no replacement PAT supplied"
  fi

  # --- confirmation --------------------------------------------------------
  if (( ! ASSUME_YES )); then
    echo
    case "$MODE" in
      uninstall)
        warn "'uninstall' removes every runner, user and home this installer created,"
        warn "on all ${#SELECTED[@]} selected host(s). There is no undo."
        read -rp "${C_CYN}?${C_R} Type 'uninstall' to confirm: " reply
        [[ "$reply" == "uninstall" ]] || die "aborted, nothing was contacted" ;;
      install|reconfigure|sandbox-off|updates|retune|rotate-pat)
        read -rp "${C_CYN}?${C_R} Run '${MODE}' on ${#SELECTED[@]} host(s)? [y/N]: " reply
        [[ "${reply,,}" == y* ]] || die "aborted, nothing was contacted" ;;
      *) ;;   # audit, verify, diagnose, reap, version: read-mostly, just go
    esac
  fi

  LOG_DIR="${LOG_DIR:-${PWD}/.fleet-logs/$(date +%Y%m%d-%H%M%S)-${MODE}}"
  mkdir -p "$LOG_DIR"
  echo
  log "logs: ${LOG_DIR}"

  # --- fan out, bounded ----------------------------------------------------
  local -a pids=()
  for h in "${SELECTED[@]}"; do
    while (( $(jobs -pr | wc -l) >= PARALLEL )); do sleep 0.2; done
    run_host "$h" &
    pids+=("$!")
    printf '  %s started%s %s\n' "$C_DIM" "$C_R" "$h"
  done
  # Statuses come from the per-host files, so a non-zero child here is not an
  # error to propagate - it is the report we are about to print.
  wait "${pids[@]}" || true

  # --- report --------------------------------------------------------------
  head1 "Result"
  local failed=0 rc secs status
  for h in "${SELECTED[@]}"; do
    read -r rc secs < "${LOG_DIR}/${h}.status" 2>/dev/null || { rc=255; secs=0; }
    if [[ "$rc" == "0" ]]; then
      status="${C_GRN}ok${C_R}"
    else
      status="${C_RED}FAILED (exit ${rc})${C_R}"
      failed=$(( failed + 1 ))
    fi
    printf '  %-18s %-28s %4ss  %s\n' "$h" "$status" "$secs" \
      "${C_DIM}${LOG_DIR}/${h}.log${C_R}"
  done

  echo
  if (( failed )); then
    err "${failed}/${#SELECTED[@]} host(s) failed - read the logs above"
    echo "  ${C_DIM}Most failures are one of: SSH key not authorised, sudo needs a"
    echo "  password (become = sudo requires NOPASSWD), or the admin PAT lacks"
    echo "  runner-admin permission. The installer prints which one.${C_R}"
    if (( NO_PAT )); then
      echo "  ${C_DIM}With --no-pat, 'no terminal available' means that host has no PAT at"
      echo "  /etc/github-runner/pat yet -- it has never been installed. Give it one"
      echo "  with --pat-file on its first run. Every other unattended answer now"
      echo "  has a default or its own error message.${C_R}"
    fi
    return 1
  fi
  ok "${C_B}all ${#SELECTED[@]} host(s) completed '${MODE}'${C_R}"
  return 0
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
