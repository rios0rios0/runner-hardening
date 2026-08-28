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
set -uo pipefail

ROOT="$(cd -- "$(dirname -- "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

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
# shellcheck disable=SC2034
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
  # shellcheck disable=SC2034
  out=$( MODE=""; NO_PAT=0; PAT_FILE=""; parse_args --no-pat --pat-file /tmp/x install 2>&1 )

  # then it fails at startup rather than silently picking one
  assert_contains "should reject --no-pat together with --pat-file" \
    "$out" "contradict each other"
}
it_rejects_no_pat_with_pat_file

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
  # A directive covers only the next command, and `a=1; b=2` is two commands.
  # shellcheck disable=SC2034  # all three are read by build_bootstrap, in fleet.sh
  MODE=version
  # shellcheck disable=SC2034
  ADMIN_PAT=""
  # shellcheck disable=SC2034
  NEW_PAT=""
  INSTALLER="${ROOT}/harden-gha-runners.sh"
  parse_config "${WORK}/basic.conf"
  # shellcheck disable=SC2034  # read by build_bootstrap, which lives in fleet.sh
  INSTALLER_B64="$(base64 < "$INSTALLER")"

  # when it is transferred and asked to identify itself
  local out expected
  out="$(build_bootstrap host1 | bash -s 2>&1)"
  expected="$(sha256sum "$INSTALLER" | cut -c1-12)"

  # then the checksum it reports for itself matches the local file
  assert_contains "should transfer the installer without altering a byte" "$out" "sha256:${expected}"
}
it_ships_the_installer_byte_for_byte

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
    set +eu
    # Both are read by load_config, which lives in harden-gha-runners.sh.
    # shellcheck disable=SC2034
    ENV_FILE="${WORK}/inst_env"
    # shellcheck disable=SC2034
    PAT_FILE="${WORK}/inst_pat"
    eval "$1"
    load_config >/dev/null 2>&1
    printf '%s|%s|%s|%s' "${GHA_LABELS}" "${GHA_COUNT}" "${GHA_PAT}" "${RUNNER_NAME_PREFIX}"
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
printf '%d passed, %d failed\n' "$PASS" "$FAIL"
(( FAIL == 0 )) || exit 1
