#!/usr/bin/env bash
#
# The Azure DevOps helpers, driven as they ship: azp-cycle (the restart
# backoff around every agent cycle), azp-register (registration in a pristine
# copy, removal by the host's own record, the token in no argv), azp-run-once
# (one job, as a child, never exec), and vendor.sh's verify hook.
#
# Run from the repository root:  bash test/runtime/azure_devops_test.sh
#
# Substituted, as harness.sh allows, only what a box has and a test run does
# not, each one recording how it was called:
#   - the root-only steps: ensure_run_dir's chown to root, the setpriv drop
#     (as_runner), and the agent users (runner_uid). azp-register's "root" is
#     whoever runs the suite: it checks a tree is all its own user's;
#   - what a box talks to: systemctl and docker (harness.sh's), the account
#     database (getent), the pool's REST API (curl), and sleep, so a 20-second
#     backoff takes no time;
#   - the agent itself: config.sh and run.sh in the scratch agent tree.
#
# Several names are read only by the scripts driven here, which ShellCheck
# cannot follow across the source.
# shellcheck disable=SC2034

# shellcheck source=harness.sh
. "$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")/harness.sh"

TOKEN="fixture-token-placeholder"
AGENTS=""   # the scratch box's agent base, set by azp_box
LOGS=""     # where the stand-in config.sh records, set by azp_box
RECORDS=""  # azp-register's record of each agent, set by azp_box

# azp_box [KEY=VALUE...] - a scratch Azure DevOps box, with the stand-ins this
# file adds on PATH: sleep, getent, and curl as the pool's REST API (it answers
# the status in state/curl.code, 204 by default, and keeps the header file it
# was handed in state/curl.headers)
azp_box() {
  new_box azure_devops "$@"
  AGENTS="$BOX/opt/azure-pipelines-agent"
  LOGS="$BOX/state/register"
  RECORDS="$BOX/state/azp"
  mkdir -p "$LOGS"
  cat > "$BOX/bin/sleep" <<'EOF'
#!/usr/bin/env bash
# stand-in sleep: records the wait, takes none
printf 'sleep %s\n' "$*" >> "${STANDIN_STATE:?}/calls.log"
EOF
  cat > "$BOX/bin/getent" <<EOF
#!/usr/bin/env bash
# stand-in getent: the accounts of a box an agent was adopted on
cat <<'PASSWD'
root:x:0:0:root:/root:/bin/bash
bin:x:2:2:bin:/bin:/usr/sbin/nologin
agent:x:1000:1000:the account the agent ran as:/home/agent:/bin/bash
azp1:x:1001:1001::${BOX}/home/azp1:/bin/bash
nobody:x:65534:65534:nobody:/nonexistent:/usr/sbin/nologin
PASSWD
EOF
  cat > "$BOX/bin/curl" <<'EOF'
#!/usr/bin/env bash
# stand-in curl: the pool's REST API, recording each call and its header file
state="${STANDIN_STATE:?}"
printf 'curl %s\n' "$*" >> "${state}/curl.log"
prev=""
for a in "$@"; do
  if [[ "$prev" == "-H" && "$a" == @* ]]; then cat -- "${a#@}" >> "${state}/curl.headers"; fi
  prev="$a"
done
cat "${state}/curl.code" 2>/dev/null || printf '204'
EOF
  chmod 0755 "$BOX/bin/sleep" "$BOX/bin/getent" "$BOX/bin/curl"
}

# agent_tree <n> [registered] - an unpacked agent; registered adds its identity
agent_tree() {
  local d="${AGENTS}/$1"
  mkdir -p "$d/bin" "$d/_diag"
  printf '#!/bin/sh\n' > "$d/bin/Agent.Listener"; chmod 0755 "$d/bin/Agent.Listener"
  if [[ "${2:-}" == "registered" ]]; then
    printf '{"agentId": 7, "agentName": "build-01-%s", "poolName": "your-pool", "workFolder": "_work"}\n' "$1" > "$d/.agent"
    printf '{"scheme": "OAuth"}\n' > "$d/.credentials"
    printf '{"d": "fixture-key-placeholder"}\n' > "$d/.credentials_rsaparams"
    chmod 0600 "$d/.credentials" "$d/.credentials_rsaparams"
  fi
}

