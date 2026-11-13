# The quality gates live in the shared pipelines repository rather than here, so
# every project in the fleet runs the same tool versions and the same configs.
# SCRIPTS_DIR points at a local checkout of it; override it if yours lives
# elsewhere:  make SCRIPTS_DIR=/path/to/pipelines lint
SCRIPTS_DIR ?= $(HOME)/Development/github.com/rios0rios0/pipelines
PIPELINES_REPO ?= https://github.com/rios0rios0/pipelines.git
COMMON_MK := $(SCRIPTS_DIR)/makefiles/common.mk

-include $(COMMON_MK)

# Every script that ships to a box, plus the suites that drive them. Runtime
# scripts carry a .sh suffix in the repository (the roles drop it on install)
# so that the shared ShellCheck target, which only lints *.sh, covers them.
SHELL_SOURCES := $(sort $(shell find roles test -name '*.sh' -type f 2>/dev/null))
PLAYBOOKS     := $(sort $(wildcard playbooks/*.yaml))

# The collection is the repository root itself. Ansible only finds a collection
# under <path>/ansible_collections/<namespace>/<name>, so development resolves
# it through this link -- the same fully qualified names a consumer uses.
COLLECTION_LINK := build/collections/ansible_collections/rios0rios0/runner_hardening

.PHONY: lint test setup sast codeql semgrep hadolint shellcheck gitleaks collection

collection: $(COLLECTION_LINK)

$(COLLECTION_LINK):
	@mkdir -p "$(dir $@)"
	@ln -sfn ../../../.. "$@"

ifeq ($(wildcard $(COMMON_MK)),)

# The shared scripts are not on disk, which is the state of every fresh clone.
# Without this block `-include` fails silently and the gates die with "No rule
# to make target 'shellcheck'" -- a message about an internal target name that
# tells a new contributor nothing. Worse, `make setup` is itself defined in the
# file that is missing, so the first command CONTRIBUTING.md asks for would not
# exist either.
setup:
	@echo "Cloning the shared pipeline scripts into $(SCRIPTS_DIR)"
	@mkdir -p "$(dir $(SCRIPTS_DIR))"
	@git clone --depth 1 "$(PIPELINES_REPO)" "$(SCRIPTS_DIR)"

lint sast codeql semgrep hadolint shellcheck gitleaks ansible-lint:
	@echo "'$@' comes from the shared pipeline scripts, which are not present at:"
	@echo "    $(SCRIPTS_DIR)"
	@echo
	@echo "Fetch them once, then re-run:"
	@echo "    make setup && make $@"
	@echo "Or point at an existing checkout:"
	@echo "    make SCRIPTS_DIR=/path/to/pipelines $@"
	@echo
	@echo "'make test' needs none of this and works on a bare clone."
	@exit 1

else

# `sast` already runs ShellCheck; `lint` adds ansible-lint for the roles and
# playbooks. Both come from the shared scripts, never from a local binary.
lint: shellcheck ansible-lint

endif

# What is testable without a VM: every script parses, the runtime scripts
# behave (driven against scratch trees, as non-root), the resource-policy math
# and the rendered units hold their invariants, and every playbook parses.
# Anything that changes a real box is exercised by the converge workflow on a
# disposable VM, and nowhere else.
test: collection
	@for f in $(SHELL_SOURCES); do \
		bash -n "$$f" && echo "  ok  $$f parses" || exit 1; \
	done
	@bash test/runtime/run.sh
	@for t in test/ansible/policy.yaml test/ansible/templates.yaml; do \
		ansible-playbook "$$t" || exit 1; \
	done
	@for p in $(PLAYBOOKS); do \
		ansible-playbook --syntax-check -i localhost, "$$p" >/dev/null \
			&& echo "  ok  $$p syntax" || exit 1; \
	done
