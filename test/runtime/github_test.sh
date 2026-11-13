#!/usr/bin/env bash
#
# github_test.sh - the GitHub flavour's runtime: gha-jitconfig, gha-jitreap,
# the one-job wrapper and vendor.sh, each driven as shipped against a scratch
# box (see harness.sh for what may be substituted, and why).
#
# Run from anywhere:  bash test/runtime/github_test.sh   (or: make test)

# shellcheck source=harness.sh
. "$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")/harness.sh"

TOKEN="fixture-token-placeholder"

# The box's /etc/github-runner, in the installer's exact format. Its
# RUNNER_BASE is a real box's, not this box's: host.env is where the helpers
# must take their paths from, and a helper that took this one instead would
# look for its runner's tree in the wrong place.
github_config() {
  cat > "$BOX/etc/github-runner/env" <<'EOF'
GHA_SCOPE="org"
GHA_ORG="your-org"
GHA_REPO=""
GHA_GROUP_ID="1"
GHA_LABELS="self-hosted,linux,x64,internal"
GHA_COUNT="3"
GHA_TRUST="internal"
GHA_OLD_USER="none"
GHA_HEAVY_RUNNERS="1"
GHA_CODEQL_RAM="auto"
GHA_SLICE_CEILING="none"
WIPE_DOCKER_AFTER_JOB="false"
SHARE_TOOLCACHE="true"
RUNNER_NAME_PREFIX="build-01"
USER_PREFIX="gha"
RUNNER_BASE="/opt/actions-runner"
EOF
  printf '%s' "$TOKEN" > "$BOX/etc/github-runner/pat"
  chmod 0600 "$BOX/etc/github-runner/env" "$BOX/etc/github-runner/pat"
}

new_box

echo "JIT helpers"

it_ships_helpers_that_parse() {
  # given the JIT helpers, the wrapper and the hooks exactly as the role installs them
  # when each is parsed
  local f bad=""
  for f in gha-jitconfig.sh gha-jitreap.sh gha-run-ephemeral.sh vendor.sh; do
    bash -n "${GITHUB_FILES}/${f}" 2>/dev/null || bad+="${f} "
  done

  # then every one is a valid script - the unit would otherwise fail its first start
  assert_eq "should ship JIT helpers, wrapper and hooks that parse" "" "$bad"
}
it_ships_helpers_that_parse

it_carries_the_tested_backoff_from_lib_rather_than_a_copy() {
  # given gha-jitconfig and gha-jitreap as the role installs them
  # when each is loaded the way it loads on a box, sourcing lib.sh
  local wait jc_def lib_def jr_has copies
  wait=$( ( . "${GITHUB_FILES}/gha-jitconfig.sh"; restart_backoff_delay 3 ) 2>&1 )
  jc_def=$( ( . "${GITHUB_FILES}/gha-jitconfig.sh"; declare -f restart_backoff_delay ) 2>&1 )
  lib_def=$( ( . "${HOST_FILES}/lib.sh"; declare -f restart_backoff_delay ) 2>&1 )
  jr_has=$( ( . "${GITHUB_FILES}/gha-jitreap.sh"; declare -F cycle_ran_a_job record_cycle | tr '\n' ' ' ) 2>&1 )
  copies=$(cat "${GITHUB_FILES}"/gha-jit*.sh | grep -cE '^(restart_backoff_delay|cycle_ran_a_job|record_cycle|wait_out_backoff)\(\)')

  # then each carries the one definition the host suite tests, rather than a
  # copy that could drift from it
  assert_eq "should carry the tested backoff into gha-jitconfig" "40" "$wait"
  assert_eq "should take the backoff from lib.sh, not a definition of its own" "$lib_def" "$jc_def"
  assert_eq "should carry the tested job check into gha-jitreap" "cycle_ran_a_job record_cycle " "$jr_has"
  assert_eq "should define no copy of a lib.sh function in either helper" "0" "$copies"
}
it_carries_the_tested_backoff_from_lib_rather_than_a_copy

