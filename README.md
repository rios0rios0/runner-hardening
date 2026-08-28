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
- **Hardened systemd units** — dedicated user, read-only filesystem outside `ReadWritePaths`, no capabilities, no new privileges, private `/tmp`.
- **Capacity-aware resource policy** — a lone job may use the whole machine, while an aggregate slice ceiling stops the fleet from exhausting the host and keeps any OOM kill inside CI.
- **Self-maintaining** — a daily janitor trims image caches under disk pressure, reaps leaked registrations, and warns before the admin PAT expires; a reboot guard applies pending kernel updates only when no runner is busy.
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
> ssh_options = -o IdentitiesOnly=yes -i ~/.ssh/id_ed25519.pub
> ```
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
| `GHA_TRUST`              | `internal` keeps the layer cache warm; `untrusted` wipes state every job  |
| `GHA_COUNT`              | runner count, or `auto` to size it from the box's own CPU and RAM         |
| `GHA_OLD_USER`           | the over-privileged account to dismantle, or `none`                       |
| `GHA_YES`                | answer every confirmation with yes                                        |
| `GHA_FORCE_DEPRIVILEGE`  | de-privilege an account the installer protects — read the warning first   |

### `fleet.sh` — every machine at once

```bash
./fleet.sh install                    # the full setup on every host
./fleet.sh verify                     # post-flight checks, changes nothing
./fleet.sh --limit build-01 diagnose  # one host
./fleet.sh --dry-run install          # validate the config, connect to nothing
./fleet.sh -p 10 updates              # ten at a time
./fleet.sh rotate-pat                 # replace the admin PAT fleet-wide
./fleet.sh --no-pat install           # re-deploy; each host reuses its own PAT
```

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
trust    = internal
labels   = self-hosted,linux,x64,internal
runners  = auto

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
machine driving the fleet. Nothing secret is ever an argument to `ssh`, `sudo` or the
installer, so no credential appears in any process list on either side.

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

## Operating the fleet

Both timers are installed and enabled by the installer:

| Timer               | Schedule       | What it does                                                                                        |
|---------------------|----------------|------------------------------------------------------------------------------------------------------|
| `gha-janitor.timer` | daily          | trims caches at 75% disk and fully prunes at 90%, reaps orphan registrations, checks the admin PAT   |
| `gha-reboot.timer`  | 02:00–05:00    | applies a pending reboot **only** when no runner on the host is executing a job                     |

```bash
journalctl -fu 'gha-runner@*'      # watch the runners
systemctl status 'gha-runner@*'
sudo /usr/local/sbin/gha-janitor   # run the janitor now
./fleet.sh verify                  # check the whole fleet
```

## Limits of this hardening

- **Fork pull requests on self-hosted runners are a losing position regardless
  of hardening.** Set *Require approval for all external contributors* under
  **Settings → Actions → General**, or keep public repositories on
  GitHub-hosted runners. `trust = untrusted` reduces the blast radius; it does
  not eliminate it.
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
