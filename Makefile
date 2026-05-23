SHELL := /bin/sh

.PHONY: update publish

update:
	@./scripts/npm.sh update

publish:
	@./scripts/npm.sh publish