it_labels_only_the_first_heavy_runners_as_heavy() {
  # given a box whose first runner is set aside for heavy jobs
  # when each runner's labels are worked out
  local got
  got=$( ( . "${GITHUB_FILES}/gha-jitconfig.sh"
           printf "%s|" "$(runner_labels 1 self-hosted,x64 1)" "$(runner_labels 2 self-hosted,x64 1)" \
                        "$(runner_labels 1 self-hosted,x64 0)" "$(runner_labels 1 self-hosted,heavy 1)" \
                        "$(runner_labels 1 self-hosted,x64 junk)" ) 2>&1 )

  # then only runner 1 carries `heavy`, a count of 0 labels nobody, a label set
  # that already has it is not given a second, and a count that is not a
  # number is taken as none rather than as all
  assert_eq "should label runner 1 heavy when one runner is set aside" \
    "self-hosted,x64,heavy" "$(cut -d'|' -f1 <<<"$got")"
  assert_eq "should leave runner 2 as it is when only one runner is set aside" \
    "self-hosted,x64" "$(cut -d'|' -f2 <<<"$got")"
  assert_eq "should label nobody heavy when no runner is set aside" \
    "self-hosted,x64" "$(cut -d'|' -f3 <<<"$got")"
  assert_eq "should not add heavy twice" \
    "self-hosted,heavy" "$(cut -d'|' -f4 <<<"$got")"
  assert_eq "should treat a count that is not a number as none" \
    "self-hosted,x64" "$(cut -d'|' -f5 <<<"$got")"
}
it_labels_only_the_first_heavy_runners_as_heavy

it_ships_a_jit_helper_that_registers_with_the_tested_labels() {
  # given gha-jitconfig exactly as the role installs it
  local jc labels
  jc=$(cat "${GITHUB_FILES}/gha-jitconfig.sh")

  # when the label function it defines is run
  labels=$( ( . "${GITHUB_FILES}/gha-jitconfig.sh"; runner_labels 1 self-hosted 1 ) 2>&1 )

  # then it is the one this suite tests, and what it works out - not the
  # host-wide GHA_LABELS - is what the registration is sent with
  assert_eq "should define the tested label function in gha-jitconfig" "self-hosted,heavy" "$labels"
  assert_contains "should work out this runner's labels with runner_labels" \
    "$jc" 'labels=$(runner_labels "$n" "$GHA_LABELS"'
  assert_contains "should register with the labels it worked out" \
    "$jc" "split(\",\")' <<<\"\$labels\")"
}
it_ships_a_jit_helper_that_registers_with_the_tested_labels

# mint_probe <n> -> gha-jitconfig's own main for runner <n>, against the box.
# It reaches the network only through the stand-in curl, which fails, so it
# stops before anything root-only (the chown of the registration) is reached.
mint_probe() {
  ( . "${GITHUB_FILES}/gha-jitconfig.sh"; main "$1" )
}

it_mints_with_the_token_in_a_file_and_the_runners_own_labels() {
  # given a box whose answers and admin token are stored
  if ! command -v jq >/dev/null; then
    printf 'skip  minting through the real helper: jq is not installed\n'; return
  fi
  new_box; github_config

  # when runners 1 and 2 ask to register, and the API cannot be reached
  local out1 rc1 out2 calls
  out1=$(mint_probe 1 2>&1); rc1=$?
  out2=$(mint_probe 2 2>&1)
  calls=$(cat "$BOX/state/curl.log" 2>/dev/null)

  # then the request names the token only as a file, each runner asks for its
  # own labels, and a failed request fails the start loudly
  assert_contains "should pass the token to curl as a header file" "$calls" "-H @"
  assert_not_contains "should never put the token on curl's command line" "$calls" "$TOKEN"
  assert_contains "should ask GitHub for an org-scoped JIT config" "$calls" "/orgs/your-org/actions/runners/generate-jitconfig"
  assert_contains "should register runner 1 with the heavy label" "$(head -1 <<<"$calls")" '"internal","heavy"]'
  assert_not_contains "should register runner 2 without it" "$(sed -n 2p <<<"$calls")" '"heavy"'
  assert_contains "should name the runner after the box, its number and the time" "$calls" '"name":"build-01-1-'
  assert_eq "should fail the start when the API cannot be reached" "1" "$rc1"
  assert_contains "should say why the start failed" "$out1" "API request failed"
  assert_eq "should leave no registration behind for a failed start" "no" "$(exists "$BOX/run/gha-runner/1.jit")"
  assert_not_contains "should not wait out a backoff with no job-less cycle counted" "$out2" "waiting"
}
it_mints_with_the_token_in_a_file_and_the_runners_own_labels

# reap_probe -> gha-jitreap's own main for runner 1, as root would run it; the
# run directory is not chowned to root, the one root-only step
reap_probe() {
  (
    # shellcheck source=../../roles/runner_github/files/gha-jitreap.sh
    . "${GITHUB_FILES}/gha-jitreap.sh"
    ensure_run_dir() { mkdir -p "$(run_dir)"; }
    main 1
  )
}

