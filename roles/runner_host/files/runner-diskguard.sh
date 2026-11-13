#!/usr/bin/env bash
#
# <sbin>-diskguard <n> - runs as root from ExecStartPre=-+, before the unit's
# registration step (gha-jitconfig, azp-cycle pre). Installed by the
# runner_host role from roles/runner_host/files/runner-diskguard.sh; change it
# there, not on a box.
#
# DISK GUARD - bounded caches, enforced between jobs
#
# trust=internal keeps a runner's caches from one job to the next on purpose,
# and there are three of them: $HOME (every package manager's cache, and the
# SDKs some setup-* actions unpack there), the hosted tool cache, and the
# rootless Docker store. Nothing bounded the first two - the janitor only ever
# pruned Docker - and every runner keeps a private copy of all three. On a busy
# fleet that reached tens of GB per runner, most of it superseded tool versions
# no job had read in weeks, and it filled the disk.
#
# The guard runs as ExecStartPre, before the registration is minted: the one
# moment its runner is guaranteed idle, because the last job is over and no
# new one can be assigned to a runner that is not registered yet. So it can
# delete caches outright, which the daily janitor, racing live jobs, cannot.
#
# trust=untrusted keeps no caches on purpose, and the same moment serves it:
# there the guard resets the runner in full before every job, disk or no disk,
# so nothing a fork PR leaves in $HOME or the tool cache reaches the next job.
#
# A no-op until the disk holding this runner's caches reaches the soft
# threshold. Past it, frees space from THIS runner's caches, cheapest loss
# first, measuring again after every step and stopping as soon as the disk is
# back under the threshold. An untrusted runner is reset in full before every
# job instead. Never fails the unit: a cold cache beats a runner that will not
# start.
#
# RUNNER_WORK_POLICY says what a runner's _work is. `wipe` (GitHub): one job's
# workspace, which the wrapper deletes before every job anyway, so a leftover
# one is the cheapest thing to lose. `lru` (Azure Pipelines): the agent keeps
# _work between jobs on purpose, so it is a cache like the others, evicted
# stale entry by stale entry and dropped whole only once cheaper losses were
# not enough.
set -uo pipefail
export LC_ALL=C

# shellcheck source=lib.sh
. "${RUNNER_LIB_DIR:-/usr/local/lib/runner-hardening}/lib.sh" || exit 0

# All a reset keeps of $HOME: the rootless daemon's user unit (put back from a
# root-owned copy before every untrusted job: see restore_unit), the link that
# enables it, and its data root (emptied through Docker, never with rm under a
# running daemon). Nothing broader. A job can write anywhere in $HOME, and a
# Docker CLI plugin, a credential helper, a user unit beside the daemon's or a
# rewritten .profile, kept here, would run in the next job. Nothing else is
# needed either: jobs, the wrapper and this script all pass DOCKER_HOST.
#
# RUNNER_HOME_KEEP adds to this list, never replaces it: the paths an operator
# chose to carry over (runner_home_keep_extra, and every runner_home_seed key).
# Each is as much a way into the next job as anything above; it survives
# because somebody decided so.
KEEP_BASE=(.config/systemd/user/docker.service
           .config/systemd/user/default.target.wants/docker.service
           .local/share/docker)
KEEP=()
# Judged child by child rather than whole: ~/.cache holds a dozen unrelated
# tools' caches, and one of them in daily use must not keep the rest alive.
SPLIT=(.cache)
declare -A WHERE=()
STEPS=()

log() { echo "${0##*/}[${N:-?}]: $*"; }

use_pct()  { local p; p=$(df --output=pcent "$1" 2>/dev/null | tail -1 | tr -dc '0-9'); echo "${p:-0}"; }
avail_mb() { local a; a=$(df -BM --output=avail "$1" 2>/dev/null | tail -1 | tr -dc '0-9'); echo "${a:-0}"; }
over()     { (( $(use_pct "$1") >= SOFT )); }
# The fuller of the filesystems this runner's caches live on - one disk on
# most boxes, but /home and /opt can be separate.
worst_pct() {
  local d p w=0
  for d in "$H" "$TC"; do p=$(use_pct "$d"); (( p > w )) && w=$p; done
  echo "$w"
}

# Every deletion goes through as_runner (lib.sh): as the runner user, never as
# root. All of these paths are job-writable, so a job can plant a symlink
# anywhere in them; as the runner user, the most a planted link can make rm
# reach is what the job could already delete itself.

