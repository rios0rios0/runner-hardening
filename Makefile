# The quality gates live in the shared pipelines repository rather than here, so
# every project in the fleet runs the same tool versions and the same configs.
# SCRIPTS_DIR points at a local checkout of it; override it if yours lives
# elsewhere:  make SCRIPTS_DIR=/path/to/pipelines lint
SCRIPTS_DIR ?= $(HOME)/Development/github.com/rios0rios0/pipelines
PIPELINES_REPO ?= https://github.com/rios0rios0/pipelines.git
COMMON_MK := $(SCRIPTS_DIR)/makefiles/common.mk

-include $(COMMON_MK)

SHELL_SOURCES := harden-gha-runners.sh fleet.sh test/bootstrap_test.sh

.PHONY: lint test setup sast codeql semgrep hadolint shellcheck gitleaks

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

lint sast codeql semgrep hadolint shellcheck gitleaks:
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

# `sast` already runs ShellCheck, but `lint` is the target every other project
# here exposes; a contributor should not have to know this one happens to be
# pure shell to find it.
lint: shellcheck

endif

# Nothing in this repository can be unit-tested the way a library can: every
# code path either changes system state or talks to the GitHub API. What IS
# testable without a VM is that the scripts parse, and that fleet.sh builds a
# remote bootstrap that round-trips the installer and the answers intact --
# which is the one piece of machinery with no other way to catch a regression.
test:
	@for f in $(SHELL_SOURCES); do \
		bash -n "$$f" && echo "  ok  $$f parses" || exit 1; \
	done
	@bash test/bootstrap_test.sh