it_counts_a_cycle_that_ran_no_job_and_cleans_up_its_registration() {
  # given runner 1 at the end of a cycle that ran no job, whose registration
  # id was recorded
  new_box; github_config
  mkdir -p "$BOX/opt/actions-runner/1/_diag"
  touch -d '10 minutes ago' "$BOX/run/gha-runner/1.jit"
  printf '123' > "$BOX/run/gha-runner/1.id"

  # when its ExecStopPost runs
  local rc=0; reap_probe >/dev/null 2>&1 || rc=$?
  local calls; calls=$(cat "$BOX/state/curl.log" 2>/dev/null)

  # then the cycle is counted for the backoff, the registration is deleted with
  # the token in a file, the markers are gone, and the stop never fails
  assert_eq "should count the job-less cycle" "1" "$(cat "$BOX/run/gha-runner/1.fails" 2>/dev/null)"
  assert_contains "should delete the registration it minted" "$calls" "-X DELETE"
  assert_contains "should delete it at the configured scope" "$calls" "/orgs/your-org/actions/runners/123"
  assert_contains "should pass the token as a header file" "$calls" "-H @"
  assert_not_contains "should never put the token on curl's command line" "$calls" "$TOKEN"
  assert_eq "should remove the cycle's markers" "no no" \
    "$(exists "$BOX/run/gha-runner/1.jit") $(exists "$BOX/run/gha-runner/1.id")"
  assert_eq "should exit 0 even when the API cannot be reached" "0" "$rc"
}
it_counts_a_cycle_that_ran_no_job_and_cleans_up_its_registration

it_clears_the_count_after_a_job_judged_in_host_envs_tree() {
  # given runner 1 backing off, whose latest cycle ran a job in the tree
  # host.env names - not in the RUNNER_BASE the env file still carries
  new_box; github_config
  mkdir -p "$BOX/opt/actions-runner/1/_diag"
  echo 3 > "$BOX/run/gha-runner/1.fails"
  touch -d '10 minutes ago' "$BOX/run/gha-runner/1.jit"
  touch -d '5 minutes ago' "$BOX/opt/actions-runner/1/_diag/Worker_20261112-000000-utc.log"

  # when its ExecStopPost runs
  reap_probe >/dev/null 2>&1

  # then the count is cleared, and with no registration recorded there was
  # nothing to delete
  assert_eq "should clear the count after a cycle that ran a job" "no" "$(exists "$BOX/run/gha-runner/1.fails")"
  assert_eq "should make no API call with no registration recorded" "no" "$(exists "$BOX/state/curl.log")"
}
it_clears_the_count_after_a_job_judged_in_host_envs_tree

it_never_puts_the_token_on_a_command_line() {
  # given every runtime script, comments dropped and continuation lines joined
  # so that one curl call reads as one line
  local f joined line bad="" writes_a_file names_a_token
  writes_a_file=$(cat <<'RE'
^[[:space:]]*printf 'Authorization: Bearer %s\\n' "[^"]+" > "\$[A-Za-z_]+"$
RE
)
  names_a_token='\$\{?(GHA_)?(PAT|pat)([^A-Za-z0-9_]|$)'

  # when every curl call, and every line that spells the header, is read
  for f in "${HOST_FILES}"/*.sh "${GITHUB_FILES}"/*.sh; do
    joined=$(sed -e ':a' -e '/\\$/N' -e 's/\\\n//' -e 'ta' "$f" | grep -v '^[[:space:]]*#')
    while IFS= read -r line; do
      if [[ "$line" == *curl* ]] && [[ "$line" == *Authorization* || "$line" =~ $names_a_token ]]; then
        bad+="${f##*/}: ${line}"$'\n'
      fi
      if [[ "$line" == *Bearer* ]] && ! [[ "$line" =~ $writes_a_file ]]; then
        bad+="${f##*/}: ${line}"$'\n'
      fi
    done <<<"$joined"
  done

  # then the token is only ever written to a file, which curl reads with
  # -H @file: /proc/<pid>/cmdline is readable by every runner user on the box
  assert_eq "should write the token only to a file, never into a curl argument" "" "$bad"
}
it_never_puts_the_token_on_a_command_line

echo
echo "the one-job wrapper"

