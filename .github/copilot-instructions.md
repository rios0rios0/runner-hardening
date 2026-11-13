## What this repository is

An Ansible collection, `rios0rios0.runner_hardening`, that turns raw Ubuntu
boxes into hardened, ephemeral, rootless self-hosted CI hosts — GitHub Actions
runners or Azure Pipelines agents — and converges a fleet of them from one
inventory. The repository root is the collection, and it depends on nothing
beyond `ansible.builtin`.

| Path                         | Role                                                                    |
|------------------------------|-------------------------------------------------------------------------|
| `roles/runner_host/`         | The vendor-neutral host role: hardening, users, rootless Docker, the unit, slice and resource policy, the disk guard, janitor and reboot guard. |
| `roles/runner_github/`       | GitHub Actions runners: JIT registration, the one-job wrapper, `/etc/github-runner`. |
| `roles/runner_azure_devops/` | Azure Pipelines agents: adoption or registration, `run.sh --once`, the `lru` work policy. |
| `roles/*/files/*.sh`         | Every runtime script, static, installed without its `.sh`.               |
| `playbooks/`                 | `github.yaml`, `azure_devops.yaml`, `verify`, `diagnose`, `drain`, `uninstall`, `rotate_github_pat`. |
| `inventory/example/`         | The documented inventory; real ones live in the gitignored `inventory/local/`. |

`AGENTS.md` at the repo root covers the same ground in more depth; read it for
the full architecture map. This file is the fast orientation for Copilot Chat.

## Commands

```bash
make setup        # clone/update the shared pipelines scripts lint and sast need
make collection   # resolve the collection from build/collections
make lint         # ShellCheck + ansible-lint (production profile)
make test         # bash -n, the runtime suite, the Ansible test playbooks, syntax checks
make sast         # CodeQL, Semgrep, Trivy, Hadolint, Gitleaks
```

`make test` needs only `bash` and `ansible-core`; the rest read the shared
configuration from a local checkout of `rios0rios0/pipelines` and need
`make setup` first (or `make SCRIPTS_DIR=/path/to/pipelines <target>`). Never
call `shellcheck`, `ansible-lint`, `semgrep` or `gitleaks` directly — the
Makefile targets load the shared config that every repository standardises on.

## Architecture you cannot see by reading one file

- **A vendor role orchestrates; the host role is called into it.** A vendor
  role's `tasks/main.yaml` sets the flavour facts first, validates its
  credentials, then calls `runner_host` three times:
  `tasks_from: prepare` (preflight, legacy units, de-privilege, one-time wipe,
  prerequisites, users and rootless Docker), then its own helpers and trees,
  then `tasks_from: finish` (`host.env`, scripts, policy, unit, slice,
  drop-ins, enable, timers, `verify`), then surplus de-registration, then
  `tasks_from: retire`. The order encodes dependencies. Do not reorder without
  tracing what each step assumes exists.

- **The flavour is data.** `runner_user_prefix`, `runner_base_dir`,
  `runner_unit`, `runner_slice`, `runner_sbin_prefix`, `runner_config_dir`,
  `runner_worker_pattern`, `runner_work_policy` and the unit's vendor lines are
  set by the vendor role and drive every name on the box. The GitHub values
  (`gha`, `/opt/actions-runner`, `gha-runner@`, `gha.slice`,
  `/etc/github-runner`) are the shell installer's, on purpose: an existing
  fleet converges without anything being renamed.

- **Scripts are static; configuration is a file.** The roles copy fixed
  scripts and write the files those read at runtime:
  `/etc/runner-hardening/host.env`, `/etc/github-runner/env`,
  `/etc/azure-pipelines-agent/env`. No script is a template, so every script is
  identical on every box and the tests drive the real file. Every script
  sources `/usr/local/lib/runner-hardening/lib.sh` for the shared functions;
  nothing is spliced in. Vendor hooks in `vendor.sh` run only when `declare -F`
  finds them.

