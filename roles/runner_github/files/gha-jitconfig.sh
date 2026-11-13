#!/usr/bin/env bash
#
# gha-jitconfig <n> - runs as root via systemd ExecStartPre=+, after the disk
# guard. Mints a single-use JIT runner config and drops it where exactly one
# runner user can read it. The PAT never leaves this process. Installed 0700
# root by the runner_github role from roles/runner_github/files/gha-jitconfig.sh.
#
# Reads ${RUNNER_CONFIG_DIR}/env and /pat (/etc/github-runner, in the
# installer's exact format) for what to register, and host.env for where.
set -euo pipefail

# shellcheck source=../../runner_host/files/lib.sh
. "${RUNNER_LIB_DIR:-/usr/local/lib/runner-hardening}/lib.sh"

# ===========================================================================
# HEAVY JOBS
#
# The resource policy caps what all the runners on a box use together, not how
# the jobs inside that cap are mixed, and one kind of job does not mix. A CodeQL
# analysis sizes itself from the whole machine and, on a mid-sized codebase,
# fills its runner's entire memory ceiling and swaps on top. Two on one box
# overrun gha.slice, swap fills, and the kernel kills one of them. A runner
# cannot refuse such a job: it only learns what it was given once it has it.
#
# Where the job is sent can prevent the overlap. The first GHA_HEAVY_RUNNERS
# runners on a box also register with the label `heavy`, so a workflow that
# sends its analysis to `[self-hosted, heavy]` never has more than that many
# of them on one box - a second one queues instead of stacking. Every other job
# still runs on every runner, the heavy ones included.
#
# Defined here, behind the main guard, so the test suite sources this file and
# checks the labels a runner registers with.
# ===========================================================================

# runner_labels <runner number> <labels> <heavy runner count> -> this runner's labels
runner_labels() {
  local n="$1" list="$2" heavy="$3"
  [[ "$heavy" =~ ^[0-9]+$ ]] || heavy=0
  if [[ "$n" =~ ^[1-9][0-9]*$ ]] && (( n <= 10#$heavy )) \
     && [[ ",${list}," != *",heavy,"* ]]; then
    list="${list},heavy"
  fi
  printf '%s\n' "$list"
}

# The env file keeps the installer's exact keys, RUNNER_BASE among them, so a
# rollback to the installer still finds what it wrote. host.env is where the
# paths come from, so its RUNNER_BASE is the one kept.
load_github_env() {
  local base="$RUNNER_BASE"
  # shellcheck source=/dev/null
  . "${RUNNER_CONFIG_DIR}/env"
  RUNNER_BASE="$base"
}

main() {
  local n="${1:-}" pat u url labels body resp jit f
  [[ "$n" =~ ^[1-9][0-9]*$ ]] || die "usage: ${0##*/} <runner-number>"
  load_host_env || die "cannot read ${RUNNER_HOST_ENV:-/etc/runner-hardening/host.env}"
  load_github_env

  # Wait before minting only if the last cycles ran no job; see RESTART BACKOFF
  # in lib.sh. Waiting here, before any registration exists, also means a
  # `systemctl stop` cuts the wait short instead of sitting it out.
  wait_out_backoff "$(run_dir)/${n}.fails"

  pat="$(< "${RUNNER_CONFIG_DIR}/pat")"
  u=$(runner_user "$n")

  # A PAT passed as `-H "Authorization: ..."` is readable by every local user
  # through /proc/<pid>/cmdline, and this runs on every runner start, with the
  # unprivileged runner users already on the box. `-H @file` reads it from a
  # file mktemp creates 0600; see gh_api in vendor.sh for why not `-K -`.
  # A global, not a local: the EXIT trap fires after main has returned.
  AUTH=$(mktemp)
  trap 'rm -f "$AUTH"' EXIT
  printf 'Authorization: Bearer %s\n' "$pat" > "$AUTH"

  if [[ "$GHA_SCOPE" == "org" ]]; then
    url="https://api.github.com/orgs/${GHA_ORG}/actions/runners/generate-jitconfig"
  else
    url="https://api.github.com/repos/${GHA_ORG}/${GHA_REPO}/actions/runners/generate-jitconfig"
  fi

  # An env file written before heavy runners existed has no GHA_HEAVY_RUNNERS;
  # the installer's default for it is 1, so that is what an absent value means.
  labels=$(runner_labels "$n" "$GHA_LABELS" "${GHA_HEAVY_RUNNERS:-1}")

  body=$(jq -nc \
    --arg n "${RUNNER_NAME_PREFIX}-${n}-$(date +%s)" \
    --argjson g "$GHA_GROUP_ID" \
    --argjson l "$(jq -Rc 'split(",")' <<<"$labels")" \
    '{name:$n, runner_group_id:$g, labels:$l, work_folder:"_work"}')

  resp=$(curl -fsS -X POST "$url" \
    -H @"$AUTH" \
    -H "Accept: application/vnd.github+json" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    -d "$body") || { echo "${0##*/}: API request failed" >&2; exit 1; }

  jit=$(jq -er '.encoded_jit_config' <<<"$resp") || {
    echo "${0##*/}: $(jq -r '.message // "no jit config returned"' <<<"$resp")" >&2; exit 1; }

  ensure_run_dir
  f="$(run_dir)/${n}.jit"
  (umask 077; printf '%s' "$jit" > "$f")
  chown "root:${u}" "$f"
  chmod 0040 "$f"   # group-read only: this runner's user, and no other

  # Record the registration id so ExecStopPost can delete it. Without this, a
  # runner that never comes online leaves an offline registration behind on
  # every single start attempt.
  jq -er '.runner.id' <<<"$resp" > "$(run_dir)/${n}.id" 2>/dev/null || true
  chmod 0600 "$(run_dir)/${n}.id" 2>/dev/null || true
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
