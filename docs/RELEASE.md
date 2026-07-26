# Release process

## Preconditions

- The default branch contains only the canonical source tree.
- No staging, transfer, generated package, legacy dashboard, or local data directories are tracked.
- The package version and changelog agree.
- The lockfile is current.
- All documentation describes implemented behavior.

## Local release gate

```bash
npm ci
npm run build
npm audit --omit=dev --audit-level=high
npm run dist:dir
```

Inspect the unpacked application, startup, provider/account editing, server restart, local authentication, protocol requests, usage ledger, and website.

## CI

The desktop CI workflow runs:

1. Deterministic npm installation.
2. Repository verification.
3. Full test/coverage suite.
4. Documentation link checks.
5. Renderer and website builds.
6. Production dependency audit.
7. Unpacked Electron packaging on macOS, Windows, and Linux.

CodeQL analyzes JavaScript. The Pages workflow deploys the generated public website.

## Tagging

Create an annotated `vMAJOR.MINOR.PATCH` tag only after default-branch CI succeeds. The release workflow builds platform artifacts and checksums.

Unsigned packages are suitable for development and testing. Public end-user distribution should add:

- Apple Developer ID signing and notarization.
- Windows Authenticode signing.
- Maintainer-controlled release secrets.
- Platform installation testing.

Do not weaken security settings or CI checks to make packaging pass.
