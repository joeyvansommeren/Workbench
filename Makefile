.PHONY: update install test

# Pull main, build, replace /Applications/Workbench.app, relaunch.
update:
	@zsh scripts/update.sh

# Build and install the current checkout without pulling.
install:
	@zsh scripts/update.sh --no-pull

test:
	@./scripts/test.sh
