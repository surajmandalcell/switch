SHELL := /bin/sh

NPM ?= npm
NODE ?= node
HOST ?= 127.0.0.1
PORT ?= 8081

PACKAGE_NAME := @smc/codex-proxy
PRIMARY_BIN := codex-proxy
LEGACY_BIN := codex-claude-proxy
NODE_MODULES_STAMP := node_modules/.package-lock.json

.PHONY: dev link start install build test test-all unlink

dev: link
	@echo "Starting $(PACKAGE_NAME) from this git checkout on http://$(HOST):$(PORT)"
	HOST=$(HOST) PORT=$(PORT) $(NODE) ./bin/cli.js start

link: $(NODE_MODULES_STAMP)
	$(NPM) link
	@echo "Linked local commands: $(PRIMARY_BIN), $(LEGACY_BIN)"

start: $(NODE_MODULES_STAMP)
	HOST=$(HOST) PORT=$(PORT) $(NODE) ./bin/cli.js start

install: $(NODE_MODULES_STAMP)

$(NODE_MODULES_STAMP): package.json package-lock.json
	$(NPM) install

build:
	$(NPM) run build

test:
	$(NPM) test

test-all:
	$(NPM) run test:all

unlink:
	-$(NPM) unlink -g $(PACKAGE_NAME)
