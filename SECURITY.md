# Security policy

AI Manager is a local macOS account manager for Codex. It does not provide a
proxy, provider router, hosted service, or OAuth implementation.

## Report a vulnerability

Do not open a public issue for a vulnerability. Do not include credentials,
tokens, transcripts, private settings, or unredacted logs in a report. Use
GitHub private vulnerability reporting and include the affected commit,
macOS version, reproduction steps, and security effect.

## Security boundaries

- Credentials stay in Codex-compatible private files.
- App metadata contains no raw credential bytes.
- The app does not access the login Keychain.
- Discovery does not make network calls or execute imported hooks.
- Imported commands and plugins are preserved only as data.
- User-selected paths are inspected with bounded file operations.
- Staging, backups, and account homes use private permissions.
- Source data remains unchanged after a successful import.
- Failed mutations retain a usable prior state and a recovery record.

The app does not request Full Disk Access, Accessibility, Automation, or
network access merely to inspect a selected Codex home.

See [goals.md](goals.md) for the full data ownership and recovery model.
