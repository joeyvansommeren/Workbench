.PHONY: update install test test-interactive-titlebar

# Pull main, build, replace /Applications/Workbench.app, relaunch.
update:
	@zsh scripts/update.sh

# Build and install the current checkout without pulling.
install:
	@zsh scripts/update.sh --no-pull

test:
	@./scripts/test.sh

# Manual desktop verification. Requires explicit AGENTHUB_TEST_VISIBLE_WINDOWS=1.
test-interactive-titlebar:
	@./scripts/test.sh titlebar-interactive
