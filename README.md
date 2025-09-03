## Run Tests

```
go test -v -cover
```

## Build Executable

```
go build -o ./build/switch switch.go
```

## Install Globally

```
sudo mv switch /usr/local/bin/
```

## Or add to PATH:

```
mkdir -p ~/bin
mv switch ~/bin/
echo 'export PATH="$HOME/bin:$PATH"' >> ~/.zshrc
source ~/.zshrc
```

## Initial Setup

```
# Ensure codex directory exists
mkdir -p ~/.codex

# Add your first account (assuming auth.json exists)
switch codex add myaccount

# Add more accounts
switch codex add work
switch codex add personal
```

## Extras

macOS:

```
GOOS=darwin GOARCH=arm64 go build -o ./build/switch-darwin-arm64 switch.go
bashGOOS=darwin GOARCH=amd64 go build -o ./build/switch-darwin-amd64 switch.go
```

Linux:

```
bashGOOS=linux GOARCH=amd64 go build -o ./build/switch-linux-amd64 switch.go
GOOS=linux GOARCH=arm64 go build -o ./build/switch-linux-arm64 switch.go
```

Windows:

```
bashGOOS=windows GOARCH=amd64 go build -o ./build/switch.exe switch.go
```
