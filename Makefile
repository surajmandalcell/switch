SHELL := /bin/sh

NPM ?= npm
NODE ?= node
HOST ?= 127.0.0.1
PORT ?= 8081
TEST_HOST ?= 127.0.0.1
TEST_PORT ?= 28081
PACK_DIR ?= tmp/release-artifacts
NPM_ACCESS ?= public
NPM_TAG ?= latest
NPM_SCOPE ?= @smc
NPM_REGISTRY ?= https://registry.npmjs.org/
NPM_AUTH_TYPE ?= web

PACKAGE_NAME := @smc/codex-proxy
PRIMARY_BIN := codex-proxy
LEGACY_BIN := codex-claude-proxy
NODE_MODULES_STAMP := node_modules/.package-lock.json
REGISTRY_ARGS := --registry=$(NPM_REGISTRY)
LOGIN_ARGS := --scope=$(NPM_SCOPE) $(REGISTRY_ARGS) --auth-type=$(NPM_AUTH_TYPE)
PUBLISH_ARGS := --access $(NPM_ACCESS) --tag $(NPM_TAG)
ifneq ($(strip $(OTP)),)
PUBLISH_ARGS += --otp $(OTP)
endif

.PHONY: dev link start install build test test-all test-all-with-server pack publish-dry-run publish ensure-clean npm-login login npm-logout npm-whoami npm-auth unlink

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

test-all-with-server: $(NODE_MODULES_STAMP)
	@set -eu; \
	mkdir -p tmp; \
	log_file="tmp/test-server.log"; \
	rm -f "$$log_file"; \
	HOST=$(TEST_HOST) PORT=$(TEST_PORT) $(NODE) src/index.js > "$$log_file" 2>&1 & \
	pid=$$!; \
	trap 'kill $$pid 2>/dev/null || true; wait $$pid 2>/dev/null || true' EXIT INT TERM; \
	ok=0; \
	i=0; \
	while [ $$i -lt 20 ]; do \
		if curl -fsS "http://$(TEST_HOST):$(TEST_PORT)/health" >/dev/null 2>&1; then ok=1; break; fi; \
		i=$$((i + 1)); \
		sleep 0.5; \
	done; \
	if [ "$$ok" -ne 1 ]; then \
		echo "Server did not start on http://$(TEST_HOST):$(TEST_PORT)"; \
		cat "$$log_file"; \
		exit 1; \
	fi; \
	ROUTING_TEST_BASE_URL="http://$(TEST_HOST):$(TEST_PORT)" UI_TEST_URL="http://$(TEST_HOST):$(TEST_PORT)/" $(NPM) run test:all

ensure-clean:
	@if ! git diff --quiet || ! git diff --cached --quiet || [ -n "$$(git ls-files --others --exclude-standard)" ]; then \
		echo "Working tree must be clean before packing or publishing."; \
		git status --short; \
		exit 1; \
	fi

npm-login login:
	$(NPM) login $(LOGIN_ARGS)

npm-logout:
	$(NPM) logout --scope=$(NPM_SCOPE) $(REGISTRY_ARGS)

npm-whoami:
	$(NPM) whoami $(REGISTRY_ARGS)

npm-auth:
	@if ! $(NPM) whoami $(REGISTRY_ARGS) >/dev/null; then \
		echo "Not logged in to $(NPM_REGISTRY) for publishing $(PACKAGE_NAME)."; \
		echo "Run: make npm-login"; \
		exit 1; \
	fi

pack: ensure-clean build
	@mkdir -p $(PACK_DIR)
	@rm -f $(PACK_DIR)/*.tgz
	$(NPM) pack --pack-destination $(PACK_DIR)

publish-dry-run: ensure-clean build test-all-with-server
	$(NPM) publish --dry-run $(PUBLISH_ARGS) $(REGISTRY_ARGS)

publish: ensure-clean npm-auth build test-all-with-server
	$(NPM) publish $(PUBLISH_ARGS) $(REGISTRY_ARGS)

unlink:
	-$(NPM) unlink -g $(PACKAGE_NAME)