# run_cycle pre|post <n> - azp-cycle, sourced so the chown to root can be
# substituted; sets OUT and RC
run_cycle() {
  OUT=$( (
    # shellcheck source=../../roles/runner_azure_devops/files/azp-cycle.sh
    . "${AZP_FILES}/azp-cycle.sh"
    ensure_run_dir() { mkdir -p "$(run_dir)"; }
    main "$@"
  ) 2>&1 )
  RC=$?
}

fails_of() { cat "$BOX/run/azp-agent/$1.fails" 2>/dev/null || echo none; }

echo "azp-cycle: the restart backoff"

it_counts_a_cycle_that_ran_no_job() {
  # given an agent whose cycle started and ended without a worker log
  azp_box; agent_tree 1 registered
  run_cycle pre 1

  # when the cycle ends
  run_cycle post 1

  # then it counts as one that ran no job, and its marker is gone
  assert_eq "a job-less cycle is counted" "1" "$(fails_of 1)"
  assert_eq "post removes the cycle's marker" "no" "$(exists "$BOX/run/azp-agent/1.start")"
}
it_counts_a_cycle_that_ran_no_job

it_clears_the_count_after_a_cycle_that_ran_a_job() {
  # given an agent that had failed three starts, then started a cycle
  azp_box; agent_tree 1 registered
  echo 3 > "$BOX/run/azp-agent/1.fails"
  run_cycle pre 1
  touch -d '1 minute ago' "$BOX/run/azp-agent/1.start"

  # when that cycle's job wrote its worker log, and the cycle ends
  put "$AGENTS/1/_diag/Worker_20261112-120000-utc.log"
  run_cycle post 1

  # then the count is cleared
  assert_eq "a cycle that ran a job clears the count" "none" "$(fails_of 1)"
}
it_clears_the_count_after_a_cycle_that_ran_a_job

it_leaves_the_count_alone_when_the_stop_was_asked_for() {
  # given a job-less cycle ended by a stop somebody queued (a drain, a reboot)
  azp_box; agent_tree 1 registered
  echo 2 > "$BOX/run/azp-agent/1.fails"
  run_cycle pre 1
  echo "41 azp-agent@1.service stop running" > "$BOX/state/jobs/azp-agent@1.service"

  # when the cycle ends
  run_cycle post 1

  # then the stop is no failure: the count stays where it was
  assert_eq "a requested stop is not counted" "2" "$(fails_of 1)"
}
it_leaves_the_count_alone_when_the_stop_was_asked_for

it_counts_a_start_that_never_reached_its_marker() {
  # given an agent whose pre failed before it wrote a marker
  azp_box; agent_tree 1 registered

  # when the unit's post runs anyway, as systemd runs it after a failed start
  run_cycle post 1

  # then that start ran no job, and post still succeeds
  assert_eq "a start without a marker is counted" "1" "$(fails_of 1)"
  assert_eq "post never fails the unit" "0" "$RC"
}
it_counts_a_start_that_never_reached_its_marker

it_waits_out_the_backoff_before_starting_again() {
  # given an agent whose last two starts ran no job
  azp_box; agent_tree 1 registered
  echo 2 > "$BOX/run/azp-agent/1.fails"

  # when its next cycle starts
  run_cycle pre 1

  # then it waits 20 s first, and then starts
  assert_contains "pre waits the backoff" "$(cat "$BOX/state/calls.log")" "sleep 20"
  assert_eq "pre then writes the marker" "yes" "$(exists "$BOX/run/azp-agent/1.start")"
  assert_eq "pre succeeds" "0" "$RC"
}
it_waits_out_the_backoff_before_starting_again

it_starts_at_once_after_a_healthy_cycle() {
  # given an agent with no job-less start behind it
  azp_box; agent_tree 1 registered

  # when its next cycle starts
  run_cycle pre 1

  # then nothing waits
  assert_not_contains "a healthy agent does not wait" "$(cat "$BOX/state/calls.log")" "sleep"
  assert_eq "the marker is written" "yes" "$(exists "$BOX/run/azp-agent/1.start")"
}
it_starts_at_once_after_a_healthy_cycle