# Go's module cache is read-only on purpose (0444 files in 0555 directories),
# and not even the owner can unlink inside a directory it cannot write - so rm
# fails on it unless those directories are opened up first.
rm_tree() { # rm_tree <path>...
  local p
  for p in "$@"; do
    if [[ -d "$p" && ! -L "$p" ]]; then
      as_runner "$N" find "$p" -type d ! -perm -u+w -exec chmod u+w {} + 2>/dev/null
    fi
    as_runner "$N" rm -rf -- "$p" 2>/dev/null
  done
  return 0
}

# Has no job read anything under <path> in STALE_DAYS? Files only: listing a
# directory (du, find, this script) refreshes its atime, while a file's atime
# moves only when something reads it - running a tool, loading a cached
# package. relatime updates it at most daily, all the precision this needs. On
# a noatime mount everything looks as old as its install, and this degrades to
# evicting by install age.
stale() { # stale <path>
  [[ -z "$(find "$1" -type f -amin "-$(( STALE_DAYS * 1440 ))" -print -quit 2>/dev/null)" ]]
}

# The entries of a home a reset removes, each one whole: everything except
# KEEP, descending only into the directories that lead to a KEEP entry and into
# SPLIT. Never deeper - half a Go module or half a pub package is a corrupt
# cache, not a smaller one. A symlink is an entry, never a way in.
home_entries() { # home_entries <dir> [<path relative to the home>]
  local dir="$1" rel="${2:-}" e r k s keep descend
  for e in "$dir"/* "$dir"/.[!.]* "$dir"/..?*; do
    [[ -e "$e" || -L "$e" ]] || continue
    r="${rel:+${rel}/}${e##*/}"
    keep=0; descend=0
    for k in "${KEEP[@]}"; do
      [[ "$r" == "$k" ]] && keep=1
      [[ "$k" == "$r"/* ]] && descend=1
    done
    for s in "${SPLIT[@]}"; do [[ "$r" == "$s" ]] && descend=1; done
    (( keep )) && continue
    if (( descend )) && [[ -d "$e" && ! -L "$e" ]]; then
      home_entries "$e" "$r"
    else
      printf '%s\n' "$e"
    fi
  done
  return 0
}

# One entry per installed tool version: <tool>/<version> holds both the tree
# and the .complete marker the setup-* actions look for. A <tool> that is a
# symlink is no way in either; wiping the cache removes the link itself.
tool_entries() { # tool_entries <toolcache>
  local t e
  [[ -d "$1" && ! -L "$1" ]] || return 0
  for t in "$1"/*; do
    [[ -d "$t" && ! -L "$t" ]] || continue
    for e in "$t"/*; do
      if [[ -d "$e" && ! -L "$e" ]]; then printf '%s\n' "$e"; fi
    done
  done
  return 0
}

# Listed in full before anything is deleted, so the walk never runs into a
# directory the loop below has just removed. <remover> is rm_tree unless an
# entry needs more than its own tree removed.
evict_stale() { # evict_stale <lister> <root> [<remover>]
  local e remover="${3:-rm_tree}"
  local -a all=() gone=()
  mapfile -t all < <("$1" "$2")
  for e in ${all[@]+"${all[@]}"}; do
    stale "$e" || continue
    "$remover" "$e"
    [[ -e "$e" || -L "$e" ]] || gone+=("${e#"$2"/}")
  done
  (( ${#gone[@]} )) && log "evicted ${#gone[@]} unused for ${STALE_DAYS}+ days: ${gone[*]}"
  return 0
}

# ---- the lru work policy ----------------------------------------------------
# An Azure Pipelines agent keeps _work between jobs on purpose. Each pipeline
# gets its own numbered build directory (a, b, s and TestResults inside) that
# its next run fetches into instead of cloning afresh, _work/_tasks holds every
# task version a job has downloaded, and _diag gathers a log per cycle. The
# agent itself is not listening while this runs, so whole entries can go - but
# never half of one, and never through a link a job planted: _work, _tasks,
# _tool and _diag are each checked to be real directories before anything
# beneath them is listed. Left alone on purpose: _work/_temp, which the agent
# empties at the start of every job, and _work/SourceRootMapping, the agent's
# own record of which build directory is whose (a recorded directory that is
# gone is simply created again).
work_is_real() { [[ -d "${1}/_work" && ! -L "${1}/_work" ]]; }

build_dirs() { # build_dirs <runner dir> -> each _work/<n>, one pipeline's build directory
  local e
  work_is_real "$1" || return 0
  for e in "$1"/_work/*; do
    if [[ -d "$e" && ! -L "$e" && "${e##*/}" =~ ^[0-9]+$ ]]; then printf '%s\n' "$e"; fi
  done
  return 0
}
task_versions() { # task_versions <runner dir> -> each _work/_tasks/<task>/<version>
  local t e
  work_is_real "$1" || return 0
  [[ -d "$1/_work/_tasks" && ! -L "$1/_work/_tasks" ]] || return 0
  for t in "$1"/_work/_tasks/*; do
    [[ -d "$t" && ! -L "$t" ]] || continue
    for e in "$t"/*; do
      if [[ -d "$e" && ! -L "$e" ]]; then printf '%s\n' "$e"; fi
    done
  done
  return 0
}
# The agent's own tool directory. Unused while the unit points
# AGENT_TOOLSDIRECTORY at the tool cache, and an adopted agent can still carry
# years of toolchains in it, so nothing a job reads survives the stale check.
work_tools() { # work_tools <runner dir> -> each _work/_tool/<tool>/<version>
  work_is_real "$1" || return 0
  tool_entries "$1/_work/_tool"
}
diag_logs() { # diag_logs <runner dir> -> each _diag/*.log
  local e
  [[ -d "$1/_diag" && ! -L "$1/_diag" ]] || return 0
  for e in "$1"/_diag/*.log; do
    if [[ -f "$e" && ! -L "$e" ]]; then printf '%s\n' "$e"; fi
  done
  return 0
}
# The agent writes <version>.completed beside each task version it downloads,
# and trusts that marker without looking inside the directory. So the marker
# goes first: one left without its directory would send every job that uses
# the task to an empty one, while a directory left without its marker is
# downloaded again.
rm_task_version() { rm_tree "${1}.completed" "$1"; }
drop_empty_dirs() { # drop_empty_dirs <dir>...
  local d
  for d in "$@"; do
    if [[ -d "$d" && ! -L "$d" ]]; then
      as_runner "$N" find "$d" -mindepth 1 -maxdepth 1 -type d -empty -delete 2>/dev/null
    fi
  done
  return 0
}

# ---- the steps, cheapest loss first -----------------------------------------
# The wrapper deletes _work before every job anyway; one left by a job that was
# killed before its cleanup ran would otherwise cost caches it need not.
drop_leftover_work() { rm_tree "${R}/_work"; }
evict_stale_tools() {
  evict_stale tool_entries "$TC"
  drop_empty_dirs "$TC"
}
evict_stale_home() { evict_stale home_entries "$H"; }
evict_stale_work() {
  evict_stale build_dirs "$R"
  evict_stale task_versions "$R" rm_task_version
  evict_stale work_tools "$R"
  evict_stale diag_logs "$R"
  if work_is_real "$R"; then drop_empty_dirs "${R}/_work/_tasks" "${R}/_work/_tool"; fi
  return 0
}
# A build directory costs its pipeline one full clone to lose, the task cache
# one download per task; both are cheaper than an image store or a toolchain.
drop_build_dirs() {
  local -a e=()
  mapfile -t e < <(build_dirs "$R")
  rm_tree ${e[@]+"${e[@]}"}
}
drop_task_cache() {
  if work_is_real "$R"; then rm_tree "${R}/_work/_tasks"; fi
  return 0
}
# Safe to take everything: nothing runs between jobs. Running containers go
# first, because `system prune` skips them - a job's `--restart always`
# container would otherwise outlive it. `system prune` also spares named
# volumes on current Docker, hence the separate `volume prune -a`.
prune_docker() {
  [[ -S "/run/user/${RUID}/docker.sock" ]] || return 0
  as_runner "$N" timeout 300 sh -c 'docker ps -aq | xargs -r docker rm -f' >/dev/null 2>&1
  as_runner "$N" timeout 600 docker system prune -af --volumes >/dev/null 2>&1
  as_runner "$N" timeout 300 docker volume prune -af           >/dev/null 2>&1
  as_runner "$N" timeout 300 docker builder prune -af          >/dev/null 2>&1
  return 0
}
wipe_toolcache() {
  local -a e=(); mapfile -t e < <(find "$TC" -mindepth 1 -maxdepth 1 2>/dev/null)
  rm_tree ${e[@]+"${e[@]}"}
}
reset_home() {
  local -a e=(); mapfile -t e < <(home_entries "$H")
  rm_tree ${e[@]+"${e[@]}"}
}

# Each step names the directory whose filesystem it frees, so a box with /home
# and /opt on separate disks only clears the side that is actually full.
WIPE_STEPS=(
  work:drop_leftover_work
  tools:evict_stale_tools
  home:evict_stale_home
  home:prune_docker       # the rootless data root lives in $HOME
  tools:wipe_toolcache
  home:reset_home
)
# No leftover step: _work is kept on purpose, so it goes stale entry by stale
# entry with the other caches, and whole only after them.
LRU_STEPS=(
  work:evict_stale_work   # stale build directories, task versions, tools, logs
  tools:evict_stale_tools
  home:evict_stale_home
  work:drop_build_dirs
  work:drop_task_cache
  home:prune_docker       # the rootless data root lives in $HOME
  tools:wipe_toolcache
  home:reset_home
)

# ---- the rootless daemon's user unit ----------------------------------------
# A reset keeps the unit the rootless daemon runs from, and that unit lives in
# $HOME, where a job can write: a fork PR could add an ExecStartPre= to it, or
# put a directory of its own first in the daemon's PATH, and either would run
# again after every job and every reboot. So for an untrusted runner the unit
# is never taken on trust. A root-owned copy of each runner's unit is kept in
# the state directory: taken the first time the guard runs for that runner,
# which is before its first job, and never overwritten (the runner_host role
# may write the same file itself, as soon as it creates the unit). Before every
# untrusted job the unit is put back from that copy when the two differ, and
# the daemon is restarted from it, whatever it was running from until then.
UNIT_REL=".config/systemd/user/docker.service"
WANTS_REL=".config/systemd/user/default.target.wants/docker.service"

unit_reference() { printf '%s/rootless/%s.docker.service\n' "$(state_dir)" "$(runner_user "$N")"; }

# keep_unit_reference - takes the reference copy, when there is none yet and
# the runner has a unit to take it from. Read as the runner's user, never
# through a link (read_untrusted, lib.sh); written by root, into root's own.
keep_unit_reference() {
  local ref tmp
  ref=$(unit_reference)
  [[ -e "$ref" ]] && return 0
  [[ -f "${H}/${UNIT_REL}" && ! -L "${H}/${UNIT_REL}" ]] || return 0
  ensure_root_dir "${ref%/*}" 0700
  tmp="${ref}.new"
  if (umask 077; read_untrusted "${H}/${UNIT_REL}" > "$tmp") 2>/dev/null && [[ -s "$tmp" ]]; then
    mv -f "$tmp" "$ref"
    log "kept the rootless daemon's user unit as ${ref}, to put it back from before every untrusted job"
  else
    rm -f "$tmp"
  fi
  return 0
}

# restore_unit - puts the unit back from its reference copy when they differ,
# keeps it enabled, and restarts the daemon from it
restore_unit() {
  local ref dir
  ref=$(unit_reference)
  if [[ ! -s "$ref" ]]; then
    log "no reference copy of the rootless daemon's user unit at ${ref} - left as it is"
    return 0
  fi
  dir="${H}/.config/systemd/user"
  if ! cmp -s "$ref" <(read_untrusted "${H}/${UNIT_REL}" 2>/dev/null); then
    # Written by the runner's user, from the root-owned copy on its stdin, and
    # renamed into place: over a link or a directory a job put there, never
    # through it.
    as_runner "$N" sh -c 'rm -rf -- "$1/docker.service" "$1/.docker.service.new" && mkdir -p -- "$1" &&
      cat > "$1/.docker.service.new" && mv -f -- "$1/.docker.service.new" "$1/docker.service"' \
      _ "$dir" < "$ref" 2>/dev/null
    log "put the rootless daemon's user unit back from ${ref}: a job had changed it"
  fi
  if [[ ! -L "${H}/${WANTS_REL}" ]]; then
    as_runner "$N" sh -c 'rm -rf -- "$2" && mkdir -p -- "${2%/*}" && ln -s -- "$1" "$2"' \
      _ "${H}/${UNIT_REL}" "${H}/${WANTS_REL}" 2>/dev/null
  fi
  # Whatever the files say now, the daemon still running may be one a job
  # started some other way, or from a unit it changed and changed back.
  as_runner "$N" systemctl --user daemon-reload >/dev/null 2>&1
  as_runner "$N" timeout 120 systemctl --user restart docker.service >/dev/null 2>&1 \
    || log "the rootless daemon did not restart - see: journalctl --user -u docker.service -M $(runner_user "$N")@"
  return 0
}

# An untrusted runner has no cache worth keeping warm, only what a fork PR
# could leave for the next job: a ~/.gitconfig hook, a poisoned build cache, a
# Docker CLI plugin, a tampered image or daemon unit. So it gets every step,
# before every job, whatever the disk says, and whatever its work policy: _work
# goes entirely. The wrapper's own post-job wipe cannot be the only defence: it
# runs as the job's own user, so a job can kill it before its EXIT trap fires.
#
# The home goes before the daemon restarts, so nothing a job left beside its
# unit (a drop-in, an environment.d file) is read by that restart; and Docker is
# pruned after it, through a daemon started from the unit just checked.
reset_runner() {
  drop_leftover_work
  wipe_toolcache
  reset_home
  restore_unit
  prune_docker
  log "reset to its installed state before the next job (trust=${RUNNER_TRUST:-unset})"
}

run_steps() {
  local step fn dir before
  for step in "${STEPS[@]}"; do
    fn="${step#*:}"; dir="${WHERE[${step%%:*}]}"
    over "$dir" || continue
    before=$(avail_mb "$dir")
    "$fn"
    log "${fn//_/ }: freed $(( $(avail_mb "$dir") - before )) MB, disk now $(use_pct "$dir")%"
  done
  return 0
}

# guard_init <n> - everything the steps read, from host.env; 1 when runner <n>
# is not (or not yet) on this box, which the guard treats as nothing to do.
guard_init() {
  local k
  local -a extra=()
  N="$1"
  load_host_env || return 1
  SOFT="$RUNNER_DISK_SOFT"   # the janitor's soft threshold, read the same way
  STALE_DAYS="$RUNNER_STALE_DAYS"   # unread this long, a cache entry is not earning its space
  RUID=$(runner_uid "$N") || return 1
  H=$(runner_home "$N")
  TC=$(runner_toolcache "$N")
  R=$(runner_dir "$N")
  [[ -d "$H" && -d "$TC" ]] || return 1
  KEEP=("${KEEP_BASE[@]}")
  read -ra extra <<<"$RUNNER_HOME_KEEP"
  for k in ${extra[@]+"${extra[@]}"}; do
    # Compared as the walk spells paths: relative, no trailing slash.
    k="${k#./}"; k="${k%/}"
    if [[ -n "$k" ]]; then KEEP+=("$k"); fi
  done
  WHERE=([work]="$R" [tools]="$TC" [home]="$H")
  if [[ "$RUNNER_WORK_POLICY" == "lru" ]]; then STEPS=("${LRU_STEPS[@]}"); else STEPS=("${WIPE_STEPS[@]}"); fi
  return 0
}

main() {
  [[ "${1:-}" =~ ^[0-9]+$ ]] || { echo "usage: ${0##*/} <runner-number>" >&2; exit 0; }
  guard_init "$1" || exit 0
  # For every runner, whatever its trust: on a box installed with this guard
  # that is before its first job, so a box later made untrusted has a copy no
  # job could have touched.
  keep_unit_reference

  if ! runner_trusted; then
    reset_runner
    exit 0
  fi

  (( $(worst_pct) >= SOFT )) || exit 0       # the common case, in milliseconds

  # One guard at a time. Runners that finish together would otherwise all
  # measure the same full disk and all empty their caches, when the first
  # one's work alone may have been enough - so the others wait, then measure.
  ensure_run_dir
  exec 9>"$(run_dir)/diskguard.lock"
  flock -w 300 9 || log "gave up waiting for another runner's guard; going ahead"
  (( $(worst_pct) >= SOFT )) || exit 0

  log "disk at $(worst_pct)%, soft threshold ${SOFT}% - freeing space from runner ${N}'s caches"
  run_steps
  if (( $(worst_pct) >= SOFT )); then
    log "STILL at $(worst_pct)% with runner ${N}'s caches emptied. Each runner empties its own"
    log "before its next job; if every one of them reports this, the disk is filling with"
    log "something that is not a runner cache - see: ${RUNNER_SBIN_PREFIX:-runner}-admin diagnose"
  fi
  exit 0
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
