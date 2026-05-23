SHELL := /bin/sh

UPDATE_LEVELS := patch minor major
UPDATE_LEVEL_FROM_GOALS := $(filter $(UPDATE_LEVELS),$(MAKECMDGOALS))

.PHONY: dev update publish patch minor major

dev:
	@npm run start

update:
	@if [ -n "$(UPDATE_LEVEL_FROM_GOALS)" ]; then \
		./scripts/npm.sh update "$(firstword $(UPDATE_LEVEL_FROM_GOALS))"; \
	else \
		./scripts/npm.sh update; \
	fi

publish:
	@./scripts/npm.sh publish

patch minor major:
	@:
