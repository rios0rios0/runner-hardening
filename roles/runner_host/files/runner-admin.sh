#!/usr/bin/env bash
#
# <sbin>-admin - look after the runners on this box: check them, explain them,
# drain them. Installed 0700 root by the runner_host role from
# roles/runner_host/files/runner-admin.sh; the modes are in usage() below.
#
# Every mode reads /etc/runner-hardening/host.env, so the one script serves
# every flavour. What only a flavour knows comes from its vendor.sh hooks.
set -Eeuo pipefail
umask 022   # deterministic modes for the drop-ins written here

# shellcheck source=lib.sh
. "${RUNNER_LIB_DIR:-/usr/local/lib/runner-hardening}/lib.sh"

usage() {
  local me="${0##*/}"
  cat <<EOF
usage: ${me} [--yes] <mode> [arguments]

  verify          post-flight checks; exits non-zero when any fails
  diagnose        everything needed to work out why a runner will not stay up
  audit           persistence surfaces a root-capable job could have used
  sandbox-probe   which systemd directive breaks a job?
  sandbox-relax   clear the seccomp-bearing directives, keep the confinement
  sandbox-off     strip the sandbox down to the unprivileged user (diagnostic)
  reap            delete registrations this host leaked, where the flavour leaks any
  drain [n...]    let each runner finish the job it is on, then keep it down
  undrain [n...]  put drained runners back the way they were
  restart-idle    reload systemd, then restart every runner not running a job
  busy <n>        exit 0 when runner n is running a job, 1 when it is idle
  instances       the instance numbers this box has, one per line

--yes answers every confirmation. Without it a question is asked on the
terminal, and with no terminal (a run from Ansible) takes its own default.
With no numbers, drain takes every instance and undrain every drained one.
EOF
}

require_root() { [[ $EUID -eq 0 ]] || die "run as root"; }

check_instance() { [[ "$1" =~ ^[1-9][0-9]*$ ]] || die "not an instance number: '$1'"; }

# ===========================================================================
# VERIFY
# ===========================================================================

# One filesystem's line in `verify`; returns 1 past the hard threshold. Given
# numbers, not a df to ask, so the split-disk case is testable on a box with
# one disk. <caches> is 1 when runner caches live on it, the only thing the
# disk guard frees. A separate /var holds the jobs' temp files but no cache, so
# its warning must not promise the sweep.
report_disk() { # report_disk <mount> <pct> <soft> <hard> <caches>
  local mnt="$1" pct="$2" soft="$3" hard="$4" caches="$5"
  if (( pct >= hard )); then
    err "disk ${pct}% full on ${mnt} - past the ${hard}% hard threshold, jobs are about to fail with ENOSPC"
    return 1
  elif (( pct < soft )); then
    ok "disk ${pct}% full on ${mnt}"
  elif (( caches )); then
    warn "disk ${pct}% full on ${mnt} - past ${soft}%, so each runner frees its own caches before its next job"
  else
    warn "disk ${pct}% full on ${mnt} - past ${soft}%; it takes the jobs' temp files but holds no runner cache, so the disk guard frees nothing here"
  fi
}

