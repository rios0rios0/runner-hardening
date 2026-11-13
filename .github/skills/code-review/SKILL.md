---
name: code-review
description: 'Review a pull request against rios0rios0/runner-hardening; reach for this skill whenever judging any change to the repository — the Ansible roles, their runtime scripts and templates, the playbooks, the example inventory, the tests and workflows, or the configuration and documentation files.'
---

# Code review — runner-hardening

## When to use this skill

Use it when reviewing any change to this repository: the roles under `roles/`
(tasks, templates, defaults, handlers, and the runtime scripts in `files/`),
the playbooks, `inventory/example`, `test/`, the workflows, or the
configuration and documentation files. It teaches how a change here is
*judged*; `.github/copilot-instructions.md` teaches how the code *works*. Read
that file first for context, then apply the checklist below.

## Source of truth and precedence

When guidance conflicts, earlier wins over later:

1. The code as it actually runs (Bash semantics under `set -Eeuo pipefail`,
   Ansible semantics on the supported `ansible-core` releases).
2. This skill's repo-specific checklist.
3. `.github/copilot-instructions.md` and `AGENTS.md`.
4. The shared [Development Guide](https://github.com/rios0rios0/guide/wiki) and
   its [Git-Flow](https://github.com/rios0rios0/guide/wiki/Git-Flow) commit
   conventions.

A claim in the docs that the code contradicts is a doc bug, not a code bug —
flag the drift, do not demand the code change to match stale prose.

## How to run the review

```bash
make test    # bash -n, the runtime suite, the Ansible test playbooks, syntax checks
make lint    # ShellCheck + ansible-lint (production) — needs `make setup` first
make sast    # CodeQL, Semgrep, Trivy, Hadolint, Gitleaks — needs `make setup`
```

`make test` needs only `bash` and `ansible-core`. `make lint` and `make sast`
read the shared configuration from a local checkout of `rios0rios0/pipelines`,
so they need `make setup` (or a `SCRIPTS_DIR=` override) first. Never invoke
`shellcheck`, `ansible-lint`, `semgrep` or `gitleaks` directly — the Makefile
targets load the shared config every repository standardises on. The converge
workflow is the only check that touches a real box, and it never starts or
registers a runner: do not approve a change to registration, the job loop or a
reboot path as "verified" on CI alone — say it needs a disposable VM.

## Repo-specific checklist

- **The ephemeral loop must stay intact.** `gha-runner@N` and `azp-agent@N` run
  exactly one job per start: the disk guard's `ExecStartPre` first, then the
  vendor's (`gha-jitconfig` mints a single-use JIT config as root, PAT unseen by
  the runner user; `azp-cycle pre` waits out the backoff and marks the start),
  then the root-owned wrapper in `/usr/local/libexec/runner-hardening` runs one
  job (`run.sh --jitconfig`, `run.sh --once`), `ExecStopPost` counts a job-less
  cycle (and on GitHub reaps the registration), `Restart=always` loops. Flag
  anything that lets `run.sh` survive a second job, that makes a wrapper
  `exec ./run.sh` — `exec` discards the EXIT trap and skips cleanup, silently
  restoring a long-lived runner — or that moves a wrapper back into the tree a
  job can write. The wrapper still runs as the job's user, so a job can kill it
  before its trap fires: flag any change that relies on the wrapper's cleanup to
  keep one job's state from the next. That is the root disk guard's reset.
- **Trust fails safe.** `runner_trusted` in `lib.sh` is true only for an exact
  `internal` in `host.env`. Flag a trust check that treats a missing, empty or
  unknown value as trusted.
- **The disk guard keeps its place and its privilege drop.** Its `ExecStartPre`
  must stay first, ahead of every vendor pre line: a runner not yet running
  cannot be handed a job, which is the only thing that makes deleting its
  caches safe. Every deletion goes through `as_runner` (`setpriv` to the runner
  user) because every path it clears is job-writable; flag a deletion moved to
  root. Anything a change puts in a runner's `$HOME` must join the keep list
  (`RUNNER_HOME_KEEP`), or the first reset under disk pressure deletes it.
- **`StartLimitIntervalSec=0` is deliberate.** systemd's start limit counts
  *attempts*; a healthy runner finishing many quick jobs would trip a nonzero
  limit. Do not flag it as a missing safeguard, and flag any change that removes
  it.
- **No `RestartSteps`/`RestartMaxDelaySec`, for the same reason.** They count
  every restart and every job ends in one, so they idled healthy runners for
  minutes after each job. The backoff lives in `lib.sh`
  (`restart_backoff_delay`, `cycle_ran_a_job`), keyed on cycles that ran no job;
  flag a change that brings systemd's back, that keys the backoff on the exit
  status (run-helper exits 0 even on a terminated error), or that lets the two
  flavours' backoffs diverge.
- **No secret may become a command-line argument.** `/proc/<pid>/cmdline` is
  world-readable. Flag a secret in `command`/`shell` arguments, in the
  `environment:` keyword (Ansible renders it onto the remote command line), or
  passed as `-e name=value` in a doc, a workflow or a test (a vars file given as
  `-e @file` puts only its path in argv); flag a secret-bearing task
  without `no_log: true`; flag a secret reaching a box any way other than
  `copy` `content:` into a root-only file or `uri` `headers:`. In scripts, flag
  any `-H "Authorization: Bearer ..."`, any token in argv, any
  `env VAR=secret cmd`, and any `curl -K -` substitute (its unquoted value form
  drops a malformed header silently and sends the request unauthenticated).
- **Scripts are static.** A runtime script reads paths, prefixes and thresholds
  from `/etc/runner-hardening/host.env` (or its vendor's env file) at runtime.
  Flag a script turned into a template, a value baked in at install time, or a
  script that would differ between two boxes.
- **The `.sh` suffix and the `main` guard.** A runtime script without `.sh` in
  the repository escapes ShellCheck silently; its install task must drop the
  suffix. Flag a removed `if [[ "${BASH_SOURCE[0]}" == "${0}" ]]` guard — the
  tests source the scripts through it.
- **The GitHub flavour's names are fixed.** Users `gha<n>`,
  `/opt/actions-runner`, `gha-runner@`, `gha.slice`, `/etc/github-runner` and
  the format of `/etc/github-runner/env` and `pat` are the shell installer's.
  Flag a rename, and a new key in `/etc/github-runner/env` the `0.1.0`
  installer could not source harmlessly: both break converging an existing
  fleet or rolling back to it.
- **The stored PAT is a fallback, never a requirement.** An undefined
  `runner_github_pat` must reuse `/etc/github-runner/pat`. Flag a code path that
  needs the controller to hold the admin token for a host that already stores
  one. Flag any Azure DevOps PAT written anywhere but the transient root-only
  registration file.
- **Idempotency.** A second converge must report `changed=0`. Flag a `command`
  or `shell` task without `changed_when`, any `changed_when: true`, a write that
  does not compare first, and a handler notified on every run.
- **`runner_host_dedicated` gates destruction.** Flag a task that dismantles
  Docker, de-privileges an account or deletes state without asserting it, and
  any change to its `false` default.
- **De-privileging is explicit.** Only the accounts `runner_old_users` names are
  touched; detected candidates are reported. Flag a change that acts on a
  detected account, or that weakens the protections (uid 1000, a `NOPASSWD`
  sudoer, an `authorized_keys` owner, an active session) without
  `runner_force_deprivilege`.
- **A configuration change never kills a job.** Flag a change that restarts busy
  runners, replaces a runner tree without a version change, or drains without a
  `rescue` that undrains.
- **`ansible.builtin` only.** Flag any module or lookup from another collection
  in the roles or playbooks (the example inventory may show `community.general`
  lookups, labelled as optional), a module called without its FQCN, an unnamed
  task, or a role variable without its role's prefix.
- **`set -Eeuo pipefail` correctness.** A `[[ cond ]] && action` whose action can
  fail needs `|| true` or an `if`. `exit` inside `$( )` only leaves the
  subshell. Watch for unset-variable hazards under `-u`.
- **Cross-file sync.** A new variable must land in its `defaults/main.yaml`, the
  README's variable table and `inventory/example`; a new runtime script needs
  its install task, a `test/runtime` case and its removal in
  `playbooks/uninstall.yaml`; a new `<sbin>-admin` mode needs the README table; a
  new playbook needs the README's playbook table. A partial addition is a latent
  bug.
- **Comments explain the surprising decision, not the obvious line.** Flag a new
  comment that restates code, and a why-comment ported from the installer that a
  change drops; do not flag the existing ones that explain why a systemd
  directive is deliberately unset.
- **Tests.** New behaviour in a runtime script should come with a
  `test/runtime` case; a change to the resource policy, with
  `test/ansible/policy.yaml` cases; a change to the unit template, with
  `test/ansible/templates.yaml` assertions. Do not ask for a test that would
  require a VM.

## Shared guide rules

A pull-request review does not have the author's global rules loaded, so restate
the ones this stack depends on:

- **Commits and PRs follow [Git-Flow](https://github.com/rios0rios0/guide/wiki/Git-Flow)**:
  Conventional-Commit subjects, simple past tense, branch off and target `main`.
- **Fail loudly.** Under `errexit` a silently swallowed error is worse than a
  crash; prefer an explicit failure with a cause over a bare `|| true` that hides
  a real failure. In a role, prefer `ansible.builtin.assert` with a `fail_msg`
  that says what to supply.
- **Every change carries a `chlog` fragment** under `.changes/unreleased/`
  (`kind` one of Added, Changed, Deprecated, Removed, Fixed, Security). Flag a
  behaviour change with no fragment, and flag a hand edit to the generated
  `CHANGELOG.md`.

## Security

- **Never write a PEM header sentinel or a realistic key shape into a fixture**
  (GitHub `ghp_` prefixes, OpenAI `sk-` prefixes, AWS `AKIA` prefixes, Slack `xoxb`
  prefixes, JWT-shaped strings, or the dashed `BEGIN …` banners). Gitleaks matches
  the shape, not the value, so a placeholder that merely *looks* like a credential
  fails the pipeline. Use inert placeholders such as `fixture-token-placeholder`.
- **Anonymity.** This repo is public and describes infrastructure. Flag any host
  name, IP address, organisation or pool name, or fleet size. Examples must use
  `your-org`, `your-pool`, `example`, and RFC 5737 / RFC 1918 addresses.
- **Least privilege in the units.** A new `ReadWritePaths` entry, a granted
  capability, or a relaxed sandbox directive needs a comment justifying it at the
  point it happens, as the AppArmor `unprivileged_userns` relaxation does.

## What not to flag

- `StartLimitIntervalSec=0`, the absence of `RestartSteps`, or a wrapper's
  avoidance of `exec` — all intentional and documented.
- The GitHub flavour's legacy names (`gha`, `/etc/github-runner`) — they are
  fixed for compatibility with the existing fleet and the rollback.
- Missing tests for tasks that change system state; there is no way to test
  them without a VM here, beyond what the converge workflow does.
- Style already fixed by ShellCheck, ansible-lint and the shared config — do not
  re-litigate what `make lint` enforces.
- Restructuring stable, working code for its own sake: churn on the invariants
  above costs more than it saves. Suggest a rewrite only when it fixes a
  concrete defect.

## Output format

Report findings grouped by severity, most severe first. For each: the file and
line, one sentence on the defect, and a concrete failure scenario (inputs or
state → wrong outcome). Cite `file:line`. If nothing survives scrutiny, say so
plainly rather than manufacturing findings.

## Severity

| Severity | Use it for                                                                                     |
|----------|------------------------------------------------------------------------------------------------|
| Critical | Breaks the ephemeral loop, leaks a secret into argv, `environment:` or logs, or de-privileges/wipes the wrong account. |
| High     | A converge stops being idempotent, a GitHub-flavour name or file format changes, the stored-PAT fallback regresses, or a cross-file set falls out of sync. |
| Medium   | An `errexit` hazard that fails only at job time; a missing `chlog` fragment or README update.   |
| Low      | A comment restating code, an anonymity slip in an example, or a missing test for a runtime function. |
