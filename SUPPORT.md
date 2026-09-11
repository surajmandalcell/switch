# Support

Read [goals.md](goals.md) for supported workflows and limits.

## Local checks

```bash
scripts/check-native.sh
scripts/build-native.sh
```

AI Manager supports macOS 14 or later. The first verified build target is
Apple Silicon. Codex is optional for offline discovery and contract tests.

## Report a defect

Use the repository issue form. Include the app version or commit, macOS
version, architecture, exact action, and redacted error text. Remove tokens,
auth files, transcript content, private paths, and personal identity fields.

For import failures, include the source kind and failure phase. Do not attach
real Codex homes or backups. Reproduce with a temporary home when possible.

## Outside support

The project does not recover credentials, access the login Keychain, execute
imported hooks, or bypass account limits. Sign-in and online verification
remain user-controlled Codex actions.