mode_verify() {
  head1 "Verification"
  local fail=0 n u uid g bad ou st sub res code fails out
  local -a olds=()

  read -ra olds <<<"$RUNNER_OLD_USERS"
  for ou in ${olds[@]+"${olds[@]}"}; do
    [[ "$ou" == "none" ]] && continue
    id "$ou" &>/dev/null || continue
    bad=0
    for g in sudo docker lxd adm; do
      if id -nG "$ou" | tr ' ' '\n' | grep -qx "$g"; then
        err "${ou} is STILL in group ${g}"; bad=1; fail=1
      fi
    done
    (( bad )) || ok "${ou} holds no privileged groups"
  done

  if systemctl is-active --quiet docker.service 2>/dev/null; then
    err "rootful docker.service is running - jobs can still find a root socket"; fail=1
  else
    ok "no rootful docker daemon"
  fi

  # Measured where the runners keep their caches, and where their jobs keep
  # temp files. Past the soft threshold each runner empties its own caches
  # before its next job, so a disk that is still past the hard one means that
  # is not keeping up - and a box can be one large job from failing every job
  # with ENOSPC while every other check here is green.
  local soft="$RUNNER_DISK_SOFT" hard="$RUNNER_DISK_HARD" mnt pct
  local -A cached=()
  while read -r mnt; do cached[$mnt]=1; done \
    < <(df --output=target "$RUNNER_HOME_ROOT" "$RUNNER_BASE" 2>/dev/null | tail -n +2)
  while read -r mnt pct; do
    pct="${pct//%/}"
    [[ "$pct" =~ ^[0-9]+$ ]] || continue
    report_disk "$mnt" "$pct" "$soft" "$hard" "${cached[$mnt]:-0}" || fail=1
  done < <(df --output=target,pcent "$RUNNER_HOME_ROOT" "$RUNNER_BASE" /var/tmp 2>/dev/null | tail -n +2 | sort -u)

  # OOMPolicy=continue lets an OOM kill fail the job's step and leaves the unit
  # up, so no unit result records one any more - the kernel log still does. A
  # warning, not a failure: the box is fine, a job was not. Counted in the
  # runner units and in the runners' own slices, where container jobs live.
  local uids="" ooms
  for n in $(seq 1 "$RUNNER_COUNT"); do
    uid=$(runner_uid "$n") && uids+="${uids:+|}${uid}" || true
  done
  ooms=$(journalctl -k --since -24h --no-pager -o cat 2>/dev/null | grep -F 'oom-kill:constraint' \
         | grep -cE "task_memcg=/(${RUNNER_SLICE//./\\.}/|user\.slice/user-(${uids:-none})\.slice/)" || true)
  [[ "$ooms" =~ ^[0-9]+$ ]] || ooms=0
  if (( ooms > 0 )); then
    warn "${ooms} job process(es) OOM-killed on this box in the last 24h (journalctl -k -g oom-kill)"
    warn "  jobs are outgrowing the memory they share - see runner_heavy_runners and runner_codeql_ram"
  else
    ok "no job OOM-killed on this box in the last 24h"
  fi

  for n in $(seq 1 "$RUNNER_COUNT"); do
    u=$(runner_user "$n"); uid=$(runner_uid "$n" || true)
    if [[ -z "$uid" ]]; then err "${u} missing"; fail=1; continue; fi
    if id -nG "$u" | tr ' ' '\n' | grep -qxE 'sudo|docker|lxd'; then
      err "${u} sits in a privileged group"; fail=1
    fi
    if [[ -S "/run/user/${uid}/docker.sock" ]]; then
      ok "${u}: rootless docker socket present"
    else
      err "${u}: no rootless docker socket"; fail=1
    fi
    if has_hook vendor_registered && ! vendor_registered "$n"; then
      warn "${RUNNER_UNIT}@${n}: not registered yet - it has nothing to run"
      continue
    fi
    if systemctl is-active --quiet "$(unit_of "$n")"; then
      ok "${RUNNER_UNIT}@${n}: active"
    elif runner_unit_healthy "$n"; then
      ok "${RUNNER_UNIT}@${n}: restarting between jobs (activating/$(unit_prop "$n" SubState), last exit 0)"
    else
      # Report what systemd actually says. "inactive", "failed" and a restart
      # that followed a failing run are three different diagnoses, and only
      # these numbers tell them apart.
      st=$(unit_prop "$n" ActiveState); sub=$(unit_prop "$n" SubState)
      res=$(unit_prop "$n" Result); code=$(unit_prop "$n" ExecMainStatus)
      err "${RUNNER_UNIT}@${n}: ${st}/${sub}  result=${res}  exit=${code}"
      fail=1
      echo "${C_DIM}      --- last 15 journal lines ---${C_R}"
      journalctl -u "$(unit_of "$n")" -n 15 --no-pager -o cat 2>/dev/null \
        | sed 's/^/      /' || echo "      (no journal)"
      echo "${C_DIM}      -----------------------------${C_R}"
    fi
    # To systemd, a runner that keeps failing to start looks like one between
    # jobs - a clean exit, then auto-restart - because run-helper exits 0 even
    # on a terminated error. The job-less count the unit's ExecStopPost keeps
    # is what gives it away.
    fails=$(cat "$(run_dir)/${n}.fails" 2>/dev/null || echo 0)
    [[ "$fails" =~ ^[0-9]+$ ]] || fails=0
    if (( fails >= 3 )); then
      err "${RUNNER_UNIT}@${n}: its last ${fails} starts ran no job - now waiting $(restart_backoff_delay "$fails")s between attempts (see: ${0##*/} diagnose)"
      fail=1
    fi
  done

  # Prove the socket is genuinely rootless: uid 0 inside must not be root outside.
  uid=$(runner_uid 1 || true)
  if [[ -n "$uid" && -S "/run/user/${uid}/docker.sock" ]]; then
    log "escape test: writing to /etc from inside a container"
    out=$(as_runner 1 timeout 120 docker run --rm -v /etc:/host-etc:ro alpine:latest \
          sh -c 'touch /host-etc/pwned 2>&1 || echo DENIED' 2>&1 || true)
    if grep -qiE 'denied|read-only' <<<"$out"; then
      ok "container root cannot write to the host filesystem"
    elif grep -qi 'unable to find image\|pull access\|timeout' <<<"$out"; then
      warn "escape test inconclusive (image pull failed) - re-run 'verify' later"
    else
      err "a container reached the host filesystem - do not use this box"; fail=1
    fi
  fi

  # What only the flavour can check: does the service see these runners?
  if has_hook vendor_verify; then vendor_verify || fail=1; fi

  echo
  if (( fail == 0 )); then ok "${C_B}all checks passed${C_R}"; else err "${C_B}checks failed - see above${C_R}"; fi
  return "$fail"
}

