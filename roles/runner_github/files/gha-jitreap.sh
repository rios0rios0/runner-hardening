#!/usr/bin/env bash
#
# gha-jitreap <n> - runs as root via ExecStopPost=+. Deletes the registration
# this unit minted. If the runner finished a job normally GitHub already
# retired it and this 404s harmlessly; if it crashed on start, this is what
# stops the leak. Installed 0700 root by the runner_github role from
# roles/runner_github/files/gha-jitreap.sh.
#
# Never fails: an ExecStopPost that fails marks the unit's result failed, and a
# runner that just finished a job cleanly would then read as a broken one.
set -uo pipefail

# shellcheck source=../../runner_host/files/lib.sh
. "${RUNNER_LIB_DIR:-/usr/local/lib/runner-hardening}/lib.sh" || exit 0

# As in gha-jitconfig: the env file's own RUNNER_BASE is the installer's copy,
# kept for a rollback; host.env's is the one used.
load_github_env() {
  local base="$RUNNER_BASE"
  # shellcheck source=/dev/null
  . "${RUNNER_CONFIG_DIR}/env" 2>/dev/null || return 1
  RUNNER_BASE="$base"
}

main() {
  local n="${1:-}" rid pat rpath idf
  [[ "$n" =~ ^[1-9][0-9]*$ ]] || exit 0
  load_host_env || exit 0
  load_github_env || exit 0

  # Count the cycles in a row that ran no job, for gha-jitconfig's backoff
  # (record_cycle in lib.sh). The .jit file was written when this cycle's
  # registration was minted, which makes it the cycle's marker; it is removed
  # below, so this has to come first.
  ensure_run_dir
  record_cycle "$(unit_of "$n")" "$(runner_dir "$n")" "$(run_dir)/${n}.jit" "$(run_dir)/${n}.fails"

  idf="$(run_dir)/${n}.id"
  if [[ -s "$idf" ]]; then
    rid="$(< "$idf")"
    pat="$(< "${RUNNER_CONFIG_DIR}/pat")"
    # Keeps the PAT out of argv; see gh_api in vendor.sh. A global, because the
    # EXIT trap fires after main has returned.
    AUTH=$(mktemp)
    trap 'rm -f "$AUTH"' EXIT
    printf 'Authorization: Bearer %s\n' "$pat" > "$AUTH"
    if [[ "$GHA_SCOPE" == "org" ]]; then
      rpath="/orgs/${GHA_ORG}/actions/runners"
    else
      rpath="/repos/${GHA_ORG}/${GHA_REPO}/actions/runners"
    fi
    [[ "$rid" =~ ^[0-9]+$ ]] && curl -fsS -X DELETE \
      -H @"$AUTH" \
      -H "Accept: application/vnd.github+json" \
      "https://api.github.com${rpath}/${rid}" >/dev/null 2>&1 || true
  fi
  rm -f "$(run_dir)/${n}.jit" "$idf"
  exit 0
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