# A runner tree whose run.sh stands in for the runner's own: it records what it
# was handed and from where, leaves something in _work the way a job does, and
# with RUNSH_SLEEP set waits until it is told to stop.
wrapper_tree() {
  local r="$BOX/opt/actions-runner/1"
  mkdir -p "$r"
  cat > "$r/run.sh" <<'EOF'
#!/usr/bin/env bash
log="${STANDIN_STATE:?}/run.log"
{
  printf 'args=%s\n' "$*"
  printf 'ppid=%s\n' "$PPID"
  printf 'work-entries=%s\n' "$(find _work -mindepth 1 2>/dev/null | wc -l | tr -d ' ')"
  printf 'toolsdir=%s\n' "${AGENT_TOOLSDIRECTORY-unset}"
} >> "$log"
mkdir -p _work/left-by-this-job && : > _work/left-by-this-job/out
if [[ -n "${RUNSH_SLEEP:-}" ]]; then
  trap 'echo "got=TERM" >> "$log"; kill "$sleeper" 2>/dev/null; exit 143' TERM
  sleep "$RUNSH_SLEEP" & sleeper=$!
  echo "ready" >> "$log"
  wait "$sleeper"
fi
exit "${RUNSH_EXIT:-0}"
EOF
  chmod 0755 "$r/run.sh"
  printf 'fixture-jit-placeholder' > "$BOX/run/gha-runner/1.jit"
  put "$r/_work/left-by-the-last-job"
}

# run_wrapper [KEY=VALUE...] -> the real wrapper for runner 1, started in the
# background with those in its environment; WRAPPER_PID is its pid
run_wrapper() {
  env -u AGENT_TOOLSDIRECTORY "$@" bash "${GITHUB_FILES}/gha-run-ephemeral.sh" 1 \
    > "$BOX/state/wrapper.out" 2>&1 &
  WRAPPER_PID=$!
}

it_runs_exactly_one_job_in_a_fresh_workspace_and_cleans_up_after_it() {
  # given runner 1 with a registration minted and the last job's workspace still there
  new_box; wrapper_tree

  # when the wrapper runs a job that ends with status 3
  local rc=0 log docker
  run_wrapper RUNSH_EXIT=3
  wait "$WRAPPER_PID" || rc=$?
  log=$(cat "$BOX/state/run.log" 2>/dev/null); docker=$(cat "$BOX/state/docker.log" 2>/dev/null)

  # then the runner was started once, on that registration, in an empty
  # workspace, as a child rather than exec'd; the job's status is the
  # wrapper's; and after it nothing of the job is left
  assert_eq "should start the runner exactly once" "1" "$(grep -c '^args=' <<<"$log")"
  assert_contains "should hand the runner this cycle's single-use registration" "$log" "args=--jitconfig fixture-jit-placeholder"
  assert_contains "should start the job in an emptied workspace" "$log" "work-entries=0"
  assert_contains "should run the runner as its child, never exec it" "$log" "ppid=${WRAPPER_PID}"
  assert_eq "should exit with the job's own status" "3" "$rc"
  assert_eq "should remove the workspace after the job" "no" "$(exists "$BOX/opt/actions-runner/1/_work")"
  assert_contains "should remove every container the job left" "$docker" "docker rm -f c1 c2"
  assert_contains "should remove every volume the job left" "$docker" "docker volume rm -f v1"
  assert_contains "should keep a trusted runner's layer cache, dropping only dangling images" "$docker" "docker image prune -f"
  assert_not_contains "should not wipe a trusted runner's whole Docker state" "$docker" "system prune"
  assert_contains "should set nothing a job sees itself: the unit's drop-in does" "$log" "toolsdir=unset"
}
it_runs_exactly_one_job_in_a_fresh_workspace_and_cleans_up_after_it

it_wipes_docker_whole_after_an_untrusted_runners_job() {
  # given an untrusted runner with a registration minted
  new_box github RUNNER_TRUST=untrusted; wrapper_tree

  # when the wrapper runs a job
  run_wrapper
  wait "$WRAPPER_PID"
  local docker; docker=$(cat "$BOX/state/docker.log" 2>/dev/null)

  # then Docker state goes whole, layer cache included
  assert_contains "should wipe an untrusted runner's whole Docker state" "$docker" "docker system prune -af --volumes"
  assert_not_contains "should not settle for dangling images" "$docker" "image prune"
}
it_wipes_docker_whole_after_an_untrusted_runners_job

it_forwards_a_stop_to_the_runner_and_still_cleans_up() {
  # given a runner in the middle of a job
  new_box; wrapper_tree
  run_wrapper RUNSH_SLEEP=5
  local _
  for _ in $(seq 1 100); do grep -qx ready "$BOX/state/run.log" 2>/dev/null && break; sleep 0.05; done

  # when systemd stops the unit
  kill -TERM "$WRAPPER_PID"
  wait "$WRAPPER_PID"
  for _ in $(seq 1 100); do grep -qx 'got=TERM' "$BOX/state/run.log" 2>/dev/null && break; sleep 0.05; done

  # then the runner hears the stop itself, so it can wind its job down, and
  # the post-job cleanup still runs
  assert_contains "should forward the stop to the runner" "$(cat "$BOX/state/run.log" 2>/dev/null)" "got=TERM"
  assert_eq "should still remove the workspace" "no" "$(exists "$BOX/opt/actions-runner/1/_work")"
  assert_contains "should still remove the job's containers" "$(cat "$BOX/state/docker.log" 2>/dev/null)" "docker rm -f c1 c2"
}
it_forwards_a_stop_to_the_runner_and_still_cleans_up