it_refuses_to_start_an_agent_that_is_not_registered() {
  # given an unpacked agent that was never registered
  azp_box; agent_tree 1

  # when its cycle starts
  run_cycle pre 1

  # then pre fails, says how to register it, and writes no marker
  assert_eq "pre fails for an unregistered agent" "1" "$RC"
  assert_contains "pre says what to supply" "$OUT" "runner_azp_pat"
  assert_eq "no marker for a start that cannot run" "no" "$(exists "$BOX/run/azp-agent/1.start")"
}
it_refuses_to_start_an_agent_that_is_not_registered

echo
echo "azp-register: the PAT meets only a pristine copy, removal only the host's record"

# register_box - a box where instance 1 holds a tree its jobs could have
# written, with a config.sh in it that must never run; beside it the pristine
# copy azp-register registers, whose config.sh records how it ran and writes
# the .agent a real one would; the env file the role writes; the PAT file
register_box() {
  azp_box; agent_tree 1
  cat > "$AGENTS/1/config.sh" <<EOF
#!/usr/bin/env bash
# planted by a job: if this runs, the PAT reached code a job controls
echo planted > "${LOGS}/planted-config-ran"
EOF
  chmod 0755 "$AGENTS/1/config.sh"
  mkdir -p "$BOX/home/azp1/.local/bin"
  printf '#!/bin/sh\necho planted > "%s/planted-uname-ran"\n' "$LOGS" > "$BOX/home/azp1/.local/bin/uname"
  chmod 0755 "$BOX/home/azp1/.local/bin/uname"
  mkdir -p "$AGENTS/.1.new"
  chmod 0700 "$AGENTS/.1.new"
  cat > "$AGENTS/.1.new/config.sh" <<EOF
#!/usr/bin/env bash
# stand-in config.sh: records its arguments, environment, directory and the
# uname it would run, then writes the .agent a successful registration leaves
printf '%s\n' "\$@" > "${LOGS}/config.argv"
/usr/bin/env > "${LOGS}/config.env"
pwd > "${LOGS}/config.pwd"
command -v uname > "${LOGS}/config.uname"
printf '{"agentId": 42, "agentName": "build-01-1", "poolId": 10, "poolName": "your-pool", "workFolder": "_work"}' > .agent
EOF
  chmod 0755 "$AGENTS/.1.new/config.sh"
  cat > "$BOX/etc/azure-pipelines-agent/env" <<'EOF'
AZP_URL="https://dev.azure.com/your-org"
AZP_POOL="your-pool"
AZP_SYSTEM_PATH="/usr/bin:/bin"
AZP_AGENT_NAME_1="build-01-1"
EOF
  printf '%s' "$TOKEN" > "$BOX/run/azp-register.pat"
  chmod 0600 "$BOX/run/azp-register.pat"
}

# run_register [remove] <n> - azp-register as Ansible runs it, as "root", with a
# variable in its environment that must not reach the agent; sets OUT and RC
run_register() {
  OUT=$(AZP_ENV_FILE="$BOX/etc/azure-pipelines-agent/env" AZP_PAT_FILE="$BOX/run/azp-register.pat" \
        AZP_STATE_DIR="$RECORDS" CANARY_FROM_ANSIBLE="must-not-reach-the-agent" \
        bash "${AZP_FILES}/azp-register.sh" "$@" 2>&1)
  RC=$?
}

it_registers_only_the_pristine_copy() {
  # given a tree a job could rewrite, and a fresh copy beside it
  register_box

  # when the agent is registered
  run_register 1

  # then config.sh runs in the fresh copy, and nothing in the job-writable tree runs at all
  assert_eq "azp-register succeeds" "0" "$RC"
  assert_eq "config.sh runs in the pristine copy" "$AGENTS/.1.new" "$(cat "$LOGS/config.pwd")"
  assert_eq "the instance's own config.sh never runs" "no" "$(exists "$LOGS/planted-config-ran")"
  assert_not_contains "a uname in the agent user's ~/.local/bin is not found" "$(cat "$LOGS/config.uname")" "$BOX/home/azp1"
}
it_registers_only_the_pristine_copy

