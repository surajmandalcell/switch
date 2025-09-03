BINARY_NAME=switch
BUILD_DIR=./build
VERSION=$(shell git describe --tags --always --dirty 2>/dev/null || echo "dev")
LDFLAGS=-ldflags "-X main.version=$(VERSION)"

GREEN=\033[0;32m
BLUE=\033[0;34m
NC=\033[0m

.PHONY: build install uninstall test fmt vet lint dev run quick update

build:
	@mkdir -p $(BUILD_DIR)
	@go build $(LDFLAGS) -o $(BUILD_DIR)/$(BINARY_NAME) .

install: build
	@sudo cp $(BUILD_DIR)/$(BINARY_NAME) /usr/local/bin/
	@sudo chmod +x /usr/local/bin/$(BINARY_NAME)

install-user: build
	@mkdir -p ~/bin
	@cp $(BUILD_DIR)/$(BINARY_NAME) ~/bin/
	@chmod +x ~/bin/$(BINARY_NAME)

uninstall:
	@sudo rm -f /usr/local/bin/$(BINARY_NAME)
	@rm -f ~/bin/$(BINARY_NAME)

test:
	@go test -v -race -coverprofile=coverage.out ./...

fmt:
	@go fmt ./...

vet:
	@go vet ./...

lint:
	@if command -v golangci-lint >/dev/null 2>&1; then golangci-lint run; fi

dev: fmt vet test build

run: build
	@$(BUILD_DIR)/$(BINARY_NAME)

quick: build install-user

update:
	@echo "$(BLUE)Updating $(BINARY_NAME)...$(NC)"
	@rm -rf $(BUILD_DIR)
	@mkdir -p $(BUILD_DIR)
	@go build $(LDFLAGS) -o $(BUILD_DIR)/$(BINARY_NAME) .
	@sudo cp $(BUILD_DIR)/$(BINARY_NAME) /usr/local/bin/
	@sudo chmod +x /usr/local/bin/$(BINARY_NAME)
	@echo "$(GREEN)Updated $(BINARY_NAME) to $(VERSION)$(NC)"