echo
echo "vendor hooks"

# vendor_probe <commands> -> <commands> with lib.sh, host.env and this
# flavour's vendor.sh loaded, the way <sbin>-admin loads them: from the box's
# lib directory, where vendor.sh sits beside lib.sh
vendor_probe() {
  (
    # shellcheck source=../../roles/runner_host/files/lib.sh
    . "${RUNNER_LIB_DIR}/lib.sh"
    load_host_env || { echo "load_host_env failed"; exit 1; }
    load_vendor
    eval "$1"
  )
}

it_defines_every_hook_and_always_counts_a_runner_as_registered() {
  # given a GitHub box
  new_box

  # when its hooks are looked up the way <sbin>-admin looks them up
  local hooks registered
  hooks=$(vendor_probe 'for h in vendor_verify vendor_diagnose vendor_reap vendor_janitor vendor_registered; do has_hook "$h" && printf "%s " "$h"; done')
  registered=$(vendor_probe 'vendor_registered 1 && echo yes || echo no')

  # then every hook is there, and a runner that registers itself at every
  # start is never "not registered yet"
  assert_eq "should define every hook" \
    "vendor_verify vendor_diagnose vendor_reap vendor_janitor vendor_registered " "$hooks"
  assert_eq "should count every runner as registered" "yes" "$registered"
}
it_defines_every_hook_and_always_counts_a_runner_as_registered

it_checks_the_token_file_and_asks_github_with_the_token_in_a_file() {
  # given a stored token that is not root's (as every file here is), and an
  # API the box cannot reach
  new_box; github_config

  # when verify runs the flavour's checks
  local out rc=0
  out=$(vendor_probe 'vendor_verify' 2>&1) || rc=$?
  local calls; calls=$(cat "$BOX/state/curl.log" 2>/dev/null)

  # then the wrong ownership fails verify, GitHub is still asked, and the
  # token never reaches curl's command line
  assert_contains "should fail a token file that is not 0600 root:root" "$out" "PAT file permissions are wrong"
  assert_eq "should return non-zero for it" "1" "$rc"
  assert_contains "should still ask GitHub, and say when it cannot" "$out" "could not list runners (HTTP 000)"
  assert_contains "should pass the token as a header file" "$calls" "-H @"
  assert_not_contains "should never put the token on curl's command line" "$calls" "$TOKEN"
}
it_checks_the_token_file_and_asks_github_with_the_token_in_a_file

it_shows_how_to_start_a_runner_by_hand_without_sudo_inside() {
  # given a GitHub box
  new_box

  # when diagnose asks the flavour for its own lines
  local inst host
  inst=$(vendor_probe 'vendor_diagnose 1')
  host=$(vendor_probe 'vendor_diagnose')

  # then each runner's wrapper is the root-owned one outside its tree, and the
  # hand-run line reads the registration as the runner user, who has no sudo
  assert_contains "should show the wrapper installed outside the runner tree" "$inst" "wrapper : MISSING"
  assert_contains "should show the runner's registration file" "$inst" "jit file:"
  assert_contains "should read the registration as the runner user" "$host" "\"\$(cat $BOX/run/gha-runner/1.jit)\""
  assert_not_contains "should not ask the runner user for sudo it does not have" "$host" "sudo cat"
}
it_shows_how_to_start_a_runner_by_hand_without_sudo_inside

it_names_the_likely_cause_only_when_a_runner_is_down() {
  # given a GitHub box with no token stored
  new_box
  # when the janitor hands over, once with runner 2 down and once with none
  local down none
  down=$(vendor_probe 'log() { echo "$*"; }; vendor_janitor 2')
  none=$(vendor_probe 'log() { echo "$*"; }; vendor_janitor')

  # then the PAT is named as the likely cause only when something is down, and
  # with no token stored nothing is asked of GitHub
  assert_contains "should name the admin PAT as the likely cause of a down runner" "$down" "Most common cause"
  assert_eq "should say nothing when every runner is up" "" "$none"
  assert_eq "should not reach the network with no token stored" "no" "$(exists "$BOX/state/curl.log")"
}
it_names_the_likely_cause_only_when_a_runner_is_down

finish
