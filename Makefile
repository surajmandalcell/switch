SHELL := /bin/sh

UPDATE_LEVELS := patch minor major
UPDATE_LEVEL_FROM_GOALS := $(filter $(UPDATE_LEVELS),$(MAKECMDGOALS))

.PHONY: help dev build test test-unit test-all test-api test-routing test-cors test-ui \
	account account-add account-add-headless account-show account-verify account-remove account-clear \
	update publish patch minor major

help:
	@printf '%s\n' 'Usage: make <target>'
	@printf '\n%s\n' 'Development:'
	@printf '  %-22s %s\n' 'dev' 'Start the proxy server'
	@printf '  %-22s %s\n' 'build' 'Run JavaScript syntax checks'
	@printf '\n%s\n' 'Tests:'
	@printf '  %-22s %s\n' 'test' 'Run integration/browser contract tests'
	@printf '  %-22s %s\n' 'test-unit' 'Run unit tests'
	@printf '  %-22s %s\n' 'test-all' 'Run unit and integration tests'
	@printf '  %-22s %s\n' 'test-api' 'Run API route tests'
	@printf '  %-22s %s\n' 'test-routing' 'Run routing tests'
	@printf '  %-22s %s\n' 'test-cors' 'Run CORS/security tests'
	@printf '  %-22s %s\n' 'test-ui' 'Run static UI contract tests'
	@printf '\n%s\n' 'Account:'
	@printf '  %-22s %s\n' 'account' 'Show account CLI help'
	@printf '  %-22s %s\n' 'account-add' 'Add or replace the local account'
	@printf '  %-22s %s\n' 'account-add-headless' 'Add or replace the local account without opening a browser'
	@printf '  %-22s %s\n' 'account-show' 'Show the configured account'
	@printf '  %-22s %s\n' 'account-verify' 'Verify the configured account'
	@printf '  %-22s %s\n' 'account-remove' 'Remove the configured account'
	@printf '  %-22s %s\n' 'account-clear' 'Clear the configured account'
	@printf '\n%s\n' 'Release:'
	@printf '  %-22s %s\n' 'update [patch|minor|major]' 'Prepare an npm update'
	@printf '  %-22s %s\n' 'publish' 'Publish through scripts/npm.sh'

dev:
	@npm run start

build:
	@npm run build

test:
	@npm test

test-unit:
	@npm run test:unit

test-all:
	@npm run test:all

test-api:
	@npm run test:api

test-routing:
	@npm run test:routing

test-cors:
	@npm run test:cors

test-ui:
	@npm run test:ui

account:
	@npm run account -- help

account-add:
	@npm run account:add

account-add-headless:
	@npm run account:add:headless

account-show:
	@npm run account:show

account-verify:
	@npm run account:verify

account-remove:
	@npm run account:remove

account-clear:
	@npm run account:clear

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
