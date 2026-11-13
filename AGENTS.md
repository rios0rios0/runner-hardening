# AGENTS.md

This file provides guidance to AI coding agents (Claude Code, Codex, Cursor, GitHub Copilot) when working with code in this repository.

## What this is

An Ansible collection, `rios0rios0.runner_hardening`, that turns raw Ubuntu
boxes into hardened, ephemeral, rootless self-hosted CI hosts: GitHub Actions
runners or Azure Pipelines agents. The repository root *is* the collection
(`galaxy.yml`, `meta/runtime.yml`), and it depends on nothing beyond
`ansible.builtin`, on purpose.

| Path                              | Role                                                                       |
|-----------------------------------|----------------------------------------------------------------------------|
| `roles/runner_host/`              | The vendor-neutral host role: preflight, de-privilege, wipe, prerequisites, users and rootless Docker, the unit, slice and resource policy, the disk guard, janitor and reboot guard, retiring surplus instances. |
| `roles/runner_github/`            | GitHub Actions: the JIT helpers, the per-job wrapper, `/etc/github-runner/{env,pat}`, the runner trees. |
| `roles/runner_azure_devops/`      | Azure Pipelines: adoption or registration, `azp-cycle`, `azp-run-once`, the agents' own `docker`, the agent trees. |
| `roles/*/files/*.sh`              | Every runtime script, as a static file; installed without its `.sh`.       |
| `playbooks/`                      | `github.yaml` and `azure_devops.yaml` converge; `verify`, `diagnose`, `drain` and `uninstall` take both flavours; `rotate_github_pat.yaml`. |
| `inventory/example/`              | The documented inventory. Real ones live in the gitignored `inventory/local/`, which `ansible.cfg` reads by default. |
| `test/runtime/`, `test/ansible/`  | The runtime scripts driven against scratch trees, and the policy and template invariants. |
| `.github/workflows/converge.yaml` | Both playbooks converged twice on a disposable VM.                          |

## Commands

```bash
make setup        # clone/update the shared pipelines scripts lint and sast use
make collection   # link build/collections/... to this checkout (make test does it too)
make lint         # ShellCheck + ansible-lint (production profile)
make test         # bash -n, the runtime suite, the Ansible test playbooks, syntax checks
make sast         # CodeQL, Semgrep, Trivy, Hadolint, Gitleaks
```

Never invoke `shellcheck`, `ansible-lint`, `semgrep` or `gitleaks` directly —
the Makefile targets load the shared configuration first. `make test` needs
only `bash` and `ansible-core` on `PATH`; the rest need `make setup` (or
`make SCRIPTS_DIR=/path/to/pipelines <target>`).

## Architecture

### One host role, called by two vendor roles

A vendor role's `tasks/main.yaml` is the orchestrator. It calls `runner_host` at
three fixed points, and the order encodes dependencies: do not reorder without
tracing what each step assumes already exists. `runner_host` is never applied
on its own; its `main.yaml` only fails with a pointer to the vendor roles.

```
runner_github | runner_azure_devops  tasks/main.yaml
  1. set_fact the flavour (the table below)
  2. vendor validation and credential handling (GitHub: check the PAT, write /etc/github-runner/pat)
  3. include_role runner_host, tasks_from: prepare
       preflight asserts: Ubuntu, x86_64, kernel >= 5.11, cgroup v2, runner_host_dedicated
       → resolve the count → lib.sh and <sbin>-admin, early, so `audit` runs on a first install
       → legacy units (runner_legacy_unit_globs): wait out their job, stop, disable, remove; keep their dirs
       → de-privilege runner_old_users → one-time wipe (marker /var/lib/runner-hardening/wiped)
       → prerequisites → swap → per-instance users, runner_home_seed, rootless Docker
  4. vendor: helpers, configuration, runner/agent trees; adoption or registration (Azure DevOps)
  5. include_role runner_host, tasks_from: finish
       host.env and the diskguard/janitor/reboot-if-idle scripts → policy facts
       → unit, slice, protect drop-in, instance drop-ins, user-slice drop-ins → remove stale drop-ins
       → daemon-reload, enable every instance (start it when runner_start_units)
       → notify "Restart idle runners" on any change → janitor, updates, reboot guard, stale artefacts
       → <sbin>-admin verify: output shown, failures warn and never fail the play
  6. vendor: de-register runner_surplus_instances (Azure DevOps, when a PAT is given)
  7. include_role runner_host, tasks_from: retire
       drain, then remove completely, every instance above the count
```

