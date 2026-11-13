<h1 align="center">runner-hardening</h1>
<p align="center">
    <a href="https://github.com/rios0rios0/runner-hardening/releases/latest">
        <img src="https://img.shields.io/github/release/rios0rios0/runner-hardening.svg?style=for-the-badge&logo=github" alt="Latest Release"/></a>
    <a href="https://github.com/rios0rios0/runner-hardening/blob/main/LICENSE">
        <img src="https://img.shields.io/github/license/rios0rios0/runner-hardening.svg?style=for-the-badge&logo=github" alt="License"/></a>
    <a href="https://github.com/rios0rios0/runner-hardening/actions/workflows/checks.yaml">
        <img src="https://img.shields.io/github/actions/workflow/status/rios0rios0/runner-hardening/checks.yaml?branch=main&style=for-the-badge&logo=github" alt="Build Status"/></a>
</p>

Turns a raw Ubuntu box into a hardened, ephemeral, rootless host for
self-hosted CI — GitHub Actions runners or Azure Pipelines agents — and
converges a whole fleet of them from one Ansible inventory.

It is an Ansible collection, `rios0rios0.runner_hardening`: a vendor-neutral
role, `runner_host`, that hardens the box, and one role per CI service,
`runner_github` and `runner_azure_devops`, that puts its runners on it.

## Why