# ===========================================================================
# DIAGNOSE - everything needed to work out why a runner will not stay up
# ===========================================================================
mode_diagnose() {
  head1 "Diagnostics"
  # Purely informational: every probe may come back empty or non-zero.
  set +e +o pipefail
  local n u uid d diag pp

  echo "${C_B}host${C_R}"
  printf '    %s | kernel %s | %s\n' "$(hostname -s)" "$(uname -r)" \
    "$( . /etc/os-release 2>/dev/null; echo "${PRETTY_NAME:-?}" )"

  # A full disk fails jobs in ways that look like anything but a full disk: a
  # crashed listener, a container that cannot be saved, a tool that dies
  # mid-unpack. Each runner keeps its own warm caches, so name their size.
  echo
  echo "${C_B}disk${C_R}"
  df -h "$RUNNER_HOME_ROOT" "$RUNNER_BASE" 2>/dev/null | awk '!seen[$0]++' | sed 's/^/    /'
  for n in $(seq 1 "$RUNNER_COUNT"); do
    printf '    runner %s: home %s, tool cache %s\n' "$n" \
      "$(timeout 120 du -sxh "$(runner_home "$n")" 2>/dev/null | cut -f1)" \
      "$(timeout 120 du -sxh "$(runner_toolcache "$n")" 2>/dev/null | cut -f1)"
  done
  echo "    ${C_DIM}latest disk-guard actions (journalctl -t ${RUNNER_SBIN_PREFIX}-diskguard):${C_R}"
  journalctl -t "${RUNNER_SBIN_PREFIX}-diskguard" -n 8 --no-pager -o short-iso 2>/dev/null | sed 's/^/      /'

  for n in $(seq 1 "$RUNNER_COUNT"); do
    u=$(runner_user "$n"); uid=$(runner_uid "$n"); d=$(runner_dir "$n")
    echo
    echo "${C_B}${RUNNER_UNIT}@${n}${C_R}"
    printf '    state   : %s / %s   result=%s exit=%s restarts=%s job-less starts in a row=%s\n' \
      "$(unit_prop "$n" ActiveState)" "$(unit_prop "$n" SubState)" "$(unit_prop "$n" Result)" \
      "$(unit_prop "$n" ExecMainStatus)" "$(unit_prop "$n" NRestarts)" \
      "$(cat "$(run_dir)/${n}.fails" 2>/dev/null || echo 0)"
    printf '    user    : %s (uid %s)\n' "$u" "${uid:-MISSING}"
    printf '    socket  : %s\n' "$( [[ -S /run/user/${uid}/docker.sock ]] && echo present || echo MISSING )"
    printf '    runner  : %s\n' "$(stat -c '%a %U:%G' "${d}/run.sh" 2>/dev/null || echo MISSING)"
    if has_hook vendor_diagnose; then vendor_diagnose "$n"; fi
    printf '    chdir as %s: %s\n' "$u" \
      "$(runuser -u "$u" -- test -x "$d" 2>/dev/null && echo OK || echo "DENIED  <-- this is a CHDIR/exit-200 failure")"
    echo "    ${C_DIM}path components (first one without o+x is the culprit):${C_R}"
    if command -v namei >/dev/null; then
      namei -l "${d}/run.sh" 2>/dev/null | sed 's/^/      /'
    else
      pp="$d"
      while [[ "$pp" != "/" ]]; do
        printf '      %s  %s\n' "$(stat -c '%A %U:%G' "$pp" 2>/dev/null)" "$pp"; pp=$(dirname "$pp")
      done
    fi

    echo "    ${C_DIM}last 25 journal lines:${C_R}"
    journalctl -u "$(unit_of "$n")" -n 25 --no-pager -o cat 2>/dev/null | sed 's/^/      /'

    # The runner writes its real errors here, not to the journal.
    # shellcheck disable=SC2012  # newest first; these names never hold a newline
    diag=$(ls -t "${d}"/_diag/*.log 2>/dev/null | head -1)
    if [[ -n "$diag" ]]; then
      echo "    ${C_DIM}tail of $(basename "$diag"):${C_R}"
      tail -n 25 "$diag" 2>/dev/null | sed 's/^/      /'
    else
      echo "    ${C_DIM}no _diag logs - the runner never got far enough to write one${C_R}"
    fi
  done

  # The flavour's own: its binary, and how to reproduce a start by hand.
  if has_hook vendor_diagnose; then vendor_diagnose; fi
  set -eo pipefail
  return 0
}

# ===========================================================================
# AUDIT - persistence surfaces a root-capable job could have used
# ===========================================================================
mode_audit() {
  head1 "Audit - persistence surfaces a root-capable job could have used"
  # Purely informational. Every probe here is allowed to come back empty or
  # non-zero (no sudoers.d, no cron, no out-of-tree modules), and under
  # `set -e -o pipefail` any of those would otherwise abort the run.
  set +e +o pipefail
  local f shown g m u c
  local -a olds=()
  read -ra olds <<<"${RUNNER_OLD_USERS:-}"

  echo "${C_B}privileged group membership${C_R}"
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
  for u in root ${olds[@]+"${olds[@]}"}; do
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
  # which flooded an earlier run with false positives. Pruning is faster too.
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
  warn "Reimaging is the only clean remediation; the converge is what you run after."
  set -eo pipefail
  return 0
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
  local unit pr v
  unit=$(unit_of 1)
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
  local u="$1" dir="$2" pr
  shift 2
  local -a args=(--quiet --wait --pipe --collect
                 --property=User="$u" --property=Group="$u"
                 --property=WorkingDirectory="$dir"
                 --property=ReadWritePaths="$dir")
  for pr in "$@"; do args+=(--property="$pr"); done
  systemd-run "${args[@]}" -- /bin/bash -c \
    "rm -rf '${dir}/out' && mkdir -p '${dir}/out' && tar -xzf '${dir}/payload.tar.gz' -C '${dir}/out'" \
    >/dev/null 2>&1
}

mode_sandbox_probe() {
  head1 "Sandbox probe"
  command -v systemd-run >/dev/null || die "systemd-run not available"
  local u dir build prop i j
  u=$(runner_user 1); dir="$(runner_dir 1)/.probe"
  id "$u" &>/dev/null || die "${u} does not exist - converge this host first"

  # A payload shaped like the archive that failed: a dot-directory, nested
  # dot-directories, and files inside them.
  rm -rf "${dir:?}"; install -d -m 0755 -o "$u" -g "$u" "$dir"
  build="${dir}/src/sample-action/.docs/examples/sample/.github/workflows"
  install -d -m 0755 "$build"
  echo "x" > "${build}/ci.yaml"
  echo "y" > "${dir}/src/sample-action/.docs/readme.md"
  tar -czf "${dir}/payload.tar.gz" -C "${dir}/src" sample-action
  rm -rf "${dir}/src"
  chown -R "$u:$u" "$dir"
  ok "payload built (mirrors the failing action tarball)"

  echo
  log "what the LIVE unit is actually enforcing right now"
  for prop in SystemCallFilter SystemCallErrorNumber RestrictSUIDSGID ProtectClock \
              ProtectKernelModules ProtectKernelLogs LockPersonality ProtectSystem \
              ReadWritePaths NoNewPrivileges CapabilityBoundingSet; do
    printf '    %-24s %s\n' "$prop" "$(unit_prop 1 "$prop" | cut -c1-90)"
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
  log "extraction OUTSIDE systemd entirely (a plain privilege drop)"
  if as_runner 1 bash -c "rm -rf '${dir}/out2' && mkdir -p '${dir}/out2' && tar -xzf '${dir}/payload.tar.gz' -C '${dir}/out2'" 2>/dev/null; then
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
    echo "    ${C_CYN}a converge${C_R}             (rewrites the base unit)"
  fi
  rm -rf "${dir:?}"
}

# Drop a per-instance override neutralising the seccomp-bearing directives,
# keeping the filesystem isolation (which is what actually contains a job).
mode_sandbox_relax() {
  head1 "Relaxing the seccomp directives"
  local n d v up=0 bad=0
  for n in $(seq 1 "$RUNNER_COUNT"); do
    install -d -m 0755 "$(dropin_dir "$n")"
    cat > "$(dropin_dir "$n")/20-sandbox-relax.conf" <<'EOF'
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
    chmod 0644 "$(dropin_dir "$n")/20-sandbox-relax.conf"
  done
  systemctl daemon-reload
  for n in $(seq 1 "$RUNNER_COUNT"); do
    systemctl restart "$(unit_of "$n")" 2>/dev/null || true
  done
  sleep 6
  for n in $(seq 1 "$RUNNER_COUNT"); do
    runner_unit_healthy "$n" && up=$(( up + 1 )) || true
  done
  ok "${up}/${RUNNER_COUNT} runners back up"

  # Verify the drop-in actually landed. An unparseable line is ignored in
  # silence, which is exactly how an earlier version appeared to succeed
  # while changing nothing.
  for d in RestrictSUIDSGID ProtectClock ProtectKernelModules LockPersonality; do
    v=$(unit_prop 1 "$d")
    if [[ "$v" == "yes" ]]; then err "  ${d} is STILL yes - the override did not apply"; bad=1
    else ok "  ${d}=${v:-no}"; fi
  done
  if (( bad )); then
    err "Re-converge the host instead - it rewrites the base unit without these."
    return 1
  fi
  echo
  echo "  ${C_DIM}Still enforced: unprivileged user, read-only filesystem outside${C_R}"
  echo "  ${C_DIM}ReadWritePaths, no capabilities, no new privileges, private /tmp.${C_R}"
}

# Strip the sandbox down to the unprivileged user. This is a diagnostic and an
# emergency unblock, not a destination: if CI works after this, the fault is
# definitively in the unit's hardening, and sandbox-probe will name which part.
mode_sandbox_off() {
  head1 "Disabling the systemd sandbox (diagnostic)"
  warn "This keeps ONLY: dedicated unprivileged user, no sudo, no docker group,"
  warn "rootless Docker, ephemeral runners."
  warn "It drops the filesystem and syscall confinement. Use it to confirm the"
  warn "cause, then put the sandbox back with: ${0##*/} sandbox-relax"
  echo
  confirm "Proceed?" n || { warn "aborted (with no terminal, pass --yes)"; return 0; }

  local n u uid up=0
  for n in $(seq 1 "$RUNNER_COUNT"); do
    u=$(runner_user "$n")
    uid=$(runner_uid "$n") || { warn "${u} missing - skipped"; continue; }
    install -d -m 0755 "$(dropin_dir "$n")"
    cat > "$(dropin_dir "$n")/30-sandbox-off.conf" <<EOF
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
    chmod 0644 "$(dropin_dir "$n")/30-sandbox-off.conf"
  done
  systemctl daemon-reload
  for n in $(seq 1 "$RUNNER_COUNT"); do systemctl restart "$(unit_of "$n")" 2>/dev/null || true; done
  sleep 6
  for n in $(seq 1 "$RUNNER_COUNT"); do
    runner_unit_healthy "$n" && up=$(( up + 1 )) || true
  done
  ok "${up}/${RUNNER_COUNT} runners up with the sandbox disabled"
  echo
  echo "  Re-run the failing job now."
  echo "    ${C_CYN}still fails${C_R} -> not the sandbox; it is the filesystem or kernel"
  echo "    ${C_CYN}now passes${C_R}  -> it IS the sandbox; run sandbox-probe to name the directive"
  echo
  echo "  Undo with: ${C_CYN}rm -f ${RUNNER_SYSTEMD_DIR}/${RUNNER_UNIT}@*.service.d/30-sandbox-off.conf${C_R}"
  echo "             ${C_CYN}systemctl daemon-reload && systemctl restart '${RUNNER_UNIT}@*'${C_R}"
  echo "  or re-converge the host, which removes it."
}

