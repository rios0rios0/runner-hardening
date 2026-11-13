#!/usr/bin/env bash
#
# run.sh - runs every test/runtime/*_test.sh, prints a total, and exits
# non-zero when any assertion failed or any file did not finish cleanly.
#
# Run from anywhere:  bash test/runtime/run.sh   (or: make test)
#
# Each file is its own process, so one cannot leave state behind for the next.
# Counted from the protocol lines every file prints (see harness.sh), not from
# its own summary, so a file that dies half way still counts what it ran.
set -uo pipefail

DIR="$(cd -- "$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")" && pwd)"
OUT="$(mktemp)"
trap 'rm -f "$OUT"' EXIT

passed=0; failed=0; files=0
for f in "$DIR"/*_test.sh; do
  [[ -e "$f" ]] || continue
  files=$(( files + 1 ))
  echo
  echo "${f##*/}"
  bash "$f" 2>&1 | tee "$OUT"
  rc=${PIPESTATUS[0]}
  ok=$(grep -c '^  ok  ' "$OUT")
  bad=$(grep -c '^FAIL  ' "$OUT")
  passed=$(( passed + ok )); failed=$(( failed + bad ))
  # A file that exits non-zero without reporting why, or that ran nothing at
  # all, is broken however clean its output looks.
  if (( rc != 0 && bad == 0 )); then
    printf 'FAIL  %s: exited %d without reporting a failure\n' "${f##*/}" "$rc"
    failed=$(( failed + 1 ))
  elif (( ok + bad == 0 )); then
    printf 'FAIL  %s: ran no case\n' "${f##*/}"
    failed=$(( failed + 1 ))
  fi
done

echo
printf 'runtime: %d passed, %d failed, in %d file(s)\n' "$passed" "$failed" "$files"
(( files > 0 && failed == 0 ))
