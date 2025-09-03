# Switch

A lightweight CLI tool for seamlessly switching between multiple authentication accounts for AI services like Codex, Claude, and other applications.

## Overview

Switch eliminates the hassle of manually managing different authentication configurations by allowing you to store multiple account profiles and switch between them instantly. Perfect for developers who work with multiple AI service accounts or different authentication contexts.

## Features

- **Fast Account Switching**: Cycle through accounts with a single command
- **Multiple Service Support**: Currently supports Codex with extensible architecture
- **Secure Storage**: Authentication files are stored securely in your home directory
- **Interactive Setup**: Guided setup for your first account
- **Cross-Platform**: Supports macOS, Linux, and Windows
- **Colorful CLI**: Enhanced user experience with colored terminal output

## Installation

### From Source

```bash
git clone https://github.com/surajmandalcell/switch.git
cd switch
go build -o switch switch.go
```

### Install Globally

#### macOS/Linux
```bash
sudo mv switch /usr/local/bin/
```

#### Or add to your PATH
```bash
mkdir -p ~/bin
mv switch ~/bin/
echo 'export PATH="$HOME/bin:$PATH"' >> ~/.zshrc  # or ~/.bashrc
source ~/.zshrc
```

### Cross-Platform Builds

#### macOS
```bash
# ARM64 (Apple Silicon)
GOOS=darwin GOARCH=arm64 go build -o ./build/switch-darwin-arm64 switch.go

# AMD64 (Intel)
GOOS=darwin GOARCH=amd64 go build -o ./build/switch-darwin-amd64 switch.go
```

#### Linux
```bash
# AMD64
GOOS=linux GOARCH=amd64 go build -o ./build/switch-linux-amd64 switch.go

# ARM64
GOOS=linux GOARCH=arm64 go build -o ./build/switch-linux-arm64 switch.go
```

#### Windows
```bash
GOOS=windows GOARCH=amd64 go build -o ./build/switch.exe switch.go
```

## Quick Start

### 1. Initial Setup
```bash
# Ensure the codex directory exists
mkdir -p ~/.codex

# Place your authentication file at ~/.codex/auth.json
# Example auth.json content:
# {"api_key": "your-api-key", "organization": "your-org"}
```

### 2. Add Your First Account
```bash
switch codex add myaccount
```

### 3. Add More Accounts
```bash
switch codex add work
switch codex add personal
```

### 4. Switch Between Accounts
```bash
# Cycle through all accounts
switch

# Switch to a specific account
switch codex myaccount

# List all accounts
switch codex list
```

## Usage

### Commands

| Command | Description |
|---------|-------------|
| `switch` | Cycle through all available accounts |
| `switch codex` | Cycle through Codex accounts |
| `switch codex <name>` | Switch to a specific account |
| `switch codex add <name>` | Add current auth.json as a new account |
| `switch codex list` | List all configured accounts |
| `switch list` | List all configured accounts (alias) |
| `switch help` | Show help information |

### Examples

```bash
# Quick account switching
switch                    # Cycles to next account

# Specific account switching
switch codex work         # Switches to 'work' account
switch codex personal     # Switches to 'personal' account

# Account management
switch codex add staging  # Saves current auth.json as 'staging'
switch codex list         # Shows all accounts with current indicator
```

## Configuration

Switch stores its configuration in `~/.switch.toml` and authentication files in `~/.codex/`. 

### Directory Structure
```
~/.codex/
├── auth.json              # Current active authentication
├── auth.json.work.switch  # 'work' account backup
└── auth.json.personal.switch  # 'personal' account backup

~/.switch.toml             # Switch configuration file
```

### Configuration File Format
```toml
[default]
config = "codex"

[codex]
work = { current = "work" }
personal = { current = "personal" }
```

## Development

### Running Tests
```bash
go test -v -cover
```

### Building
```bash
go build -o ./build/switch switch.go
```

### Contributing

1. Fork the repository
2. Create a feature branch (`git checkout -b feature/amazing-feature`)
3. Commit your changes (`git commit -m 'Add amazing feature'`)
4. Push to the branch (`git push origin feature/amazing-feature`)
5. Open a Pull Request

## Requirements

- Go 1.25.0 or higher
- Write access to your home directory

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

## Author

**Suraj Mandal**
- GitHub: [@surajmandalcell](https://github.com/surajmandalcell)
- Project: [github.com/surajmandalcell/switch](https://github.com/surajmandalcell/switch)

## Acknowledgments

- Built with Go and the [BurntSushi/toml](https://github.com/BurntSushi/toml) library
- Inspired by the need for efficient account management in AI development workflows