# ===========================================================================
# REAP - registrations a flavour leaks, where it leaks any
# ===========================================================================
mode_reap() {
  if has_hook vendor_reap; then
    vendor_reap
  else
    ok "nothing to reap: ${RUNNER_FLAVOR:-this flavour} leaves no registrations behind"
  fi
}

# ===========================================================================
# DRAIN, UNDRAIN - taking runners down without killing the job they are on
#
# A converge that replaces a runner tree, or anything else that must not race
# a job writing into it, takes the runner down first, and gracefully: a job
# that is already running is finished, not killed. Left running, a job writing
# into _work races rm's own recursion, rm exits "Directory not empty", and the
# change aborts half way.
#
# Undrain is what puts them back if that later fails. Without it, any failure
# after the drain - a lost apt lock, a bad token, a full disk - would leave
# the drained units with Restart=no and the box out of the pool, which is a far
# worse outcome than the failure itself. The drop-in records whether its unit
# was up, so that a separate run, long after this one exited, still knows.
# ===========================================================================
DRAIN_CONF="40-drain.conf"

write_drain_dropin() { # write_drain_dropin <n> <yes|no: was the unit up>
  local d f
  d=$(dropin_dir "$1"); f="${d}/${DRAIN_CONF}"
  # A second drain keeps the first one's record: by now the runner is down
  # because of that drain, and recording "no" would keep it down for good.
  [[ -e "$f" ]] && return 0
  install -d -m 0755 "$d"
  cat > "$f" <<EOF
# Written by ${0##*/} drain. Restart=no lets this runner finish the job it is
# on and then stay down; ${0##*/} undrain, or the next converge, removes it.
# was-up=$2
[Service]
Restart=no
EOF
  chmod 0644 "$f"
}