A self-hosted runner installed the documented way runs every job as one
long-lived user that is usually in the `docker` group, which is
[root-equivalent](https://docs.docker.com/engine/security/#docker-daemon-attack-surface).
Workspaces, caches and container images survive between jobs, so anything one
job leaves behind is available to the next one. An Azure Pipelines agent set up
by its own instructions is the same arrangement. This project replaces it:

| Default install                              | After this collection                                                  |
|----------------------------------------------|------------------------------------------------------------------------|
| one shared runner user, often in `docker`    | one dedicated unprivileged user per runner — no sudo, no docker group  |
| root-owned `/var/run/docker.sock`            | rootless Docker per user, no root socket anywhere on the box           |
| one long-lived process, reused workspace     | one job per runner process, then a fresh start; a GitHub runner also gets a single-use registration and an empty `_work` every time |
| the registration token sits on disk for jobs | the GitHub admin PAT is root-only and never readable by a job; no Azure DevOps PAT is stored on the box at all (an agent keeps its own credential: see [Limits](#limits-of-this-hardening)) |
| no resource ceiling                          | per-runner memory and CPU policy derived from the machine's capacity   |
| unattended reboots kill running jobs         | reboots only in a window, and only when every runner is idle           |

## Features

- **Rootless Docker per runner** — `container:` jobs and `docker build` both keep working, with no root-owned socket for a job to reach.
- **One job per runner, then a fresh start** — a GitHub runner gets a single-use JIT registration, minted by a root-only helper at every start and handed to the runner in its environment, never on a command line, so no credential and no workspace survives a job; an Azure Pipelines agent runs with `--once`.
- **Hardened systemd units** — dedicated user, read-only filesystem outside `ReadWritePaths`, no capabilities, no new privileges, private `/tmp`, and job temp files (`TMPDIR`) in a private `/var/tmp` on disk, not the RAM-backed `/tmp` every runner on the box would otherwise share.
- **Capacity-aware resource policy** — a lone job may use the whole machine, while an aggregate slice ceiling stops the runners together from exhausting the host and keeps any OOM kill inside CI.
- **Heavy jobs kept apart** — the first runner on each box also takes jobs the size of a CodeQL analysis (GitHub label `heavy`, Azure Pipelines capability `heavy`), and every job sees a `CODEQL_RAM` sized from the box, so two analyses never pile onto one machine.
- **Self-maintaining** — before every job a disk guard frees space from that runner's own caches once the disk passes 75%, starting with whatever no job has read in a week; a daily janitor trims Docker images (and on GitHub hosts reaps leaked registrations and warns before the admin PAT expires); a reboot guard applies pending kernel updates only when no runner is busy.
- **Declarative and idempotent** — the inventory is the whole configuration. A converge brings every host to it, a second one changes nothing (the converge workflow fails a pull request otherwise), and a configuration change never kills a running job.
- **Diagnostics that name the cause** — `verify`, `diagnose`, and a leave-one-out `sandbox-probe` that identifies the exact systemd directive breaking a build.

## Requirements

**On the controller**, the machine you run `ansible-playbook` on

- `ansible-core` `2.16` or later, installed with `pip` or `pipx`
- key-based SSH to every host, as root or as an account with sudo
- `community.general`, only to read secrets with its 1Password lookup (see [Secrets](#secrets))

> **If your agent holds many keys**, `sshd`'s `MaxAuthTries` (6 by default) can
> be exhausted before the right one is offered, and every host fails with
> `Too many authentication failures` — even when the key is installed. Pin the
> identity per host, or for every host in `group_vars/runner_hosts.yaml`:
>
> ```yaml
> ansible_ssh_private_key_file: '~/.ssh/id_ed25519'
> ansible_ssh_common_args: '-o IdentitiesOnly=yes'
> ```
>
> The key file already reaches `ssh` as its identity, so do not add a second
> one in `ansible_ssh_common_args`. If the private key exists only inside an
> agent, point `ansible_ssh_private_key_file` at the **public** half instead —
> `ssh` matches it against the agent and asks the agent to sign.
>
> A machine with no key yet cannot be reached this way at all: install one
> first (`ssh-copy-id`). Ansible turns SSH password authentication off unless
> you pass `--ask-pass`.

**On each runner host**

- Ubuntu on `x86_64`: the roles are exercised on `24.04` (the converge workflow, on every pull request) and `26.04` (a live fleet converged from the shell installer); the shell installer before them was also tested on `22.04`
- kernel `5.11` or later and cgroup v2 — both needed for rootless overlayfs
- Python 3, which every Ubuntu release ships
- a machine that does nothing but CI: the roles refuse to run until `runner_host_dedicated: true` says so
- outbound HTTPS to the CI service and to Docker's apt repository

Everything else — `curl`, `jq`, `unzip`, `make`, `python3` with `venv` support,
Docker CE and the rootless extras, `uidmap`, `fuse-overlayfs`, `slirp4netns` —
is installed by the roles.

**Credentials**

- **GitHub:** a PAT that can administer runners: a classic PAT with `admin:org`
  (or `repo` for a single repository), or a fine-grained PAT with
  **Self-hosted runners: Read and write**. Each host stores it root-only, so the
  controller needs it only for a first install or a replacement.
- **Azure DevOps:** a PAT with the **Agent Pools (Read & manage)** scope, only to
  register a new agent or to remove one. It is never stored on a host.

## Installation

### As a collection

```bash
ansible-galaxy collection install 'git+https://github.com/rios0rios0/runner-hardening.git,<tag>'
```

Or pin it in your project's `requirements.yaml`, and install it with
`ansible-galaxy collection install -r requirements.yaml`:

```yaml
collections:
  - name: 'https://github.com/rios0rios0/runner-hardening.git'
    type: 'git'
    version: '<tag>'   # a release tag; tags carry no `v` prefix
```

The playbooks then run by their fully qualified names:

```bash
ansible-playbook -i inventory/ rios0rios0.runner_hardening.github
```

A project that consumes the collection keeps its own `ansible.cfg`: turn on
pipelining in it (see [Secrets](#secrets)).

### From a checkout

```bash
git clone https://github.com/rios0rios0/runner-hardening.git
cd runner-hardening
make collection
```

`make collection` links `build/collections/ansible_collections/rios0rios0/runner_hardening`
to the checkout, so the playbooks and roles resolve each other by the same fully
qualified names a consumer uses. The repository's `ansible.cfg` points
`collections_path` at that link, reads the inventory from `inventory/local/`
(which `.gitignore` keeps out of git), and turns on pipelining.

## Quick start

### GitHub Actions

```bash
cp -r inventory/example inventory/local   # then edit it: hosts, organisation, labels
read -rs RUNNER_GITHUB_PAT && export RUNNER_GITHUB_PAT
ansible-playbook playbooks/github.yaml --limit build-01 --check --diff   # what it would do, changing nothing
ansible-playbook playbooks/github.yaml --limit build-01                  # one host first
ansible-playbook playbooks/github.yaml                                   # then the rest
ansible-playbook playbooks/verify.yaml
```

The example inventory reads the admin PAT from `RUNNER_GITHUB_PAT`. The converge
checks it against the GitHub API before it changes anything, then stores it
root-only on each host, so a later re-deploy can leave the variable unset.

### Azure Pipelines

```bash
cp -r inventory/example inventory/local   # then edit it: hosts, organisation URL, pool
read -rs RUNNER_AZP_PAT && export RUNNER_AZP_PAT   # only to register new agents
ansible-playbook playbooks/azure_devops.yaml --limit agent-01
ansible-playbook playbooks/azure_devops.yaml
ansible-playbook playbooks/verify.yaml
```

A host whose agents are already registered needs no PAT at all: name them in
`runner_azp_adopt` (see [Adopting registered agents](#adopting-registered-agents)).

## Configuration

Everything is an Ansible variable, set in the inventory: for a group in
`group_vars/`, for one host in `host_vars/`. [`inventory/example/`](inventory/example)
shows each one in place.

### The host (`runner_host`)

| Variable                          | Default                      | Meaning |
|-----------------------------------|------------------------------|---------|
| `runner_host_dedicated`           | `false`                      | must be `true`. A converge dismantles rootful Docker, de-privileges accounts and deletes leftover build state, so every destructive step refuses to run on a box nobody has declared dedicated to CI |
| `runner_count`                    | `auto`                       | runner count, or `auto` to size it from the box: one runner per vCPU or per 2 GB of RAM above a 1.5 GB reserve, whichever gives fewer. Lowering it retires the runners above the new count completely |
| `runner_trust`                    | `internal`                   | `internal` keeps caches warm between jobs; `untrusted` resets the runner's home, tool cache, Docker and workspace before every job — see [Disk](#disk) |
| `runner_heavy_runners`            | `1`                          | how many runners, from runner 1, also take heavy jobs; `0` for none — see [Memory](#memory) |
| `runner_codeql_ram`               | `auto`                       | the `CODEQL_RAM`, in MB, every job sees: `auto` sizes it from the box, `off` leaves CodeQL to size itself |
| `runner_slice_ceiling`            | `none`                       | which runners may grow to the whole slice budget instead of the usual per-runner ceiling: `none`, `heavy` or `all` — see [Memory](#memory) |
| `runner_old_users`                | `[]`                         | over-privileged accounts to de-privilege, named explicitly: the converge reports the candidates it finds and touches only the accounts listed here. Each is removed from `sudo`, `docker`, `lxd` and the other root-equivalent groups, locked, its processes killed, and its caches cleared as that account, never as root; its home is left for you to delete. A listed account that is protected is left alone, and the summary names it beside the accounts it did de-privilege |
| `runner_force_deprivilege`        | `false`                      | de-privilege an account the role protects — uid 1000, a `NOPASSWD` sudoer, an `authorized_keys` owner, an active session. Read the warning first |
| `runner_drain_timeout`            | `1800`                       | seconds a drain lets running jobs finish before it stops their runners anyway |
| `runner_extra_packages`           | `[]`                         | apt packages your jobs need on top of the base list |
| `runner_extra_apt_repositories`   | `[]`                         | where apt finds them: a list of `{name, key_url, repo}`. `key_url` is an `https` URL serving an ASCII-armored key, which lands in `/etc/apt/keyrings/<name>.asc`; `repo` is the whole source line, written to `/etc/apt/sources.list.d/<name>.list` as given, and its `signed-by` must name `/etc/apt/keyrings/<name>.asc` |
| `runner_extra_binaries`           | `[]`                         | CLIs no apt source ships, each checked against its SHA-256 and installed root-owned, one copy for every runner — see [Extra binaries](#extra-binaries) |
| `runner_disk_soft_pct`            | `75`                         | disk use at which the disk guard starts freeing a runner's caches before its next job, the janitor trims Docker, and `verify` warns |
| `runner_disk_hard_pct`            | `90`                         | disk use at which the janitor prunes Docker in full and `verify` fails |
| `runner_stale_days`               | `7`                          | a cache entry no job has read for this many days is the first to go |
| `runner_home_keep_extra`          | `[]`                         | more `$HOME`-relative paths a home reset must keep. With `runner_trust: untrusted` they survive every reset, so whatever one job leaves there reaches the next; the converge warns |
| `runner_home_seed`                | `{}`                         | `{relative_path: source}`: a file or directory on the host, copied once into every runner home, owner fixed, mode kept. A home reset keeps each one too, so with `runner_trust: untrusted` the converge warns, and `.local/bin`, first on every agent's `PATH`, must never be seeded there |
| `runner_dismantle_rootful_docker` | `true`                       | disable the rootful Docker and containerd daemons and delete their image store, once |
| `runner_unattended_upgrades`      | `true`                       | security-only unattended upgrades, with automatic reboots off; `false` leaves whatever the box already has configured alone |
| `runner_reboot_guard`             | `true`                       | a timer that applies a pending reboot between 02:00 and 05:00, and only when no runner is busy; `false` removes the timer and its script |
| `runner_start_units`              | `true`                       | `false` installs and enables the units without starting them |
| `runner_mem_mb`                   | `{{ ansible_facts['memtotal_mb'] }}` | the RAM, in MB, the resource policy is computed from |
| `runner_vcpus`                    | `{{ ansible_facts['processor_vcpus'] }}` | the vCPUs `runner_count: auto` sizes from |

#### Extra binaries

`runner_extra_binaries` installs the CLIs your jobs call that no apt source
ships. Installed by hand into a runner's `~/.local/bin`, such a tool sits where
one job could swap it for the next; here each is root-owned and shared by every
runner, and its download is checked against the pinned SHA-256 before anything
is installed. An entry takes one of three forms:

```yaml
runner_extra_binaries:
  # The download is the binary: /usr/local/bin/<name>.
  - name: 'tool'
    url: 'https://downloads.example.com/tool-linux-amd64'
    sha256: '<sha256 of the download>'
  # One file of a .tar.gz or .zip: /usr/local/bin/<name>.
  - name: 'other-tool'
    url: 'https://downloads.example.com/other-tool-linux-amd64.tar.gz'
    sha256: '<sha256 of the archive>'
    member: 'bin/other-tool'
  # A directory of the archive, kept whole in
  # /usr/local/lib/runner-hardening/tools/<name>/, with one /usr/local/bin
  # symlink per `links` entry: {command: its path inside that directory}.
  - name: 'aws'
    url: 'https://downloads.example.com/awscli-exe-linux-x86_64.zip'
    sha256: '<sha256 of the archive>'
    member: 'aws/dist'
    links:
      aws: 'aws'
      aws_completer: 'aws_completer'
```

An installed file is compared by checksum on every converge; a tool tree is
replaced only when its pinned `sha256` changes.

### GitHub Actions (`runner_github`)

| Variable                     | Default     | Meaning |
|------------------------------|-------------|---------|
| `runner_github_scope`        | `org`       | `org` or `repo` |
| `runner_github_org`          | (required)  | organisation login, or the owner when the scope is `repo` |
| `runner_github_repo`         | (none)      | repository name, required only when the scope is `repo` |
| `runner_github_group_id`     | `1`         | runner group id; `1` is *Default* |
| `runner_github_labels`       | `self-hosted,linux,x64,internal` | runner labels, comma-separated with no spaces; runners 1 to `runner_heavy_runners` also get `heavy` |
| `runner_github_version`      | `latest`    | the `actions/runner` release to install, or a pinned one such as `2.338.2`. A runner's tree is replaced only when the release it holds differs |
| `runner_github_pat`          | (undefined) | the admin PAT. Given, it is checked and written `0600 root:root` to `/etc/github-runner/pat`, replacing the stored one; undefined or empty, each host reuses the PAT it stores — see [Secrets](#secrets) |
| `runner_github_validate_pat` | `true`      | check the PAT against the GitHub API before anything changes |
| `runner_github_new_pat`      | (undefined) | the replacement admin PAT, read only by `playbooks/rotate_github_pat.yaml` |

### Azure Pipelines (`runner_azure_devops`)

| Variable                       | Default                         | Meaning |
|--------------------------------|---------------------------------|---------|
| `runner_azp_url`               | (required)                      | the organisation, as `https://dev.azure.com/<org>` |
| `runner_azp_pool`              | (required)                      | the agent pool |
| `runner_azp_agent_name`        | `{{ ansible_facts['hostname'] }}-{{ n }}` | a new agent's name, templated with its instance number `n`; an adopted agent keeps the name it was registered with |
| `runner_azp_pat`               | (none)                          | a PAT with Agent Pools (Read & manage), only to register a new agent or remove one; never stored. Undefined or empty means none |
| `runner_azp_version`           | `latest`                        | the agent release fresh installs download. `latest` asks GitHub's releases API and checks the package against the SHA-256 in that release's notes; a pinned one such as `4.264.2` asks nothing (that API allows 60 unauthenticated calls an hour per address), builds the documented download URL, and is checked by unpacking it. Installed and adopted agents update themselves from the pool |
| `runner_azp_adopt`             | `{}`                            | `{n: '/path/to/agent'}`: an already-registered agent to adopt as instance `n`. Keys are read as integers, so `1:` and `'1':` both work; naming one instance both ways is refused |
| `runner_azp_adopt_keep_work`   | `false`                         | keep an adopted agent's `_work`, which the over-privileged account it ran as wrote |
| `runner_azp_adopt_home`        | (none)                          | the home of the account the adopted agents ran as. An adopted agent's `.env` values that point into it are dropped, and `runner_home_seed` can name what each new agent user starts with from it |
| `runner_azp_skip_registration` | `false`                         | leave instances that have nothing to adopt and no PAT unregistered, instead of failing |

### Converging on a throwaway VM

The converge workflow (`.github/workflows/converge.yaml`) runs both playbooks on
a disposable GitHub-hosted VM, twice, and fails unless the second run changes
nothing. Three variables exist for it, and a runner host should never need
them:

| Variable                       | Default | The workflow sets | Why |
|--------------------------------|---------|-------------------|-----|
| `runner_start_units`           | `true`  | `false`           | install and enable the units without starting them: no credential there is real |
| `runner_github_validate_pat`   | `true`  | `false`           | skip the API check of a dummy PAT |
| `runner_azp_skip_registration` | `false` | `true`            | leave instances unregistered without failing |

`runner_dismantle_rootful_docker` stays `true` there, because the VM is thrown
away afterwards. The workflow also runs two runners, a heavy one and a regular
one, and turns `runner_reboot_guard` off: every runner there is idle, so
between 02:00 and 05:00 the guard would reboot the VM under the job.

### What each flavour installs

The GitHub values are the shell installer's own, on purpose: a fleet it set up
converges without a single user, home, unit or cache being renamed.

|                           | GitHub Actions                       | Azure Pipelines                          |
|---------------------------|--------------------------------------|------------------------------------------|
| runner users              | `gha1` … `ghaN`                      | `azp1` … `azpN`                          |
| instance trees            | `/opt/actions-runner/<n>`            | `/opt/azure-pipelines-agent/<n>`         |
| units                     | `gha-runner@<n>.service`             | `azp-agent@<n>.service`                  |
| aggregate slice           | `gha.slice`                          | `azp.slice`                              |
| root-only helpers         | `/usr/local/sbin/gha-*`              | `/usr/local/sbin/azp-*`                  |
| configuration             | `/etc/github-runner`                 | `/etc/azure-pipelines-agent`             |
| one job per               | single-use JIT registration          | agent process (`run.sh --once`)          |
| workspace between jobs    | wiped (work policy `wipe`)           | kept, evicted under disk pressure (`lru`) |
| heavy jobs                | label `heavy`                        | capability `heavy`                       |
| legacy units it replaces  | `actions.runner.*`                   | `vsts.agent.*`                           |

## Secrets

Never put a token in the inventory in clear text, and never pass one as
`-e name=value`: a command line is readable through `/proc/<pid>/cmdline` by
every account on the machine for as long as the play runs. (A vars file given as
`-e @file` puts only its path there.) Give the variable a lookup instead, which
reads the value when the play needs it:

```yaml
# group_vars/github_runners.yaml
runner_github_pat: "{{ lookup('ansible.builtin.env', 'RUNNER_GITHUB_PAT', default=undef()) }}"
```

```bash
read -rs RUNNER_GITHUB_PAT && export RUNNER_GITHUB_PAT   # typed, never echoed, never in argv
ansible-playbook playbooks/github.yaml
unset RUNNER_GITHUB_PAT
```

An environment variable, unlike an argument, is readable only by your own
account and root. Left unset, the lookup leaves `runner_github_pat` undefined —
not empty — and each host reuses the PAT it already stores at
`/etc/github-runner/pat`. That is all a re-deploy of registered hosts needs, so
the controller holds no copy of the admin token at all. A host with nothing
stored stops before it changes anything and says what to supply.
`runner_azp_pat` works the same way, from `RUNNER_AZP_PAT`, and so does
`runner_github_new_pat`, the replacement token only
`playbooks/rotate_github_pat.yaml` reads, from `RUNNER_GITHUB_NEW_PAT`.

Two other sources work as well:

- **1Password**, through `community.general.onepassword`. That collection
  becomes a requirement of the controller — this one depends on nothing beyond
  `ansible.builtin` — together with a signed-in `op` CLI:

  ```yaml
  runner_github_pat: "{{ lookup('community.general.onepassword', 'your-item', field='credential', vault='your-vault') }}"
  ```

- **Ansible Vault**: `ansible-vault encrypt_string --stdin-name runner_github_pat`
  reads the token from stdin, never from an argument, and prints a block to
  paste in place of the lookup. Run the playbooks with `--ask-vault-pass`.

On its way to a host, a token travels only inside a `no_log` task: as the
stdin of an `install … /dev/stdin` that writes its root-only file — so no
temporary copy of it lands in `~/.ansible/tmp`, as one would through `copy` —
or as the header of an API call. The GitHub PAT goes to a staging file that is
then renamed over the stored one, so a runner starting meanwhile never reads
half a token. A token is never a command argument, and never an `environment:`
value, which Ansible renders onto the remote command line. Keep **pipelining**
on, so that a module and its arguments reach the target over the SSH session's
stdin rather than through a temporary file there:

```ini
# ansible.cfg, in the project that runs the playbooks
[ssh_connection]
pipelining = True
```

This repository's `ansible.cfg` turns it on. A project that consumes the
collection from git keeps its own `ansible.cfg` and has to turn it on there.
Pipelining needs a sudo that does not insist on a TTY (no `requiretty`), which
is how Ubuntu ships it.

## Playbooks

| Playbook                           | Hosts                 | What it does |
|------------------------------------|-----------------------|--------------|
| `playbooks/github.yaml`            | `github_runners`      | converges the whole GitHub Actions setup |
| `playbooks/azure_devops.yaml`      | `azure_devops_agents` | converges the whole Azure Pipelines setup |
| `playbooks/verify.yaml`            | `runner_hosts`        | post-flight checks; changes nothing, and fails each host whose checks fail |
| `playbooks/diagnose.yaml`          | `runner_hosts`        | why a runner will not stay up: unit state, job-less starts, disk and cache sizes, the journal, the runner's own `_diag` log |
| `playbooks/drain.yaml`             | `runner_hosts`        | lets each runner finish the job it is on, then keeps it stopped |
| `playbooks/rotate_github_pat.yaml` | `github_runners`      | checks `runner_github_new_pat` against the API on each host, for the scope stored there, then swaps it in atomically |
| `playbooks/uninstall.yaml`         | `runner_hosts`        | drains, then removes every runner, user, home, unit and helper the roles created |

```bash
ansible-playbook playbooks/github.yaml                    # converge every GitHub runner host
ansible-playbook playbooks/github.yaml --limit build-01   # one host
ansible-playbook playbooks/github.yaml --check --diff     # what a converge would change, changing nothing
ansible-playbook playbooks/verify.yaml                    # check the whole fleet
ansible-playbook playbooks/diagnose.yaml --limit build-01
ansible-playbook playbooks/drain.yaml --limit build-01 -e '{"runner_drain_instances": [2, 3]}'
ansible-playbook playbooks/uninstall.yaml --limit build-01 -e runner_uninstall_confirm=true
```

`--check --diff` completes on any host, one with no runner users yet included,
and changes nothing. Its diff leaves out the files the roles write into a tree
a job can write: computing it would have root read a file a job may have
replaced with a link to anything root can read.

Both vendor playbooks converge one host at a time and stop at the first one
that fails, so the rest of the fleet keeps taking jobs while a host drains for
a new release or adopts its agents. `serial` is read before any host is chosen,
so the inventory cannot raise it: pass `-e runner_serial=3`, which carries no
secret.

The vendor-neutral playbooks read the flavour from the host itself, so they
need a host its vendor playbook has converged: they stop on a box with no
`gha-admin` or `azp-admin`.

`drain.yaml` takes every runner on the host, or only the ones
`runner_drain_instances` lists. They stay stopped until the next converge, or
until `sudo gha-admin undrain [n…]` on the host puts them back.

`uninstall.yaml` runs only with `-e runner_uninstall_confirm=true`. It drains
first, then removes the runners with their users, homes and tool caches, the
units and timers, `/etc/runner-hardening`, `/usr/local/lib/runner-hardening`,
`/usr/local/libexec/runner-hardening`, the flavour's helpers in
`/usr/local/sbin` and the extra binaries. It leaves three things in place, and
says so: the vendor configuration directory (on a GitHub host,
`/etc/github-runner`, which holds the admin PAT), `/var/lib/runner-hardening`
with the sudoers drop-ins de-privileging moved aside (the rootless-unit
snapshots in it go), and `/swapfile`. It does not remove Azure Pipelines agents
from their pool: delete them there.

A rotation restarts no runner: `gha-jitconfig` reads the stored PAT at every
start, and every runner starts again after each job, so the new token is in use
from each runner's next job. Once every host reports it, revoke the old token
in GitHub.

Every playbook is idempotent: a converge brings each host to what the inventory
says, and a second one changes nothing. Edit `runner_github_labels` or
`runner_count`, re-run, and the hosts follow. Lowering the count retires the
runners above the new count completely (unit, user, home and tool cache), so
they neither return at the next boot nor keep their disk.

A configuration change never kills a job. An ephemeral runner restarts after
every job anyway, so an idle one is restarted on the new definition at once,
and a busy one picks it up when its job ends. Two changes cannot wait for that,
so they drain the runners they touch first — each finishes the job it is on,
bounded by `runner_drain_timeout` — and put them back if anything fails:

- a lower `MemoryMax` or `MemoryLow` for a runner, because systemd applies
  cgroup limits to a running unit the moment it reloads, under the job;
- a new runner release, which replaces the runner's tree: the new one is
  staged beside it and renamed into place.

## Using the runners

### GitHub Actions

```yaml
jobs:
  build:
    runs-on: ['self-hosted', 'linux', 'x64', 'internal']
    container:
      image: 'node:22-bookworm'
      options: '--user 1000:1000 --cap-drop ALL --security-opt no-new-privileges'
    steps:
      - uses: 'actions/checkout@v7'
      - run: 'npm ci && npm test'
```

Send the heaviest job — a CodeQL analysis — to the `heavy` runners, so a box
never runs more of them at once than it has heavy runners:

```yaml
jobs:
  codeql:
    runs-on: ['self-hosted', 'linux', 'x64', 'internal', 'heavy']
```

`runs-on` is a hard selector: a job asking for `heavy` waits until a runner
carrying it is free, and forever if none exists. When the analysis comes from a
reusable workflow, that workflow has to let you give its CodeQL job a `runs-on`
of its own.

### Azure Pipelines

```yaml
pool:
  name: 'your-pool'

jobs:
  - job: 'build'
    steps:
      - script: 'make test'

  - job: 'codeql'
    pool:
      name: 'your-pool'
      demands: 'heavy'
```

A demand is as hard a selector as `runs-on`: the job waits until an agent with
the capability is free. See [Heavy jobs](#heavy-jobs) for where the capability
comes from.

## Operating the fleet

Names here are the GitHub flavour's. On an Azure DevOps host read `azp-` for
`gha-`, `azp-agent@` for `gha-runner@` and `azp.slice` for `gha.slice` (see
[What each flavour installs](#what-each-flavour-installs)).

Both timers are installed and enabled by the converge:

| Timer               | Schedule       | What it does |
|---------------------|----------------|--------------|
| `gha-janitor.timer` | daily          | trims Docker images once the filesystem holding the runners' homes passes `runner_disk_soft_pct`, and prunes them in full past `runner_disk_hard_pct`; on a GitHub host it also reaps orphan registrations and checks when the admin PAT expires, pointing at `playbooks/rotate_github_pat.yaml` when it must be replaced |
| `gha-reboot.timer`  | 02:00–05:00    | applies a pending reboot **only** when no runner on the host is executing a job (`runner_reboot_guard`) |

The reboot guard asks the box, not the CI service. A runner is busy while a
job's worker process runs inside its unit's own cgroup; a process of the same
user anywhere else does not count. The guard looks twice, two seconds apart, so
a job handed out an instant earlier is not missed. It needs no PAT, and works
the same on both flavours, as the drain and `restart-idle`, which use the same
test, do.

```bash
journalctl -fu 'gha-runner@*'           # watch the runners
systemctl status 'gha-runner@*'
journalctl -t gha-reboot-if-idle        # what the reboot guard decided, and when
sudo gha-janitor                        # run the janitor now
ansible-playbook playbooks/verify.yaml  # check the whole fleet
```

Each host also carries `gha-admin`, the on-box half of the playbooks. It asks
before anything drastic when it has a terminal; `--yes`, before the mode,
answers every question:

| `sudo gha-admin …` | What it does |
|--------------------|--------------|
| `verify`           | post-flight checks; exits non-zero on any failure |
| `diagnose`         | everything needed to work out why a runner will not stay up |
| `audit`            | reports the persistence surfaces a root-capable job could have used; changes nothing |
| `reap`             | deletes this host's leaked offline registrations (GitHub) |
| `sandbox-probe`    | which systemd directive breaks a job? |
| `sandbox-relax`    | clears the seccomp filter |
| `sandbox-off`      | strips the sandbox, to diagnose |
| `drain [n…]`       | lets runners finish their jobs, bounded by `runner_drain_timeout`, then keeps them stopped; every instance when no number is given |
| `undrain [n…]`     | puts drained runners back; every drained one when no number is given |
| `restart-idle`     | restarts every runner that is not running a job |
| `busy <n>`         | exits 0 while a job's worker runs in runner `n`'s unit |
| `instances`        | prints the instance numbers that exist |

The next converge puts the sandbox back: it removes the drop-ins
`sandbox-relax` and `sandbox-off` write.

`reap` and `verify` recognise this host's registrations by name, exactly or by
the `<host>-` prefix its runners are named with, and leave alone any minted in
the last 5 minutes: a runner that has just registered is not a leak.

### Restarts

A runner is back one second after its job ends. Every job ends in a restart, so
that delay sits between every two jobs a runner takes; at 10 seconds it was most
of the gap, spent idle while queued jobs waited. One whose starts keep failing —
the listener exits without ever running a job — backs off instead: 10 seconds,
then 20, 40, 80, 160, and at most 5 minutes between attempts, so a broken box
does not spend the fleet's shared API budget minting and deleting
registrations. The first cycle that runs a job resets it, and a stop somebody
asked for (a drain, a reboot, the restart a converge makes) never counts.
`verify` fails once three
starts in a row have run no job, and `diagnose` shows the count.

Whether a cycle ran a job is read from the `_diag/Worker_*.log` the runner
writes for each one, never from the exit status, which the runner sets to 0 even
on a terminated error. An Azure Pipelines agent writes the same log, and
`azp-cycle` applies the same backoff around it.

systemd's own `RestartSteps` backoff is deliberately not used: it counts every
restart, and an ephemeral runner restarts after every job, so it made healthy
runners wait the full 5 minutes before each one.

### Memory

Each runner may use most of the machine on its own, and `gha.slice` caps what
all of them use together, so the operating system always keeps a working set.
What the cap cannot do is choose which jobs share it. A CodeQL analysis sizes
itself from the whole machine rather than from its runner, and on a mid-sized
codebase it fills its runner's memory ceiling and swaps on top: two of them on
one box overrun the slice, swap fills, and the kernel kills one. Three variables
keep them apart:

- **`runner_heavy_runners`** (default `1`): runners 1 to N also take heavy jobs —
  on GitHub they register with the label `heavy`, on Azure Pipelines they carry
  the capability `heavy`. Send CodeQL there (see [Using the runners](#using-the-runners))
  and no more than N analyses ever share a box; the next one queues. Every other
  job still runs on every runner, the heavy ones included.
- **`runner_codeql_ram`** (default `auto`): every job sees `CODEQL_RAM`, which
  GitHub's `codeql-action` prefers to its own whole-machine estimate. `auto`
  gives what a heavy job can take while each other runner keeps 1 GB, split
  between the heavy runners and never above a runner's own ceiling. With no
  heavy runner it is each runner's fair share. A number of MB is taken as given;
  `off` lets CodeQL size itself again.
- **`runner_slice_ceiling`** (default `none`): each runner's memory ceiling is
  85% of what is left once the OS and the rootless daemons are reserved, so a
  lone job gets most of the box and a runner beside it keeps something. A job
  that needs more than that to run at all — one compile of a very large package
  — is killed at that ceiling with the slice's last gigabytes unused. `heavy`
  lifts the heavy runners to the whole slice budget, so such a job routed there
  gets the box while the other runners keep their guaranteed share; `all` lifts
  every runner. (A box with one runner gains little: its ceiling is already its
  fair share, everything but the reserve.) The slice still caps all runners
  together, so the cost falls on whatever shares the box: a job beside a lifted
  runner can be reclaimed or OOM-killed sooner.

Like every variable, they take effect at the next converge: idle runners pick
the new policy up at once, busy ones after their job. A converge that lowers a
runner's `MemoryMax` or `MemoryLow` drains that runner first, because systemd
applies a unit's new cgroup limits the moment it reloads, under whatever job
the runner is running.

When the kernel does kill a job's process, only that process dies: the step
fails as killed (exit code 137) and the job ends as a failure. systemd's
default would instead stop the whole runner, which the job logs as "The runner
has received a shutdown signal" — or, when the killed process sits below the
step, such as a compiler or an extractor, reports as cancelled. Nothing in the
unit's state records the kill afterwards, so `verify` reads it from the kernel
log and warns on any in the last 24 hours:

```bash
journalctl -k -g oom-kill                              # which process, in which runner
ansible-playbook playbooks/verify.yaml --limit build-01 # warns on any OOM kill in the last day
```

### Disk

With `runner_trust: internal` a runner keeps its caches from one job to the next
on purpose, and every runner keeps its own private copy: its home directory
(each package manager's cache, and the SDKs some `setup-*` actions unpack
there), its hosted tool cache, and its rootless Docker store. With heavy
toolchains — CodeQL bundles, mobile SDKs, browser images — that reaches tens of
gigabytes per runner, so size the disk for the runner count, not for one runner.

What keeps it bounded is `gha-diskguard`, which each runner runs before every
job: the one moment it is guaranteed idle, because its runner process has not
started yet, so no job can reach it. Below `runner_disk_soft_pct` (75%) it does
nothing. At or above, it frees space from that runner's own caches, cheapest
loss first, and stops as soon as the disk is back under the threshold:

1. a workspace left behind by a job that was killed before its cleanup ran
2. tool versions and caches no job has read in `runner_stale_days` (7) days
3. the runner's Docker images, volumes and build cache
4. the runner's whole hosted tool cache
5. everything in its home the roles did not put there

An Azure Pipelines agent keeps its workspace on purpose (see
[The workspace stays between jobs](#the-workspace-stays-between-jobs)), so
there the guard treats `_work` as one more cache.

With `runner_trust: untrusted` there is no cache worth keeping, only state a
fork PR could leave for the next job — a `~/.gitconfig` hook, a Docker CLI
plugin, a poisoned build cache. So there the guard clears all of the above,
`_work` included, before every job, whatever the disk says. It fails safe: the
guard reads the trust level from `/etc/runner-hardening/host.env`, and anything
there but exactly `internal` — the key missing, misspelt or empty — gets the
full reset.

Either way a reset keeps only what the rootless daemon needs — its user unit,
the link that enables it, and its data root, which is emptied through Docker
rather than deleted under a running daemon — plus whatever
`runner_home_keep_extra` and `runner_home_seed` name. Under `untrusted` those
paths survive every reset, so the converge warns when either is set there.
The daemon's user unit survives too, and a job can rewrite it, so on its first
run the guard keeps a root-owned copy of each runner's,
`/var/lib/runner-hardening/rootless/<user>.docker.service`; before every
untrusted job it puts that copy back and restarts the runner's Docker daemon,
which costs about one to three seconds a job. Every deletion runs as the
runner's own user, never as root, so a symlink a job plants in its home cannot
make the guard delete anything the job could not, and root never reads a file
under a runner's home or tree through a link.
`verify` warns past `runner_disk_soft_pct` and fails past
`runner_disk_hard_pct`, on the disks that hold these caches and on the one that
holds the jobs' temp files (`/var/tmp`). A separate `/var` has no cache for the
guard to free, and its warning says so.

```bash
journalctl -t gha-diskguard                               # what the guard freed, and when
ansible-playbook playbooks/diagnose.yaml --limit build-01 # each runner's cache sizes
```

## Azure DevOps specifics

### Adopting registered agents

A host that already runs agents set up by hand needs no PAT: name each agent's
directory in `runner_azp_adopt`, keyed by the instance it becomes.

```yaml
# host_vars/agent-02.yaml
runner_azp_adopt:
  1: '/home/agent/myagent'
runner_count: 1
```

The converge first stops and removes the agent's old `vsts.agent.*` unit, once
any job it is running has finished (bounded by `runner_drain_timeout`), and
leaves the directory in place. It then moves that directory to
`/opt/azure-pipelines-agent/1` — a rename, so the directory has to be on the
same filesystem as `/opt` — removes its `_work` (unless
`runner_azp_adopt_keep_work`) and its `.service`, and hands it to `azp1`. It
rewrites `.path` to the new user's own `~/.local/bin` followed by the standard
system `PATH`, and drops from `.env` every value that points into
`runner_azp_adopt_home`, so nothing of the old account stays on the agent's
path. `.agent`, `.credentials` and `.credentials_rsaparams` are kept byte for
byte, so the pool sees the same agent, with the same name and id. An adopted
agent keeps its own binaries and updates itself from the pool, as it did before.

Two things must hold for an adoption: the agent's `.agent` names a relative
`workFolder` (the default `_work`), so the work directory moves with it; and
`runner_count` is a number that covers every key of `runner_azp_adopt`, not
`auto`, while any adoption is pending. The converge refuses to move a
directory that is an account's home, one that holds an `.ssh`, or one every
account can write. Once it has adopted an agent, it records the agent's pool
and agent ids root-side, in `/var/lib/runner-hardening/azp/<n>.json`, for a
later removal to go by.

To carry over what the old account installed for its jobs, name it in
`runner_azp_adopt_home` and the paths in `runner_home_seed`, which copies them
once into every agent's home. When that account is also in `runner_old_users`,
the one-time wipe clears its caches first, so only what it installed comes
across:

```yaml
runner_azp_adopt_home: '/home/agent'
runner_home_seed:
  '.local/bin': "{{ runner_azp_adopt_home }}/.local/bin"
```

With `runner_trust: untrusted`, seed nothing into `.local/bin`: a seeded path
survives every home reset, and `~/.local/bin` is first on every agent's
`PATH`, so whatever one job put there would run in the next.

### Registering new agents

An instance with no agent to adopt is registered fresh, which needs
`runner_azp_pat`. The PAT never becomes an argument, is never stored, and never
reaches code a job can write. The role writes it, through stdin, to a
root-only `/run/azp-register.pat`, and `azp-register` reads it into
`VSTS_AGENT_INPUT_TOKEN` — the variable the agent's `config.sh` takes its
token from — and runs `config.sh --unattended --auth pat --replace` with the
URL, pool and agent name, never `--token`. It runs it as root
(`AGENT_ALLOW_RUNASROOT=1`), in a pristine, root-owned unpack of the verified
package rather than in the instance's own tree, which a job can rewrite. Only
then is the new tree handed to `azp<n>` and swapped into place, so a
registration replaces the instance's whole tree, its `_work` aside. The agent's
pool and agent ids are recorded root-side, in
`/var/lib/runner-hardening/azp/<n>.json`, and the PAT file is removed whether
the registration succeeds or not. With neither an agent to adopt nor a PAT, the
converge stops and says which of the two to supply.

`--replace` takes over an agent of the same name already in the pool, so keep
`runner_azp_agent_name` unique across hosts, as the default, which carries the
host name, is.

Fresh installs download the release `runner_azp_version` names, the latest by
default. Lowering `runner_count` removes the instances above it from the box.
Given a PAT, it also deletes their registrations from the pool, through the
REST API, by the pool and agent ids recorded at registration or adoption. An
agent registered before that record existed is left in the pool, with a
warning saying so, as is every agent when no PAT is given: delete those in the
pool yourself.

### One job per agent process

`azp-agent@<n>` runs the agent as `run.sh --once`: it takes one job, exits, and
systemd starts it again, with the same disk guard and the same backoff as a
GitHub runner. Unlike a GitHub runner's single-use registration, the
registration itself lasts: the agent comes back as the same agent after every
job.

### Heavy jobs

Azure Pipelines routes by capabilities rather than labels, and the agent
reports every variable in its environment as one. Runners 1 to
`runner_heavy_runners` start with `heavy=true` in theirs, so a pipeline sends a
job there with `demands: 'heavy'` (see [Using the runners](#using-the-runners)).

### The workspace stays between jobs

A GitHub runner wipes `_work` before and after every job (work policy `wipe`).
An Azure Pipelines agent keeps it, as agents are built to: each pipeline's build
directory under `_work/<n>` and the task cache under `_work/_tasks` stay warm
for the next job, and a pipeline that wants a clean one asks for it with
`workspace: clean: all`. The disk guard bounds it instead (work policy `lru`):
past `runner_disk_soft_pct` it evicts the build directories, task versions and
`_diag` logs nothing has read in `runner_stale_days`, and if that is not enough,
every build directory and then the task cache. With `runner_trust: untrusted`
the whole `_work` goes before every job.

## Migrating from `fleet.sh`

The shell implementation — `harden-gha-runners.sh` and `fleet.sh` — is gone
from this release; the `0.1.0` tag keeps it, which is what the
[rollback](#rollback) relies on. The roles converge a host the installer set up
without renaming anything: the GitHub flavour keeps the installer's users,
homes, tool caches, unit and slice names, and the exact format of
`/etc/github-runner/env` and `/etc/github-runner/pat`. What changes on the box:

- the per-job wrapper moves from `/opt/actions-runner/<n>/run-ephemeral.sh`,
  inside the tree its job can write, to
  `/usr/local/libexec/runner-hardening/gha-run-ephemeral`, root-owned;
- `AGENT_TOOLSDIRECTORY` moves from the wrapper into the instance drop-in;
- the helpers become static files that read `/etc/runner-hardening/host.env`,
  and `gha-admin` takes over the installer's on-box modes.

**The inventory is now the whole configuration.** `fleet.sh` sent only the keys
`fleet.conf` named, and each host kept its stored answer for the rest. A
converge applies every variable, and one the inventory omits takes the role's
default. So before the first converge, copy each host's answers out of
`/etc/github-runner/env` — it holds no secret; the PAT is a separate file. One
omission the role refuses outright: a host stored as `untrusted` whose
inventory gives no `runner_trust` stops the converge, because the default,
`internal`, would stop it resetting itself between fork-PR jobs. Say which it
is.

| `fleet.conf`        | Inventory |
|---------------------|-----------|
| `[<name>]`          | a host under `github_runners` in `hosts.yaml` |
| `[defaults]`        | `group_vars/github_runners.yaml` and `group_vars/runner_hosts.yaml` |
| `host`              | `ansible_host` |
| `port`              | `ansible_port` |
| `user`              | `ansible_user` |
| `ssh_key`           | `ansible_ssh_private_key_file` |
| `ssh_options`       | `ansible_ssh_common_args` |
| `become`            | nothing: the playbooks always become root; a sudo that asks for a password takes `--ask-become-pass` |
| `enabled = false`   | leave the host out of its group, or skip it with `--limit '!<name>'` |
| `scope`             | `runner_github_scope` |
| `org`               | `runner_github_org` |
| `repo`              | `runner_github_repo` |
| `group_id`          | `runner_github_group_id` |
| `labels`            | `runner_github_labels` |
| `trust`             | `runner_trust` |
| `runners`           | `runner_count` |
| `heavy_runners`     | `runner_heavy_runners` |
| `codeql_ram`        | `runner_codeql_ram` |
| `slice_ceiling`     | `runner_slice_ceiling` |
| `old_user`          | `runner_old_users`, a list: `none` becomes `[]`. The installer de-privileged a lone account it detected by itself; the roles only report candidates, so list every account to de-privilege |
| `force_deprivilege` | `runner_force_deprivilege` |

| `fleet.sh`                                     | Now |
|------------------------------------------------|-----|
| `install`, `reconfigure`                       | `ansible-playbook playbooks/github.yaml` |
| `verify`, `diagnose`, `uninstall`              | `playbooks/verify.yaml`, `playbooks/diagnose.yaml`, `playbooks/uninstall.yaml` |
| `rotate-pat`                                   | `playbooks/rotate_github_pat.yaml` |
| `retune`, `updates`                            | a converge: the resource policy and the update settings are variables now |
| `audit`, `reap`, `sandbox-*`                   | `sudo gha-admin <mode>` on the host |
| `--limit build-01`                             | `--limit build-01` |
| `-p 10`                                        | `-e runner_serial=10` |
| `--dry-run`                                    | `ansible-inventory --graph`, which reads the inventory without connecting |
| the PAT prompt, `--pat-file`                   | `runner_github_pat` from a lookup (see [Secrets](#secrets)) |
| `--no-pat`                                     | leave `runner_github_pat` undefined |
| `.fleet-logs/`                                 | Ansible's `log_path`, or `ANSIBLE_LOG_PATH` |

Then move the fleet over in check mode first, one host at a time:

1. Write `inventory/local/` from `fleet.conf` and the stored answers, and check
   that it parses and every host sits in `github_runners`:
   `ansible-inventory --graph`.
2. Leave `RUNNER_GITHUB_PAT` unset, so each host keeps the PAT it stores, and
   see what the first converge would change on one host:
   `ansible-playbook playbooks/github.yaml --limit build-01 --check --diff`.
   A change to `/etc/github-runner/env` is an answer your inventory disagrees
   with: fix the inventory until only the expected changes remain — the wrapper
   moving, and the new files.
   Check mode is supported on such a host: on a box the shell installer set up,
   expect about thirty changes. Those are the new runtime files, the unit and its drop-ins, the trees'
   `0750` mode and release markers, the update settings, and the one-time wipe's
   marker. Expect no drain unless a runner's memory limit would drop.
3. Converge that host, run `ansible-playbook playbooks/verify.yaml --limit build-01`,
   and watch a job run on it. A busy runner finishes its job first and picks the
   new definition up on its own restart, so the move costs no builds.
4. Converge it again: it must report `changed=0`.
5. Then the rest: `ansible-playbook playbooks/github.yaml`, which takes one host
   at a time and stops at the first that fails.

### Rollback

The previous release stays a working way back, because the GitHub flavour
keeps `/etc/github-runner/env` and `/etc/github-runner/pat` in the installer's
format:

```bash
git checkout 0.1.0
./fleet.sh --no-pat install   # each host re-installs from its own stored answers and PAT
```

`fleet.conf` was never tracked by git, so it is still where you left it.
`0.1.0` predates `slice_ceiling`, and its `fleet.sh` rejects a key it does not
know: drop that key from `fleet.conf` first, and lifted ceilings fall back to
the usual one. The re-install rewrites the unit, the helpers and the runner
trees. What only the roles wrote — `/etc/runner-hardening/`,
`/usr/local/lib/runner-hardening/`, `/usr/local/libexec/runner-hardening/`,
`/usr/local/sbin/gha-admin`, `/var/lib/runner-hardening/` and any
`runner_extra_binaries` in `/usr/local/bin` — stays behind, unused, until you
remove it.

## Limits of this hardening

- **Fork pull requests on self-hosted runners are a losing position regardless
  of hardening.** On GitHub, set *Require approval for all external
  contributors* under **Settings → Actions → General**, or keep public
  repositories on GitHub-hosted runners. In Azure Pipelines, require a team
  member's comment before a pull request from a fork is built, and do not make
  secrets available to those builds. `runner_trust: untrusted` reduces the blast
  radius; it does not eliminate it. Its reset covers the runner's home, tool
  cache, Docker and workspace, but not the runner's own install tree, which its
  user has to be able to write, nor a process a job starts through that user's
  own service manager — either can outlive the job that planted it. The wrapper
  that runs each job is root-owned and outside the tree, so a job cannot edit
  it, but it runs as the job's user, so a job can kill it before its cleanup
  trap fires. What keeps one job's state from the next is the reset the
  root-owned `ExecStartPre` runs before every job, never the wrapper's cleanup
  after one.
- **An Azure Pipelines agent's credential is readable by its jobs.** The
  registration is long-lived, its key sits in `.credentials` and
  `.credentials_rsaparams` in the agent's own tree, and a job runs as the
  agent's user, so a hostile job — an untrusted pipeline's — can copy them and
  act as that agent in its pool until the agent is removed. A GitHub runner has
  no such key to steal: its registration is good for one job, and the admin PAT
  stays root-only.
- **A box that has already run a hostile job cannot be cleaned by a script.**
  `gha-admin audit` reports the usual persistence surfaces, but a job that held
  root could have hidden from all of them. Reimage, then converge.
- On Ubuntu `24.04` the roles relax
  `kernel.apparmor_restrict_unprivileged_userns`, which rootlesskit requires.
  That is a real, small reduction in `24.04`'s default posture, made
  deliberately and documented in the role at the point where it happens.

## Contributing

Contributions are welcome. See [CONTRIBUTING.md](CONTRIBUTING.md) for
guidelines.

## License

See [LICENSE](LICENSE) file for details.
