#!/usr/bin/env bash
#
# host_test.sh - the vendor-neutral runtime: lib.sh, the disk guard, the
# janitor, the reboot guard and <sbin>-admin, each driven as shipped against a
# scratch box (see harness.sh for what may be substituted, and why).
#
# Run from anywhere:  bash test/runtime/host_test.sh   (or: make test)

# shellcheck source=harness.sh
. "$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")/harness.sh"

# lib_probe <commands> -> <commands> run with lib.sh loaded and host.env read
lib_probe() {
  (
    # shellcheck source=../../roles/runner_host/files/lib.sh
    . "${HOST_FILES}/lib.sh"
    load_host_env || { echo "load_host_env failed"; exit 1; }
    eval "$1"
  )
}

# admin_probe <commands> -> <commands> run with <sbin>-admin sourced, as root
# would run it. Its own options stay on: production runs under errexit.
admin_probe() {
  (
    # shellcheck source=../../roles/runner_host/files/runner-admin.sh
    . "${HOST_FILES}/runner-admin.sh"
    require_root() { :; }
    eval "$1"
  )
}

new_box

echo "configuration"

it_reads_only_what_host_env_says() {
  # given a host.env that names no trust level, read from an environment that
  # does name one
  new_box
  sed -i '/^RUNNER_TRUST=/d' "$BOX/host.env"

  # when it is read and the runner's trust judged
  local got
  got=$(RUNNER_TRUST=internal lib_probe 'if runner_trusted; then echo internal; else echo untrusted; fi')

  # then nothing inherited leaks in, and a trust level the file does not state
  # is taken as untrusted: a cold cache is the cheaper of the two mistakes
  assert_eq "should read the trust level from host.env alone, and take none as untrusted" "untrusted" "$got"
}
it_reads_only_what_host_env_says

it_refuses_a_count_bash_would_read_as_octal() {
  # given a runner count with a leading zero
  new_box github RUNNER_COUNT=08

  # when host.env is read
  local got; got=$(lib_probe 'echo "$RUNNER_COUNT"')

  # then it is refused rather than left to die in arithmetic far from here
  assert_eq "should refuse a leading-zero count instead of misreading it" "0" "$got"
}
it_refuses_a_count_bash_would_read_as_octal

echo
echo "runner unit health"

# runner_state_between_jobs is the pure part of verify's unit check, and the
# part that decides whether a `verify` run passes.
between_jobs_probe() { lib_probe "if runner_state_between_jobs $1 $2 $3; then echo yes; else echo no; fi"; }

it_treats_a_clean_auto_restart_as_a_runner_between_jobs() {
  # given the state systemd reports for the moment after a job finishes
  # cleanly: the unit exited 0 and Restart=always is waiting out RestartSec
  new_box
  local state=(activating success 0)

  # when the state is judged
  local got; got=$(between_jobs_probe "${state[@]}")

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

  # then both are reported - only "activating" is ever excused
  assert_eq "should still report an inactive unit" "no" "$stopped"
  assert_eq "should still report a failed unit" "no" "$failed"
}
it_still_reports_a_unit_that_is_not_coming_back

echo
echo "restart backoff"

