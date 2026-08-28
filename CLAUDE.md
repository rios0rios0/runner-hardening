# CLAUDE.md

Guidance for AI assistants working in this repository.

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
make test    # parse check + the bootstrap suite (~2s, no VM needed)
make sast    # CodeQL, Semgrep, Trivy, Hadolint, Gitleaks
```

Never invoke `shellcheck`, `semgrep` or `gitleaks` directly — the Makefile
targets load the shared configuration first.

## Rules specific to this repository

- **`harden-gha-runners.sh` is self-contained.** It is copied onto machines on
  its own, so it must never source another file from this repository. Shared
  helpers between it and `fleet.sh` are duplicated on purpose.
- **`set -Eeuo pipefail` is on in both scripts.** A `[[ cond ]] && action` list
  whose condition can be false is fine on its own, but one whose *action* can
  fail needs `|| true`, or write it as an `if`.
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
- **Tests are hand-rolled**, in BDD `# given / # when / # then` form, with
  no mocking library. The bootstrap tests run the real bootstrap through a real
  `bash -s` against a stand-in installer; only the SSH hop is substituted.
- **Anything that changes system state is untestable here.** It has to be
  exercised on a disposable Ubuntu VM — say so rather than claiming a change is
  verified when only `make test` has run.

## Anonymity

This repository is public and describes infrastructure. Do not add host names,
IP addresses, organisation names, fleet sizes, or anything else that identifies
a specific deployment. Examples use `your-org`, `example`, and RFC 5737 / RFC
1918 addresses.

## Documentation

Every change updates a `chlog` fragment under `.changes/unreleased/`; never
edit `CHANGELOG.md` by hand. Update `README.md` whenever a flag, a `GHA_*`
variable, a `fleet.conf` key or a requirement changes.
