# Contributing

Contributions are welcome. By participating, you agree to maintain a respectful and constructive environment.

For coding standards, testing patterns, architecture guidelines, commit conventions, and all
development practices, refer to the **[Development Guide](https://github.com/rios0rios0/guide/wiki)**.

## Prerequisites

- Bash 4.3+
- [Make](https://www.gnu.org/software/make/)
- [ShellCheck](https://www.shellcheck.net/) (run through `make lint`, not directly)
- A disposable Ubuntu VM — the installer changes system state and is not safe to test on a workstation

## Development Workflow

1. Fork and clone the repository
2. Create a branch: `git checkout -b feat/my-change`
3. Install the shared pipeline scripts the Makefile targets read from:
   ```bash
   make setup
   ```
4. Make your changes
5. Validate:
   ```bash
   make lint
   make test
   make sast
   ```
6. Add a changelog fragment — never edit `CHANGELOG.md`, which is generated from them:
   ```bash
   chlog new --kind Added --body "added the thing that was not there before"
   ```
7. Commit following the [commit conventions](https://github.com/rios0rios0/guide/wiki/Git-Flow)
8. Open a pull request against `main`

## Testing a change

`make test` only proves the scripts parse and that `fleet.sh` builds a correct
remote bootstrap. Anything that touches system state has to be exercised on a
disposable VM:

```bash
# on a throwaway Ubuntu box
sudo ./harden-gha-runners.sh          # install
sudo ./harden-gha-runners.sh verify   # must pass every check
sudo ./harden-gha-runners.sh uninstall
```

Re-run each mode twice. Every mode is idempotent, and a second run that
changes something is a bug.

## Conventions specific to this repository

- **`harden-gha-runners.sh` stays self-contained.** It is copied onto machines
  on its own and must never source a second file from this repository.
- **`set -Eeuo pipefail` is on.** A bare `[[ cond ]] && action` list that can
  fail needs a trailing `|| true`, or write it as an `if`.
- **Comment the surprising decision, not the obvious line.** The reason a
  systemd directive is deliberately *not* set is worth a paragraph; a
  `chmod 0600` is not.
- **Anything the wizard asks for must also be settable from the environment**,
  or `fleet.sh` cannot drive it: an SSH session without a pty has no terminal
  to prompt on.
- **No secret may become a command-line argument** on either side of the SSH
  connection — argv is readable from `/proc` by any local user.
