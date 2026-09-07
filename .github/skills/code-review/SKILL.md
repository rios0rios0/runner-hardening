---
name: code-review
description: 'Review a pull request against rios0rios0/runner-hardening; reach for this skill whenever judging any change to the repository — the installer, the fleet driver, their generated artefacts, the tests, or the configuration and documentation files.'
---

# Code review — runner-hardening

## When to use this skill

Use it when reviewing any change to this repository: `harden-gha-runners.sh`,
`fleet.sh`, the config/documentation files, or `test/bootstrap_test.sh`. It
teaches how a change here is *judged*; `.github/copilot-instructions.md` teaches
how the code *works*. Read that file first for context, then apply the checklist
below.

## Source of truth and precedence

When guidance conflicts, earlier wins over later:

1. The code as it actually runs (Bash semantics under `set -Eeuo pipefail`).
2. This skill's repo-specific checklist.
3. `.github/copilot-instructions.md` and `CLAUDE.md`.
4. The shared [Development Guide](https://github.com/rios0rios0/guide/wiki) and
   its [Git-Flow](https://github.com/rios0rios0/guide/wiki/Git-Flow) commit
   conventions.

A claim in the docs that the code contradicts is a doc bug, not a code bug —
flag the drift, do not demand the code change to match stale prose.

## How to run the review

```bash
make test    # parse check + bootstrap suite (~2s, 81 assertions, no VM needed)
make lint    # ShellCheck — needs `make setup` first
make sast    # CodeQL, Semgrep, Trivy, Hadolint, Gitleaks — needs `make setup`
```

`make test` is the only gate that runs on a bare clone. `make lint` and
`make sast` read the shared configuration from a local checkout of
`rios0rios0/pipelines`, so they need `make setup` (or a `SCRIPTS_DIR=` override)
first. Never invoke `shellcheck`, `semgrep` or `gitleaks` directly — the
Makefile targets load the shared config the whole fleet standardises on.
Anything that changes system state cannot be tested here; it has to be run on a
disposable Ubuntu VM. Do not approve such a change as "verified" on `make test`
alone — say it needs VM exercise.

## Repo-specific checklist

- **The ephemeral loop must stay intact.** `gha-runner@N` runs exactly one job:
  `ExecStartPre` mints a single-use JIT config (root, PAT unseen by the runner
  user), `ExecStart` wipes `_work` and runs one job, `ExecStopPost` reaps the
  registration, `Restart=always` loops. Flag anything that lets `run.sh` survive
  a second job, or that makes the wrapper `exec ./run.sh` — `exec` discards the
  EXIT trap and skips cleanup, silently restoring a long-lived runner.
- **`StartLimitIntervalSec=0` is deliberate.** systemd's start limit counts
  *attempts*; a healthy runner finishing many quick jobs would trip a nonzero
  limit. Do not flag it as a missing safeguard, and flag any change that removes
  it.
- **`harden-gha-runners.sh` stays self-contained.** It is copied onto machines
  alone, so a new `source` of another repo file is a defect even though the
  helper is duplicated in `fleet.sh` on purpose.
- **Heredoc quoting is load-bearing.** `<<EOF` bakes installer-side values
  (`${d}`, `${uid}`, `${USER_PREFIX}`) into the generated artefact; `<<'EOF'`
  ships verbatim, so every runtime `$` must be escaped (`\$JIT`,
  `\$RUNNER_PID`). Getting it backwards yields a valid script that reads an empty
  variable at job time. A new generated script must keep a `bash -n` check like
  the one `phase_runners` runs on the wrapper it writes.
- **No secret may become a command-line argument.** `/proc/<pid>/cmdline` is
  world-readable. The SSH bootstrap streams its env file on stdin; every `curl`
  passes the token with `-H @file`. Flag any `-H "Authorization: Bearer ..."`,
  any token in argv, and any `curl -K -` substitute (its unquoted value form
  drops a malformed header silently and sends the request unauthenticated).
- **`load_config` is a default, never an override.** It saves caller `GHA_*`
  answers, sources `/etc/github-runner/env`, then restores them, falling back to
  `/etc/github-runner/pat` only when no `GHA_PAT` was supplied. A change to a
  plain `. "$ENV_FILE"` breaks unattended runs (they report success while
  changing nothing) and `fleet.sh --no-pat install`.
- **`die` inside `$( )` only exits the subshell.** `build_bootstrap` assigns
  `build_env`'s output to a variable so the failure propagates under `errexit`.
  Flag a change that inlines the command substitution again.
- **`set -Eeuo pipefail` correctness.** A `[[ cond ]] && action` whose action can
  fail needs `|| true` or an `if`. Watch for unset-variable hazards under `-u`.
- **Idempotency.** Every mode must converge; a second consecutive run that
  changes something is a bug.
- **Cross-file sync.** A new mode must land in the `main()` `case`, the
  `die "unknown mode ..."` list, the installer header USAGE block **and its
  hardcoded `sed -n '2,30p'` `--help` range**, `VALID_MODES` in `fleet.sh`, and
  the README. A new `fleet.conf` key must land in `KNOWN_KEYS`, `build_env`,
  `fleet.conf.example`, and the README. A new `GHA_*` answer must land in
  `CONFIG_ANSWERS`, the `save_config` heredoc, the wizard, and the README table.
  A partial addition is a latent bug: an unknown `fleet.conf` key is a hard
  parse error, not a warning.
- **Every wizard prompt needs an environment answer.** `fleet.sh` drives the
  installer with no pty, so an interactive-only question is unreachable to the
  fleet.
- **Comments explain the surprising decision, not the obvious line.** Flag a new
  comment that restates code; do not flag the existing ones that explain why a
  systemd directive is deliberately unset.
- **Tests.** New behaviour in the pure functions (`parse_config`, `build_env`,
  `build_bootstrap`, `load_config`, `should_preload_config`,
  `runner_state_between_jobs`) should come with an `it_*` case. Do not ask for a
  test that would require a VM.

## Shared guide rules

A pull-request review does not have the author's global rules loaded, so restate
the ones this stack depends on:

- **Commits and PRs follow [Git-Flow](https://github.com/rios0rios0/guide/wiki/Git-Flow)**:
  Conventional-Commit subjects, imperative mood, branch off and target `main`.
- **Fail loudly.** Under `errexit` a silently swallowed error is worse than a
  crash; prefer an explicit `die` with a cause over a bare `|| true` that hides
  a real failure.
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
  name, IP address, organisation name, or fleet size. Examples must use
  `your-org`, `example`, and RFC 5737 / RFC 1918 addresses.
- **Least privilege in generated units.** A new `ReadWritePaths` entry, a granted
  capability, or a relaxed sandbox directive needs a comment justifying it at the
  point it happens, as the AppArmor `unprivileged_userns` relaxation does.

## What not to flag

- The deliberate duplication of helpers between the two scripts.
- `StartLimitIntervalSec=0`, or the wrapper's avoidance of `exec` — both are
  intentional and documented.
- Missing unit tests for phases that change system state; there is no way to test
  them without a VM here.
- Style already fixed by ShellCheck and the shared config — do not re-litigate
  what `make lint` enforces.
- Modernising or restructuring stable, working Bash for its own sake: this is a
  small, self-contained toolset, and churn on the invariants above costs more
  than it saves. Suggest a rewrite only when it fixes a concrete defect.

## Output format

Report findings grouped by severity, most severe first. For each: the file and
line, one sentence on the defect, and a concrete failure scenario (inputs or
state → wrong outcome). Cite `file:line`. If nothing survives scrutiny, say so
plainly rather than manufacturing findings.

## Severity

| Severity | Use it for                                                                                     |
|----------|------------------------------------------------------------------------------------------------|
| Critical | Breaks the ephemeral loop, leaks a secret into argv/logs, or de-privileges/wipes the wrong account. |
| High     | A mode stops being idempotent, `load_config` semantics regress, or a cross-file set falls out of sync. |
| Medium   | A heredoc-quoting or `errexit` hazard that fails only at job time; a missing `chlog` fragment or README update. |
| Low      | A comment restating code, an anonymity slip in an example, or a missing test for a pure function. |
