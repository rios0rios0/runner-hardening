# Contributing

Contributions are welcome. By participating, you agree to maintain a respectful and constructive environment.

For coding standards, testing patterns, architecture guidelines, commit conventions, and all
development practices, refer to the **[Development Guide](https://github.com/rios0rios0/guide/wiki)**.

## Prerequisites

- [`ansible-core`](https://docs.ansible.com/ansible/latest/installation_guide/intro_installation.html) `2.16` or later
- [Make](https://www.gnu.org/software/make/)
- Bash `4.3` or later
- [Docker](https://docs.docker.com/get-started/get-docker/), only for `make sast`
- A disposable Ubuntu VM, for anything that changes a box — the roles change system state and are not safe to point at a workstation

## Development Workflow

1. Fork and clone the repository
2. Create a branch: `git checkout -b feat/my-change`
3. Install dependencies:
   ```bash
   make setup        # the shared pipeline scripts behind lint and sast
   make collection   # resolve the collection from build/collections
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
   chlog new --kind Added --body 'added the thing that was not there before'
   ```
7. Commit following the [commit conventions](https://github.com/rios0rios0/guide/wiki/Git-Flow)
8. Open a pull request against `main`

## Testing a change on a box

`make test` proves that every script parses, that the runtime scripts behave
when driven against scratch trees, that the resource-policy math and the
rendered units hold their invariants, and that every playbook parses. It never
touches a real system. The converge workflow does, on a disposable VM, for
every pull request; anything it cannot reach — a real registration, a job, a
reboot — has to be exercised on a throwaway Ubuntu VM of your own, listed in
`inventory/local/`:

```bash
ansible-playbook playbooks/github.yaml --limit build-01      # converge
ansible-playbook playbooks/github.yaml --limit build-01      # again: must report changed=0
ansible-playbook playbooks/verify.yaml --limit build-01      # must pass every check
ansible-playbook playbooks/uninstall.yaml --limit build-01
```

Converge twice, every time. A second run that changes something is a bug.

## Adding a New Variable

1. Add it to the role's `defaults/main.yaml`, with that role's prefix
   (`runner_`, `runner_github_` or `runner_azp_`)
2. Add its row to the variable table in `README.md`
3. Add it to `inventory/example`, commented out and showing its default
4. If a runtime script reads it, add it to the `host.env` template and the
   script, with a `test/runtime` case
5. Add a changelog fragment with `--kind Added`

## Conventions specific to this repository

`AGENTS.md` holds the full list; these are the ones a change most often breaks.

- **Runtime scripts are static.** They read their configuration at runtime from
  the files the roles write, never from values baked in at install time. Each
  ends in `.sh` in the repository, so the shared ShellCheck target lints it, and
  is installed without the suffix.
- **No secret may become a command-line argument**, on the controller or on a
  box: argv is readable from `/proc` by any local user. Not in `command` or
  `shell`, not in `environment:`, not as `-e name=value`. A secret reaches a box
  only inside a `no_log: true` task: as the `stdin` of an `install … /dev/stdin`
  that writes its root-only file, or as `uri` `headers:`.
- **Every converge is idempotent.** Every `command` or `shell` task has a
  `changed_when`, and never `changed_when: true`.
- **`ansible.builtin` only**, called by fully qualified name: the collection has
  no dependencies on purpose.
- **The GitHub flavour keeps the shell installer's names and file formats**, so
  a fleet it set up converges without anything being renamed, and the previous
  release stays a working rollback.
- **Comment the surprising decision, not the obvious line.** The reason a
  systemd directive is deliberately *not* set is worth a paragraph; a
  `mode: '0600'` is not.
