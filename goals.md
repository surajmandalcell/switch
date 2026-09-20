# Switch: current goals

Status: Switch 3.0.0 is released for Apple Silicon macOS. The native app,
shared Swift core, terminal interface, GitHub release, and local npm package
have passed their recorded release gates.

The current product contract is [`docs/specs/product.md`](docs/specs/product.md).
Older milestones and verification evidence are in [`goals.archive.md`](goals.archive.md).

## Active work

### Publish the terminal package to npm

- [x] Package the existing native executable as `switch-codex` without
  duplicating account behavior in JavaScript.
- [ ] Expose both `switch-codex` and the existing `ai-manager` command.
- [ ] Verify the packed package, `npx switch-codex`, and an isolated global
  installation with synthetic homes.
- [ ] Sign in to npm and publish `switch-codex@3.0.0` as a public package.
- [ ] Replace GitHub-tarball install commands with the shorter registry commands.
- [ ] Verify the public package metadata and a clean registry install.

### Optional distribution upgrade

- [ ] Publish a Developer ID signed and notarized Mac artifact when the owner
  supplies those Apple credentials. The current ad hoc signed release remains
  the supported download until then.

## Ledger convention

Keep only current requirements, open acceptance gates, and the latest useful
evidence here. Move old completed detail to `goals.archive.md` without losing it.
Both ledgers are local and ignored by Git.
