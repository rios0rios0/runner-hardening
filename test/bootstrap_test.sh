#!/usr/bin/env bash
#
# Tests for the two pieces of fleet.sh that can go wrong silently: the
# fleet.conf reader, and the bootstrap it streams to a host.
#
# The bootstrap tests are not simulations. Each one runs the real bootstrap
# through a real `bash -s`, exactly as sshd would on the far side, against a
# stand-in installer that reports what it received. Nothing here is doubled
# except the SSH hop itself.
#
# Run from the repository root:  bash test/bootstrap_test.sh   (or: make test)
#
# This file wires globals that functions in fleet.sh and harden-gha-runners.sh
# read (MODE, ADMIN_PAT, NO_PAT, ENV_FILE, ...). ShellCheck cannot follow the
# interpolated `source` below, so it sees every one of them assigned and never
# used. Disabling SC2034 for the file is the honest trade here -- a test file
# that only sets up state for a sourced library has no other use for the check,
# and the alternative was six near-identical inline directives that had to be
# re-added with every new case. The directive must sit BEFORE the first command
# to apply file-wide.
# shellcheck disable=SC2034

set -uo pipefail

ROOT="$(cd -- "$(dirname -- "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
WORK="$(mktemp -d)"
# chmod first: the disk-guard cases build a read-only Go module cache, which
# rm -rf cannot remove from under a directory it cannot write.
trap 'chmod -R u+w "$WORK" 2>/dev/null; rm -rf "$WORK"' EXIT

# shellcheck source=/dev/null
source "${ROOT}/fleet.sh"
set +e            # a failing assertion must report, not abort the suite

PASS=0; FAIL=0
pass() { PASS=$(( PASS + 1 )); printf '  ok   %s\n' "$1"; }
fail() { FAIL=$(( FAIL + 1 )); printf '  FAIL %s\n' "$1"; printf '       %s\n' "$2"; }

# assert_eq <name> <expected> <actual>
assert_eq() {
  if [[ "$2" == "$3" ]]; then pass "$1"; else fail "$1" "expected [$2], got [$3]"; fi
}
# assert_contains <name> <haystack> <needle>
assert_contains() {
  if [[ "$2" == *"$3"* ]]; then pass "$1"; else fail "$1" "[$3] not found in output"; fi
}
# assert_not_contains <name> <haystack> <needle>
assert_not_contains() {
  if [[ "$2" != *"$3"* ]]; then pass "$1"; else fail "$1" "[$3] should not be in output"; fi
}

# Resets the parser's state between cases. Every name below is read by a
# function that lives in fleet.sh, which ShellCheck does not follow through the
# interpolated `source` above - so it sees the assignment and not the use.
reset_config() { CFG=(); HOSTS=(); SELECTED=(); }

# A stand-in installer: prints what the elevated shell handed it, then exits 7
# so the transport's exit-status handling is observable.
cat > "${WORK}/stub-installer.sh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
echo "MODE=$1"
echo "ORG=${GHA_ORG:-<unset>}"
echo "SCOPE=${GHA_SCOPE:-<unset>}"
echo "COUNT=${GHA_COUNT:-<unset>}"
echo "LABELS=${GHA_LABELS:-<unset>}"
echo "TRUST=${GHA_TRUST:-<unset>}"
echo "GROUP=${GHA_GROUP_ID:-<unset>}"
echo "YES=${GHA_YES:-<unset>}"
echo "PAT=${GHA_PAT:-<unset>}"
echo "DIRMODE=$(stat -c %a "$(dirname "$0")")"
echo "ENVMODE=$(stat -c %a "$(dirname "$0")/env")"
echo "DIR=$(dirname "$0")"
exit 7
STUB
chmod 0700 "${WORK}/stub-installer.sh"

# run_bootstrap <config> <mode> <pat> -> prints remote stdout, sets RC
run_bootstrap() {
  reset_config
  MODE="$2"; ADMIN_PAT="$3"; NEW_PAT=""
  INSTALLER="${WORK}/stub-installer.sh"
  parse_config "$1"
  INSTALLER_B64="$(base64 < "$INSTALLER")"
  build_bootstrap host1 > "${WORK}/boot.sh"
  bash -s < "${WORK}/boot.sh" 2>&1
  RC=$?
}

# ---------------------------------------------------------------------------
cat > "${WORK}/basic.conf" <<'CONF'
[defaults]
become  = none
scope   = org
org     = your-org
trust   = internal
labels  = self-hosted,linux,x64,internal
group_id = 3

[host1]
host    = 10.0.0.1
runners = 2
CONF

echo "fleet.conf parsing"

it_reads_defaults() {
  # given a config whose host section overrides only one key
  reset_config
  parse_config "${WORK}/basic.conf"

  # when the host's settings are resolved
  local org runners labels

  org="$(cfg host1 org)"
  runners="$(cfg host1 runners auto)"
  labels="$(cfg host1 labels)"

  # then the override wins and everything else is inherited from [defaults]
  assert_eq "should inherit [defaults] when the host does not override a key" "your-org" "$org"
  assert_eq "should prefer the host value over [defaults] when both are set"  "2" "$runners"
  assert_eq "should inherit a comma-separated value intact" \
    "self-hosted,linux,x64,internal" "$labels"
}
it_reads_defaults

it_falls_back_to_the_section_name_as_hostname() {
  # given a host section with no explicit `host`
  reset_config
  printf '[defaults]\norg = o\n\n[builder-07]\nrunners = 1\n' > "${WORK}/noname.conf"
  parse_config "${WORK}/noname.conf"

  # when the hostname is resolved
  local host; host="$(cfg builder-07 host builder-07)"

  # then the section name is used
  assert_eq "should use the section name as the hostname when host is omitted" \
    "builder-07" "$host"
}
it_falls_back_to_the_section_name_as_hostname

it_strips_an_inline_comment() {
  # given values with a spaced comment and with a '#' glued to the value
  reset_config
  printf '[defaults]\norg = acme   # the org\nlabels = a,b#c\n\n[host1]\nhost = h\n' \
    > "${WORK}/comment.conf"
  parse_config "${WORK}/comment.conf"

  # when they are resolved
  local org labels
  org="$(cfg host1 org)"; labels="$(cfg host1 labels)"

  # then only the spaced comment is removed
  assert_eq "should strip a comment that follows whitespace" "acme" "$org"
  assert_eq "should keep a '#' that is glued to the value" "a,b#c" "$labels"
}
it_strips_an_inline_comment

it_rejects_an_unknown_key() {
  # given a config with a misspelled key
  printf '[defaults]\norg = o\n\n[host1]\nhsot = 10.0.0.1\n' > "${WORK}/typo.conf"

  # when it is parsed in a subshell (die exits)
  local out; out=$( reset_config; parse_config "${WORK}/typo.conf" 2>&1 )

  # then the parse fails and names the line
  assert_contains "should reject an unknown key instead of ignoring it" "$out" "unknown key 'hsot'"
  assert_contains "should report the file and line of a bad key" "$out" "typo.conf:5"
}
it_rejects_an_unknown_key

it_rejects_a_duplicate_host() {
  # given the same host section twice
  printf '[defaults]\norg = o\n\n[host1]\nhost = a\n\n[host1]\nhost = b\n' > "${WORK}/dup.conf"

  # when it is parsed
  local out; out=$( reset_config; parse_config "${WORK}/dup.conf" 2>&1 )

  # then the second definition is an error, not a silent overwrite
  assert_contains "should reject a duplicate host section" "$out" "duplicate host '[host1]'"
}
it_rejects_a_duplicate_host

it_rejects_an_invalid_trust_level() {
  # given a host whose trust level is not one the installer accepts
  printf '[defaults]\nbecome = none\nscope = org\norg = o\ntrust = kinda\n\n[host1]\nhost = h\n' \
    > "${WORK}/badtrust.conf"

  # when the environment for that host is built
  local out
  out=$( reset_config; MODE=install; ADMIN_PAT=x; parse_config "${WORK}/badtrust.conf"; \
         build_env host1 2>&1 )

  # then it fails before anything is sent anywhere
  assert_contains "should reject a trust level the installer cannot honour" \
    "$out" "trust must be 'internal' or 'untrusted'"
}
it_rejects_an_invalid_trust_level

it_requires_an_org_for_install() {
  # given a config with no org
  printf '[defaults]\nbecome = none\nscope = org\n\n[host1]\nhost = h\n' > "${WORK}/noorg.conf"

  # when an install environment is built
  local out
  out=$( reset_config; MODE=install; ADMIN_PAT=x; parse_config "${WORK}/noorg.conf"; \
         build_env host1 2>&1 )

  # then the missing answer is reported rather than sent as an empty string
  assert_contains "should require 'org' before an install can be sent" "$out" "'org' is required"
}
it_requires_an_org_for_install

echo
echo "remote bootstrap"

it_delivers_every_answer() {
  # given a fleet entry and an admin PAT
  # when the bootstrap runs on the far side
  local out; out="$(run_bootstrap "${WORK}/basic.conf" install 'fixture-pat-placeholder')"

  # then the installer is invoked in the requested mode with every answer set
  assert_contains "should invoke the installer in the requested mode"      "$out" "MODE=install"
  assert_contains "should deliver the organisation"                        "$out" "ORG=your-org"
  assert_contains "should deliver the scope"                               "$out" "SCOPE=org"
  assert_contains "should deliver the host's runner count"                 "$out" "COUNT=2"
  assert_contains "should deliver the labels"                              "$out" "LABELS=self-hosted,linux,x64,internal"
  assert_contains "should deliver the trust level"                         "$out" "TRUST=internal"
  assert_contains "should deliver the runner group id"                     "$out" "GROUP=3"
  assert_contains "should answer every confirmation so no terminal is needed" "$out" "YES=1"
  assert_contains "should deliver the admin PAT"                           "$out" "PAT=fixture-pat-placeholder"
}
it_delivers_every_answer

it_protects_the_transferred_files() {
  # given any bootstrap run
  local out; out="$(run_bootstrap "${WORK}/basic.conf" install 'fixture-pat-placeholder')"

  # then the staging directory and the answers file are unreadable by others
  assert_contains "should stage the transfer in a 0700 directory" "$out" "DIRMODE=700"
  assert_contains "should write the answers file 0600"            "$out" "ENVMODE=600"
}
it_protects_the_transferred_files

it_survives_a_hostile_pat() {
  # given a PAT containing every character that breaks naive quoting, plus a
  # command-injection attempt
  local hostile='fix'\''ture_a b"c$d`e;rm -rf /'

  # when it is sent
  local out; out="$(run_bootstrap "${WORK}/basic.conf" install "$hostile")"

  # then it arrives byte for byte, and nothing in it was executed
  assert_contains "should deliver a PAT containing quotes, \$, backticks and ';'" \
    "$out" "PAT=${hostile}"
}
it_survives_a_hostile_pat

it_propagates_the_remote_exit_status() {
  # given a stand-in installer that exits 7
  # when the bootstrap runs
  run_bootstrap "${WORK}/basic.conf" install 'fixture-pat-placeholder' >/dev/null

  # then the caller sees 7, not the status of the cleanup that follows it
  assert_eq "should propagate the installer's exit status to the caller" "7" "$RC"
}
it_propagates_the_remote_exit_status

it_cleans_up_the_staging_directory() {
  # given a run that failed (the stand-in installer always exits 7)
  local out dir; out="$(run_bootstrap "${WORK}/basic.conf" install 'fixture-pat-placeholder')"
  dir="$(sed -n 's/^DIR=//p' <<<"$out")"

  # then the staging directory is gone even though the run did not succeed
  if [[ -n "$dir" && ! -e "$dir" ]]; then
    pass "should remove the staging directory even when the installer fails"
  else
    fail "should remove the staging directory even when the installer fails" \
         "directory [$dir] still exists"
  fi
}
it_cleans_up_the_staging_directory

it_omits_the_pat_when_no_pat_is_given() {
  # given --no-pat on an install, and a box that already stores its own PAT
  reset_config

  # when the bootstrap runs -- NO_PAT set inside the subshell, so the suite
  # cannot become order-dependent on a global left behind here
  local out
  out="$( NO_PAT=1; run_bootstrap "${WORK}/basic.conf" install 'fixture-pat-placeholder' )"

  # then every other answer still arrives, but no credential is sent -- the
  # installer falls back to /etc/github-runner/pat on the host
  assert_contains "should still send the install answers with --no-pat" "$out" "ORG=your-org"
  assert_contains "should still answer confirmations with --no-pat"     "$out" "YES=1"
  assert_contains "should send no PAT at all with --no-pat"             "$out" "PAT=<unset>"
}
it_omits_the_pat_when_no_pat_is_given

it_rejects_no_pat_with_pat_file() {
  # given both --no-pat and --pat-file, which say opposite things
  # when the arguments are parsed
  # Reset in a subshell so the guard sees a clean slate; all three are read by
  # parse_args, which lives in fleet.sh.
  local out
  out=$( MODE=""; NO_PAT=0; PAT_FILE=""; parse_args --no-pat --pat-file /tmp/x install 2>&1 )

  # then it fails at startup rather than silently picking one
  local rc=$?
  assert_contains "should reject --no-pat together with --pat-file" \
    "$out" "contradict each other"
  assert_eq "should exit non-zero, making it a startup error not a warning" \
    "1" "$rc"
}
it_rejects_no_pat_with_pat_file

it_warns_rather_than_failing_on_modes_that_send_no_pat() {
  # given --no-pat on modes where it cannot apply
  # when the arguments are parsed
  local out_rotate out_verify
  out_rotate=$( MODE=""; NO_PAT=0; PAT_FILE=""; parse_args --no-pat rotate-pat 2>&1 )
  out_verify=$( MODE=""; NO_PAT=0; PAT_FILE=""; parse_args --no-pat verify 2>&1 )

  # then each says something true for that mode rather than one generic line
  assert_contains "should say --no-pat does not govern rotate-pat's new token" \
    "$out_rotate" "still needs --new-pat-file"
  assert_contains "should say --no-pat is inert on a read-only mode" \
    "$out_verify" "never sends a PAT anyway"
}
it_warns_rather_than_failing_on_modes_that_send_no_pat

it_sends_no_answers_for_a_read_only_mode() {
  # given a mode that reads the configuration already on the box
  # when the bootstrap runs
  local out; out="$(run_bootstrap "${WORK}/basic.conf" verify 'fixture-pat-placeholder')"

  # then no answer is sent, so the box cannot be told it is something it is not
  assert_contains "should still invoke the requested mode"                "$out" "MODE=verify"
  assert_contains "should not send an organisation for a read-only mode"  "$out" "ORG=<unset>"
  assert_not_contains "should never send the admin PAT for a read-only mode" "$out" "PAT=fixture-pat-placeholder"
  assert_contains "should still answer confirmations for a read-only mode" "$out" "YES=1"
}
it_sends_no_answers_for_a_read_only_mode

it_ships_the_installer_byte_for_byte() {
  # given the real installer rather than the stand-in
  reset_config
  MODE=version
  ADMIN_PAT=""
  NEW_PAT=""
  INSTALLER="${ROOT}/harden-gha-runners.sh"
  parse_config "${WORK}/basic.conf"
  INSTALLER_B64="$(base64 < "$INSTALLER")"

  # when it is transferred and asked to identify itself
  local out expected
  out="$(build_bootstrap host1 | bash -s 2>&1)"
  expected="$(sha256sum "$INSTALLER" | cut -c1-12)"

  # then the checksum it reports for itself matches the local file
  assert_contains "should transfer the installer without altering a byte" "$out" "sha256:${expected}"
}
it_ships_the_installer_byte_for_byte

it_sends_only_what_the_config_specifies() {
  # given a fleet entry that names nothing but the org and the host
  reset_config
  printf '[defaults]\nbecome = none\norg = some-org\n\n[h1]\nhost = 10.0.0.1\n' \
    > "${WORK}/minimal.conf"
  parse_config "${WORK}/minimal.conf"

  # when the environment for that host is built (globals scoped to the subshell
  # so the suite cannot become order-dependent on what is left behind)
  local out
  out="$( MODE=install; ADMIN_PAT="fixture-pat-placeholder"; NEW_PAT=""; build_env h1 )"

  # then nothing is invented. The installer keeps a caller's answers over its
  # stored ones, so an invented default is not a fallback -- it is a silent
  # rewrite of that host's configuration, and for `trust` it would disable the
  # per-job Docker wipe on a box that runs fork PRs.
  assert_contains "should send the org it was given" "$out" "GHA_ORG='some-org'"
  assert_not_contains "should not invent a trust level"  "$out" "GHA_TRUST"
  assert_not_contains "should not invent a runner count" "$out" "GHA_COUNT"
  assert_not_contains "should not invent a runner group" "$out" "GHA_GROUP_ID"
  assert_not_contains "should not invent a label set"    "$out" "GHA_LABELS"
  assert_not_contains "should not invent an old user"    "$out" "GHA_OLD_USER"
  assert_not_contains "should not invent a scope"        "$out" "GHA_SCOPE"
}
it_sends_only_what_the_config_specifies

# parse_config calls die on a missing file, and these tests call it directly
# rather than in a subshell -- so a fixture written by a sibling test would exit
# the whole suite mid-run if that sibling were ever reordered or removed, with
# the pass/fail summary never printed.
setup_repo_noscope_config() {
  printf '[defaults]\nbecome = none\norg = some-org\nrepo = some-repo\n\n[h1]\nhost = 10.0.0.1\n' \
    > "${WORK}/repo_noscope.conf"
}

it_writes_nothing_but_exports_to_the_environment_file() {
  # given a config that sets `repo` without `scope`
  reset_config
  setup_repo_noscope_config
  parse_config "${WORK}/repo_noscope.conf"

  # when the environment is built, capturing stdout only
  local out stray
  out="$( MODE=install; ADMIN_PAT="fixture-pat-placeholder"; NEW_PAT=""; build_env h1 2>/dev/null )"
  stray="$(grep -cv '^export ' <<<"$out" || true)"

  # then every line is an assignment. build_env's stdout IS the file the remote
  # host sources, so a diagnostic printed here becomes a line that shell tries
  # to execute -- and the operator it was meant for never sees it.
  assert_eq "should emit only export lines, never diagnostics" "0" "$stray"
  assert_contains "should still emit the answers themselves" "$out" "GHA_ORG='some-org'"
}
it_writes_nothing_but_exports_to_the_environment_file

it_warns_on_stderr_when_repo_has_no_scope() {
  # given a config that sets `repo` without `scope`
  reset_config
  setup_repo_noscope_config
  parse_config "${WORK}/repo_noscope.conf"

  # when the config is checked, capturing stderr only
  local errout
  errout="$( warn_config_smells h1 2>&1 >/dev/null )"

  # then the operator gets the warning, on the stream that reaches them
  assert_contains "should warn about a repo with no scope, on stderr" \
    "$errout" "'repo' is set but 'scope' is not"
}

it_stops_the_run_when_a_host_fails_validation() {
  # given a fleet where one host has an invalid trust level
  reset_config
  printf '[defaults]\nbecome = none\nscope = org\norg = some-org\n\n[good]\nhost = 10.0.0.1\ntrust = internal\n\n[bad]\nhost = 10.0.0.2\ntrust = kinda\n' \
    > "${WORK}/badtrust.conf"

  # when the run is planned
  # Executed, not sourced: this suite runs with `set +e`, and the abort under
  # test is an errexit abort. Only the real script carries its own options.
  local out rc=0
  out=$("${ROOT}/fleet.sh" -c "${WORK}/badtrust.conf" -f "${WORK}/stub-installer.sh" \
        -n -y --no-pat install 2>&1) || rc=$?

  # then it stops. `die` inside build_env runs in a command substitution, so
  # without an assignment to propagate its status the run printed the error and
  # then announced the configuration valid, shipping an EMPTY environment file
  # to the offending host while installing every other one.
  assert_contains "should report which host and key failed" "$out" "trust must be 'internal' or 'untrusted'"
  assert_not_contains "should not announce the configuration valid" "$out" "configuration valid"
  assert_not_contains "should not reach the dry-run summary" "$out" "nothing was contacted"
  assert_eq "should exit non-zero so a caller can stop" "1" "$rc"
}
it_stops_the_run_when_a_host_fails_validation

it_only_warns_about_smells_on_modes_that_can_act_on_them() {
  # given a config that sets `repo` without `scope`
  reset_config
  setup_repo_noscope_config

  # when a read-only mode is planned against it
  local out
  out=$("${ROOT}/fleet.sh" -c "${WORK}/repo_noscope.conf" -f "${WORK}/stub-installer.sh" \
        -n -y verify 2>&1)
  assert_contains "the verify plan should have been reached at all" "$out" "dry run"

  # then it stays quiet: that mode sends no answers, so there is no scope
  # decision for the warning to be about
  assert_not_contains "should not warn about a scope a read-only mode never sets" \
    "$out" "'repo' is set but 'scope' is not"
}
it_only_warns_about_smells_on_modes_that_can_act_on_them

it_warns_about_smells_on_a_mode_that_does_set_a_scope() {
  # given the same config, planned for install
  reset_config
  setup_repo_noscope_config

  # when the run is planned
  local out
  out=$("${ROOT}/fleet.sh" -c "${WORK}/repo_noscope.conf" -f "${WORK}/stub-installer.sh" \
        -n -y --no-pat install 2>&1)
  assert_contains "the install plan should have been reached at all" "$out" "dry run"

  # then the operator is told, before anything is contacted
  assert_contains "should warn about a repo with no scope when installing" \
    "$out" "'repo' is set but 'scope' is not"
}
it_warns_about_smells_on_a_mode_that_does_set_a_scope

it_says_nothing_when_the_config_has_no_smells() {
  # given a fully specified config
  reset_config
  parse_config "${WORK}/basic.conf"

  # when it is checked
  local errout
  errout="$( warn_config_smells host1 2>&1 >/dev/null )"

  # then it is silent, so the warning stays worth reading
  assert_eq "should say nothing about a config with no smells" "" "$errout"
}
it_says_nothing_when_the_config_has_no_smells
it_warns_on_stderr_when_repo_has_no_scope

it_still_sends_everything_the_config_does_specify() {
  # given a fleet entry that spells every answer out
  reset_config
  parse_config "${WORK}/basic.conf"

  # when the environment is built
  local out
  out="$( MODE=install; ADMIN_PAT="fixture-pat-placeholder"; NEW_PAT=""; build_env host1 )"

  # then each one is sent, so a deliberate change still reaches the host
  assert_contains "should send a configured trust level"  "$out" "GHA_TRUST='internal'"
  assert_contains "should send a configured runner count" "$out" "GHA_COUNT='2'"
  assert_contains "should send a configured runner group" "$out" "GHA_GROUP_ID='3'"
}
it_still_sends_everything_the_config_does_specify

echo
echo "installer configuration precedence"

# The installer sets its own shell options and cds to /, so it is sourced in a
# subshell. These exercise load_config directly: it is the one function whose
# failure mode is silence -- an unattended run reports success and changes
# nothing.
setup_stored_config() {
  cat > "${WORK}/inst_env" <<'ENV'
GHA_SCOPE="org"
GHA_ORG="stored-org"
GHA_REPO=""
GHA_GROUP_ID="1"
GHA_LABELS="self-hosted,linux,x64,internal"
GHA_COUNT="3"
GHA_TRUST="internal"
GHA_OLD_USER="none"
RUNNER_NAME_PREFIX="storedbox"
ENV
  printf 'stored-pat' > "${WORK}/inst_pat"
}

# load_config_probe <exported assignments...> -> "labels|count|pat|name_prefix"
load_config_probe() {
  (
    # shellcheck source=/dev/null
    source "${ROOT}/harden-gha-runners.sh"
    # Only -e is dropped. `nounset` stays ON, because the two constructs this
    # rewrite added -- the ${!v+set} guard before the indirect expansion, and
    # iterating a possibly-empty associative array -- exist precisely to
    # survive it. Production runs under `set -Eeuo pipefail`; a probe that
    # relaxed -u would pass while every real host died with "unbound variable".
    set +e
    ENV_FILE="${WORK}/inst_env"
    PAT_FILE="${WORK}/inst_pat"
    eval "$1"
    load_config >/dev/null 2>&1
    printf '%s|%s|%s|%s|%s' "${GHA_LABELS:-}" "${GHA_COUNT:-}" "${GHA_PAT:-}" \
                            "${RUNNER_NAME_PREFIX:-}" "${CONFIG_OVERRIDDEN:-}"
  )
}

it_keeps_caller_answers_over_the_stored_file() {
  # given a host with stored answers and a caller asking for different ones
  setup_stored_config

  # when the configuration is loaded during an unattended install
  local got
  got=$(load_config_probe 'GHA_LABELS="self-hosted,linux,x64,internal,gpu"; GHA_COUNT=9; unset GHA_PAT')

  # then the caller wins, the unsent value still comes from the file, and the
  # credential the caller did not supply is the one the host already stores
  assert_eq "should keep a caller's labels over the stored ones" \
    "self-hosted,linux,x64,internal,gpu" "${got%%|*}"
  assert_eq "should keep a caller's runner count over the stored one" \
    "9" "$(cut -d'|' -f2 <<<"$got")"
  assert_eq "should fall back to the stored PAT when the caller sends none" \
    "stored-pat" "$(cut -d'|' -f3 <<<"$got")"
  assert_eq "should still load a value the caller did not send" \
    "storedbox" "$(cut -d'|' -f4 <<<"$got")"
}
it_keeps_caller_answers_over_the_stored_file

it_records_whether_the_caller_overrode_the_stored_config() {
  # given the three shapes an install can take
  setup_stored_config
  local none labels pat
  none=$(load_config_probe   'unset GHA_SCOPE GHA_ORG GHA_REPO GHA_GROUP_ID GHA_LABELS GHA_COUNT GHA_TRUST GHA_OLD_USER GHA_PAT')
  labels=$(load_config_probe 'unset GHA_PAT; GHA_LABELS="self-hosted,linux,x64,internal,gpu"')
  pat=$(load_config_probe    'unset GHA_LABELS; GHA_PAT="caller-pat"')

  # then the flag distinguishes "the stored file is the whole truth" from "the
  # caller supplied something". The dispatch offers its "Reuse it?" shortcut
  # only in the first case: taking it in the others would run on the caller's
  # values and leave the old ones on disk, including the PAT that gha-jitconfig
  # reads on every job start.
  assert_eq "should not flag an override when the caller supplied nothing" \
    "0" "${none##*|}"
  assert_eq "should flag an override when the caller supplied an answer" \
    "1" "${labels##*|}"
  assert_eq "should flag an override when the caller supplied only a PAT" \
    "1" "${pat##*|}"
}
it_records_whether_the_caller_overrode_the_stored_config

it_prefers_an_explicitly_supplied_pat() {
  # given a host that stores a PAT and a caller supplying a different one
  setup_stored_config

  # when the configuration is loaded
  local got
  got=$(load_config_probe 'GHA_PAT="caller-pat"')

  # then the supplied token wins, so an install can replace a stored credential
  assert_eq "should prefer an explicitly supplied PAT over the stored one" \
    "caller-pat" "$(cut -d'|' -f3 <<<"$got")"
}
it_prefers_an_explicitly_supplied_pat

it_preloads_the_stored_answers_for_every_unattended_run() {
  # given each combination of mode and attendedness
  # when the preload rule is consulted
  local got
  got=$(
    # shellcheck source=/dev/null
    source "${ROOT}/harden-gha-runners.sh"
    set +e
    r() { GHA_YES="$1" should_preload_config "$2" && printf 'yes' || printf 'no'; }
    printf '%s|%s|%s|%s' "$(r 1 install)" "$(r 1 reconfigure)" "$(r '' install)" "$(r '' reconfigure)"
  ) </dev/null

  # then both unattended modes take the host's stored answers as a baseline.
  # `reconfigure` is the one that matters: it is not gated on a stored file, so
  # without this an omitted key falls to a wizard default and a box stored as
  # `untrusted` comes back `internal`, no longer wiping Docker between jobs.
  assert_eq "should preload for an unattended install"     "yes" "$(cut -d'|' -f1 <<<"$got")"
  assert_eq "should preload for an unattended reconfigure" "yes" "$(cut -d'|' -f2 <<<"$got")"
  assert_eq "should preload for an interactive install, which offers to reuse it" \
    "yes" "$(cut -d'|' -f3 <<<"$got")"
  assert_eq "should NOT preload for an interactive reconfigure, which re-asks everything" \
    "no" "$(cut -d'|' -f4 <<<"$got")"
}
it_preloads_the_stored_answers_for_every_unattended_run

it_takes_an_unattended_default_instead_of_reaching_for_a_terminal() {
  # given a first install: nothing stored, and an answer the config omitted
  # when the wizard asks for it with GHA_YES set and no terminal anywhere
  # setsid for the same reason as the case below: if the GHA_YES branch this
  # test guards is ever removed, ask falls to ensure_tty, opens the controlling
  # terminal a command substitution inherits, and blocks on `read` forever with
  # the prompt discarded. A regression here must be red, not a silent hang.
  local got
  got=$(setsid bash -c '
    source "$1/harden-gha-runners.sh"
    set +e
    export GHA_YES=1
    unset GHA_COUNT GHA_TRUST
    ask GHA_COUNT "Runners on this machine" "4" >/dev/null 2>&1
    ask_menu GHA_TRUST "trust?" "internal:Internal" "untrusted:Untrusted" >/dev/null 2>&1
    printf "%s|%s" "${GHA_COUNT:-DIED}" "${GHA_TRUST:-DIED}"
  ' _ "$ROOT" 2>/dev/null </dev/null)

  # then the supplied default is taken. A default that can only be reached
  # through a tty is unusable to fleet.sh, which has no pty -- and the values
  # cannot override anything, because this path is only reached when the host
  # has no stored answer at all.
  assert_eq "should take a plain default unattended rather than needing a tty" \
    "4" "${got%%|*}"
  assert_eq "should take a menu's first option unattended rather than needing a tty" \
    "internal" "${got##*|}"
}
it_takes_an_unattended_default_instead_of_reaching_for_a_terminal

it_still_refuses_to_invent_an_answer_that_has_no_safe_default() {
  # given a required answer with no default (the admin PAT)
  # when it is asked for unattended
  # `setsid`, not just </dev/null: ensure_tty's second branch opens /dev/tty,
  # the CONTROLLING terminal, which a command substitution inherits whatever
  # stdin is. Without detaching, this passes in CI (no controlling terminal)
  # and blocks forever on `read` when the suite is run from a real shell --
  # with the prompt swallowed by the surrounding 2>&1, so it hangs silently.
  local out
  out=$(setsid bash -c '
    source "$1/harden-gha-runners.sh"
    set +e
    export GHA_YES=1
    unset GHA_ORG
    ask GHA_ORG "GitHub organisation login" 2>&1
  ' _ "$ROOT" 2>&1 </dev/null)

  # then it fails loudly instead of guessing
  assert_contains "should refuse to invent an answer that has no default" \
    "$out" "no terminal available"
}
it_still_refuses_to_invent_an_answer_that_has_no_safe_default

it_survives_nounset_with_nothing_supplied() {
  # given a caller that exports no GHA_* at all, so the saved-values array is
  # empty -- the case that would blow up under `set -u` without the guards
  setup_stored_config

  # when the configuration is loaded with nounset in force
  local got
  got=$(load_config_probe 'unset GHA_SCOPE GHA_ORG GHA_REPO GHA_GROUP_ID GHA_LABELS GHA_COUNT GHA_TRUST GHA_OLD_USER GHA_PAT')

  # then it completes rather than dying on an unbound variable
  assert_eq "should load under nounset when the caller supplied nothing" \
    "self-hosted,linux,x64,internal" "${got%%|*}"
}
it_survives_nounset_with_nothing_supplied

it_uses_the_stored_answers_when_the_caller_sends_nothing() {
  # given a mode that supplies no answers at all (verify, reap, diagnose...)
  setup_stored_config

  # when the configuration is loaded
  local got
  got=$(load_config_probe 'unset GHA_LABELS GHA_COUNT GHA_PAT')

  # then every value comes from the host, exactly as before
  assert_eq "should use the stored labels when the caller sends none" \
    "self-hosted,linux,x64,internal" "${got%%|*}"
  assert_eq "should use the stored runner count when the caller sends none" \
    "3" "$(cut -d'|' -f2 <<<"$got")"
}
it_uses_the_stored_answers_when_the_caller_sends_nothing

echo
echo "runner unit health"

# Everything else in phase_verify talks to systemd and cannot be exercised
# here; runner_state_between_jobs is the one part that is pure, and it is the
# part that decides whether a `verify` run passes.
# between_jobs_probe <ActiveState> <Result> <ExecMainStatus> -> "yes" | "no"
between_jobs_probe() {
  (
    # shellcheck source=/dev/null
    source "${ROOT}/harden-gha-runners.sh"
    set +e
    if runner_state_between_jobs "$1" "$2" "$3"; then echo yes; else echo no; fi
  )
}

it_treats_a_clean_auto_restart_as_a_runner_between_jobs() {
  # given the state systemd reports for the ten seconds after a job finishes
  # cleanly: the unit exited 0 and Restart=always is waiting out RestartSec
  local state=(activating success 0)

  # when the state is judged
  local got
  got=$(between_jobs_probe "${state[@]}")

  # then it is healthy - this is the normal state of an ephemeral runner, and
  # failing on it made verify unusable as a fleet health gate
  assert_eq "should treat a clean auto-restart as a runner between jobs" "yes" "$got"
}
it_treats_a_clean_auto_restart_as_a_runner_between_jobs

it_still_reports_a_restart_that_followed_a_failed_run() {
  # given the two shapes a genuine restart loop takes
  local bad_result bad_exit

  # when each is judged
  bad_result=$(between_jobs_probe activating exit-code 2)
  bad_exit=$(between_jobs_probe activating success 1)

  # then neither is excused: an auto-restart is only healthy when the run it
  # follows succeeded
  assert_eq "should still report a restart after a non-success result" "no" "$bad_result"
  assert_eq "should still report a restart after a non-zero exit" "no" "$bad_exit"
}
it_still_reports_a_restart_that_followed_a_failed_run

it_still_reports_a_unit_that_is_not_coming_back() {
  # given a stopped unit and a failed one
  local stopped failed

  # when each is judged
  stopped=$(between_jobs_probe inactive success 0)
  failed=$(between_jobs_probe failed exit-code 1)

  # then both keep the old behaviour - only "activating" is ever excused
  assert_eq "should still report an inactive unit" "no" "$stopped"
  assert_eq "should still report a failed unit" "no" "$failed"
}
it_still_reports_a_unit_that_is_not_coming_back

echo
echo "disk guard"

# gha-diskguard is generated, so it is rendered from the real installer, then
# sourced and driven against a scratch runner tree. The one thing it does that
# a test cannot is the privilege drop, which needs root: as_runner is replaced
# by running the command as whoever runs the suite, and nothing else changes.
( source "${ROOT}/harden-gha-runners.sh"; render_diskguard ) > "${WORK}/gha-diskguard" 2>/dev/null

# guard_probe <commands> -> runs <commands> in a subshell with the guard loaded
# and its globals pointed at the scratch runner under ${WORK}/g
guard_probe() {
  (
    # shellcheck source=/dev/null
    source "${WORK}/gha-diskguard"
    set +e
    N=1; U="$(id -un)"; SOFT=75
    RUID=4294967294       # no such user: no docker socket, so prune_docker is inert
    RUNNER_BASE="${WORK}/g/opt"; H="${WORK}/g/home"; TC="${WORK}/g/tc"
    declare -A WHERE=([work]="${RUNNER_BASE}/1" [tools]="$TC" [home]="$H")
    as_runner() { env HOME="$H" "$@"; }
    eval "$1"
  )
}

fresh_runner_tree() {
  chmod -R u+w "${WORK}/g" 2>/dev/null; rm -rf "${WORK}/g"
  mkdir -p "${WORK}/g/opt/1" "${WORK}/g/home" "${WORK}/g/tc"
}

# put <file> [<days since a job last read it>] - nothing reads a fixture after
# this, so the atime it is given is the one the guard sees
put() {
  mkdir -p "$(dirname "$1")"; printf 'x' > "$1"
  [[ -z "${2:-}" ]] || touch -a -d "$2 days ago" "$1"
}

exists() { if [[ -e "$1" || -L "$1" ]]; then echo yes; else echo no; fi; }

it_ships_a_guard_that_parses() {
  # given the guard exactly as the installer writes it
  # when it is parsed
  local rc=0
  bash -n "${WORK}/gha-diskguard" 2>/dev/null || rc=$?

  # then it is a valid script - the unit would otherwise fail its first start
  assert_eq "should render a disk guard that parses" "0" "$rc"
}
it_ships_a_guard_that_parses

it_runs_the_guard_before_the_registration_is_minted() {
  # given the unit template the installer writes
  # when the order of its ExecStartPre lines is read
  local guard mint
  guard=$(grep -n '^ExecStartPre=.*gha-diskguard' "${ROOT}/harden-gha-runners.sh" | cut -d: -f1)
  mint=$(grep -n '^ExecStartPre=.*gha-jitconfig' "${ROOT}/harden-gha-runners.sh" | cut -d: -f1)

  # then the guard runs first: an unregistered runner cannot be handed a job,
  # which is the only thing that makes deleting its caches safe
  if [[ -n "$guard" && -n "$mint" ]] && (( guard < mint )); then
    pass "should run the guard while the runner is still unregistered"
  else
    fail "should run the guard while the runner is still unregistered" \
         "guard at line [${guard}], JIT mint at line [${mint}]"
  fi
}
it_runs_the_guard_before_the_registration_is_minted

it_evicts_only_what_no_job_has_read_in_a_week() {
  # given a tool cache and a home whose entries were last read at different times
  fresh_runner_tree
  local tc="${WORK}/g/tc" h="${WORK}/g/home"
  put "${tc}/go/1.20.0/x64/bin/go" 30
  put "${tc}/go/1.22.0/x64/bin/go" 30
  put "${tc}/go/1.22.0/x64/src/fmt.go"                 # read today
  put "${tc}/flutter/3.0.0/x64/bin/flutter" 30
  put "${h}/.cache/pip/wheel" 30
  put "${h}/.cache/go-build/ab/cd"                     # read today
  put "${h}/.pub-cache/hosted/pkg/lib.dart" 30
  put "${h}/go/pkg/mod/mod.go"                         # read today

  # when the two stale steps run
  guard_probe 'evict_stale_tools; evict_stale_home' >/dev/null

  # then exactly the entries nobody read in a week are gone, each one whole
  assert_eq "should evict a tool version no job has read in a week" \
    "no" "$(exists "${tc}/go/1.20.0")"
  assert_eq "should keep a tool version if any file in it was read this week" \
    "yes" "$(exists "${tc}/go/1.22.0/x64/bin/go")"
  assert_eq "should remove a tool whose last version was evicted" \
    "no" "$(exists "${tc}/flutter")"
  assert_eq "should judge each ~/.cache child alone, evicting the stale one" \
    "no" "$(exists "${h}/.cache/pip")"
  assert_eq "should judge each ~/.cache child alone, keeping the one in use" \
    "yes" "$(exists "${h}/.cache/go-build/ab/cd")"
  assert_eq "should evict a stale top-level cache from the home" \
    "no" "$(exists "${h}/.pub-cache")"
  assert_eq "should keep a top-level cache read this week" \
    "yes" "$(exists "${h}/go/pkg/mod/mod.go")"
}
it_evicts_only_what_no_job_has_read_in_a_week

it_resets_a_home_to_what_the_rootless_daemon_needs() {
  # given a home holding the rootless Docker plumbing and what jobs left behind,
  # including the kind of thing a hostile job would plant for the next one
  fresh_runner_tree
  local h="${WORK}/g/home" wants="${WORK}/g/home/.config/systemd/user/default.target.wants"
  put "${h}/.config/systemd/user/docker.service"
  mkdir -p "$wants"
  ln -s "${h}/.config/systemd/user/docker.service" "${wants}/docker.service"
  put "${h}/.local/share/docker/overlayfs/layer"
  put "${h}/.config/systemd/user/planted.service"
  ln -s "${h}/.config/systemd/user/planted.service" "${wants}/planted.service"
  put "${h}/.docker/config.json"
  put "${h}/.docker/cli-plugins/docker-buildx"
  put "${h}/.bashrc"
  put "${h}/.profile"
  put "${h}/.config/gh/hosts.yml"
  put "${h}/.local/share/flutter/sdk"
  put "${h}/.local/bin/tool"
  put "${h}/.npm/_cacache/index"
  put "${h}/.gitconfig"
  put "${h}/.ssh/config"

  # when the home is reset
  guard_probe 'reset_home' >/dev/null

  # then the daemon still starts and still has its images, and nothing a job
  # wrote survives - least of all what would run in the next job
  assert_eq "should keep the rootless daemon's user unit" \
    "yes" "$(exists "${h}/.config/systemd/user/docker.service")"
  assert_eq "should keep the link that starts the daemon at boot" \
    "yes" "$(exists "${wants}/docker.service")"
  assert_eq "should leave the Docker data root to docker, never to rm" \
    "yes" "$(exists "${h}/.local/share/docker/overlayfs/layer")"
  assert_eq "should remove a user unit a job planted beside the daemon's" \
    "no" "$(exists "${h}/.config/systemd/user/planted.service")"
  assert_eq "should remove the link that would have started the planted unit" \
    "no" "$(exists "${wants}/planted.service")"
  assert_eq "should remove the Docker CLI config, where a credential helper or plugin hides" \
    "no" "$(exists "${h}/.docker")"
  assert_eq "should remove login-shell dotfiles a job could have rewritten" \
    "no" "$(exists "${h}/.profile")"
  assert_eq "should remove a tool's config a job wrote" "no" "$(exists "${h}/.config/gh")"
  assert_eq "should remove an SDK unpacked beside the Docker data root" \
    "no" "$(exists "${h}/.local/share/flutter")"
  assert_eq "should remove binaries a job installed to ~/.local/bin" "no" "$(exists "${h}/.local/bin")"
  assert_eq "should remove a package cache" "no" "$(exists "${h}/.npm")"
  assert_eq "should remove dotfiles a job wrote" "no" "$(exists "${h}/.gitconfig")"
  assert_eq "should remove an ssh config a job could have planted" "no" "$(exists "${h}/.ssh")"
}
it_resets_a_home_to_what_the_rootless_daemon_needs

it_removes_a_read_only_go_module_cache() {
  # given Go's module cache, which Go makes read-only on purpose
  fresh_runner_tree
  local mod="${WORK}/g/home/go/pkg/mod/example.com/m@v1.0.0"
  put "${mod}/m.go"
  chmod 0444 "${mod}/m.go"
  chmod 0555 "$mod" "$(dirname "$mod")"

  # when the home is reset
  guard_probe 'reset_home' >/dev/null

  # then it is gone - rm alone cannot unlink inside a directory it cannot write
  assert_eq "should remove a read-only module cache" "no" "$(exists "${WORK}/g/home/go")"
}
it_removes_a_read_only_go_module_cache

it_never_follows_a_planted_symlink() {
  # given symlinks a job planted in its home, one where the walk would descend
  fresh_runner_tree
  local h="${WORK}/g/home" outside="${WORK}/g/outside"
  put "${outside}/precious"
  mkdir -p "${h}/.cache"
  ln -s "$outside" "${h}/.cache/evil"
  ln -s "$outside" "${h}/.local"

  # when the home is reset
  guard_probe 'reset_home' >/dev/null

  # then only the links go. In production rm also runs as the runner user, so
  # a link to something root owns could not be followed into anyway.
  assert_eq "should not delete through a planted symlink" "yes" "$(exists "${outside}/precious")"
  assert_eq "should remove the planted symlink itself" "no" "$(exists "${h}/.cache/evil")"
  assert_eq "should not descend into a symlinked directory" "no" "$(exists "${h}/.local")"
}
it_never_follows_a_planted_symlink

# steps_probe <disk % before any step> <disk % once stale tools are evicted>
#   -> the steps the guard took, in order
steps_probe() {
  fresh_runner_tree
  guard_probe "
    calls=()
    use_pct()  { if [[ -e \"\${WORK}/g/freed\" ]]; then echo $2; else echo $1; fi; }
    avail_mb() { echo 0; }
    log()      { :; }
    drop_leftover_work() { calls+=(work); }
    evict_stale_tools()  { calls+=(tools); : > \"\${WORK}/g/freed\"; }
    evict_stale_home()   { calls+=(home); }
    prune_docker()       { calls+=(docker); }
    wipe_toolcache()     { calls+=(wipe); }
    reset_home()         { calls+=(reset); }
    run_steps
    echo \"\${calls[*]}\""
}

it_stops_as_soon_as_the_disk_is_back_under_the_threshold() {
  # given a disk at 90% that evicting stale tool versions brings to 60%
  # when the guard runs its steps
  local got; got=$(steps_probe 90 60)

  # then nothing costlier runs: the warm caches jobs are using stay warm
  assert_eq "should stop at the first step that brings the disk under the threshold" \
    "work tools" "$got"
}
it_stops_as_soon_as_the_disk_is_back_under_the_threshold

it_escalates_cheapest_loss_first_while_the_disk_stays_full() {
  # given a disk no step manages to free
  # when the guard runs its steps
  local got; got=$(steps_probe 95 95)

  # then every step runs, in the order that loses the least warm cache first
  assert_eq "should escalate one step at a time, cheapest loss first" \
    "work tools home docker wipe reset" "$got"
}
it_escalates_cheapest_loss_first_while_the_disk_stays_full

it_does_nothing_below_the_threshold() {
  # given a disk under the soft threshold
  # when the guard runs its steps
  local got; got=$(steps_probe 50 50)

  # then it touches nothing - a box with room keeps every cache warm
  assert_eq "should take no step below the soft threshold" "" "$got"
}
it_does_nothing_below_the_threshold

it_resets_an_untrusted_runner_in_full_whatever_the_disk_says() {
  # given an untrusted runner on a near-empty disk, its caches read minutes ago
  fresh_runner_tree
  local tc="${WORK}/g/tc" h="${WORK}/g/home"
  put "${WORK}/g/opt/1/_work/repo/checkout"
  put "${tc}/node/22.0.0/x64/bin/node"
  put "${h}/.cache/go-build/ab/cd"
  put "${h}/.gitconfig"
  put "${h}/.local/share/docker/overlayfs/layer"

  # when the guard readies it for its next job
  guard_probe 'use_pct() { echo 10; }; reset_runner' >/dev/null

  # then nothing a job left survives, fresh or not: a runner serving fork PRs
  # has no warm cache worth protecting, only state a job could have planted
  assert_eq "should drop a workspace a job left behind" \
    "no" "$(exists "${WORK}/g/opt/1/_work")"
  assert_eq "should empty the tool cache, versions in use included" \
    "no" "$(exists "${tc}/node")"
  assert_eq "should empty the home, caches read minutes ago included" \
    "no" "$(exists "${h}/.cache/go-build")"
  assert_eq "should remove config a fork PR could have planted" \
    "no" "$(exists "${h}/.gitconfig")"
  assert_eq "should still leave the Docker data root to docker" \
    "yes" "$(exists "${h}/.local/share/docker/overlayfs/layer")"
}
it_resets_an_untrusted_runner_in_full_whatever_the_disk_says

echo
echo "restart backoff"

# installer_probe <commands> -> runs <commands> with the installer's functions
# loaded, in a subshell, for the same reason as load_config_probe
installer_probe() {
  (
    # shellcheck source=/dev/null
    source "${ROOT}/harden-gha-runners.sh"
    set +e
    eval "$1"
  )
}

it_restarts_a_healthy_runner_at_once_and_backs_a_failing_one_off() {
  # given runners whose last 0, 1, 2 ... starts in a row ran no job
  # when the wait before each one's next registration is worked out
  local got
  got=$(installer_probe 'for n in 0 1 2 3 5 6 40 junk; do printf "%s " "$(restart_backoff_delay "$n")"; done')

  # then one that just ran a job waits for nothing, and one that keeps failing
  # waits longer each time, never more than five minutes
  assert_eq "should wait 0s after a job, then 10s doubling per job-less start, capped at 300s" \
    "0 10 20 40 160 300 300 0 " "$got"
}
it_restarts_a_healthy_runner_at_once_and_backs_a_failing_one_off

it_counts_a_cycle_as_healthy_only_when_a_job_ran() {
  # given runner trees after four kinds of cycle
  local r="${WORK}/cycles" c
  rm -rf "$r"; mkdir -p "$r"/{ran,idle,listener,unminted}/_diag
  for c in ran idle listener; do touch -d '10 minutes ago' "${r}/${c}/minted"; done
  touch -d '5 minutes ago'  "${r}/ran/_diag/Worker_20260101-000000-utc.log"      # a job after the mint
  touch -d '20 minutes ago' "${r}/idle/_diag/Worker_20251231-000000-utc.log"     # only an older job
  touch -d '5 minutes ago'  "${r}/listener/_diag/Runner_20260101-000000-utc.log" # listener, no job
  touch -d '5 minutes ago'  "${r}/unminted/_diag/Worker_20260101-000000-utc.log" # never minted

  # when each cycle is judged
  local got
  got=$(installer_probe "
    for c in ran idle listener unminted; do
      if cycle_ran_a_job \"${r}/\$c\" \"${r}/\$c/minted\"; then printf 'yes '; else printf 'no '; fi
    done")

  # then only a Worker log written after this cycle's mint counts. The exit
  # status could not tell: the runner exits 0 whether or not a job ran.
  assert_eq "should count a cycle healthy only when a job ran after its mint" \
    "yes no no no " "$got"
}
it_counts_a_cycle_as_healthy_only_when_a_job_ran

it_ships_jit_helpers_that_parse_and_carry_the_tested_backoff() {
  # given the two JIT helpers exactly as the installer writes them
  local jc="${WORK}/gha-jitconfig" jr="${WORK}/gha-jitreap" rc=0 wait
  installer_probe 'render_jitconfig' > "$jc" 2>/dev/null
  installer_probe 'render_jitreap' > "$jr" 2>/dev/null

  # when they are parsed, and the backoff spliced into gha-jitconfig is run
  { bash -n "$jc" && bash -n "$jr"; } 2>/dev/null || rc=1
  wait=$(bash -c "$(sed -n '/^restart_backoff_delay ()/,/^}/p' "$jc"); restart_backoff_delay 3" 2>&1)

  # then both are valid, and each carries the one definition this suite tests
  # rather than a copy that could drift from it
  assert_eq "should render JIT helpers that parse" "0" "$rc"
  assert_eq "should splice the tested backoff into gha-jitconfig" "40" "$wait"
  assert_contains "should splice the tested job check into gha-jitreap" \
    "$(cat "$jr")" "cycle_ran_a_job ()"
}
it_ships_jit_helpers_that_parse_and_carry_the_tested_backoff

it_no_longer_lets_systemd_back_off_healthy_runners() {
  # given the unit template the installer writes
  # when it is searched for systemd's own restart backoff
  local found
  found=$(grep -cE '^[^#]*(RestartSteps|RestartMaxDelaySec)=[0-9]' "${ROOT}/harden-gha-runners.sh")

  # then there is none: it counts every restart, and every job ends in one, so
  # it idled each healthy runner five minutes before every job
  assert_eq "should not set RestartSteps or RestartMaxDelaySec" "0" "$found"
}
it_no_longer_lets_systemd_back_off_healthy_runners

echo
printf '%d passed, %d failed\n' "$PASS" "$FAIL"
(( FAIL == 0 )) || exit 1