mode_drain() {
  local -a inst=("$@")
  local n deadline
  (( ${#inst[@]} )) || mapfile -t inst < <(existing_instances)
  (( ${#inst[@]} )) || { ok "no runners of ours to drain"; return 0; }
  for n in "${inst[@]}"; do check_instance "$n"; done

  # Restart=always would bring a unit straight back the moment its job ends, so
  # taking the restart away is the only way to let a job finish and then STAY
  # finished. 40- sorts after every other drop-in, which is what makes it the
  # one systemd reads last and therefore the one that wins.
  #
  # Every instance named gets the drop-in - none of them may spring back while
  # whatever needed them down runs - but only the ones that were UP are
  # recorded as such and started again by undrain. A stale instance a larger
  # count left loaded is drained like the rest, and starting it again on the way
  # out would put back a runner this box is no longer configured to have.
  for n in "${inst[@]}"; do
    case "$(unit_prop "$n" ActiveState)" in
      active|activating|reloading) write_drain_dropin "$n" yes ;;
      *)                           write_drain_dropin "$n" no ;;
    esac
  done
  systemctl daemon-reload

  log "draining ${#inst[@]} runner(s): letting each finish the job it is on"
  log "  budget ${RUNNER_DRAIN_TIMEOUT}s in total - raise it with runner_drain_timeout"
  deadline=$(( $(date +%s) + RUNNER_DRAIN_TIMEOUT ))
  for n in "${inst[@]}"; do
    if runner_busy "$n"; then
      log "runner ${n} is mid-job, waiting"
      while runner_busy "$n"; do
        if (( $(date +%s) >= deadline )); then
          warn "drain budget spent and runner ${n} is still working - stopping it anyway"
          warn "  that job will fail; re-run it once this finishes"
          break
        fi
        sleep 5
      done
    fi
    # Idle now (or out of budget): stopping is instant and takes nothing with it.
    systemctl stop "$(unit_of "$n")" 2>/dev/null || true
    ok "runner ${n} drained"
  done
  ok "all ${#inst[@]} runner(s) down - nothing is writing to their trees"
}

mode_undrain() {
  local -a inst=("$@") up=()
  local n f
  if (( ${#inst[@]} == 0 )); then
    # Globbed rather than counted: a converge that lowered the count still has
    # to clear the instances the new count no longer names.
    for f in "${RUNNER_SYSTEMD_DIR}/${RUNNER_UNIT}"@*.service.d/"${DRAIN_CONF}"; do
      [[ -e "$f" ]] || continue
      n="${f%.service.d/*}"; n="${n##*@}"
      if [[ "$n" =~ ^[1-9][0-9]*$ ]]; then inst+=("$n"); fi
    done
  fi
  (( ${#inst[@]} )) || { ok "no drained runners to restore"; return 0; }
  warn "restoring the runners drained earlier"
  for n in "${inst[@]}"; do
    check_instance "$n"
    f="$(dropin_dir "$n")/${DRAIN_CONF}"
    [[ -e "$f" ]] || continue
    if grep -qx '# was-up=yes' "$f"; then up+=("$n"); fi
    rm -f "$f"
  done
  systemctl daemon-reload
  for n in ${up[@]+"${up[@]}"}; do
    if systemctl start "$(unit_of "$n")" 2>/dev/null; then
      ok "runner ${n} started again"
    else
      warn "runner ${n} did not start - see: ${0##*/} diagnose"
    fi
  done
  ok "undrained ${#inst[@]} runner(s)"
}

# ===========================================================================
# RESTART-IDLE - what a converge does after it changed a unit, a drop-in or a
# script these units run
#
# An ephemeral unit restarts after every job anyway, so a busy runner picks
# up the new definition on its own once its job is over, and only an idle one
# needs restarting now: a configuration change never waits on a drain, and
# never kills a job.
#
# Only a unit that is up and idle is touched: active/running with no worker,
# or activating/auto-restart, the moment between two jobs. A unit that is
# stopped stays stopped (a CI converge installs units without ever starting
# them). One in its ExecStartPre or ExecStopPost steps is left alone too: that
# is the disk guard deleting, or the backoff waiting, and either picks the
# change up when the unit next starts. A drained one stays down. try-restart,
# so a unit that stopped between the look and the restart is not started.
#
# stdout carries one `restarted <n>` line per instance restarted, and nothing
# else: the converge counts those lines to report the handler as changed or
# not. Everything else goes to stderr.
# ===========================================================================
mode_restart_idle() {
  local n rc
  systemctl daemon-reload
  while read -r n; do
    if [[ -e "$(dropin_dir "$n")/${DRAIN_CONF}" ]]; then
      warn "runner ${n}: drained - left down" >&2
      continue
    fi
    case "$(unit_prop "$n" ActiveState)/$(unit_prop "$n" SubState)" in
      active/running|activating/auto-restart*) ;;
      *) continue ;;
    esac
    # Asked again right before the restart, not once up front: a job handed
    # over in between must not be the one this kills.
    rc=0; runner_busy "$n" || rc=$?
    if (( rc == 0 )); then
      warn "runner ${n}: running a job - it restarts onto the new definition after it" >&2
      continue
    elif (( rc > 1 )); then
      warn "runner ${n}: cannot tell whether it is running a job - left alone" >&2
      continue
    fi
    if systemctl try-restart "$(unit_of "$n")" 2>/dev/null; then
      printf 'restarted %s\n' "$n"
    else
      warn "runner ${n}: restart failed - see: ${0##*/} diagnose" >&2
    fi
  done < <(existing_instances)
}

mode_busy() {
  local rc=0
  [[ $# -eq 1 ]] || die "usage: ${0##*/} busy <n>"
  check_instance "$1"
  runner_busy "$1" || rc=$?
  case "$rc" in 0) echo busy ;; 1) echo idle ;; *) echo unknown ;; esac
  return "$rc"
}

mode_instances() { existing_instances; }

# ===========================================================================
# MAIN
# ===========================================================================
declare -A MODES=(
  [verify]=mode_verify
  [diagnose]=mode_diagnose
  [audit]=mode_audit
  [sandbox-probe]=mode_sandbox_probe
  [sandbox-relax]=mode_sandbox_relax
  [sandbox-off]=mode_sandbox_off
  [reap]=mode_reap
  [drain]=mode_drain
  [undrain]=mode_undrain
  [restart-idle]=mode_restart_idle
  [busy]=mode_busy
  [instances]=mode_instances
)

# ASSUME_YES is read by confirm, in lib.sh.
# shellcheck disable=SC2034
main() {
  local a mode handler
  local -a args=()
  ASSUME_YES=0
  for a in "$@"; do
    case "$a" in
      -y|--yes)       ASSUME_YES=1 ;;
      -h|--help|help) usage; return 0 ;;
      *)              args+=("$a") ;;
    esac
  done
  mode="${args[0]:-}"
  [[ -n "$mode" ]] || { usage >&2; return 2; }
  handler="${MODES[$mode]:-}"
  [[ -n "$handler" ]] || die "unknown mode '${mode}' - see: ${0##*/} --help"

  require_root
  # Never let the directory this happens to be run from influence it.
  cd /
  # audit is the one mode that runs on a first install, before the converge
  # has written host.env; it reads nothing it needs from there.
  if ! load_host_env && [[ "$mode" != "audit" ]]; then
    die "cannot read ${RUNNER_HOST_ENV:-/etc/runner-hardening/host.env} - converge this host first"
  fi
  load_vendor
  use_colour
  "$handler" "${args[@]:1}"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