- **The ephemeral loop is the core invariant.** systemd starts
  `gha-runner@N` (or `azp-agent@N`); the first `ExecStartPre` (root) runs the
  disk guard, which frees that runner's own caches once the disk is past
  `runner_disk_soft_pct` and is a no-op otherwise (with `trust=untrusted` it
  resets the runner in full, every time); the next `ExecStartPre` (root) waits
  out any restart backoff, then mints a single-use JIT config (GitHub) or marks
  the cycle's start (Azure DevOps), so no PAT is ever seen by the runner user;
  `ExecStart` runs a root-owned wrapper from
  `/usr/local/libexec/runner-hardening`, outside the job-writable tree, for
  exactly ONE job (`./run.sh --jitconfig`, `./run.sh --once`); `ExecStopPost`
  (root) counts a cycle that ran no job and, on GitHub, deletes the
  registration; `Restart=always` loops. The backoff is keyed on job-less cycles
  (no `_diag/Worker_*.log` newer than the cycle's marker), never on systemd's
  `RestartSteps`, which counts every restart and so idled healthy runners for
  minutes after each job; for the same reason `RestartSec` stays at 1 s, since
  every job pays it. A change that lets `run.sh` survive a second job, or that
  lets a wrapper `exec` (which discards the EXIT trap and skips cleanup),
  silently turns these back into long-lived runners. The wrapper runs as the
  job's user, so a job can kill it before its trap fires: what isolates one job
  from the next is the root disk guard's reset with `trust=untrusted`, never the
  wrapper's cleanup. Every README security claim rests on this chain.

- **A configuration change never kills a job.** The `Restart idle runners`
  handler restarts only idle instances; a busy one picks up the new unit on the
  restart that follows its job. A runner tree is replaced only on a version
  change, after a drain, in a `block` whose `rescue` undrains.

## Conventions a generic assistant gets wrong here

- **No secret may become a command-line argument, anywhere.**
  `/proc/<pid>/cmdline` is world-readable, including to the unprivileged runner
  accounts. Never put a secret in `command`/`shell` arguments, never in the
  `environment:` keyword (Ansible renders it as a `VAR=value` prefix on the
  remote command line), never as `-e name=value`. A secret reaches a box only as
  `ansible.builtin.copy` `content:` into a root-only file, or as
  `ansible.builtin.uri` `headers:`, each with `no_log: true`, with pipelining
  on. Scripts pass a token to `curl` with `-H @file`, and to a child through a
  variable exported inside the script, never `env VAR=secret cmd`. `curl -K -`
  is not a substitute — its unquoted value form drops a malformed header
  silently and sends the request unauthenticated.
- **The `.sh` suffix is a repository convention.** Every runtime script ends in
  `.sh` so the shared ShellCheck target lints it; the install task drops it.
  `lib.sh` and `vendor.sh` keep their names, and a script's journal tag is its
  installed basename.
- **Every converge is idempotent.** A second converge must report `changed=0`;
  the converge workflow enforces it. Every `command`/`shell` task needs a
  `changed_when`, and `changed_when: true` is banned. Prefer a module.
- **`ansible.builtin` only, by FQCN, clean under the ansible-lint `production`
  profile.** No `ansible.posix`, no `community.*`; every task named and
  capitalised; variables prefixed `runner_`, `runner_github_` or `runner_azp_`,
  private facts `_runner_`.
- **Adding a variable means `defaults/main.yaml`, the README's variable table,
  and `inventory/example`.**
- **`runner_host_dedicated` gates every destructive step**, and defaults to
  `false`.
- **De-privileging touches only what `runner_old_users` lists.** Candidates the
  converge finds are reported, never acted on.
- **Trust fails safe.** `runner_trusted` in `lib.sh` is true only for an exact
  `internal` in `host.env`; anything else gets the full reset before every job.
  Never write a trust check the other way round.
- **The stored PAT is a fallback, never a requirement.** Undefined
  `runner_github_pat` means each host reuses `/etc/github-runner/pat`. Do not
  add a path that requires the controller to hold the admin token for a host
  that already has one.
- **The disk guard runs first and deletes as the runner user.** Its
  `ExecStartPre` must stay ahead of the vendor's, because before it is the one
  point a runner is guaranteed idle. Every path it clears is job-writable, so
  `as_runner` drops to the runner user (`setpriv`) for every deletion; a planted
  symlink then reaches no further than the job could delete itself. Do not move
  a deletion back to root.
- **`restart_backoff_delay` and `cycle_ran_a_job` live in `lib.sh`** with the
  installer's signatures, shared by both flavours' cycle helpers.
- **`set -Eeuo pipefail` is on in every script** (or `set -uo pipefail` where a
  script deliberately never fails its unit). A `[[ cond ]] && action` whose
  *action* can fail needs `|| true`, or write it as an `if`. Each script keeps
  its `if [[ "${BASH_SOURCE[0]}" == "${0}" ]]` guard around `main` so the tests
  can source it.
- **`OOMPolicy=continue` and the absence of any `ManagedOOM*` policy are
  deliberate.** systemd's default `stop` turned one OOM-killed job process into
  a stop of the whole runner ("The runner has received a shutdown signal"), and
  systemd-oomd is absent from a server install. Heavy jobs are kept apart by the
  `heavy` label or capability and sized by the `CODEQL_RAM` each runner exports.
- **`TMPDIR=/var/tmp` in the unit is deliberate.** Ubuntu `26.04`'s `/tmp` is a
  tmpfs of half the RAM that `PrivateTmp=` shares between every runner on the
  box; concurrent test suites filled it. The private `/var/tmp` is on disk and
  wiped at every stop just the same.

## Keeping the cross-file lists in sync

These sets live in more than one file and drift silently:

- **A new role variable** goes in `defaults/main.yaml`, the README's variable
  table and `inventory/example` — and, when a script reads it, the `host.env`
  template, the script and a `test/runtime` case.
- **A new runtime script** ends in `.sh`, gets an install task that drops the
  suffix, a `test/runtime` case, a row in `AGENTS.md`'s script table, and a
  removal in `playbooks/uninstall.yaml`.
- **A new `<sbin>-admin` mode** goes in `runner-admin.sh` and the README's
  `gha-admin` table.
- **A new playbook** goes in the README's playbook table.
- **Anything the roles put in a runner's `$HOME`** goes in the disk guard's
  keep list (`RUNNER_HOME_KEEP` in the `host.env` template), or the first reset
  under disk pressure deletes it.
- **A new key in `/etc/github-runner/env`** must be one the `0.1.0` installer
  can source harmlessly: that release is the rollback.

## Testing

`make test` runs `bash -n` on every script; `test/runtime/run.sh`, which runs
each `test/runtime/*_test.sh` in its own process and totals the result;
`test/ansible/policy.yaml` (the memory policy, the count, the surplus and the
legacy units, pinned to numbers the shell installer's arithmetic produced);
`test/ansible/templates.yaml` (the unit, slice, drop-ins, timers and `host.env`
of both flavours, rendered and checked for their invariants); and
`ansible-playbook --syntax-check` on every playbook.

The runtime tests source `test/runtime/harness.sh`, which builds a scratch box
and drives the real scripts against it as non-root, offline. Only what a test
run lacks is substituted: the root-only steps (`as_runner`, `runner_uid`,
`ensure_run_dir`), and stand-ins on `PATH` for `systemctl`, `pgrep`, `logger`,
`docker` and `curl`, each recording how it was called. Cases are hand-rolled
BDD (`# given / # when / # then`), each an `it_*` function defined and invoked
on the next line; the final tally picks up new ones automatically.

`.github/workflows/converge.yaml` converges both playbooks twice on a disposable
`ubuntu-24.04` VM and fails unless the second run reports `changed=0`, then runs
`systemd-analyze verify` on the installed units. It never starts a runner or
registers one. **Anything beyond that is untestable here** — a registration, a
job, a reboot have to be run on a disposable Ubuntu VM. Say so rather than
claiming a change is verified when only `make test` has run.

## Anonymity and documentation

This repo is public and describes infrastructure: no host names, IP addresses,
organisation or pool names, or fleet sizes. Examples use `your-org`,
`your-pool`, `example`, and RFC 5737 / RFC 1918 addresses. Every change adds a
`chlog` fragment under `.changes/unreleased/`
(`chlog new --kind <Kind> --body '...'`); never edit `CHANGELOG.md` by hand —
it is generated. Update `README.md` whenever a variable, a playbook, an admin
mode, or a requirement changes, and `inventory/example` whenever a variable
does.
