## What this repository is

Two self-contained Bash scripts that turn a raw Ubuntu box into a hardened,
ephemeral, rootless GitHub Actions runner host, and fan that setup across a
fleet over SSH. No build step, no runtime dependencies beyond a stock Ubuntu
image plus `ssh`.

| File                     | Role                                                                       |
|--------------------------|----------------------------------------------------------------------------|
| `harden-gha-runners.sh`  | The installer. Runs as root on one Ubuntu box and does all the work.       |
| `fleet.sh`               | Fans any installer mode out across the machines in `fleet.conf`, over SSH. |
| `fleet.conf.example`     | The documented fleet format. `fleet.conf` itself is gitignored.            |
| `test/bootstrap_test.sh` | Tests for the config reader, the remote bootstrap and the disk guard.      |

`CLAUDE.md` at the repo root covers the same ground in more depth; read it for
the full architecture map. This file is the fast orientation for Copilot Chat.

## Commands

```bash
make setup   # clone/update the shared pipelines scripts the other targets need
make lint    # ShellCheck
make test    # parse check + the test suite (~3s, 160 assertions, no VM)
make sast    # CodeQL, Semgrep, Trivy, Hadolint, Gitleaks
```

`make test` is the only target that works on a bare clone; the rest read the
shared configuration from a local checkout of `rios0rios0/pipelines` and need
`make setup` first (or `make SCRIPTS_DIR=/path/to/pipelines <target>`). Never
call `shellcheck`, `semgrep` or `gitleaks` directly — the Makefile targets load
the shared config that the fleet standardises on. To run one test case in
isolation there is no filter: source the file's setup and call the `it_*`
function, or just run the whole suite.

## Architecture you cannot see by reading one file

- **The installer is a mode dispatcher over phases.** `main()` at the bottom of
  `harden-gha-runners.sh` is a `case` on the mode. Most modes assert root,
  `load_config`, then run one `phase_*`. `install` and `reconfigure` are the
  exception: they run a **fixed, ordered pipeline** (preflight → discover →
  wizard/load_config → audit → stop_existing → deprivilege → wipe → prereqs →
  per-runner user + rootless Docker → swap → token_helper → diskguard → runners → systemd →
  janitor → unattended → cleanup_stale → verify → summary). The order encodes
  dependencies. Do not reorder without tracing what each phase assumes exists.

- **The installer *generates* the runtime it hardens.** Nothing under
  `/usr/local/sbin` or `/opt/actions-runner` exists in this repo. Every helper,
  wrapper and systemd unit is written by a `phase_*` function as a heredoc. To
  change the janitor you edit the heredoc inside `phase_janitor`, not a separate
  file.

- **The ephemeral loop is the core invariant.** systemd starts `gha-runner@N`;
  a first `ExecStartPre` (root) runs `gha-diskguard`, which frees that runner's
  own caches once the disk is past 75% and is a no-op otherwise (with
  `trust=untrusted` it resets the runner in full, every time); the next
  `ExecStartPre` (root) waits out any restart backoff, then mints a
  single-use JIT config to `/run/gha-runner/N.jit`
  so the PAT is never seen by the runner user; `ExecStart` (runner user) wipes
  `_work` and runs `./run.sh --jitconfig` for exactly ONE job; `ExecStopPost`
  (root) counts a cycle that ran no job and deletes the registration;
  `Restart=always` loops with a fresh registration and workspace. The
  backoff is keyed on job-less cycles (no `_diag/Worker_*.log` newer than the
  cycle's `.jit`), never on systemd's `RestartSteps`, which counts every
  restart and so idled healthy runners for minutes after each job. A change that lets `run.sh` survive a second job,
  or that lets the wrapper `exec` (which discards the EXIT trap and skips
  cleanup), silently turns these back into long-lived runners. Every README
  security claim rests on this chain.

- **`fleet.sh` is a transport, not a second installer.** `parse_config` (a
  hand-rolled INI reader — never `source`; a fleet definition is data) →
  `select_hosts` → per host `build_env` emits the `GHA_*` exports →
  `build_bootstrap` wraps them and the base64'd installer into one stdin stream →
  `run_host` pipes it to `ssh`. It never decides policy: an omitted `fleet.conf`
  key is not sent, so the host keeps its stored answer.

## Conventions a generic assistant gets wrong here

- **`harden-gha-runners.sh` is self-contained.** It is copied onto machines on
  its own, so it must never source another file from this repo. Shared helpers
  between it and `fleet.sh` are duplicated on purpose — do not refactor them
  into a common file.
- **`set -Eeuo pipefail` is on in both scripts.** A `[[ cond ]] && action` whose
  *action* can fail needs `|| true`, or write it as an `if`.
- **Heredoc quoting is load-bearing.** `<<EOF` expands installer-side variables
  into the generated artefact; `<<'EOF'` ships the body verbatim, so every
  runtime `$` must be escaped (`\$JIT`). Getting it backwards yields a valid
  script that reads an empty variable at job time. `phase_runners` runs `bash -n`
  on the wrapper it writes for this reason — keep that check for new generated
  scripts.
- **No secret may become a command-line argument, anywhere.** `/proc/<pid>/cmdline`
  is world-readable, including to the unprivileged runner accounts. The SSH
  bootstrap streams its env file on stdin; every `curl` passes the token with
  `-H @file`. `curl -K -` is not a substitute — its unquoted value form drops a
  malformed header silently and sends the request unauthenticated.
- **The stored configuration is a default, never an override.** `load_config`
  saves caller-supplied `GHA_*` answers, sources `/etc/github-runner/env`, then
  restores the caller's values, falling back to `/etc/github-runner/pat` only
  when no `GHA_PAT` was given. Do not replace it with a plain `. "$ENV_FILE"`:
  the install dispatch runs it inside an `&&` chain for its side effect, so a
  clobbering version makes unattended runs report success while changing
  nothing. It is also what lets `fleet.sh --no-pat install` work.
- **`die` inside `$( )` only exits the subshell.** `build_bootstrap` assigns
  `build_env`'s output to a variable rather than inlining the substitution, so
  the failure propagates under `errexit`. Do not inline it again.
- **Every mode is idempotent.** A second consecutive run that changes something
  is a bug.
- **The disk guard runs before the registration is minted, and deletes as the
  runner user.** Before `gha-jitconfig` is the one point a runner is guaranteed
  idle, so the two `ExecStartPre` lines must not be swapped. Every path it
  clears is job-writable, so `as_runner` drops to the runner user (`setpriv`)
  for every deletion; a planted symlink then reaches no further than the job
  could delete itself. Do not move a deletion back to root.
- **`restart_backoff_delay`, `cycle_ran_a_job` and `runner_labels` are spliced
  into the generated JIT helpers with `declare -f`.** Edit them in the installer
  and keep them self-contained: nothing else of the installer travels with them.
- **`OOMPolicy=continue` and the absence of any `ManagedOOM*` policy are
  deliberate.** systemd's default `stop` turned one OOM-killed job process into
  a stop of the whole runner ("The runner has received a shutdown signal"), and
  systemd-oomd is absent from a server install. Heavy jobs are kept apart by the
  `heavy` label and sized by the `CODEQL_RAM` each runner exports.
- **`TMPDIR=/var/tmp` in the unit is deliberate.** Ubuntu 26.04's `/tmp` is a
  tmpfs of half the RAM that `PrivateTmp=` shares between every runner on the
  box; concurrent test suites filled it. The private `/var/tmp` is on disk and
  wiped at every stop just the same.
- **Every wizard question must also be answerable from the environment.**
  `fleet.sh` drives the installer over SSH with no pty, so an interactive-only
  prompt is unreachable to the fleet.

## Keeping the cross-file lists in sync

These sets are duplicated by design and drift silently:

- **A new mode** goes in five places: the installer's `main()` `case`, the
  `die "unknown mode ..."` list beside it, the installer's header USAGE block
  (the `--help` output is a hardcoded `sed -n '2,30p'` range — adding a header
  line pushes `uninstall` out of the window, so adjust the range too),
  `VALID_MODES` in `fleet.sh`, and the README.
- **A new `fleet.conf` key** goes in `KNOWN_KEYS` (an unknown key is a hard
  parse error), the `cfg` reads in `build_env`, the export it emits,
  `fleet.conf.example`, and the README.
- **A new `GHA_*` answer** goes in `CONFIG_ANSWERS`, the `save_config` heredoc,
  the wizard, and the README's variable table.
- **Anything the installer puts in a runner's `$HOME`** goes in the disk
  guard's `KEEP` list too, or the first reset under disk pressure deletes it.

## Testing

`test/bootstrap_test.sh` sources both scripts and exercises their real
functions (`parse_config`, `build_env`, `build_bootstrap`, `load_config`,
`should_preload_config`, `runner_state_between_jobs`, `report_disk`,
`restart_backoff_delay`, `cycle_ran_a_job`, `runner_labels`,
`compute_resource_policy`, `render_instance_dropin`). The bootstrap cases run
the real bootstrap through a real `bash -s`, exactly as `sshd` would on the far
side, against a stand-in installer — only the SSH hop is substituted. The
disk-guard cases render `gha-diskguard` from `render_diskguard` and drive its
eviction steps against a scratch runner tree — only the root-only privilege
drop is substituted. Cases are
hand-rolled BDD (`# given / # when / # then`), each an `it_*` function defined
and invoked on the next line; the final tally picks up new ones automatically.

**Anything that changes system state is untestable here** — it has to be run on
a disposable Ubuntu VM. Say so rather than claiming a change is verified when
only `make test` has run.

## Anonymity and documentation

This repo is public and describes infrastructure: no host names, IP addresses,
organisation names, or fleet sizes. Examples use `your-org`, `example`, and
RFC 5737 / RFC 1918 addresses. Every change adds a `chlog` fragment under
`.changes/unreleased/` (`chlog new --kind <Kind> --body '...'`); never edit
`CHANGELOG.md` by hand — it is generated. Update `README.md` whenever a flag, a
`GHA_*` variable, a `fleet.conf` key, or a requirement changes.
