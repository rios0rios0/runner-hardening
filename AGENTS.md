# AGENTS.md

This file provides guidance to AI coding agents (Claude Code, Codex, Cursor, GitHub Copilot) when working with code in this repository.

## What this is

Two Bash scripts, no build step, no runtime dependencies beyond what a stock
Ubuntu image plus `ssh` provides.

| File                     | Role                                                                       |
|--------------------------|----------------------------------------------------------------------------|
| `harden-gha-runners.sh`  | The installer. Runs as root on one Ubuntu box and does all the work.       |
| `fleet.sh`               | Fans any installer mode out across the machines in `fleet.conf`, over SSH. |
| `fleet.conf.example`     | The documented fleet format. `fleet.conf` itself is gitignored.            |
| `test/bootstrap_test.sh` | Tests for the config reader, the remote bootstrap and the disk guard.      |

## Commands

```bash
make setup   # clone/update the shared pipelines scripts the other targets use
make lint    # ShellCheck
make test    # parse check + the test suite (~3s, 163 assertions, no VM needed)
make sast    # CodeQL, Semgrep, Trivy, Hadolint, Gitleaks
```

Never invoke `shellcheck`, `semgrep` or `gitleaks` directly — the Makefile
targets load the shared configuration first. `make test` is the only target
that works on a bare clone; the rest need `make setup` (or
`make SCRIPTS_DIR=/path/to/pipelines <target>`).

## Architecture

### The installer is a mode dispatcher over phases

`main()` at the bottom of `harden-gha-runners.sh` is a `case` on the mode. Most
modes are one line: assert root, `load_config`, run a single `phase_*`
function. `install` and `reconfigure` are the exception — their branch of the
`case` runs a **fixed, ordered pipeline** of phases. The order encodes
dependencies; do not reorder without tracing what each phase assumes already
exists.

Both scripts end with an `if [[ "${BASH_SOURCE[0]}" == "${0}" ]]` guard around
`main`. **That guard is what makes the test suite possible** — it sources both
files to test their functions. Do not remove it.

### The installer *generates* the runtime it hardens

Nothing under `/usr/local/sbin` or `/opt/actions-runner` exists in this
repository. Every helper, wrapper and unit is written by a `phase_*` function
as a heredoc. To change the janitor's behaviour you edit the heredoc inside
`phase_janitor`, not a separate file.

| Generated artefact                       | Written by            | Role                                                          |
|------------------------------------------|-----------------------|---------------------------------------------------------------|
| `/usr/local/sbin/gha-jitconfig`          | `phase_token_helper` (text from `render_jitconfig`) | root-only; waits out any restart backoff, then mints one single-use JIT config, adding the `heavy` label for runners 1..`GHA_HEAVY_RUNNERS` |
| `/usr/local/sbin/gha-jitreap`            | `phase_token_helper` (text from `render_jitreap`) | root-only; counts job-less cycles, deletes the registration when a runner stops |
| `/usr/local/sbin/gha-diskguard`          | `phase_diskguard` (text from `render_diskguard`) | root-only; before each job, frees that runner's caches under disk pressure, or resets it in full when `trust=untrusted` |
| `/opt/actions-runner/<n>/run-ephemeral.sh` | `phase_runners`     | runs exactly one job, then cleans up and exits                |
| `/etc/systemd/system/gha-runner@.service`| `phase_systemd`       | the hardened unit template                                    |
| `/etc/systemd/system/gha.slice`          | `write_resource_policy` | aggregate CPU/memory boundary for all runners                |
| `/etc/systemd/system/gha-runner@<n>.service.d/10-instance.conf` | `write_resource_policy` (text from `render_instance_dropin`) | the runner's paths, memory floor and ceiling, and the `CODEQL_RAM` every job sees |
| `/usr/local/sbin/gha-janitor` + timer    | `phase_janitor`       | daily disk trim, orphan reap, PAT expiry check                |
| `/usr/local/sbin/gha-reboot-if-idle` + timer | `install_reboot_guard` | reboots only in-window and only when no runner is busy    |

### The ephemeral loop is the core invariant

```
systemd starts gha-runner@N
  → ExecStartPre=-+/usr/local/sbin/gha-diskguard N  (root; no-op below 75% disk, else frees runner N's caches;
                                                    untrusted: resets runner N in full, every time)
  → ExecStartPre=+/usr/local/sbin/gha-jitconfig N   (root; PAT never seen by the runner user)
      waits 10s..5min first if the last cycles ran no job, then
      writes a single-use JIT config to /run/gha-runner/N.jit
  → ExecStart=run-ephemeral.sh                       (runner user; reads the .jit, wipes _work)
      ./run.sh --jitconfig "$JIT"   -- exits after ONE job
  → ExecStopPost=+/usr/local/sbin/gha-jitreap N      (root; counts a job-less cycle unless the stop was
                                                    requested, then removes the registration)
  → Restart=always  → back to the top with a fresh registration and a fresh workspace
```