it_registers_with_the_token_only_in_the_environment() {
  # given a fresh copy and a PAT handed over in a root-only file
  register_box

  # when the agent is registered
  run_register 1

  # then config.sh gets every answer but the token as an argument
  assert_eq "config.sh gets the documented unattended answers" \
    "--unattended --url https://dev.azure.com/your-org --auth pat --pool your-pool --agent build-01-1 --work _work --replace" \
    "$(paste -sd' ' "$LOGS/config.argv")"
  assert_not_contains "no --token flag" "$(cat "$LOGS/config.argv")" "--token"
  assert_not_contains "the token is in no config.sh argument" "$(cat "$LOGS/config.argv")" "$TOKEN"
  # and the token reaches config.sh where the agent reads it in place of --token
  assert_contains "the token is in config.sh's environment" "$(cat "$LOGS/config.env")" "VSTS_AGENT_INPUT_TOKEN=${TOKEN}"
}
it_registers_with_the_token_only_in_the_environment

it_registers_as_root_with_a_clean_environment() {
  # given a fresh copy
  register_box

  # when the agent is registered from a shell carrying its own variables
  run_register 1

  # then config.sh runs as root, told it may, with a system-only PATH and nothing of the caller's
  assert_contains "config.sh may run as root" "$(cat "$LOGS/config.env")" "AGENT_ALLOW_RUNASROOT=1"
  assert_contains "PATH is the system's alone" "$(cat "$LOGS/config.env")" \
    "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
  assert_not_contains "no home is on PATH" "$(grep '^PATH=' "$LOGS/config.env")" "home"
  assert_not_contains "the caller's environment stays behind" "$(cat "$LOGS/config.env")" "CANARY_FROM_ANSIBLE"
}
it_registers_as_root_with_a_clean_environment

it_records_the_agent_it_registered() {
  # given a fresh copy
  register_box

  # when the agent is registered
  run_register 1

  # then the pool and agent ids are kept root-side, for removal to read
  assert_eq "the record names the agent registered" '{"poolId":10,"agentId":42,"agentName":"build-01-1"}' \
    "$(cat "$RECORDS/1.json" 2>/dev/null)"
  assert_eq "the record is 0600" "600" "$(stat -c '%a' "$RECORDS/1.json" 2>/dev/null)"
}
it_records_the_agent_it_registered

it_refuses_a_copy_others_could_have_written() {
  # given a staging copy others can enter
  register_box
  chmod 0755 "$AGENTS/.1.new"

  # when the agent is registered
  run_register 1

  # then nothing runs
  assert_eq "azp-register refuses it" "1" "$RC"
  assert_eq "its config.sh never runs" "no" "$(exists "$LOGS/config.argv")"
}
it_refuses_a_copy_others_could_have_written

it_never_falls_back_to_the_instance_tree() {
  # given no fresh copy at all, only the tree a job could rewrite
  register_box
  rm -rf "$AGENTS/.1.new"

  # when the agent is registered
  run_register 1

  # then azp-register refuses, and the job's config.sh never runs
  assert_eq "azp-register refuses" "1" "$RC"
  assert_eq "the instance's own config.sh never runs" "no" "$(exists "$LOGS/planted-config-ran")"
}
it_never_falls_back_to_the_instance_tree

it_refuses_a_pat_file_others_can_read() {
  # given a PAT file every account on the box can read
  register_box
  chmod 0644 "$BOX/run/azp-register.pat"

  # when the agent is registered
  run_register 1

  # then nothing is registered
  assert_eq "azp-register refuses the file" "1" "$RC"
  assert_eq "config.sh never runs" "no" "$(exists "$LOGS/config.argv")"
}
it_refuses_a_pat_file_others_can_read

# removal_box [<status>] - instance 1's record says pool 10, agent 42, while its
# job-writable .agent has been rewritten to name another agent; the pool
# answers <status> (204 by default)
removal_box() {
  register_box
  mkdir -p "$RECORDS"
  printf '{"poolId":10,"agentId":42,"agentName":"build-01-1"}\n' > "$RECORDS/1.json"
  chmod 0600 "$RECORDS/1.json"
  printf '{"agentId": 7, "agentName": "someone-else", "poolId": 99}\n' > "$AGENTS/1/.agent"
  if [[ -n "${1:-}" ]]; then printf '%s' "$1" > "$BOX/state/curl.code"; fi
}