`roles/runner_host/tasks/policy.yaml` is the resource-policy math: pure
`set_fact`, no host access. Its outputs (`runner_rp_fair`, `runner_rp_ceiling`,
`runner_rp_aggregate`, `runner_rp_sysmin`, `runner_rp_codeql`,
`runner_rp_ceilings`) are the shell installer's `compute_resource_policy`,
`codeql_ram_budget` and `runner_ceiling`, ported; `test/ansible/policy.yaml`
pins them, case by case, to the numbers that arithmetic produced.

### The flavour is data

The vendor role's first task sets these facts, and every name on the box
derives from them. The GitHub values are the shell installer's own, so a fleet
it set up converges without anything being renamed.

| Fact                       | GitHub (`runner_github`)        | Azure DevOps (`runner_azure_devops`)      |
|----------------------------|---------------------------------|-------------------------------------------|
| `runner_flavor`            | `github`                        | `azure_devops`                            |
| `runner_user_prefix`       | `gha`                           | `azp`                                     |
| `runner_base_dir`          | `/opt/actions-runner`           | `/opt/azure-pipelines-agent`              |
| `runner_unit`              | `gha-runner`                    | `azp-agent`                               |
| `runner_slice`             | `gha.slice`                     | `azp.slice`                               |
| `runner_sbin_prefix`       | `gha`                           | `azp`                                     |
| `runner_config_dir`        | `/etc/github-runner`            | `/etc/azure-pipelines-agent`              |
| `runner_worker_pattern`    | `Runner\.Worker`                | `Agent\.Worker`                           |
| `runner_work_policy`       | `wipe`                          | `lru`                                     |
| `runner_legacy_unit_globs` | `['actions.runner.*']`          | `['vsts.agent.*']`                        |
| `runner_heavy_env`         | `{}`: the label travels in the JIT config | `{heavy: 'true'}`: an agent reports its environment as capabilities |
| `runner_instance_env`      | `{}`                            | `{VSTS_SETUP_DOCKERGROUP: 'false', AZP_AGENT_DEFAULT_MAP_DOCKER_SOCKET_TO_FALSE: 'true'}`: a rootless box has no root Docker socket for a container job to stat or mount |

`runner_unit_description`, `runner_unit_exec_start_pre`,
`runner_unit_exec_start` and `runner_unit_exec_stop_post` fill the vendor lines
of the unit template.

### The roles install static scripts and write the configuration they read

Nothing on a box is generated: the roles copy fixed files, then write the files
those read. The table names each script by its installed path; `<sbin>` is
`runner_sbin_prefix`.

