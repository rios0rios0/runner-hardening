<h1 align="center">runner-hardening</h1>
<p align="center">
    <a href="https://github.com/rios0rios0/runner-hardening/releases/latest">
        <img src="https://img.shields.io/github/release/rios0rios0/runner-hardening.svg?style=for-the-badge&logo=github" alt="Latest Release"/></a>
    <a href="https://github.com/rios0rios0/runner-hardening/blob/main/LICENSE">
        <img src="https://img.shields.io/github/license/rios0rios0/runner-hardening.svg?style=for-the-badge&logo=github" alt="License"/></a>
    <a href="https://github.com/rios0rios0/runner-hardening/actions/workflows/claude-review.yaml">
        <img src="https://img.shields.io/github/actions/workflow/status/rios0rios0/runner-hardening/claude-review.yaml?branch=main&style=for-the-badge&logo=github" alt="Build Status"/></a>
</p>

Turns a raw Ubuntu box into a hardened, ephemeral, rootless GitHub Actions
self-hosted runner host — and drives the same setup across a whole fleet over
SSH from a single command.

## Why

A self-hosted runner installed the documented way runs every job as one
long-lived user that is usually in the `docker` group, which is
[root-equivalent](https://docs.docker.com/engine/security/#docker-daemon-attack-surface).
Workspaces, caches and container images survive between jobs, so anything one
job leaves behind is available to the next one. This project replaces that
arrangement:

| Default install                              | After this installer                                                   |
|----------------------------------------------|------------------------------------------------------------------------|
| one shared runner user, often in `docker`    | one dedicated unprivileged user per runner — no sudo, no docker group  |
| root-owned `/var/run/docker.sock`            | rootless Docker per user, no root socket anywhere on the box           |
| long-lived registration, reused workspace    | ephemeral JIT runners: one job per registration, fresh `_work` each time |
| the registration token sits on disk for jobs | the admin PAT is root-only and is never readable by a job              |
| no resource ceiling                          | per-runner memory and CPU policy derived from the machine's capacity   |
| unattended reboots kill running jobs         | reboots only in a window, and only when every runner is idle           |

## Features

- **Rootless Docker per runner** — `container:` jobs and `docker build` both keep working, with no root-owned socket for a job to reach.
- **Ephemeral JIT registration** — a single-use runner config is minted by a root-only helper at every start, so no credential and no workspace survives a job.
- **Hardened systemd units** — dedicated user, read-only filesystem outside `ReadWritePaths`, no capabilities, no new privileges, private `/tmp`, and job temp files (`TMPDIR`) in a private `/var/tmp` on disk, not the RAM-backed `/tmp` every runner on the box would otherwise share.
- **Capacity-aware resource policy** — a lone job may use the whole machine, while an aggregate slice ceiling stops the fleet from exhausting the host and keeps any OOM kill inside CI.
- **Heavy jobs kept apart** — the first runner on each box also carries a `heavy` label for jobs the size of a CodeQL analysis, and every job sees a `CODEQL_RAM` sized from the box, so two analyses never pile onto one machine.
- **Self-maintaining** — before every job a disk guard frees space from that runner's own caches once the disk passes 75%, starting with whatever no job has read in a week; a daily janitor trims Docker images, reaps leaked registrations, and warns before the admin PAT expires; a reboot guard applies pending kernel updates only when no runner is busy.
- **Fleet driver** — `fleet.sh` runs any mode on every machine in `fleet.conf` over SSH, in parallel, with per-host logs and a pass/fail summary.
- **Diagnostics that name the cause** — `diagnose`, `verify` and a leave-one-out `sandbox-probe` that identifies the exact systemd directive breaking a build.

## Quick start

One machine, interactively:

```bash
git clone https://github.com/rios0rios0/runner-hardening.git
cd runner-hardening
sudo ./harden-gha-runners.sh
```

The wizard asks only what it cannot infer, validates every answer against the
GitHub API before touching anything, and prints a plan you have to confirm.

The whole fleet, from your workstation:

```bash
cp fleet.conf.example fleet.conf   # edit: hosts, org, labels
./fleet.sh install
```

## Requirements

**On each runner host**

- Ubuntu on `x86_64` (tested on 22.04, 24.04 and 26.04)
- kernel 5.11+ and cgroup v2 — both needed for rootless overlayfs
- root access
- a GitHub PAT that can administer runners: a classic PAT with `admin:org` (or
  `repo` for a single repository), or a fine-grained PAT with
  **Self-hosted runners: Read and write**

Everything else — `curl`, `jq`, `unzip`, Docker CE and the rootless extras,
`uidmap`, `fuse-overlayfs`, `slirp4netns` — is installed by the script.

**On your workstation, for `fleet.sh`**

- `bash`, `ssh` and `base64`
- key-based SSH to every host, and either root or passwordless sudo there

> **If your agent holds many keys**, `sshd`'s `MaxAuthTries` (6 by default) can
> be exhausted before the right one is offered, and every host fails with
> `Too many authentication failures` — even when the key is installed. Pin the
> identity per host, or in `[defaults]`:
>
> ```ini
> ssh_key     = ~/.ssh/id_ed25519
> ssh_options = -o IdentitiesOnly=yes
> ```
>
> `ssh_key` already becomes `-i`, so do not add a second one in `ssh_options`.
> If the private key exists only inside an agent, point `ssh_key` at the
> **public** half instead — `ssh` matches it against the agent and asks the
> agent to sign.
>
> A machine with no key yet cannot be reached this way at all: install one
> first (`ssh-copy-id`), because `fleet.sh` runs with `BatchMode=yes` and will
> never prompt for a password.

## Usage

### `harden-gha-runners.sh` — one machine

```bash
sudo ./harden-gha-runners.sh                # interactive install
sudo ./harden-gha-runners.sh audit          # report only, changes nothing
sudo ./harden-gha-runners.sh verify         # post-flight checks
sudo ./harden-gha-runners.sh diagnose       # why won't a runner stay up
sudo ./harden-gha-runners.sh reap           # delete leaked offline registrations
sudo ./harden-gha-runners.sh retune         # reapply CPU/memory policy only
sudo ./harden-gha-runners.sh sandbox-probe  # which systemd directive breaks a job?
sudo ./harden-gha-runners.sh sandbox-relax  # clear the seccomp filter
sudo ./harden-gha-runners.sh sandbox-off    # strip the sandbox (diagnostic)
sudo ./harden-gha-runners.sh updates        # unattended security upgrades + safe reboots
sudo ./harden-gha-runners.sh rotate-pat     # replace the admin PAT safely
sudo ./harden-gha-runners.sh reconfigure    # redo the wizard, reinstall
sudo ./harden-gha-runners.sh uninstall      # remove everything this created
```

Every mode is idempotent: re-running converges the box to the desired state
instead of rebuilding it.

Re-installing a box that is already serving jobs **drains it first**: each
runner is allowed to finish the job it is on, and only then is it stopped, so a
re-install costs you no builds. Runners that are idle stop immediately. The
wait is bounded by `GHA_DRAIN_TIMEOUT` (default 30 minutes); past that the
remaining jobs are cut off and the install proceeds. If the install fails at
any point after the drain, the runners are put back automatically.

Unattended, when you already know the answers:

```bash
GHA_SCOPE=org GHA_ORG=your-org GHA_GROUP_ID=1 GHA_TRUST=internal \
GHA_LABELS='self-hosted,linux,x64,internal' GHA_COUNT=auto GHA_OLD_USER=none \
GHA_YES=1 GHA_PAT='<pat>' sudo -E ./harden-gha-runners.sh
```

| Variable                 | Meaning                                                                   |
|--------------------------|---------------------------------------------------------------------------|
| `GHA_SCOPE`              | `org` or `repo`                                                           |
| `GHA_ORG`                | organisation login, or the owner when `GHA_SCOPE=repo`                    |
| `GHA_REPO`               | repository name, required only when `GHA_SCOPE=repo`                      |
| `GHA_PAT`                | admin PAT, stored `0600 root:root` and never readable by a job            |
| `GHA_GROUP_ID`           | runner group id; `1` is *Default*                                         |
| `GHA_LABELS`             | comma-separated runner labels                                             |
| `GHA_TRUST`              | `internal` keeps caches warm between jobs; `untrusted` resets the runner's home, tool cache, Docker and workspace before every job |
| `GHA_COUNT`              | runner count, or `auto` to size it from the box's own CPU and RAM         |
| `GHA_OLD_USER`           | the over-privileged account to dismantle, or `none`                       |
| `GHA_HEAVY_RUNNERS`      | how many runners, from runner 1, also carry the label `heavy`; `0` for none (default `1`) — see [Memory](#memory) |
| `GHA_CODEQL_RAM`         | the `CODEQL_RAM`, in MB, every job sees: `auto` (default) sizes it from the box, `off` leaves CodeQL to size itself |
| `GHA_YES`                | answer every confirmation with yes                                        |
| `GHA_FORCE_DEPRIVILEGE`  | de-privilege an account the installer protects — read the warning first   |
| `GHA_DRAIN_TIMEOUT`      | seconds to let running jobs finish before a re-install stops the runners (default `1800`) |

### `fleet.sh` — every machine at once

```bash
./fleet.sh install                    # the full setup on every host
./fleet.sh verify                     # post-flight checks, changes nothing
./fleet.sh --limit build-01 diagnose  # one host
./fleet.sh --dry-run install          # validate the config, connect to nothing
./fleet.sh -p 10 updates              # ten at a time
./fleet.sh rotate-pat                 # replace the admin PAT fleet-wide
./fleet.sh --no-pat install           # re-deploy; each host reuses its own PAT
./fleet.sh reconfigure                # identical to install when driven here
```

`install` applies what `fleet.conf` says: edit `labels` or `runners`, re-run,
and the hosts converge on the new values. `reconfigure` does the same thing
over the fleet — the two differ only for someone running the installer by hand
on a box, where `reconfigure` re-asks every question from scratch. A key
`fleet.conf` omits is **not** sent at all, so each host keeps the answer it
already has stored — which is also what lets `--no-pat` work, the machine
authenticating with the PAT it holds. On a host with nothing stored yet, an
omitted key falls through to the installer's own default, which it reports as
it goes. Three answers have no safe default and must be given: `org`, the PAT,
and `old_user` when a box has more than one over-privileged account. `org` is
the one key an already-registered host cannot fall back to — it is the fleet's
identity, and a run that does not name it stops before contacting anything.

Any mode the installer accepts is accepted here and fanned out unchanged.
Each host gets its own log under `.fleet-logs/<timestamp>-<mode>/`, and the
run exits non-zero if any host failed.

The fleet is described in `fleet.conf` (copy `fleet.conf.example`). A
`[defaults]` section is inherited by every `[host]` section:

```ini
[defaults]
user     = root
ssh_key  = ~/.ssh/id_ed25519
scope    = org
org      = your-org
group_id = 1
trust    = internal
labels   = self-hosted,linux,x64,internal
runners  = auto
heavy_runners = 1
old_user = none

[build-01]
host = 10.0.0.11

[build-02]
host    = 10.0.0.12
runners = 2

[public-01]
host     = 10.0.0.21
trust    = untrusted
labels   = self-hosted,linux,x64,untrusted
group_id = 4
```

No secret belongs in `fleet.conf` — and `fleet.conf` is gitignored, because it
names your hosts. The admin PAT is prompted for once, or read from
`--pat-file`, and is sent over the SSH connection's stdin along with the
installer. On a **re-deploy** of hosts that are already registered, pass
`--no-pat` instead: each host reuses the credential it already stores at
`/etc/github-runner/pat`, so no copy of the admin token is needed on the
machine driving the fleet. Nothing secret is ever an argument to `ssh`, `sudo`
or the installer, so no credential appears in any process list on either side.

## Using the runners in a workflow

```yaml
jobs:
  build:
    runs-on: [self-hosted, linux, x64, internal]
    container:
      image: node:22-bookworm
      options: --user 1000:1000 --cap-drop ALL --security-opt no-new-privileges
    steps:
      - uses: actions/checkout@v4
      - run: npm ci && npm test
```

Send the heaviest job — a CodeQL analysis — to the `heavy` runners, so a box
never runs more of them at once than it has heavy runners:

```yaml
jobs:
  codeql:
    runs-on: [self-hosted, linux, x64, internal, heavy]
```

`runs-on` is a hard selector: a job asking for `heavy` waits until a runner
carrying it is free, and forever if none exists. When the analysis comes from a
reusable workflow, that workflow has to let you give its CodeQL job a `runs-on`
of its own.

## Operating the fleet

Both timers are installed and enabled by the installer:

| Timer               | Schedule       | What it does                                                                                        |
|---------------------|----------------|------------------------------------------------------------------------------------------------------|
| `gha-janitor.timer` | daily          | trims Docker images at 75% disk and fully prunes them at 90%, reaps orphan registrations, checks the admin PAT |
| `gha-reboot.timer`  | 02:00–05:00    | applies a pending reboot **only** when no runner on the host is executing a job                     |

```bash
journalctl -fu 'gha-runner@*'      # watch the runners
systemctl status 'gha-runner@*'
sudo /usr/local/sbin/gha-janitor   # run the janitor now
./fleet.sh verify                  # check the whole fleet
```

### Restarts

A runner registers again 10 seconds after its job ends. One whose starts keep
failing — the listener exits without ever running a job — backs off instead:
10 seconds, then 20, 40, 80, 160, and at most 5 minutes between attempts, so a
broken box does not spend the fleet's shared API budget minting and deleting
registrations. The first cycle that runs a job resets it, and a stop you asked
for (a drain, a reboot, `rotate-pat`) never counts. `verify` fails once three
starts in a row have run no job, and `diagnose` shows the count.

systemd's own `RestartSteps` backoff is deliberately not used: it counts every
restart, and an ephemeral runner restarts after every job, so it made healthy
runners wait the full 5 minutes before each one.

### Memory

Each runner may use most of the machine on its own, and `gha.slice` caps what
all of them use together, so the operating system always keeps a working set.
What the cap cannot do is choose which jobs share it. A CodeQL analysis sizes
itself from the whole machine rather than from its runner, and on a mid-sized
codebase it fills its runner's memory ceiling and swaps on top: two of them on
one box overrun the slice, swap fills, and the kernel kills one. Two settings
keep them apart:

- **`heavy_runners`** (default `1`): runners 1 to N also register with the label
  `heavy`. Send CodeQL there (see [the workflow example](#using-the-runners-in-a-workflow))
  and no more than N analyses ever share a box; the next one queues. Every other
  job still runs on every runner, the heavy ones included.
- **`codeql_ram`** (default `auto`): every job sees `CODEQL_RAM`, which
  `codeql-action` prefers to its own whole-machine estimate. `auto` gives what a
  heavy job can take while each other runner keeps 1 GB, split between the
  heavy runners and never above a runner's own ceiling. With no heavy runner it
  is each runner's fair share. A number of MB is taken as given; `off` lets
  CodeQL size itself again.

When the kernel does kill a job's process, only that process dies: the step
fails as killed (exit code 137) and the job ends as a failure. systemd's
default would instead stop the whole runner, which the job logs as "The runner
has received a shutdown signal" — or, when the killed process sits below the
step, such as a compiler or an extractor, reports as cancelled. Nothing in the
unit's state records the kill afterwards, so `verify` reads it from the kernel
log and warns on any in the last 24 hours:

```bash
journalctl -k -g oom-kill               # which process, in which runner
sudo ./harden-gha-runners.sh verify     # warns on any OOM kill in the last day
```

### Disk

With `trust = internal` a runner keeps its caches from one job to the next on
purpose, and every runner keeps its own private copy: its home directory (each
package manager's cache, and the SDKs some `setup-*` actions unpack there), its
hosted tool cache, and its rootless Docker store. With heavy toolchains —
CodeQL bundles, mobile SDKs, browser images — that reaches tens of gigabytes
per runner, so size the disk for the runner count, not for one runner.

What keeps it bounded is `gha-diskguard`, which each runner runs before every
job: the one moment it is guaranteed idle, because it has not registered yet
and cannot be handed a job. Below 75% disk it does nothing. At or above, it
frees space from that runner's own caches, cheapest loss first, and stops as
soon as the disk is back under 75%:

1. a workspace left behind by a job that was killed before its cleanup ran
2. tool versions and caches no job has read in 7 days
3. the runner's Docker images, volumes and build cache
4. the runner's whole hosted tool cache
5. everything in its home the installer did not put there

With `trust = untrusted` there is no cache worth keeping, only state a fork PR
could leave for the next job — a `~/.gitconfig` hook, a Docker CLI plugin, a
poisoned build cache. So there the guard clears all of the above before every
job, whatever the disk says.

Either way a reset keeps only what the rootless daemon needs: its user unit,
the link that enables it, and its data root, which is emptied through Docker
rather than deleted under a running daemon. Every deletion runs as the runner's
own user, never as root, so a symlink a job plants in its home cannot make the
guard delete anything the job could not. `verify` warns past 75% and fails past
90%.

```bash
journalctl -t gha-diskguard               # what the guard freed, and when
sudo ./harden-gha-runners.sh diagnose     # each runner's cache sizes
```

## Limits of this hardening

- **Fork pull requests on self-hosted runners are a losing position regardless
  of hardening.** Set *Require approval for all external contributors* under
  **Settings → Actions → General**, or keep public repositories on
  GitHub-hosted runners. `trust = untrusted` reduces the blast radius; it does
  not eliminate it. Its reset covers the runner's home, tool cache, Docker and
  workspace, but not the runner's own install tree, which its user has to be
  able to write, nor a process a job starts through that user's own service
  manager — either can outlive the job that planted it.
- **A box that has already run a hostile job cannot be cleaned by a script.**
  The `audit` mode reports the usual persistence surfaces, but a job that held
  root could have hidden from all of them. Reimage, then run this installer.
- On Ubuntu 24.04 the installer relaxes
  `kernel.apparmor_restrict_unprivileged_userns`, which rootlesskit requires.
  That is a real, small reduction in 24.04's default posture, made
  deliberately and documented in the script at the point where it happens.

## Contributing

Contributions are welcome. See [CONTRIBUTING.md](CONTRIBUTING.md) for
guidelines.

## License

See [LICENSE](LICENSE) file for details.