it_removes_the_recorded_agent_not_the_one_the_tree_names() {
  # given a record, and a tree whose .agent a job rewrote
  removal_box

  # when the agent is removed from the pool
  run_register remove 1

  # then the recorded agent is deleted through the REST API, and the record goes with it
  assert_eq "azp-register remove succeeds" "0" "$RC"
  assert_contains "the recorded agent is deleted" "$(cat "$BOX/state/curl.log")" \
    "-X DELETE -H @"
  assert_contains "by the recorded pool and agent ids" "$(cat "$BOX/state/curl.log")" \
    "https://dev.azure.com/your-org/_apis/distributedtask/pools/10/agents/42?api-version=7.1"
  assert_not_contains "never the agent the tree names" "$(cat "$BOX/state/curl.log")" "agents/7"
  assert_eq "the agent's own config.sh never runs" "no" "$(exists "$LOGS/planted-config-ran")"
  assert_eq "the record goes once the agent has" "no" "$(exists "$RECORDS/1.json")"
}
it_removes_the_recorded_agent_not_the_one_the_tree_names

it_removes_with_the_token_only_in_a_header_file() {
  # given a recorded agent
  removal_box

  # when it is removed from the pool
  run_register remove 1

  # then the PAT travels in the header file curl reads, as Basic auth, never as an argument
  assert_eq "the header carries the PAT as Basic auth" \
    "Authorization: Basic $(printf ':%s' "$TOKEN" | base64 -w 0)" "$(cat "$BOX/state/curl.headers" 2>/dev/null)"
  assert_not_contains "the token is in no curl argument" "$(cat "$BOX/state/curl.log")" "$TOKEN"
  assert_not_contains "nor is its encoding" "$(cat "$BOX/state/curl.log")" "$(printf ':%s' "$TOKEN" | base64 -w 0)"
}
it_removes_with_the_token_only_in_a_header_file

it_keeps_the_record_when_the_pool_refuses() {
  # given a recorded agent, and a pool that refuses the PAT
  removal_box 401

  # when it is removed from the pool
  run_register remove 1

  # then removal fails, and the record stays for another try
  assert_eq "azp-register remove fails" "1" "$RC"
  assert_eq "the record stays" "yes" "$(exists "$RECORDS/1.json")"
}
it_keeps_the_record_when_the_pool_refuses

it_removes_nothing_it_has_no_record_of() {
  # given an instance whose agent this host never recorded
  register_box
  printf '{"agentId": 7, "agentName": "someone-else", "poolId": 99}\n' > "$AGENTS/1/.agent"

  # when it is removed from the pool
  run_register remove 1

  # then nothing is deleted
  assert_eq "azp-register says it cannot" "3" "$RC"
  assert_eq "the pool is never called" "no" "$(exists "$BOX/state/curl.log")"
}
it_removes_nothing_it_has_no_record_of

echo
echo "azp-run-once: one job, as a child"

# run_once_box <status> - a registered agent 1 whose run.sh records how it was
# started, then exits <status>
run_once_box() {
  azp_box; agent_tree 1 registered
  cat > "$AGENTS/1/run.sh" <<EOF
#!/usr/bin/env bash
# stand-in run.sh: records its arguments, its own and its parent's pid, its PATH
printf '%s\n' "\$*" > "$BOX/state/run.argv"
printf '%s %s\n' "\$\$" "\$PPID" > "$BOX/state/run.pids"
printf '%s\n' "\$PATH" > "$BOX/state/run.path"
exit $1
EOF
  chmod 0755 "$AGENTS/1/run.sh"
}

# run_once <n> - the wrapper as systemd starts it; sets WRAPPER (its pid) and RC
run_once() {
  bash "${AZP_FILES}/azp-run-once.sh" "$1" > "$BOX/state/run-once.out" 2>&1 &
  WRAPPER=$!
  wait "$WRAPPER"
  RC=$?
}

it_runs_run_sh_once_as_a_child() {
  # given a registered agent
  run_once_box 0

  # when its unit starts it
  run_once 1

  # then run.sh runs with --once, as a child of the wrapper rather than in its place
  assert_eq "run.sh gets --once" "--once" "$(cat "$BOX/state/run.argv")"
  read -r pid ppid < "$BOX/state/run.pids"
  assert_eq "not exec: run.sh has a pid of its own" "yes" "$([[ "$pid" != "$WRAPPER" ]] && echo yes || echo no)"
  assert_eq "run.sh is the wrapper's child" "$WRAPPER" "$ppid"
}
it_runs_run_sh_once_as_a_child

