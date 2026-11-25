Version bump for Switch X.Y.Z. Branch `release/vX.Y.Z`. Release issue: #

## In this PR

- [ ] `package.json` and `packages/core/Sources/AIManagerCore/BuildInfo.swift` say X.Y.Z
      (`git grep -n '<old version>'` finds nothing else that should change)
- [ ] `docs/release-notes.md` has the X.Y.Z notes
- [ ] Every other PR in milestone X.Y.Z is merged

## Checks (Switch is in production)

- [ ] Swift core suite passes on lin1 (Linux) and in the Windows container on lin1
- [ ] Mac gates: `scripts/check-native.sh`, `scripts/check-mac-gui-contract.sh`,
      `scripts/check-mac-gui-production.sh`, `scripts/check-mac-gui-lint.sh`
- [ ] CLI: `scripts/check-npm-tui.sh`, `scripts/check-linux.sh`, `scripts/check-installer.sh`
- [ ] `scripts/check-release-readiness.sh`

## After the merge

Follow the "Ship" and "After the tag" steps of the release issue: `scripts/release-macos.sh --notarized vX.Y.Z`
tags the merge commit, then npm, pinned versions, `releases.json`, and the fresh install check.
