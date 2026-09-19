.PHONY: tui

AI_MANAGER_BUILD_PATH ?= /private/tmp/ai-manager-build

tui:
	@swift run --disable-sandbox --build-path "$(AI_MANAGER_BUILD_PATH)" ai-manager interactive