Every security claim in the README rests on this chain. A change that lets
`run.sh` survive a second job, or that lets the wrapper `exec` (which discards
the EXIT trap and skips cleanup), silently turns these back into long-lived
runners. `StartLimitIntervalSec=0`, `OOMPolicy=continue` and the absence of
`RestartSteps`/`RestartMaxDelaySec` are deliberate (`phase_systemd` says why
beside each). The restart backoff is gha-jitconfig's, keyed on cycles that ran
no job — a `_diag/Worker_*.log` newer than the cycle's `.jit` — never on the
exit status, which run-helper sets to 0 even on a terminated error.

### Where state lives on a hardened box

| Path                        | Contents                                                          |
|-----------------------------|-------------------------------------------------------------------|
| `/etc/github-runner/env`    | the stored answers (`GHA_*`), sourced by `load_config`             |
| `/etc/github-runner/pat`    | the admin PAT, `0600 root:root`, never readable by a job           |
| `/opt/actions-runner/<n>`   | one extracted runner tree per instance, owned by `gha<n>`          |
| `/home/gha<n>`              | the runner's `$HOME`: package caches, SDKs, the rootless Docker data root; kept between jobs |
| `/opt/hostedtoolcache-gha<n>` | the runner's private hosted tool cache (`AGENT_TOOLSDIRECTORY` when `trust=internal`) |
| `/run/gha-runner/<n>.jit`   | the current single-use registration; tmpfs, gone on reboot         |
| `/run/gha-runner/<n>.fails` | cycles in a row that ran no job — drives the restart backoff; tmpfs |
| `/var/tmp/systemd-private-*-gha-runner@<n>.service-*/tmp` | the job's `TMPDIR` (`/var/tmp` inside the unit): private, on disk, removed at every stop |
| `/var/lib/github-runner`    | installer state                                                    |

### `fleet.sh` is a transport, not a second installer

`parse_config` (a hand-rolled INI reader — never `source`, a fleet definition
is data) → `select_hosts` → per host: `build_env` emits the `GHA_*` exports →
`build_bootstrap` wraps them and the base64'd installer into one stdin stream →
`run_host` pipes it to `ssh` and writes `.fleet-logs/<ts>-<mode>/<host>.{log,status}`,
`PARALLEL` at a time. It never decides policy: an omitted `fleet.conf` key is
**not sent at all**, so the host keeps its stored answer.

## Rules specific to this repository

- **`harden-gha-runners.sh` is self-contained.** It is copied onto machines on
  its own, so it must never source another file from this repository. Shared
  helpers between it and `fleet.sh` are duplicated on purpose.
- **`set -Eeuo pipefail` is on in both scripts.** A `[[ cond ]] && action` list
  whose condition can be false is fine on its own, but one whose *action* can
  fail needs `|| true`, or write it as an `if`.
- **Mind the heredoc quoting when editing generated code.** `<<EOF` expands
  installer-side variables into the artefact (this is how `${d}`, `${uid}` and
  `${USER_PREFIX}` are baked in); `<<'EOF'` ships the body verbatim. In an
  unquoted heredoc every runtime `$` must be escaped (`\$JIT`, `\$RUNNER_PID`).
  Getting this backwards produces a syntactically valid script that references
  an empty variable at job time. `phase_runners` runs `bash -n` on the wrapper
  it writes for exactly this reason — keep that check when you add generated
  scripts.
- **Every wizard question must also be answerable from the environment.**
  `fleet.sh` drives the installer over an SSH session with no pty, so anything
  that can only be answered interactively is unreachable to the fleet. When you
  add a prompt, add the matching `GHA_*` variable, a `fleet.conf` key, and a
  line in the README's variable table.
- **No secret may become a command-line argument**, anywhere. `/proc/<pid>/cmdline`
  is readable by every local user, including the unprivileged runner accounts
  the installer creates. Two consequences: the SSH bootstrap streams its
  environment file on stdin (`0600`, removed by an EXIT trap), and every `curl`
  call passes the admin token with `-H @file` rather than `-H "Authorization:
  Bearer ..."`. Do not "simplify" either one back. `curl -K -` is not a
  substitute: its unquoted value form drops a malformed header silently, which
  sends the request unauthenticated instead of failing.
- **Comment the surprising decision, not the obvious line**; do not add
  comments that restate code.
- **The stored configuration is a default, never an override.** `load_config`
  restores the caller's `GHA_*` answers over `/etc/github-runner/env`, and reads
  `/etc/github-runner/pat` only when no `GHA_PAT` was supplied. Do not replace
  it with a plain `. "$ENV_FILE"`: the install dispatch runs it inside an `&&`
  chain for its side effect, so a clobbering version makes every unattended run
  report success while changing nothing. It is also what lets
  `fleet.sh --no-pat install` work, so do not add a code path that requires the
  caller to hold the admin token for a machine that already has one.
- **`die` inside `$( )` only exits the subshell.** `build_bootstrap` assigns
  `build_env`'s output to a variable rather than inlining the substitution,
  because that is what propagates the failure under `errexit`; inlined, a bad
  host prints its error and the run installs anyway.
- **Every mode is idempotent.** A second consecutive run that changes something
  is a bug, not a feature.
- **The disk guard runs before the registration is minted, and deletes as the
  runner user.** Before `gha-jitconfig` is the one point a runner is guaranteed
  idle: swap the two `ExecStartPre` lines and it can delete a toolchain from
  under a job it was just handed. Every path it clears is job-writable, so a job
  can plant a symlink there; `as_runner` drops to the runner user (`setpriv`)
  for every deletion, which caps what a planted link can reach at what the job
  could delete itself. Do not "simplify" a deletion back to root. With
  `trust=untrusted` it resets the runner in full before every job — that
  reset, not the wrapper's post-job wipe, is what keeps one fork PR's state
  from the next, because the wrapper sits in a tree the job can write.
- **`restart_backoff_delay`, `cycle_ran_a_job` and `runner_labels` are spliced
  into the generated JIT helpers with `declare -f`.** Edit them in the
  installer, and keep them self-contained: the helpers carry those functions and
  nothing else of the installer, so a call to another installer function or
  global would parse fine and fail at runner start.
- **systemd-oomd is not part of the design.** `gha.slice` carries no
  `ManagedOOM*` policy (the slice's own comment says why); its `MemoryMax`
  confines the kernel's OOM killer to CI, and `OOMPolicy=continue` makes that
  kill a failed step. Heavy jobs are kept apart by routing (`runner_labels`)
  and sized by `CODEQL_RAM` (`codeql_ram_budget`), not by killing them sooner.
- **`TMPDIR=/var/tmp` in the unit is deliberate** (the unit template says
  why: Ubuntu 26.04's `/tmp` is a small tmpfs every runner shares). Do not
  point `TMPDIR` back at `/tmp`, and do not drop `PrivateTmp=`, which is what
  makes `/var/tmp` private.
- **Anything that changes system state is untestable here.** It has to be
  exercised on a disposable Ubuntu VM — say so rather than claiming a change is
  verified when only `make test` has run.

## Keeping the cross-file lists in sync

These sets are duplicated by design (the installer cannot import from the
repository) and drift silently:

- **A new mode** goes in five places: the installer's `main()` `case`, the
  `die "unknown mode ..."` list beside it, the installer's header USAGE block,
  `VALID_MODES` in `fleet.sh`, and the README. Note that the installer's
  `--help` prints a *hardcoded line range* (`sed -n '2,30p'`) — adding a line
  to the header block pushes `uninstall` out of the window, so adjust the
  range in the same edit.
- **A new `fleet.conf` key** goes in `KNOWN_KEYS` (an unknown key is a hard
  parse error, not a warning), the `cfg` reads in `build_env`, the export it
  emits, `fleet.conf.example`, and the README.
- **A new `GHA_*` answer** goes in `CONFIG_ANSWERS`, the `save_config` heredoc,
  the wizard, and the README's variable table.
- **Anything the installer puts in a runner's `$HOME`** goes in the disk
  guard's `KEEP` list too, or the first reset under disk pressure deletes it.

## Tests

`test/bootstrap_test.sh` sources both scripts and exercises their real
functions; the `it_*` cases show which. The bootstrap cases run the real
bootstrap through a real `bash -s`, as `sshd` would, against a stand-in
installer; the disk-guard cases render `gha-diskguard` from `render_diskguard`
and drive it against a scratch runner tree. Only the SSH hop and the root-only
`as_runner` drop are substituted. The spliced functions are also checked inside
the rendered JIT helpers.

- Hand-rolled BDD, `# given / # when / # then`, no mocking library.
- Each case is an `it_*` function **defined and then invoked on the very next
  line**; the final `PASS`/`FAIL` tally picks new ones up. There is no runner
  and no filter: to run one case, source the file's setup and call the
  function, or just run the whole suite (~3s).
- `load_config_probe` runs in a subshell with `set +e` but **`nounset` still
  on**, deliberately: the guards it tests exist to survive `-u`.

## Anonymity

This repository is public and describes infrastructure. Do not add host names,
IP addresses, organisation names, fleet sizes, or anything else that identifies
a specific deployment. Examples use `your-org`, `example`, and RFC 5737 / RFC
1918 addresses.

## Documentation

Every change adds a `chlog` fragment under `.changes/unreleased/`, made with
`chlog new --kind <Kind> --body '<past-tense description>'` (kinds are listed
in `.chlog.yaml`; keep the body single-quoted); never edit `CHANGELOG.md` by
hand. Update `README.md` whenever a flag, a `GHA_*` variable, a `fleet.conf` key or a
requirement changes.
