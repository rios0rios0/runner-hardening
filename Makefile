SCRIPTS_DIR ?= $(HOME)/Development/github.com/rios0rios0/pipelines
-include $(SCRIPTS_DIR)/makefiles/common.mk

SHELL_SOURCES := harden-gha-runners.sh fleet.sh

.PHONY: lint test

# The SAST suite already runs ShellCheck, but `lint` is the target every other
# repository here exposes, and a contributor should not have to know that this
# one happens to be pure shell to find it.
lint: shellcheck

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
