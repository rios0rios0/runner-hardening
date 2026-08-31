# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Two Bash scripts, no build step, no runtime dependencies beyond what a stock
Ubuntu image plus `ssh` provides.

| File                     | Role                                                                       |
|--------------------------|----------------------------------------------------------------------------|
| `harden-gha-runners.sh`  | The installer. Runs as root on one Ubuntu box and does all the work.       |
| `fleet.sh`               | Fans any installer mode out across the machines in `fleet.conf`, over SSH. |
| `fleet.conf.example`     | The documented fleet format. `fleet.conf` itself is gitignored.            |
| `test/bootstrap_test.sh` | Tests for the config reader and the remote bootstrap.                      |

## Commands

```bash
make setup   # clone/update the shared pipelines scripts the other targets use
make lint    # ShellCheck
make test    # parse check + the bootstrap suite (~2s, 81 cases, no VM needed)
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
function. `install` and `reconfigure` are the exception — they run a **fixed,
ordered pipeline** (`preflight` → `discover` → `wizard`/`load_config` →
`phase_audit` → `phase_stop_existing` → `phase_deprivilege` → `phase_wipe` →
`phase_prereqs` → per-runner user + rootless Docker → `maybe_add_swap` →
`phase_token_helper` → `phase_runners` → `phase_systemd` → `phase_janitor` →
`phase_unattended` → `phase_cleanup_stale` → `phase_verify` → `summary`). The
order encodes dependencies; do not reorder without tracing what each phase
assumes already exists.

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
| `/usr/local/sbin/gha-jitconfig`          | `phase_token_helper`  | root-only; mints one single-use JIT config per runner start   |
| `/usr/local/sbin/gha-jitreap`            | `phase_token_helper`  | root-only; deletes the registration when a runner stops       |
| `/opt/actions-runner/<n>/run-ephemeral.sh` | `phase_runners`     | runs exactly one job, then cleans up and exits                |
| `/etc/systemd/system/gha-runner@.service`| `phase_systemd`       | the hardened unit template                                    |
| `/etc/systemd/system/gha.slice`          | `write_resource_policy` | aggregate CPU/memory boundary for all runners                |
| `/usr/local/sbin/gha-janitor` + timer    | `phase_janitor`       | daily disk trim, orphan reap, PAT expiry check                |
| `/usr/local/sbin/gha-reboot-if-idle` + timer | `install_reboot_guard` | reboots only in-window and only when no runner is busy    |

### The ephemeral loop is the core invariant

```
systemd starts gha-runner@N
  → ExecStartPre=+/usr/local/sbin/gha-jitconfig N   (root; PAT never seen by the runner user)
      writes a single-use JIT config to /run/gha-runner/N.jit
  → ExecStart=run-ephemeral.sh                       (runner user; reads the .jit, wipes _work)
      ./run.sh --jitconfig "$JIT"   -- exits after ONE job
  → ExecStopPost=+/usr/local/sbin/gha-jitreap N      (root; removes the registration)
  → Restart=always  → back to the top with a fresh registration and a fresh workspace
```

Every security claim in the README rests on this chain. A change that lets
`run.sh` survive a second job, or that lets the wrapper `exec` (which discards
the EXIT trap and skips cleanup), silently turns these back into long-lived
runners. `StartLimitIntervalSec=0` is set deliberately — systemd's start limit
counts *attempts*, so a healthy runner finishing many quick jobs would trip it.

### Where state lives on a hardened box

| Path                        | Contents                                                          |
|-----------------------------|-------------------------------------------------------------------|
| `/etc/github-runner/env`    | the stored answers (`GHA_*`), sourced by `load_config`             |
| `/etc/github-runner/pat`    | the admin PAT, `0600 root:root`, never readable by a job           |
| `/opt/actions-runner/<n>`   | one extracted runner tree per instance, owned by `gha<n>`          |
| `/run/gha-runner/<n>.jit`   | the current single-use registration; tmpfs, gone on reboot         |
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
- **Comment the surprising decision, not the obvious line.** The existing
  comments explain why a systemd directive is deliberately *not* set, why
  `exec` is avoided in the runner wrapper, why pagination matters on the
  runners endpoint. Keep that standard; do not add comments restating code.
- **The stored configuration is a default, never an override.** `load_config`
  saves every caller-supplied `GHA_*` answer, sources
  `/etc/github-runner/env`, then puts the caller's values back — and only
  falls back to `/etc/github-runner/pat` when no `GHA_PAT` was supplied. Do not
  replace it with a plain `. "$ENV_FILE"`: the install dispatch runs this
  function inside an `&&` chain for its side effect, so a clobbering version
  makes every unattended run report success while changing nothing. This is
  also what lets `fleet.sh --no-pat install` work, so do not add a code path
  that requires the caller to hold the admin token for a machine that already
  has one.
- **`die` inside `$( )` only exits the subshell.** `build_bootstrap` assigns
  `build_env`'s output to a variable rather than inlining the substitution,
  because that is what propagates the failure under `errexit`. Inlining it
  again re-introduces a bug where a bad host printed its error and the run
  installed anyway.
- **Every mode is idempotent.** A second consecutive run that changes something
  is a bug, not a feature.
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

## Tests

`test/bootstrap_test.sh` sources both scripts and exercises their real
functions — `parse_config`, `build_env`, `build_bootstrap`, `load_config`,
`should_preload_config`, and `runner_state_between_jobs` (the pure core of the
`verify` health gate, which excuses a runner caught auto-restarting between jobs
instead of reporting it down). The bootstrap cases are not simulations: each runs the
real bootstrap through a real `bash -s`, exactly as `sshd` would on the far
side, against a stand-in installer that reports what it received. Only the SSH
hop is substituted.

- Hand-rolled BDD, `# given / # when / # then`, no mocking library.
- Each case is a function named `it_*`, **defined and then invoked on the very
  next line**. There is no runner and no filter — to run one case in isolation,
  source the file's setup and call the function, or just run the whole suite
  (~2s).
- `load_config_probe` runs in a subshell with `set +e` but **`nounset` still
  on**, deliberately: the guards it tests exist to survive `-u`.
- The file carries a file-wide `# shellcheck disable=SC2034` before its first
  command, because ShellCheck cannot follow the interpolated `source`.

Add a case by appending the `it_*` function plus its invocation; the final
`PASS`/`FAIL` tally at the bottom picks it up automatically.

## Anonymity

This repository is public and describes infrastructure. Do not add host names,
IP addresses, organisation names, fleet sizes, or anything else that identifies
a specific deployment. Examples use `your-org`, `example`, and RFC 5737 / RFC
1918 addresses.

## Documentation

Every change updates a `chlog` fragment under `.changes/unreleased/`; never
edit `CHANGELOG.md` by hand:

```bash
chlog new --kind Fixed --body "fixed the thing that was broken"
```

Kinds are `Added`, `Changed`, `Deprecated`, `Removed`, `Fixed`, `Security`.
Update `README.md` whenever a flag, a `GHA_*` variable, a `fleet.conf` key or a
requirement changes.
