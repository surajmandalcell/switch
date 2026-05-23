SHELL := /bin/sh

.PHONY: dev update publish

dev:
	@npm run start

update:
	@./scripts/npm.sh update

publish:
	@./scripts/npm.sh publish