it_propagates_the_status_of_run_sh() {
  # given an agent whose run.sh exits 3
  run_once_box 3

  # when its unit starts it
  run_once 1

  # then the unit sees that status
  assert_eq "the wrapper exits with run.sh's status" "3" "$RC"
}
it_propagates_the_status_of_run_sh

it_puts_the_agent_path_in_force() {
  # given an agent whose .path puts its user's ~/.local/bin first
  run_once_box 0
  printf '%s\n' "$BOX/home/azp1/.local/bin:/usr/bin:/bin" > "$AGENTS/1/.path"

  # when its unit starts it
  run_once 1

  # then the agent runs with that PATH, as the agent's own service wrapper would apply it
  assert_eq "run.sh gets the PATH in .path" "$BOX/home/azp1/.local/bin:/usr/bin:/bin" "$(cat "$BOX/state/run.path")"
}
it_puts_the_agent_path_in_force

it_removes_the_containers_a_job_left_behind() {
  # given an agent whose job left two containers and a volume in its rootless daemon
  run_once_box 0

  # when the job is done
  run_once 1

  # then they go, and with trust=internal only dangling images go with them
  assert_contains "the job's containers are removed" "$(cat "$BOX/state/docker.log")" "docker rm -f c1 c2"
  assert_contains "the job's volumes are removed" "$(cat "$BOX/state/docker.log")" "docker volume rm -f v1"
  assert_contains "the layer cache stays warm" "$(cat "$BOX/state/docker.log")" "docker image prune -f"
  assert_eq "the work directory stays (lru)" "yes" "$(exists "$AGENTS/1/_diag")"
}
it_removes_the_containers_a_job_left_behind

echo
echo "vendor_verify: what only the flavour checks"

# run_verify - vendor_verify as <sbin>-admin calls it, with the drop to the
# agent user and the agent user's uid substituted; sets OUT and RC
run_verify() {
  OUT=$( (
    # shellcheck source=../../roles/runner_host/files/lib.sh
    . "$BOX/lib/lib.sh"
    load_host_env
    load_vendor
    as_runner() { shift; "$@"; }
    runner_uid() { id -u; }
    vendor_verify
  ) 2>&1 )
  RC=$?
}

it_flags_a_path_that_reaches_into_another_home() {
  # given an adopted agent whose .path still starts in the old account's home
  azp_box RUNNER_COUNT=1; agent_tree 1 registered
  printf '%s\n' "/home/agent/.local/bin:/usr/local/bin:/usr/bin:/bin" > "$AGENTS/1/.path"

  # when the host is verified
  run_verify

  # then verify fails and names the entry, but not /bin, which is only a system account's home
  assert_eq "verify fails" "1" "$RC"
  assert_contains "the foreign entry is named" "$OUT" "another account's home: /home/agent/.local/bin"
  assert_not_contains "a system account's home is no person's" "$OUT" "/home/agent/.local/bin /bin"
}
it_flags_a_path_that_reaches_into_another_home

it_accepts_an_agent_that_is_all_its_own() {
  # given an agent whose PATH starts in its own home, with 0600 credentials of its own
  azp_box RUNNER_COUNT=1; agent_tree 1 registered
  printf '%s\n' "$BOX/home/azp1/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" > "$AGENTS/1/.path"

  # when the host is verified
  run_verify

  # then every check holds
  assert_eq "verify passes" "0" "$RC"
  assert_not_contains "no .path complaint" "$OUT" ".path"
}
it_accepts_an_agent_that_is_all_its_own

it_flags_credentials_others_can_read() {
  # given an agent whose RSA key is readable by every account
  azp_box RUNNER_COUNT=1; agent_tree 1 registered
  chmod 0644 "$AGENTS/1/.credentials_rsaparams"

  # when the host is verified
  run_verify

  # then verify fails on that file
  assert_eq "verify fails" "1" "$RC"
  assert_contains "the readable key is named" "$OUT" ".credentials_rsaparams is 644"
}
it_flags_credentials_others_can_read

it_flags_an_agent_that_is_not_registered() {
  # given an instance that was unpacked but never registered
  azp_box RUNNER_COUNT=1; agent_tree 1

  # when the host is verified
  run_verify

  # then verify fails and says what to supply
  assert_eq "verify fails" "1" "$RC"
  assert_contains "it says how to register it" "$OUT" "runner_azp_pat"
}
it_flags_an_agent_that_is_not_registered

finish
