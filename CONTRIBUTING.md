# Contributing

Read [goals.md](goals.md) before implementation. It defines IIA Directeur's
Codex account-manager scope and acceptance gates. The GUI supports macOS 14 or
later. The core library and terminal interface support macOS and Linux; the GUI
does not run on Linux.

## Build and test

```bash
scripts/check-native.sh
scripts/build-native.sh
scripts/check-release-readiness.sh
```

On Linux, run `scripts/check-linux.sh` for the core, terminal, SQLite, and
isolated runtime contracts.

Use `/private/tmp/ai-manager-build` for SwiftPM output. Set
`AI_MANAGER_BUILD_PATH` when the host requires another private path. Do not
create timestamped build copies.

Use temporary homes and synthetic credentials for tests. Keep real auth,
transcripts, private settings, backups, and copied links outside the
repository.

## Code boundaries

- `packages/core` owns shared contracts and account operations.
- `packages/gui` owns the SwiftUI app and macOS file panels.
- `packages/tui` owns CLI argument and terminal presentation code.
- GUI and CLI call core operations. They do not duplicate file mutation logic.
- Core code does not access the login Keychain or execute imported commands.

Preserve the transaction and recovery rules in [ADR 0003](docs/adr/0003-credential-transactions.md).
Keep credential bytes out of logs, process arguments, fixtures, and docs.

Keep commits focused. Inspect the complete diff and run `git diff --check`
before handoff.
