#!/usr/bin/env bash
#
# The Azure DevOps helpers, driven as they ship: azp-cycle (the restart
# backoff around every agent cycle), azp-register (registration with the token
# kept out of every argv), azp-run-once (one job, as a child, never exec), and
# vendor.sh's verify hook.
#
# Run from the repository root:  bash test/runtime/azure_devops_test.sh
#
# Substituted, as harness.sh allows, only what a box has and a test run does
# not, each one recording how it was called:
#   - the root-only steps: ensure_run_dir's chown to root, the setpriv drop
#     (as_runner, and the setpriv binary azp-register calls itself), and the
#     agent users (runner_uid);
#   - what a box talks to: systemctl and docker (harness.sh's), the account
#     database (getent), and sleep, so a 20-second backoff takes no time;
#   - the agent itself: config.sh and run.sh in the scratch agent tree.
#
# Several names are read only by the scripts driven here, which ShellCheck
# cannot follow across the source.
# shellcheck disable=SC2034

# shellcheck source=harness.sh
. "$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")/harness.sh"

TOKEN="fixture-token-placeholder"
AGENTS=""   # the scratch box's agent base, set by azp_box
LOGS=""     # where the stand-ins azp-register calls record, set by azp_box

# azp_box [KEY=VALUE...] - a scratch Azure DevOps box, with the stand-ins this
# file adds: sleep and getent on PATH, setpriv and env for azp-register (which
# clears its environment before the drop, so they log to a fixed place)
azp_box() {
  new_box azure_devops "$@"
  AGENTS="$BOX/opt/azure-pipelines-agent"
  LOGS="$BOX/state/register"
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
  cat > "$BOX/bin/setpriv" <<EOF
#!/usr/bin/env bash
# stand-in setpriv: records how it was asked to drop, then runs the rest as is
printf '%s\n' "\$@" > "${LOGS}/setpriv.argv"
while (( \$# )) && [[ "\$1" != "--" ]]; do shift; done
shift
exec "\$@"
EOF
  cat > "$BOX/bin/env" <<EOF
#!/usr/bin/env bash
# stand-in env: records its arguments, then is the real one
printf '%s\n' "\$@" > "${LOGS}/env.argv"
exec /usr/bin/env "\$@"
EOF
  chmod 0755 "$BOX/bin/sleep" "$BOX/bin/getent" "$BOX/bin/setpriv" "$BOX/bin/env"
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
echo "azp-register: the token never in an argv"

# register_box - a box with an unpacked agent 1 whose config.sh records how it
# was run, the env file the role writes, and the PAT file it hands over
register_box() {
  azp_box; agent_tree 1
  cat > "$AGENTS/1/config.sh" <<EOF
#!/usr/bin/env bash
# stand-in config.sh: records its arguments, environment and directory
printf '%s\n' "\$@" > "${LOGS}/config.argv"
/usr/bin/env > "${LOGS}/config.env"
pwd > "${LOGS}/config.pwd"
EOF
  chmod 0755 "$AGENTS/1/config.sh"
  cat > "$BOX/etc/azure-pipelines-agent/env" <<'EOF'
AZP_URL="https://dev.azure.com/your-org"
AZP_POOL="your-pool"
AZP_SYSTEM_PATH="/usr/bin:/bin"
AZP_AGENT_NAME_1="build-01-1"
EOF
  printf '%s' "$TOKEN" > "$BOX/run/azp-register.pat"
  chmod 0600 "$BOX/run/azp-register.pat"
}

# run_register [remove] <n> - azp-register as Ansible runs it, with a variable
# in its environment that must not reach the agent; sets OUT and RC
run_register() {
  OUT=$(AZP_ENV_FILE="$BOX/etc/azure-pipelines-agent/env" AZP_PAT_FILE="$BOX/run/azp-register.pat" \
        CANARY_FROM_ANSIBLE="must-not-reach-the-agent" \
        bash "${AZP_FILES}/azp-register.sh" "$@" 2>&1)
  RC=$?
}

it_registers_with_the_token_only_in_the_environment() {
  # given an unpacked agent and a PAT handed over in a root-only file
  register_box

  # when the agent is registered
  run_register 1

  # then config.sh is run unattended with every answer but the token as an argument
  assert_eq "azp-register succeeds" "0" "$RC"
  assert_eq "config.sh gets the documented unattended answers" \
    "--unattended --url https://dev.azure.com/your-org --auth pat --pool your-pool --agent build-01-1 --work _work --replace" \
    "$(paste -sd' ' "$LOGS/config.argv")"
  assert_not_contains "no --token flag" "$(cat "$LOGS/config.argv")" "--token"
  assert_not_contains "the token is in no config.sh argument" "$(cat "$LOGS/config.argv")" "$TOKEN"
  assert_not_contains "the token is in no setpriv argument" "$(cat "$LOGS/setpriv.argv")" "$TOKEN"
  assert_not_contains "the token is in no env argument" "$(cat "$LOGS/env.argv")" "$TOKEN"
  # and the token reaches config.sh where the agent reads it in place of --token
  assert_contains "the token is in config.sh's environment" "$(cat "$LOGS/config.env")" "VSTS_AGENT_INPUT_TOKEN=${TOKEN}"
}
it_registers_with_the_token_only_in_the_environment

it_registers_as_the_agent_user_with_its_own_environment() {
  # given an unpacked agent
  register_box

  # when the agent is registered from a root shell carrying its own variables
  run_register 1

  # then config.sh runs as the agent's user, in its tree, with that user's environment alone
  assert_contains "setpriv drops to the agent user" "$(paste -sd' ' "$LOGS/setpriv.argv")" "--reuid=azp1 --regid=azp1 --init-groups --"
  assert_eq "config.sh runs in the agent's tree" "$AGENTS/1" "$(cat "$LOGS/config.pwd")"
  assert_contains "HOME is the agent user's" "$(cat "$LOGS/config.env")" "HOME=$BOX/home/azp1"
  assert_contains "PATH starts at the agent user's ~/.local/bin" "$(cat "$LOGS/config.env")" "PATH=$BOX/home/azp1/.local/bin:/usr/bin:/bin"
  assert_not_contains "the caller's environment stays behind" "$(cat "$LOGS/config.env")" "CANARY_FROM_ANSIBLE"
}
it_registers_as_the_agent_user_with_its_own_environment

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

it_leaves_a_registered_agent_alone() {
  # given an agent that is already registered
  register_box
  printf '{"agentId": 7}\n' > "$AGENTS/1/.agent"

  # when it is registered again
  run_register 1

  # then that is a no-op
  assert_eq "registering twice succeeds" "0" "$RC"
  assert_eq "config.sh never runs for it" "no" "$(exists "$LOGS/config.argv")"
}
it_leaves_a_registered_agent_alone

it_removes_an_agent_with_the_token_in_the_environment() {
  # given a registered agent
  register_box
  printf '{"agentId": 7}\n' > "$AGENTS/1/.agent"

  # when it is removed from the pool
  run_register remove 1

  # then config.sh remove runs unattended, the token again only in its environment
  assert_eq "azp-register remove succeeds" "0" "$RC"
  assert_eq "config.sh remove gets the unattended answers" "remove --unattended --auth pat" \
    "$(paste -sd' ' "$LOGS/config.argv")"
  assert_not_contains "the token is in no argument" "$(cat "$LOGS/config.argv" "$LOGS/setpriv.argv" "$LOGS/env.argv")" "$TOKEN"
  assert_contains "the token is in its environment" "$(cat "$LOGS/config.env")" "VSTS_AGENT_INPUT_TOKEN=${TOKEN}"
}
it_removes_an_agent_with_the_token_in_the_environment

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