| Installed as                                             | Source                                         | Role |
|----------------------------------------------------------|------------------------------------------------|------|
| `/usr/local/lib/runner-hardening/lib.sh`                 | `roles/runner_host/files/lib.sh`               | sourced by every runtime script: the shared functions, among them `load_host_env`, `runner_trusted`, `read_untrusted`, `runner_user`, `runner_dir`, `unit_of`, `runner_busy`, `existing_instances`, `as_runner`, `restart_backoff_delay`, `cycle_ran_a_job`, `runner_state_between_jobs`, `log`/`ok`/`warn`/`err` |
| `/usr/local/lib/runner-hardening/vendor.sh`              | `roles/runner_github/files/vendor.sh`, `roles/runner_azure_devops/files/vendor.sh` | optional hooks, called only when `declare -F` finds them: `vendor_verify`, `vendor_diagnose`, `vendor_reap`, `vendor_janitor` (GitHub: orphan reap, PAT expiry), `vendor_registered` |
| `/usr/local/sbin/<sbin>-diskguard`                       | `roles/runner_host/files/runner-diskguard.sh`  | root-only; before each job, frees that runner's caches under disk pressure, or resets it in full when `trust=untrusted` |
| `/usr/local/sbin/<sbin>-janitor` + timer                 | `roles/runner_host/files/runner-janitor.sh`    | daily Docker trim, measured on the homes' filesystem, and health check, then `vendor_janitor` |
| `/usr/local/sbin/<sbin>-reboot-if-idle` + timer          | `roles/runner_host/files/runner-reboot-if-idle.sh` | reboots only 02:00–05:00, and only when no runner is busy (`runner_busy`: no worker in any runner unit's cgroup), at two looks 2 s apart. No PAT, so the same on both flavours |
| `/usr/local/sbin/<sbin>-admin`                           | `roles/runner_host/files/runner-admin.sh`      | the on-box modes: `verify`, `diagnose`, `audit`, `reap`, `sandbox-probe`/`-relax`/`-off`, `drain [n…]`, `undrain [n…]`, `restart-idle`, `busy <n>`, `instances`; the global `--yes` answers every question |
| `/usr/local/sbin/gha-jitconfig`, `gha-jitreap`           | `roles/runner_github/files/gha-jitconfig.sh`, `gha-jitreap.sh` | root-only; wait out any backoff and mint one single-use JIT config, adding `heavy` for runners 1..`GHA_HEAVY_RUNNERS`; count job-less cycles and delete the registration |
| `/usr/local/libexec/runner-hardening/gha-run-ephemeral`  | `roles/runner_github/files/gha-run-ephemeral.sh` | `0755` root, outside the tree a job can write; hands `run.sh` the JIT config in `ACTIONS_RUNNER_INPUT_JITCONFIG`, never on its command line, runs exactly one job, and on a stop waits for `run.sh` to finish before it cleans up |
| `/usr/local/sbin/azp-cycle`, `azp-register`              | `roles/runner_azure_devops/files/azp-cycle.sh`, `azp-register.sh` | root-only; the backoff before a cycle and the job-less count after it; registration as root (`AGENT_ALLOW_RUNASROOT=1`) in a pristine, root-owned unpack, the PAT in `VSTS_AGENT_INPUT_TOKEN`, then the tree handed to `azp<n>`; removal through the REST API by the ids in `/var/lib/runner-hardening/azp/<n>.json` |
| `/usr/local/libexec/runner-hardening/azp-run-once`       | `roles/runner_azure_devops/files/azp-run-once.sh` | `./run.sh --once` as the agent user |
| `/usr/local/libexec/runner-hardening/azp-bin/docker`     | `roles/runner_azure_devops/files/azp-docker.sh` | first on every agent's `.path`; runs the agent's own `docker exec -u <its uid>` of a container job's step as container root, which rootless Docker makes the agent's own user, and hands every other call to the next `docker` on `PATH` unchanged |
| `/etc/systemd/system/<unit>@.service`                    | `roles/runner_host/templates/runner@.service.j2` | the hardened unit template |
| `/etc/systemd/system/<slice>`, `system.slice.d/10-<sbin>-protect.conf`, `user-<uid>.slice.d/10-<sbin>-limits.conf` | `roles/runner_host/templates/runner.slice.j2`, `protect.conf.j2`, `user-slice.conf.j2` | the aggregate boundary, the OS floor, the rootless containers' limits |
| `/etc/systemd/system/<unit>@<n>.service.d/10-instance.conf` | `roles/runner_host/templates/instance.conf.j2` | the runner's paths, memory floor and ceiling, `CODEQL_RAM`, `AGENT_TOOLSDIRECTORY` (`trust=internal`), `runner_instance_env`, `runner_heavy_env` (heavy instances) |
| `/etc/runner-hardening/host.env`                         | `roles/runner_host/templates/host.env.j2`      | what the scripts read: the flavour, the count, trust, the thresholds, the keep list |

### The ephemeral loop is the core invariant

```
systemd starts gha-runner@N
  → ExecStartPre=-+/usr/local/sbin/gha-diskguard N   (root; no-op below RUNNER_DISK_SOFT, else frees runner N's caches;
                                                     untrusted: resets runner N in full, every time)
  → ExecStartPre=+/usr/local/sbin/gha-jitconfig N    (root; PAT never seen by the runner user)
      waits 10s..5min first if the last cycles ran no job, then
      writes a single-use JIT config to /run/gha-runner/N.jit
  → ExecStart=/usr/local/libexec/runner-hardening/gha-run-ephemeral N
                                                    (runner user; a root-owned script outside the job-writable
                                                     tree; reads the .jit, wipes _work, exports it as
                                                     ACTIONS_RUNNER_INPUT_JITCONFIG, ./run.sh -- exits after ONE job)
  → ExecStopPost=+/usr/local/sbin/gha-jitreap N      (root; counts a job-less cycle unless the stop was
                                                     requested, then removes the registration)
  → Restart=always  → back to the top with a fresh registration and a fresh workspace

systemd starts azp-agent@N
  → ExecStartPre=-+/usr/local/sbin/azp-diskguard N   (root; as above, under the lru work policy)
  → ExecStartPre=+/usr/local/sbin/azp-cycle pre N    (root; waits out the backoff in /run/azp-agent/N.fails,
                                                     then touches /run/azp-agent/N.start)
  → ExecStart=/usr/local/libexec/runner-hardening/azp-run-once N
                                                    (agent user; cd /opt/azure-pipelines-agent/N,
                                                     ./run.sh --once -- exits after ONE job; keeps _work)
  → ExecStopPost=+/usr/local/sbin/azp-cycle post N   (root; counts a job-less cycle unless a stop or
                                                     restart is queued for the unit)
  → Restart=always  → back to the top: the same registration, a fresh process
```

Every security claim in the README rests on this chain. A change that lets
`run.sh` survive a second job, or that lets a wrapper `exec` (which discards
`gha-run-ephemeral`'s EXIT trap and skips its cleanup), silently turns these
back into long-lived runners. The JIT config reaches `run.sh` in
`ACTIONS_RUNNER_INPUT_JITCONFIG`, exported inside the wrapper, never as an
argument: the listener reads it and removes it from its own environment
(`actions/runner`'s `CommandSettings.cs`). On a stop the wrapper forwards
`SIGTERM` and waits for `run.sh` to finish before its cleanup runs. It lives
root-owned outside the tree a job can write, so a job cannot edit it, but it
runs as the job's user, so a job can kill it before its trap fires: its cleanup
is housekeeping, and the reset the root `ExecStartPre` runs with
`trust=untrusted` is what isolates one job from the next. `StartLimitIntervalSec=0`, `RestartSec=1`,
`OOMPolicy=continue` and the absence of `RestartSteps`/`RestartMaxDelaySec`
are deliberate (the unit template says why beside each). The restart backoff
is keyed on cycles that ran no job — a `_diag/Worker_*.log` newer than the
cycle's marker (`N.jit`, `N.start`) — never on the exit status, which
run-helper sets to 0 even on a terminated error.

### Where state lives on a hardened box

| Path                                    | Contents                                                          |
|-----------------------------------------|-------------------------------------------------------------------|
| `/etc/runner-hardening/host.env`        | the flavour and host policy every runtime script reads; root `0644`, no secrets |
| `/usr/local/lib/runner-hardening/`      | `lib.sh` and `vendor.sh`, sourced by the scripts; `tools/<name>/`, a `runner_extra_binaries` tool tree |
| `/usr/local/libexec/runner-hardening/`  | the per-job wrappers and the agents' own `docker` (`azp-bin/`), root `0755`, outside every tree a job can write |
| `/usr/local/bin/<name>`                 | a `runner_extra_binaries` binary, or a link into its tool tree; root-owned, shared by every runner |
| `/var/cache/runner-hardening/`          | the downloads behind `runner_extra_binaries`, root-only            |
| `/etc/github-runner/env`                | the GitHub answers (`GHA_*`), in the installer's exact format      |
| `/etc/github-runner/pat`                | the admin PAT, `0600 root:root`, never readable by a job           |
| `/etc/azure-pipelines-agent/env`        | the Azure DevOps settings, `0600`; never a PAT                     |
| `/opt/actions-runner/<n>`, `/opt/azure-pipelines-agent/<n>` | one instance tree per runner, owned by its user, `0750` |
| `/home/<prefix><n>`                     | the runner's `$HOME`: package caches, SDKs, the rootless Docker data root; kept between jobs |
| `/opt/hostedtoolcache-<prefix><n>`      | the runner's private hosted tool cache (`AGENT_TOOLSDIRECTORY` when `trust=internal`) |
| `/run/gha-runner/<n>.jit`, `<n>.id`     | the current single-use registration and its id; tmpfs, gone on reboot |
| `/run/gha-runner/<n>.fails`, `/run/azp-agent/<n>.fails` | cycles in a row that ran no job — drives the restart backoff; tmpfs |
| `/run/azp-agent/<n>.start`              | written as a cycle starts; the job-less check measures against it |
| `/run/azp-register.pat`                 | a registration's PAT, root-only, for the length of one task        |
| `/var/lib/runner-hardening/rootless/<user>.docker.service` | the disk guard's root-owned copy of a runner's rootless user unit, taken on its first run and put back before every untrusted job |
| `/var/lib/runner-hardening/azp/<n>.json` | the pool and agent ids recorded at registration or adoption, which a removal goes by |
| `/var/tmp/systemd-private-*-<unit>@<n>.service-*/tmp` | the job's `TMPDIR` (`/var/tmp` inside the unit): private, on disk, removed at every stop |
| `/var/lib/runner-hardening/`            | role state, which `uninstall` leaves in place: `wiped`, which keeps the one-time wipe from ever running twice; `no-swap`, which records that this host could not take a swapfile, so later converges stop retrying (delete it to retry); and the sudoers drop-ins de-privileging disabled (`<file>.disabled-<stamp>`) |

## Rules specific to this repository

- **Runtime scripts are static and read their configuration at runtime.**
  Nothing under `/usr/local` is generated and no script is a template: the
  roles copy fixed files and write the files those read —
  `/etc/runner-hardening/host.env`, `/etc/github-runner/env`,
  `/etc/azure-pipelines-agent/env`. A path, prefix or threshold a script needs
  comes from `host.env` through `load_host_env`, never from a value baked in at
  install time, so a script is identical on every box and the test suite drives
  the real file. Every one sources `/usr/local/lib/runner-hardening/lib.sh` for
  what they share; nothing is spliced into a script. To change the janitor,
  edit `roles/runner_host/files/runner-janitor.sh`; to give it a new setting,
  add the setting to `host.env`.
- **The `.sh` suffix exists only in the repository.** Every runtime script ends
  in `.sh` there, because the shared ShellCheck target lints only `*.sh`, and
  its install task drops the suffix (`runner-diskguard.sh` →
  `/usr/local/sbin/gha-diskguard`). A script without it escapes lint silently.
  `lib.sh` and `vendor.sh` keep their names. A script's syslog and journal tag
  is its own basename (`${0##*/}`), so `journalctl -t gha-diskguard` keeps
  working on GitHub boxes and `journalctl -t azp-diskguard` works on Azure
  DevOps ones.
- **Each script is functions plus a guarded `main`.** The
  `if [[ "${BASH_SOURCE[0]}" == "${0}" ]]` guard around `main` is what lets the
  test suite source a script and call its functions. Do not remove it.
- **The flavour names are fixed for GitHub compatibility.** The GitHub values
  in the flavour table, and the format of `/etc/github-runner/env` and
  `/etc/github-runner/pat`, are the shell installer's: a fleet it set up
  converges without a user, home, unit or cache being renamed, and
  `git checkout 0.1.0 && ./fleet.sh --no-pat install` stays a working rollback.
  Never rename one, and never add a key to `/etc/github-runner/env` that the
  `0.1.0` installer cannot source harmlessly.
- **No secret may become a command-line argument**, on the controller or on a
  box. `/proc/<pid>/cmdline` is readable by every local user, including the
  unprivileged runner accounts the roles create. In Ansible:
  - never put a secret in `ansible.builtin.command` or `shell` arguments;
  - never put one in the `environment:` keyword: Ansible renders it as a
    `VAR=value` prefix on the remote command line;
  - never pass one as `-e name=value` (a vars file given as `-e @file` puts
    only its path in argv); the README and the converge workflow show the
    lookup that replaces it;
  - a secret reaches a box only inside a `no_log: true` task: as the `stdin` of
    an `install … /dev/stdin` command that writes its root-only file (unlike
    `copy` `content:`, this leaves no temporary copy in `~/.ansible/tmp`), or
    as `ansible.builtin.uri` `headers:`. A secret that must replace one in use
    goes to a staging file renamed over it, as the GitHub PAT does, so a runner
    starting meanwhile never reads half of it. `ansible.cfg` turns on
    pipelining, so module arguments travel on stdin.

  In scripts, read a secret from its root-only file, pass it to `curl` with
  `-H @file` rather than `-H "Authorization: Bearer ..."`, and hand it to a
  child through a variable exported inside the script (as `azp-register` does
  with `VSTS_AGENT_INPUT_TOKEN`, and `gha-run-ephemeral` with
  `ACTIONS_RUNNER_INPUT_JITCONFIG`), never `env VAR=secret cmd`. A secret never
  reaches code a job can write: `azp-register` runs `config.sh` as root in a
  pristine, root-owned unpack, never in the agent's own tree. Do not "simplify"
  any of these. `curl -K -` is not a substitute: its unquoted value form drops a
  malformed header silently, which sends the request unauthenticated instead of
  failing.
- **Adding a variable means its `defaults/main.yaml` entry, its row in the
  README's variable table, and its place in `inventory/example`.** A role's
  variables carry its prefix (`runner_`, `runner_github_`, `runner_azp_`), and
  a private fact starts with `_runner_`. The sync list below says what else a
  variable can drag in.
- **`ansible.builtin` only, always fully qualified.** The collection has zero
  dependencies on purpose: no `ansible.posix`, no `community.*`. Modules and
  roles are called by their FQCN (`rios0rios0.runner_hardening.runner_host`),
  and the code stays clean under the ansible-lint `production` profile, every
  task named and capitalised.
- **Every converge is idempotent.** A second converge reports `changed=0`, and
  the converge workflow fails a pull request that breaks it. Prefer a module to
  `command`/`shell`; every `command`/`shell` has a `changed_when`, and
  `changed_when: true` is banned. Use stat checks, `creates`/`removes`, and
  compare-then-write.
- **`runner_host_dedicated` gates every destructive step.** It defaults to
  `false`, and every task that dismantles Docker, de-privileges an account or
  deletes state asserts it.
- **De-privileging touches only the accounts `runner_old_users` names.** The
  candidates the converge finds are reported, never acted on: the installer's
  habit of taking a lone detected account on its own is gone, and a guess here
  locks an account out and kills its processes. The protections (uid 1000, a
  `NOPASSWD` sudoer, an `authorized_keys` owner, an active session) still apply
  to a listed account unless `runner_force_deprivilege` overrides them, and the
  summary lists only the accounts actually de-privileged, naming the protected
  ones it left alone. An account's caches are cleared as that account, never as
  root, for the disk guard's reason: what a deletion can reach through a planted
  link stays what the account could delete itself.
- **Trust fails safe.** `runner_trusted` in `lib.sh` is true only when
  `host.env` says exactly `internal`; anything else — the key missing,
  misspelt, empty — gets the full reset before every job. Keep every trust
  check that way round: the opposite mistake hands one fork PR's state to the
  next job.
- **A configuration change never kills a job.** The `Restart idle runners`
  handler restarts only idle instances (`<sbin>-admin restart-idle`); a busy
  one picks up the new definition on the restart that follows its job anyway.
  Two changes drain the runners they touch first, inside a `block` whose
  `rescue` runs `undrain`: a lower `MemoryMax` or `MemoryLow`, because a
  daemon-reload applies cgroup limits to a running unit at once, under its job;
  and a new runner release, the only thing that replaces a runner's tree. That
  `rescue` replaces the installer's EXIT trap, and like it, keeps a failed
  converge from leaving the box out of the pool.
- **Busy means a worker inside the unit's own cgroup.** `runner_busy` in
  `lib.sh` looks for `runner_worker_pattern` among the processes of the unit's
  `ControlGroup`, never among every process of the runner's uid, which a job
  can start outside the unit. The drain, the reboot guard and `restart-idle`
  all go through it; keep any new busy check there.
- **Root never reads a job-writable file through a link.** Anything root reads
  under a runner's home or tree goes through `read_untrusted` in `lib.sh`
  (`dd iflag=nofollow`, as the runner's user inside its own tree), because a
  job can replace any file there with a link to a root-only one. For the same
  reason a task that writes into a job-writable tree sets `diff: false`: the
  diff would read the old file as root and print it on the controller.
- **The stored PAT is a fallback, never an override, and never a requirement.**
  With `runner_github_pat` defined the role writes it; undefined, each host
  uses `/etc/github-runner/pat`. Do not add a code path that requires the
  controller to hold the admin token for a machine that already has one: that
  is what lets a re-deploy run with no token on the controller. Azure DevOps
  stores no PAT at all; one is needed only to register or remove an agent.
- **`reap` and `verify` touch only this host's registrations.** They match a
  registration to this host by its exact runner name or the `<host>-` prefix,
  and spare names minted in the last 5 minutes, so a runner that has just
  registered, or another host's, is never taken for a leak.
- **`set -Eeuo pipefail` is on in every script**, or `set -uo pipefail` where a
  script deliberately never fails its unit, as the disk guard does. A
  `[[ cond ]] && action` list whose condition can be false is fine on its own,
  but one whose *action* can fail needs `|| true`, or write it as an `if`.
  `exit` inside `$( )` only leaves the subshell: assign a command substitution
  whose failure must stop the script rather than inlining it. Scripts are
  ShellCheck-clean at `--severity=warning`.
- **Comment the surprising decision, not the obvious line**, and do not add
  comments that restate code. The why-comments ported from the installer are
  this repository's incident record: never drop one, or a guard, because it
  looks redundant. Nearly every one exists because of a production incident.
- **The disk guard runs first, before the vendor's pre step, and deletes as the
  runner user.** Before the vendor's `ExecStartPre` is the one point a runner is
  guaranteed idle: put any line ahead of the guard's and it can delete a
  toolchain from under a job its runner was just handed. Every path it clears is
  job-writable, so a job can plant a symlink there; `as_runner` drops to the
  runner user (`setpriv`) for every deletion, which caps what a planted link can
  reach at what the job could delete itself. Do not "simplify" a deletion back
  to root. With `trust=untrusted` it resets the runner in full before every
  job — that reset, not a wrapper's post-job wipe, is what keeps one fork PR's
  state from the next, because a job can kill its wrapper before the wrapper's
  trap fires. The paths `runner_home_keep_extra` and `runner_home_seed` name
  survive that reset, which is why the converge warns when either is set on an
  untrusted host. So does the rootless daemon's user unit, which a job can
  rewrite: the guard keeps a root-owned copy of each runner's, taken on its
  first run, in `/var/lib/runner-hardening/rootless/<user>.docker.service`,
  and before every untrusted job puts it back and restarts the runner's Docker
  daemon, about 1–3 s a job. Do not drop the restore to save that time.
- **`restart_backoff_delay` and `cycle_ran_a_job` live in `lib.sh`, with the
  installer's signatures.** `gha-jitconfig`, `gha-jitreap` and `azp-cycle` all
  go through them (`azp-cycle` by way of `lib.sh`'s `wait_out_backoff` and
  `record_cycle`), so both flavours back off the same way, and the suite tests
  the one definition.
- **systemd-oomd is not part of the design.** The slice carries no `ManagedOOM*`
  policy (its own comment says why); its `MemoryMax` confines the kernel's OOM
  killer to CI, and `OOMPolicy=continue` makes that kill a failed step. Heavy
  jobs are kept apart by routing (the `heavy` label or capability) and sized by
  `CODEQL_RAM`, not by killing them sooner.
- **`TMPDIR=/var/tmp` in the unit is deliberate** (the unit template says why:
  Ubuntu `26.04`'s `/tmp` is a small tmpfs every runner shares). Do not point
  `TMPDIR` back at `/tmp`, and do not drop `PrivateTmp=`, which is what makes
  `/var/tmp` private.
- **An Azure DevOps container job's steps run as container root.** The agent
  runs them as `docker exec -u <its own uid>`, which rootless Docker maps to a
  subordinate uid that owns nothing of the agent's; `azp-docker`, first on
  every agent's `.path`, makes that one call `-u 0`, the agent's own user.
  Keep it first on `.path`, keep it rewriting only the agent worker's own
  `exec -u <its uid>`, and do not answer a container job's permission error
  with ACLs: a file made `0700` masks every named entry out, and what such a
  uid leaves in `_work` neither the agent nor the disk guard can delete.
- **Anything that changes system state is untestable here.** `make test`
  renders and parses; only the converge workflow, or a disposable Ubuntu VM,
  exercises a real box. Say so rather than claiming a change is verified when
  only `make test` has run.

## Keeping the cross-file lists in sync

These sets live in more than one file and drift silently:

- **A new role variable** goes in the role's `defaults/main.yaml`, the README's
  variable table, and `inventory/example` (commented, showing its default) —
  and, when a runtime script reads it, in the `host.env` template, the script,
  and a `test/runtime` case.
- **A new runtime script** ends in `.sh`, and gets an install task that drops
  the suffix, a `test/runtime/*_test.sh` case, a row in this file's script
  table, and a removal in `playbooks/uninstall.yaml`. `make test` and
  `make lint` find it by its suffix.
- **A new `<sbin>-admin` mode** goes in `runner-admin.sh`'s dispatch and usage
  text, and in the README's `gha-admin` table — plus a playbook, if it should
  run fleet-wide.
- **A new playbook** goes in the README's playbook table; `make test`
  syntax-checks every `playbooks/*.yaml` by itself.
- **A new flavour fact** goes in both vendor roles' first `set_fact`, in the
  `host.env` template and `lib.sh` when a script needs it, and in the flavour
  tables here and in the README.
- **A new vendor hook** goes in its `vendor.sh`, in the caller that looks it up
  with `declare -F`, and in this file's script table.
- **Anything the roles put in a runner's `$HOME`** goes in the disk guard's
  keep list, the base `RUNNER_HOME_KEEP` in `runner_host`'s `host.env`
  template, or the first reset under disk pressure deletes it. An operator's own
  paths go in `runner_home_keep_extra`; `runner_home_seed` keys are kept
  automatically.
- **A new key in `/etc/github-runner/env`** goes in the `runner_github`
  template, and must be one the `0.1.0` installer can source harmlessly.

## Tests

`make test` runs, in order:

1. `bash -n` on every `*.sh` under `roles/` and `test/`;
2. `test/runtime/run.sh`, which runs every `test/runtime/*_test.sh`
   (`host_test.sh`, `github_test.sh`, `azure_devops_test.sh`), each in its own
   process, and prints a total. It counts the protocol lines below rather than
   trusting a file's own summary, and fails a file that exits non-zero without
   reporting why, or that ran no case;
3. `test/ansible/policy.yaml`: the pure task files of `runner_host` — the
   memory policy, the runner count, the surplus instances, the legacy units —
   against numbers the shell installer's own arithmetic produced;
4. `test/ansible/templates.yaml`: renders the unit, slice, drop-ins, timers and
   `host.env` for both flavours into a scratch directory, as non-root, and
   asserts the invariants — the guard's line before the vendor pre lines,
   `RestartSec=1`, no `RestartSteps`, `OOMPolicy=continue`,
   `TMPDIR=/var/tmp`, no `ManagedOOM`;
5. `ansible-playbook --syntax-check` on every `playbooks/*.yaml`.

`test/runtime/harness.sh` is what every runtime test file sources. It lays out
a scratch box shaped like a real one (`new_box`), and drives the real scripts
against it as non-root, offline, in seconds. A case may substitute only what a
box has and a test run does not:

- the root-only steps, overridden after sourcing a script: the `setpriv` drop
  (`as_runner`), the runner users themselves (`runner_uid`), and the chown to
  root (`ensure_run_dir`);
- what a box talks to, as stand-ins in the scratch box's `bin/`, first on
  `PATH`, each recording how it was called: `systemctl`, `pgrep`, `logger`,
  `docker` (a test must never reach the developer's own daemon) and `curl` (a
  test must never reach the network).

- Hand-rolled BDD, `# given / # when / # then`, no mocking library.
- Each case is an `it_*` function **defined and then invoked on the very next
  line**. It prints `  ok  <name>` or `FAIL  <name>: <why>`, and the file's
  closing `finish` exits 1 when anything failed. There is no filter: to run
  one case, source the file's setup and call the function, or just run the
  whole suite.
- `.github/workflows/converge.yaml` is the only automated run on a real box:
  both playbooks on a disposable `ubuntu-24.04` VM, twice, failing unless the
  second converge reports `changed=0` and `failed=0`, then
  `systemd-analyze verify` on the installed units. It sets
  `runner_start_units: false`, `runner_github_validate_pat: false` and
  `runner_azp_skip_registration: true`, so it proves the install, never a
  registration or a job.

## Anonymity

This repository is public and describes infrastructure. Do not add host names,
IP addresses, organisation names, pool names, fleet sizes, or anything else
that identifies a specific deployment. Examples use `your-org`, `example`,
`build-01`, `https://dev.azure.com/your-org`, `your-pool`, and RFC 5737 /
RFC 1918 addresses.

## Documentation

Every change adds a `chlog` fragment under `.changes/unreleased/`, made with
`chlog new --kind <Kind> --body '<past-tense description>'` (kinds are listed
in `.chlog.yaml`; keep the body single-quoted); never edit `CHANGELOG.md` by
hand. Update `README.md` whenever a variable, a playbook, an `<sbin>-admin`
mode or a requirement changes, and `inventory/example` whenever a variable
does.