it_restarts_a_healthy_runner_at_once_and_backs_a_failing_one_off() {
  # given runners whose last 0, 1, 2 ... starts in a row ran no job
  # when the wait before each one's next registration is worked out
  local got
  got=$(lib_probe 'for n in 0 1 2 3 5 6 40 junk; do printf "%s " "$(restart_backoff_delay "$n")"; done')

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
  got=$(lib_probe "
    for c in ran idle listener unminted; do
      if cycle_ran_a_job \"${r}/\$c\" \"${r}/\$c/minted\"; then printf 'yes '; else printf 'no '; fi
    done")

  # then only a Worker log written after this cycle's mint counts. The exit
  # status could not tell: the runner exits 0 whether or not a job ran.
  assert_eq "should count a cycle healthy only when a job ran after its mint" \
    "yes no no no " "$got"
}
it_counts_a_cycle_as_healthy_only_when_a_job_ran

# a runner tree whose cycle marker was written ten minutes ago, for record_cycle
cycle_tree() {
  rm -rf "${WORK}/cycle"; mkdir -p "${WORK}/cycle/_diag"
  touch -d '10 minutes ago' "${WORK}/cycle/minted"
}
record_probe() { lib_probe "record_cycle gha-runner@1.service '${WORK}/cycle' '${WORK}/cycle/minted' '${WORK}/cycle/fails'"; }

it_adds_one_for_every_cycle_in_a_row_that_ran_no_job() {
  # given a runner whose cycles keep ending without a job, and a count file
  # someone left unreadable
  new_box; cycle_tree
  printf 'junk' > "${WORK}/cycle/fails"

  # when two such cycles end
  record_probe; local first; first=$(cat "${WORK}/cycle/fails")
  record_probe; local second; second=$(cat "${WORK}/cycle/fails")

  # then each one adds to the count the backoff waits on, junk read as none
  assert_eq "should count the first job-less cycle as one, whatever the file held" "1" "$first"
  assert_eq "should add one for the next job-less cycle in a row" "2" "$second"
}
it_adds_one_for_every_cycle_in_a_row_that_ran_no_job

it_clears_the_count_after_a_cycle_that_ran_a_job() {
  # given a runner backing off, whose latest cycle did run a job
  new_box; cycle_tree
  echo 4 > "${WORK}/cycle/fails"
  touch -d '5 minutes ago' "${WORK}/cycle/_diag/Worker_20261112-000000-utc.log"

  # when that cycle ends
  record_probe

  # then the count is gone, and the runner registers again at once
  assert_eq "should clear the count after a cycle that ran a job" "no" "$(exists "${WORK}/cycle/fails")"
}
it_clears_the_count_after_a_cycle_that_ran_a_job

it_does_not_count_a_stop_somebody_asked_for() {
  # given a cycle without a job that ends because of a stop job in flight
  new_box; cycle_tree
  echo 2 > "${WORK}/cycle/fails"
  echo '17 gha-runner@1.service stop running' > "$BOX/state/jobs/gha-runner@1.service"

  # when it ends
  record_probe

  # then a drain, a reboot or a rotation is no failure: the count stays as it was
  assert_eq "should leave the count alone when the stop was requested" "2" "$(cat "${WORK}/cycle/fails")"
}
it_does_not_count_a_stop_somebody_asked_for

it_registers_at_once_after_a_cycle_that_ran_a_job() {
  # given a runner with no count of job-less cycles
  new_box

  # when its next registration waits out the backoff
  local got start
  start=$(date +%s)
  got=$(lib_probe "wait_out_backoff '${WORK}/no-such-fails'; echo registered")

  # then there is nothing to wait for and nothing to explain
  assert_eq "should not wait or say anything when no cycle failed" "registered" "$got"
  assert_eq "should return at once" "yes" "$( (( $(date +%s) - start < 3 )) && echo yes || echo no)"
}
it_registers_at_once_after_a_cycle_that_ran_a_job

echo
echo "instances"

it_lists_every_instance_once_in_numeric_order() {
  # given units 2, 10 and 1 known to systemd, the template and a non-numeric
  # instance beside them, and a tree 3 a half-finished converge left without a unit
  new_box
  unit_state gha-runner@2.service active running
  unit_state gha-runner@10.service inactive dead
  unit_state gha-runner@1.service active running
  unit_state gha-runner@foo.service active running
  unit_state gha-runner@.service inactive dead
  mkdir -p "$BOX/opt/actions-runner/"{2,3,bin}

  # when the instances are listed
  local got; got=$(admin_probe 'main instances' 2>&1 | tr '\n' ' ')

  # then every instance appears once, numerically: runner 10 comes after 3
  assert_eq "should list each instance once, numerically, from units and trees" "1 2 3 10 " "$got"
}
it_lists_every_instance_once_in_numeric_order

it_answers_busy_from_the_worker_process_alone() {
  # given runner 1 idle, runner 2 mid-job, and runner 7 whose user is gone, which
  # pgrep answers with the status it also gives a real error
  new_box
  set_busy gha2
  printf 'gha7\n' > "$BOX/state/pgrep-error"

  # when each is asked about
  local idle busy gone rc_idle rc_busy rc_gone
  idle=$(admin_probe 'main busy 1' 2>/dev/null); rc_idle=$?
  busy=$(admin_probe 'main busy 2' 2>/dev/null); rc_busy=$?
  gone=$(admin_probe 'main busy 7' 2>/dev/null); rc_gone=$?

  # then the answer is the worker's, per runner, and a user that does not
  # exist runs nothing: idle, not "cannot tell", which would block a reboot
  assert_eq "should answer busy, with status 0, for a runner with a worker" "busy 0" "${busy} ${rc_busy}"
  assert_eq "should answer idle, with status 1, for a runner without one" "idle 1" "${idle} ${rc_idle}"
  assert_eq "should take a runner whose user is gone as idle" "idle 1" "${gone} ${rc_gone}"
}
it_answers_busy_from_the_worker_process_alone

echo
echo "disk guard"

# fresh_runner [azure_devops] [<host.env KEY=VALUE>...] - a new box whose runner
# 1 has its home, tool cache and tree; R, H and TC name them
fresh_runner() {
  local flavor="github" prefix="gha" base="actions-runner"
  if [[ "${1:-}" == "azure_devops" ]]; then flavor="azure_devops"; prefix="azp"; base="azure-pipelines-agent"; shift; fi
  new_box "$flavor" "$@"
  R="$BOX/opt/${base}/1"; H="$BOX/home/${prefix}1"; TC="$BOX/opt/hostedtoolcache-${prefix}1"
  mkdir -p "$R" "$H" "$TC"
}

# guard_probe <commands> -> <commands> run in a subshell with the disk guard
# sourced and initialised for runner 1. The three overrides are the root-only
# steps: the privilege drop runs the command as whoever runs the suite, the
# runner's uid is one no user has (so there is no Docker socket, and
# prune_docker is inert), and the run directory is not chowned to root.
guard_probe() {
  (
    # shellcheck source=../../roles/runner_host/files/runner-diskguard.sh
    . "${HOST_FILES}/runner-diskguard.sh"
    set +e
    as_runner()      { shift; env HOME="$H" "$@"; }
    runner_uid()     { echo 4294967294; }
    ensure_run_dir() { mkdir -p "$(run_dir)"; }
    guard_init 1 || { echo "guard_init: runner 1 is not on this box"; exit 1; }
    eval "$1"
  )
}

# guard_main [<commands>] -> the guard's own main for runner 1, the same three
# overrides in place, after <commands>
guard_main() {
  (
    # shellcheck source=../../roles/runner_host/files/runner-diskguard.sh
    . "${HOST_FILES}/runner-diskguard.sh"
    as_runner()      { shift; env HOME="$H" "$@"; }
    runner_uid()     { echo 4294967294; }
    ensure_run_dir() { mkdir -p "$(run_dir)"; }
    eval "${1:-}"
    main 1
  )
}

it_ships_a_guard_that_parses() {
  # given the guard exactly as the role installs it
  # when it is parsed
  local rc=0
  bash -n "${HOST_FILES}/runner-diskguard.sh" 2>/dev/null || rc=$?

  # then it is a valid script - the unit would otherwise fail its first start
  assert_eq "should ship a disk guard that parses" "0" "$rc"
}
it_ships_a_guard_that_parses

it_evicts_only_what_no_job_has_read_in_a_week() {
  # given a tool cache and a home whose entries were last read at different times
  fresh_runner
  put "${TC}/go/1.20.0/x64/bin/go" 30
  put "${TC}/go/1.22.0/x64/bin/go" 30
  put "${TC}/go/1.22.0/x64/src/fmt.go"                 # read today
  put "${TC}/flutter/3.0.0/x64/bin/flutter" 30
  put "${H}/.cache/pip/wheel" 30
  put "${H}/.cache/go-build/ab/cd"                     # read today
  put "${H}/.pub-cache/hosted/pkg/lib.dart" 30
  put "${H}/go/pkg/mod/mod.go"                         # read today

  # when the two stale steps run
  guard_probe 'evict_stale_tools; evict_stale_home' >/dev/null

  # then exactly the entries nobody read in a week are gone, each one whole
  assert_eq "should evict a tool version no job has read in a week" \
    "no" "$(exists "${TC}/go/1.20.0")"
  assert_eq "should keep a tool version if any file in it was read this week" \
    "yes" "$(exists "${TC}/go/1.22.0/x64/bin/go")"
  assert_eq "should remove a tool whose last version was evicted" \
    "no" "$(exists "${TC}/flutter")"
  assert_eq "should judge each ~/.cache child alone, evicting the stale one" \
    "no" "$(exists "${H}/.cache/pip")"
  assert_eq "should judge each ~/.cache child alone, keeping the one in use" \
    "yes" "$(exists "${H}/.cache/go-build/ab/cd")"
  assert_eq "should evict a stale top-level cache from the home" \
    "no" "$(exists "${H}/.pub-cache")"
  assert_eq "should keep a top-level cache read this week" \
    "yes" "$(exists "${H}/go/pkg/mod/mod.go")"
}
it_evicts_only_what_no_job_has_read_in_a_week

it_resets_a_home_to_what_the_rootless_daemon_needs() {
  # given a home holding the rootless Docker plumbing and what jobs left behind,
  # including the kind of thing a hostile job would plant for the next one
  fresh_runner
  local wants="${H}/.config/systemd/user/default.target.wants"
  put "${H}/.config/systemd/user/docker.service"
  mkdir -p "$wants"
  ln -s "${H}/.config/systemd/user/docker.service" "${wants}/docker.service"
  put "${H}/.local/share/docker/overlayfs/layer"
  put "${H}/.config/systemd/user/planted.service"
  ln -s "${H}/.config/systemd/user/planted.service" "${wants}/planted.service"
  put "${H}/.docker/config.json"
  put "${H}/.docker/cli-plugins/docker-buildx"
  put "${H}/.bashrc"
  put "${H}/.profile"
  put "${H}/.config/gh/hosts.yaml"
  put "${H}/.local/share/flutter/sdk"
  put "${H}/.local/bin/tool"
  put "${H}/.npm/_cacache/index"
  put "${H}/.gitconfig"
  put "${H}/.ssh/config"

  # when the home is reset
  guard_probe 'reset_home' >/dev/null

  # then the daemon still starts and still has its images, and nothing a job
  # wrote survives - least of all what would run in the next job
  assert_eq "should keep the rootless daemon's user unit" \
    "yes" "$(exists "${H}/.config/systemd/user/docker.service")"
  assert_eq "should keep the link that starts the daemon at boot" \
    "yes" "$(exists "${wants}/docker.service")"
  assert_eq "should leave the Docker data root to docker, never to rm" \
    "yes" "$(exists "${H}/.local/share/docker/overlayfs/layer")"
  assert_eq "should remove a user unit a job planted beside the daemon's" \
    "no" "$(exists "${H}/.config/systemd/user/planted.service")"
  assert_eq "should remove the link that would have started the planted unit" \
    "no" "$(exists "${wants}/planted.service")"
  assert_eq "should remove the Docker CLI config, where a credential helper or plugin hides" \
    "no" "$(exists "${H}/.docker")"
  assert_eq "should remove login-shell dotfiles a job could have rewritten" \
    "no" "$(exists "${H}/.profile")"
  assert_eq "should remove a tool's config a job wrote" "no" "$(exists "${H}/.config/gh")"
  assert_eq "should remove an SDK unpacked beside the Docker data root" \
    "no" "$(exists "${H}/.local/share/flutter")"
  assert_eq "should remove binaries a job installed to ~/.local/bin" "no" "$(exists "${H}/.local/bin")"
  assert_eq "should remove a package cache" "no" "$(exists "${H}/.npm")"
  assert_eq "should remove dotfiles a job wrote" "no" "$(exists "${H}/.gitconfig")"
  assert_eq "should remove an ssh config a job could have planted" "no" "$(exists "${H}/.ssh")"
}
it_resets_a_home_to_what_the_rootless_daemon_needs

it_keeps_what_the_operator_chose_to_carry_over_and_no_more() {
  # given a host.env whose keep list names two carried-over paths, spelt with a
  # trailing slash and a leading ./, and omits the daemon's data root
  fresh_runner RUNNER_HOME_KEEP=".config/systemd/user/docker.service .m2/settings.xml/ ./.local/share/certs"
  put "${H}/.m2/settings.xml"
  put "${H}/.m2/repository/org/lib.jar"
  put "${H}/.local/share/certs/ca.pem"
  put "${H}/.local/share/docker/overlayfs/layer"
  put "${H}/.gitconfig"

  # when the home is reset
  guard_probe 'reset_home' >/dev/null

  # then what was chosen survives however it was spelt, the daemon's own list
  # cannot be dropped by configuration, and the rest of the directory a kept
  # path lives in goes like anything else
  assert_eq "should keep a carried-over file named with a trailing slash" "yes" "$(exists "${H}/.m2/settings.xml")"
  assert_eq "should keep a carried-over directory named with a leading ./" "yes" "$(exists "${H}/.local/share/certs/ca.pem")"
  assert_eq "should keep the daemon's data root even when the list leaves it out" \
    "yes" "$(exists "${H}/.local/share/docker/overlayfs/layer")"
  assert_eq "should still remove what sits beside a carried-over path" "no" "$(exists "${H}/.m2/repository")"
  assert_eq "should still remove what nobody chose to keep" "no" "$(exists "${H}/.gitconfig")"
}
it_keeps_what_the_operator_chose_to_carry_over_and_no_more

it_removes_a_read_only_go_module_cache() {
  # given Go's module cache, which Go makes read-only on purpose
  fresh_runner
  local mod="${H}/go/pkg/mod/example.com/m@v1.0.0"
  put "${mod}/m.go"
  chmod 0444 "${mod}/m.go"
  chmod 0555 "$mod" "$(dirname "$mod")"

  # when the home is reset
  guard_probe 'reset_home' >/dev/null

  # then it is gone - rm alone cannot unlink inside a directory it cannot write
  assert_eq "should remove a read-only module cache" "no" "$(exists "${H}/go")"
}
it_removes_a_read_only_go_module_cache

it_never_follows_a_planted_symlink() {
  # given symlinks a job planted in its home and its tool cache, where the walk
  # would descend
  fresh_runner
  local outside="${BOX}/outside"
  put "${outside}/precious"
  put "${outside}/1.0.0/x64/old" 30
  mkdir -p "${H}/.cache"
  ln -s "$outside" "${H}/.cache/evil"
  ln -s "$outside" "${H}/.local"
  ln -s "$outside" "${TC}/linked-tool"

  # when the stale tools are evicted and the home is reset
  guard_probe 'evict_stale_tools; reset_home' >/dev/null

  # then only the links go. In production rm also runs as the runner user, so
  # a link to something root owns could not be followed into anyway.
  assert_eq "should not delete through a planted symlink" "yes" "$(exists "${outside}/precious")"
  assert_eq "should not evict through a tool that is a symlink" "yes" "$(exists "${outside}/1.0.0/x64/old")"
  assert_eq "should remove the planted symlink itself" "no" "$(exists "${H}/.cache/evil")"
  assert_eq "should not descend into a symlinked directory" "no" "$(exists "${H}/.local")"
}
it_never_follows_a_planted_symlink

# steps_probe <work policy> <disk % before> <disk % once <step> ran> <step>
#   -> the steps the guard took, in order
steps_probe() {
  fresh_runner "RUNNER_WORK_POLICY=$1"
  guard_probe "
    calls=()
    use_pct()  { if [[ -e '${BOX}/freed' ]]; then echo $3; else echo $2; fi; }
    avail_mb() { echo 0; }
    log()      { :; }
    took()     { calls+=(\"\$1\"); if [[ \"\$1\" == '$4' ]]; then : > '${BOX}/freed'; fi; }
    drop_leftover_work() { took work; }
    evict_stale_work()   { took stalework; }
    evict_stale_tools()  { took tools; }
    evict_stale_home()   { took home; }
    drop_build_dirs()    { took builds; }
    drop_task_cache()    { took tasks; }
    prune_docker()       { took docker; }
    wipe_toolcache()     { took wipe; }
    reset_home()         { took reset; }
    run_steps
    echo \"\${calls[*]}\""
}

it_stops_as_soon_as_the_disk_is_back_under_the_threshold() {
  # given a disk at 90% that evicting stale tool versions brings to 60%
  # when the guard runs its steps
  local got; got=$(steps_probe wipe 90 60 tools)

  # then nothing costlier runs: the warm caches jobs are using stay warm
  assert_eq "should stop at the first step that brings the disk under the threshold" \
    "work tools" "$got"
}
it_stops_as_soon_as_the_disk_is_back_under_the_threshold

it_escalates_cheapest_loss_first_while_the_disk_stays_full() {
  # given a disk no step manages to free
  # when the guard runs its steps
  local got; got=$(steps_probe wipe 95 95 none)

  # then every step runs, in the order that loses the least warm cache first
  assert_eq "should escalate one step at a time, cheapest loss first" \
    "work tools home docker wipe reset" "$got"
}
it_escalates_cheapest_loss_first_while_the_disk_stays_full

it_does_nothing_below_the_threshold() {
  # given a disk under the soft threshold
  # when the guard runs its steps
  local got; got=$(steps_probe wipe 50 50 none)

  # then it touches nothing - a box with room keeps every cache warm
  assert_eq "should take no step below the soft threshold" "" "$got"
}
it_does_nothing_below_the_threshold

it_leaves_every_cache_alone_on_a_disk_with_room() {
  # given a trusted runner with stale caches and a leftover workspace, on a
  # disk at half its soft threshold
  fresh_runner
  put "${R}/_work/repo/checkout" 30
  put "${TC}/go/1.20.0/x64/bin/go" 30
  put "${H}/.cache/pip/wheel" 30

  # when the guard runs before the next job
  guard_main 'use_pct() { echo 40; }' >/dev/null

  # then it measured and left: the common case, in milliseconds
  assert_eq "should leave a leftover workspace while the disk has room" "yes" "$(exists "${R}/_work/repo/checkout")"
  assert_eq "should leave a stale tool version while the disk has room" "yes" "$(exists "${TC}/go/1.20.0")"
  assert_eq "should leave a stale home cache while the disk has room" "yes" "$(exists "${H}/.cache/pip")"
}
it_leaves_every_cache_alone_on_a_disk_with_room

it_resets_an_untrusted_runner_in_full_whatever_the_disk_says() {
  # given an untrusted runner on a near-empty disk, its caches read minutes ago
  fresh_runner RUNNER_TRUST=untrusted
  put "${R}/_work/repo/checkout"
  put "${TC}/node/22.0.0/x64/bin/node"
  put "${H}/.cache/go-build/ab/cd"
  put "${H}/.gitconfig"
  put "${H}/.local/share/docker/overlayfs/layer"

  # when the guard readies it for its next job
  guard_main 'use_pct() { echo 10; }' >/dev/null

  # then nothing a job left survives, fresh or not: a runner serving fork PRs
  # has no warm cache worth protecting, only state a job could have planted
  assert_eq "should drop a workspace a job left behind" "no" "$(exists "${R}/_work")"
  assert_eq "should empty the tool cache, versions in use included" "no" "$(exists "${TC}/node")"
  assert_eq "should empty the home, caches read minutes ago included" "no" "$(exists "${H}/.cache/go-build")"
  assert_eq "should remove config a fork PR could have planted" "no" "$(exists "${H}/.gitconfig")"
  assert_eq "should still leave the Docker data root to docker" \
    "yes" "$(exists "${H}/.local/share/docker/overlayfs/layer")"
}
it_resets_an_untrusted_runner_in_full_whatever_the_disk_says

it_resets_an_untrusted_runner_before_every_job_not_only_the_first() {
  # given an untrusted runner that was reset before its last job, and whose
  # job then planted a hook again
  fresh_runner RUNNER_TRUST=untrusted
  put "${H}/.gitconfig"
  guard_main 'use_pct() { echo 10; }' >/dev/null
  put "${H}/.gitconfig"

  # when the guard readies it for the job after
  guard_main 'use_pct() { echo 10; }' >/dev/null

  # then it is reset again: nothing records that a reset already happened
  assert_eq "should reset an untrusted runner before every job" "no" "$(exists "${H}/.gitconfig")"
}
it_resets_an_untrusted_runner_before_every_job_not_only_the_first

it_takes_a_trust_level_it_does_not_know_as_untrusted() {
  # given a host.env whose trust level is misspelt
  fresh_runner RUNNER_TRUST=intenal
  put "${H}/.gitconfig"

  # when the guard runs on a disk with room
  guard_main 'use_pct() { echo 10; }' >/dev/null

  # then it resets: losing a warm cache is the safe way to be wrong
  assert_eq "should reset a runner whose trust level is not exactly internal" "no" "$(exists "${H}/.gitconfig")"
}
it_takes_a_trust_level_it_does_not_know_as_untrusted

echo
echo "disk guard, lru work policy"

# A work tree the way an Azure Pipelines agent keeps it between jobs. Fresh
# entries were read today, stale ones 30 days ago.
lru_tree() {
  put "${R}/_work/1/s/src/main.c"                           # a pipeline that ran today
  put "${R}/_work/1/b/obj/old.o" 30                         # ...holding an old file: kept whole
  put "${R}/_work/2/s/src/main.c" 30                        # a pipeline nobody ran this month
  put "${R}/_work/2/a/artifact.zip" 30
  put "${R}/_work/_tasks/Build_0a1b/1.0.0/task.json" 30
  put "${R}/_work/_tasks/Build_0a1b/1.0.0.completed" 30
  put "${R}/_work/_tasks/Build_0a1b/2.0.0/task.json"
  put "${R}/_work/_tasks/Build_0a1b/2.0.0.completed"
  put "${R}/_work/_tasks/Old_2c3d/0.1.0/task.json" 30
  put "${R}/_work/_tasks/Old_2c3d/0.1.0.completed" 30
  put "${R}/_work/_tool/node/16.0.0/x64/bin/node" 30
  put "${R}/_work/_temp/left-by-a-job" 30
  put "${R}/_work/SourceRootMapping/Mappings.json" 30
  put "${R}/_diag/Agent_20260101-000000-utc.log" 30
  put "${R}/_diag/Worker_20261111-000000-utc.log"
}

it_evicts_only_stale_build_dirs_task_versions_and_logs() {
  # given an agent's work tree holding fresh and stale entries of every kind
  fresh_runner azure_devops
  lru_tree

  # when the stale work step runs
  guard_probe 'evict_stale_work' >/dev/null

  # then each kind loses exactly its stale entries, each one whole
  assert_eq "should evict a build directory no job read this week" "no" "$(exists "${R}/_work/2")"
  assert_eq "should keep a build directory read this week, old files and all" \
    "yes" "$(exists "${R}/_work/1/b/obj/old.o")"
  assert_eq "should evict a stale task version" "no" "$(exists "${R}/_work/_tasks/Build_0a1b/1.0.0")"
  assert_eq "should take a stale task version's .completed marker with it" \
    "no" "$(exists "${R}/_work/_tasks/Build_0a1b/1.0.0.completed")"
  assert_eq "should keep a task version in use, marker and all" \
    "yes yes" "$(exists "${R}/_work/_tasks/Build_0a1b/2.0.0/task.json") $(exists "${R}/_work/_tasks/Build_0a1b/2.0.0.completed")"
  assert_eq "should remove a task whose only version was evicted" "no" "$(exists "${R}/_work/_tasks/Old_2c3d")"
  assert_eq "should evict a stale version from the agent's own tool directory" \
    "no" "$(exists "${R}/_work/_tool/node")"
  assert_eq "should evict a diag log nobody read this week" \
    "no" "$(exists "${R}/_diag/Agent_20260101-000000-utc.log")"
  assert_eq "should keep this week's diag log" "yes" "$(exists "${R}/_diag/Worker_20261111-000000-utc.log")"
  assert_eq "should leave _temp to the agent, which empties it at every job" \
    "yes" "$(exists "${R}/_work/_temp/left-by-a-job")"
  assert_eq "should leave the agent's record of which build directory is whose" \
    "yes" "$(exists "${R}/_work/SourceRootMapping/Mappings.json")"
}
it_evicts_only_stale_build_dirs_task_versions_and_logs

it_drops_every_build_dir_once_stale_entries_were_not_enough() {
  # given an agent's work tree whose build directories are all in use
  fresh_runner azure_devops
  lru_tree
  put "${R}/_work/2/s/src/main.c"

  # when the work tier's first step runs
  guard_probe 'drop_build_dirs' >/dev/null

  # then every build directory goes, fresh ones included, and nothing else
  assert_eq "should drop every build directory" \
    "no no" "$(exists "${R}/_work/1") $(exists "${R}/_work/2")"
  assert_eq "should keep the task cache for the step after" "yes" "$(exists "${R}/_work/_tasks/Build_0a1b/2.0.0")"
  assert_eq "should keep the agent's own bookkeeping" "yes" "$(exists "${R}/_work/SourceRootMapping/Mappings.json")"
}
it_drops_every_build_dir_once_stale_entries_were_not_enough

it_drops_the_task_cache_whole_when_even_that_was_not_enough() {
  # given an agent's work tree with tasks in use
  fresh_runner azure_devops
  lru_tree

  # when the work tier's second step runs
  guard_probe 'drop_task_cache' >/dev/null

  # then the task cache goes, every marker with it, and the work dir stays
  assert_eq "should drop the whole task cache, markers included" "no" "$(exists "${R}/_work/_tasks")"
  assert_eq "should keep the work dir itself" "yes" "$(exists "${R}/_work/SourceRootMapping/Mappings.json")"
}
it_drops_the_task_cache_whole_when_even_that_was_not_enough

it_escalates_an_lru_runner_through_its_work_dir_cheapest_loss_first() {
  # given an lru runner on a disk no step manages to free
  # when the guard runs its steps
  local got; got=$(steps_probe lru 95 95 none)

  # then there is no leftover step, the work dir goes stale entry by stale
  # entry with the other caches, and whole only before images and toolchains
  assert_eq "should escalate an lru runner without a leftover step" \
    "stalework tools home builds tasks docker wipe reset" "$got"
}
it_escalates_an_lru_runner_through_its_work_dir_cheapest_loss_first

it_keeps_an_lru_work_dir_when_its_stale_entries_were_enough() {
  # given a full disk that evicting one stale build directory brings back
  fresh_runner azure_devops
  lru_tree

  # when the guard runs before the next job
  local out
  out=$(guard_main "use_pct() { if [[ -e '${R}/_work/2' ]]; then echo 90; else echo 60; fi; }")

  # then that is all it took: the work the agent keeps on purpose survives
  assert_eq "should evict the stale build directory" "no" "$(exists "${R}/_work/2")"
  assert_eq "should keep the build directory in use" "yes" "$(exists "${R}/_work/1/s/src/main.c")"
  assert_eq "should keep the task cache" "yes" "$(exists "${R}/_work/_tasks/Build_0a1b/2.0.0")"
  assert_contains "should say what it freed" "$out" "evict stale work: freed"
  assert_not_contains "should stop once the disk is back under the threshold" "$out" "evict stale tools"
}
it_keeps_an_lru_work_dir_when_its_stale_entries_were_enough

it_still_resets_an_untrusted_lru_runner_work_dir_and_all() {
  # given an untrusted lru runner whose work tree is all in use, on a disk with room
  fresh_runner azure_devops RUNNER_TRUST=untrusted
  lru_tree
  put "${H}/.gitconfig"

  # when the guard readies it for its next job
  guard_main 'use_pct() { echo 10; }' >/dev/null

  # then the work policy changes nothing: untrusted means everything goes
  assert_eq "should wipe an untrusted runner's whole work dir, whatever its policy" "no" "$(exists "${R}/_work")"
  assert_eq "should still reset the home" "no" "$(exists "${H}/.gitconfig")"
}
it_still_resets_an_untrusted_lru_runner_work_dir_and_all

it_never_follows_a_link_planted_in_an_lru_work_dir() {
  # given links a job planted where the lru walk lists entries: a task cache,
  # a numbered build directory and a diag directory that point outside
  fresh_runner azure_devops
  local outside="${BOX}/outside"
  put "${outside}/5/s/main.c" 30
  put "${outside}/Task_9f/1.0.0/task.json" 30
  put "${outside}/old.log" 30
  mkdir -p "${R}/_work"
  ln -s "$outside" "${R}/_work/_tasks"
  ln -s "$outside" "${R}/_work/9"
  ln -s "$outside" "${R}/_diag"

  # when every lru work step runs
  guard_probe 'evict_stale_work; drop_build_dirs; drop_task_cache' >/dev/null

  # then nothing outside is touched; at most a link itself goes
  assert_eq "should not evict through a linked task cache" "yes" "$(exists "${outside}/Task_9f/1.0.0/task.json")"
  assert_eq "should not take a linked build directory for a real one" "yes" "$(exists "${outside}/5/s/main.c")"
  assert_eq "should not evict logs through a linked _diag" "yes" "$(exists "${outside}/old.log")"
  assert_eq "should remove the linked task cache as the link it is" "no" "$(exists "${R}/_work/_tasks")"
}
it_never_follows_a_link_planted_in_an_lru_work_dir

it_never_walks_into_a_work_dir_that_is_a_link() {
  # given a job that replaced the whole _work with a link to a stale tree
  fresh_runner azure_devops
  local outside="${BOX}/outside"
  put "${outside}/3/s/main.c" 30
  put "${outside}/_tasks/T_1/1.0.0/task.json" 30
  ln -s "$outside" "${R}/_work"

  # when every lru work step runs
  guard_probe 'evict_stale_work; drop_build_dirs; drop_task_cache' >/dev/null

  # then nothing beneath the link is listed, let alone removed
  assert_eq "should not evict through a linked _work" \
    "yes yes" "$(exists "${outside}/3/s/main.c") $(exists "${outside}/_tasks/T_1/1.0.0/task.json")"
}
it_never_walks_into_a_work_dir_that_is_a_link

echo
echo "verify"

it_promises_the_cache_sweep_only_where_the_runner_caches_are() {
  # given two disks past the soft threshold: the one the runners' caches are
  # on, and a separate /var that holds only the jobs' temp files
  new_box
  # when verify reports each
  local caches var
  caches=$(admin_probe 'report_disk / 80 75 90 1')
  var=$(admin_probe 'report_disk /var 80 75 90 0')

  # then only the first promises the per-runner sweep: the disk guard frees
  # runner caches and nothing else, so on a split-disk box the /var line would
  # promise a remediation that cannot run
  assert_contains "should promise the sweep on the disk that holds the caches" "$caches" "each runner frees its own caches"
  assert_not_contains "should not promise the sweep on a /var that holds none" "$var" "frees its own caches"
  assert_contains "should say the disk guard frees nothing on that /var" "$var" "the disk guard frees nothing here"
}
it_promises_the_cache_sweep_only_where_the_runner_caches_are

it_fails_verify_on_a_full_disk_whether_or_not_it_holds_caches() {
  # given a separate /var past the hard threshold, and a cache disk under the
  # soft one
  # when verify reports each, with the status it returns
  local full fine
  full=$(admin_probe 'set +e; report_disk /var 95 75 90 0 2>&1; echo "status=$?"')
  fine=$(admin_probe 'set +e; report_disk / 40 75 90 1 2>&1; echo "status=$?"')

  # then the full /var fails verify, since every job's TMPDIR is on it, and
  # the other passes
  assert_contains "should fail verify on a /var past the hard threshold" "$full" "status=1"
  assert_contains "should pass a disk under the soft threshold" "$fine" "status=0"
}
it_fails_verify_on_a_full_disk_whether_or_not_it_holds_caches

echo
echo "restart-idle"

it_restarts_only_the_runners_that_are_up_and_idle() {
  # given a runner of every kind: listening idle (1, 10), mid-job (2), stopped
  # (3), between two jobs (4), in its pre-start steps (5), and drained (6)
  new_box
  unit_state gha-runner@1.service active running
  unit_state gha-runner@2.service active running
  unit_state gha-runner@3.service inactive dead
  unit_state gha-runner@4.service activating auto-restart
  unit_state gha-runner@5.service activating start-pre
  unit_state gha-runner@6.service active running
  unit_state gha-runner@10.service active running
  set_busy gha2
  mkdir -p "$BOX/systemd/gha-runner@6.service.d"
  printf '[Service]\nRestart=no\n' > "$BOX/systemd/gha-runner@6.service.d/40-drain.conf"

  # when the converge's handler restarts the idle ones
  local out calls reload first_restart
  out=$(admin_probe 'main restart-idle' 2>/dev/null)
  calls=$(cat "$BOX/state/calls.log")
  reload=$(grep -n 'systemctl daemon-reload' <<<"$calls" | head -1 | cut -d: -f1)
  first_restart=$(grep -n 'systemctl try-restart' <<<"$calls" | head -1 | cut -d: -f1)

  # then exactly the idle, up ones are restarted, onto a reloaded definition,
  # and stdout is nothing but one line each: the converge counts those lines
  assert_eq "should print one 'restarted <n>' line per runner restarted, and nothing else" \
    $'restarted 1\nrestarted 4\nrestarted 10' "$out"
  assert_eq "should restart three runners, no more" "3" "$(grep -c 'systemctl try-restart' <<<"$calls")"
  assert_not_contains "should never restart a runner mid-job" "$calls" "try-restart gha-runner@2.service"
  assert_not_contains "should never start a runner that was stopped" "$calls" "try-restart gha-runner@3.service"
  assert_not_contains "should leave a runner in its pre-start steps to finish them" "$calls" "try-restart gha-runner@5.service"
  assert_not_contains "should leave a drained runner down" "$calls" "try-restart gha-runner@6.service"
  assert_eq "should reload systemd before restarting anything" "yes" \
    "$( [[ -n "$reload" && -n "$first_restart" ]] && (( reload < first_restart )) && echo yes || echo no)"
}
it_restarts_only_the_runners_that_are_up_and_idle

it_prints_nothing_when_no_runner_needed_restarting() {
  # given a box whose only runner is mid-job
  new_box
  unit_state gha-runner@1.service active running
  set_busy gha1

  # when the handler runs
  local out err
  out=$(admin_probe 'main restart-idle' 2>"${WORK}/restart-idle.err")
  err=$(cat "${WORK}/restart-idle.err")

  # then stdout is empty, so the converge reports nothing changed, and the
  # reason is on stderr for whoever reads the log
  assert_eq "should print nothing on stdout when nothing was restarted" "" "$out"
  assert_contains "should say on stderr why a runner was left alone" "$err" "runner 1: running a job"
}
it_prints_nothing_when_no_runner_needed_restarting

echo
echo "drain"

it_drains_every_runner_without_killing_a_job_it_could_wait_for() {
  # given an idle runner, one mid-job with no drain budget left, and one that
  # was never started
  new_box github RUNNER_DRAIN_TIMEOUT=0
  unit_state gha-runner@1.service active running
  unit_state gha-runner@2.service active running
  unit_state gha-runner@3.service inactive dead
  set_busy gha2

  # when they are drained
  local out calls d
  out=$(admin_probe 'main drain' 2>&1)
  calls=$(cat "$BOX/state/calls.log")
  d="$BOX/systemd"

  # then each loses its restart, the one that was up is recorded as such, and
  # each is stopped - the busy one only once its budget was spent, and loudly
  assert_contains "should take runner 1's restart away" "$(cat "$d/gha-runner@1.service.d/40-drain.conf")" "Restart=no"
  assert_contains "should record that runner 1 was up" "$(cat "$d/gha-runner@1.service.d/40-drain.conf")" "# was-up=yes"
  assert_contains "should record that runner 3 was not" "$(cat "$d/gha-runner@3.service.d/40-drain.conf")" "# was-up=no"
  assert_contains "should reload systemd so the drop-ins apply" "$calls" "systemctl daemon-reload"
  assert_contains "should stop each drained runner" "$calls" "systemctl stop gha-runner@2.service"
  assert_contains "should say when it stopped a runner still working" "$out" "drain budget spent and runner 2 is still working"
}
it_drains_every_runner_without_killing_a_job_it_could_wait_for

it_undrains_and_starts_again_only_the_runners_that_were_up() {
  # given runners 1 and 2 drained while up, runner 3 drained while stopped,
  # and all three down since
  new_box github RUNNER_DRAIN_TIMEOUT=0
  unit_state gha-runner@1.service active running
  unit_state gha-runner@2.service active running
  unit_state gha-runner@3.service inactive dead
  admin_probe 'main drain' >/dev/null 2>&1
  unit_state gha-runner@1.service inactive dead
  unit_state gha-runner@2.service inactive dead
  : > "$BOX/state/calls.log"

  # when they are undrained
  admin_probe 'main undrain' >/dev/null 2>&1
  local calls; calls=$(cat "$BOX/state/calls.log")

  # then no drop-in is left, and only what was up comes back: starting a runner
  # this box never ran would add one it is not configured to have
  assert_eq "should remove every drain drop-in" "0" \
    "$(find "$BOX/systemd" -name 40-drain.conf | wc -l | tr -d ' ')"
  assert_contains "should start runner 1 again" "$calls" "systemctl start gha-runner@1.service"
  assert_contains "should start runner 2 again" "$calls" "systemctl start gha-runner@2.service"
  assert_not_contains "should not start runner 3, which was down before the drain" "$calls" "start gha-runner@3.service"
}
it_undrains_and_starts_again_only_the_runners_that_were_up

it_keeps_the_first_drains_record_when_drained_twice() {
  # given runner 1 drained while up, and down since
  new_box github RUNNER_DRAIN_TIMEOUT=0
  unit_state gha-runner@1.service active running
  admin_probe 'main drain 1' >/dev/null 2>&1
  unit_state gha-runner@1.service inactive dead

  # when it is drained again
  admin_probe 'main drain 1' >/dev/null 2>&1

  # then it is still recorded as up: it is down only because of the first
  # drain, and the second one must not keep it down for good
  assert_contains "should keep the first drain's record" \
    "$(cat "$BOX/systemd/gha-runner@1.service.d/40-drain.conf")" "# was-up=yes"
}
it_keeps_the_first_drains_record_when_drained_twice

echo
echo "janitor"

it_reports_down_only_the_runners_that_are_down() {
  # given three runners: active, between two jobs, and failed
  new_box
  unit_state gha-runner@1.service active running
  unit_state gha-runner@2.service activating auto-restart success 0
  unit_state gha-runner@3.service failed failed exit-code 1

  # when the daily janitor runs
  bash "${HOST_FILES}/runner-janitor.sh" >/dev/null 2>&1
  local journal; journal=$(cat "$BOX/state/journal.log" 2>/dev/null)

  # then only the failed one is named, in the journal under the janitor's own
  # name, and the flavour adds what most often causes it
  assert_contains "should name the failed runner as down" "$journal" "runner-janitor.sh: RUNNERS DOWN: 3 -"
  assert_not_contains "should not count a runner between jobs as down" "$journal" "RUNNERS DOWN: 2"
  assert_contains "should hand the down runners to the flavour's own check" "$journal" "Most common cause"
  assert_eq "should not reach the network for a box with no GitHub configuration" "no" "$(exists "$BOX/state/curl.log")"
}
it_reports_down_only_the_runners_that_are_down

echo
echo "reboot guard"

it_defers_a_pending_reboot_while_any_runner_is_busy() {
  # given a pending reboot, and two runners, the second mid-job
  new_box
  : > "$BOX/run/reboot-required"
  unit_state gha-runner@1.service active running
  unit_state gha-runner@2.service active running
  set_busy gha2

  # when the reboot guard runs - only ever against the stand-in systemctl
  if [[ "$(command -v systemctl)" != "$BOX/bin/systemctl" ]]; then
    fail "should run the reboot guard against the stand-in systemctl" "PATH resolves systemctl to $(command -v systemctl)"
    return
  fi
  bash "${HOST_FILES}/runner-reboot-if-idle.sh" >/dev/null 2>&1
  local calls journal
  calls=$(cat "$BOX/state/calls.log"); journal=$(cat "$BOX/state/journal.log" 2>/dev/null)

  # then it defers, says which runner held it back, and touches nothing
  assert_contains "should defer, naming the busy runner" "$journal" "runner 2 is busy - deferring"
  assert_not_contains "should not stop any runner" "$calls" "systemctl stop"
  assert_not_contains "should not reboot" "$calls" "systemctl reboot"
}
it_defers_a_pending_reboot_while_any_runner_is_busy

it_does_nothing_when_no_reboot_is_pending() {
  # given runners, all idle, and no pending reboot
  new_box
  unit_state gha-runner@1.service active running

  # when the reboot guard runs
  if [[ "$(command -v systemctl)" != "$BOX/bin/systemctl" ]]; then
    fail "should run the reboot guard against the stand-in systemctl" "PATH resolves systemctl to $(command -v systemctl)"
    return
  fi
  bash "${HOST_FILES}/runner-reboot-if-idle.sh" >/dev/null 2>&1

  # then it does not even look at the runners
  assert_eq "should not look at the runners with no reboot pending" "" "$(cat "$BOX/state/calls.log")"
}
it_does_nothing_when_no_reboot_is_pending

finish
