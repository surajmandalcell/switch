---
name: Release
about: Checklist for one Switch feature or patch release
title: Release X.Y.Z
labels: release
---

Version: X.Y.Z  ·  Milestone: X.Y.Z

## Before the tag

- [ ] Every PR for this release is merged and the milestone is closed
- [ ] Version-bump PR merged. The source version lives in `package.json` and
      `packages/core/Sources/AIManagerCore/BuildInfo.swift` (check with
      `git grep -n '<old version>'`; the app's `Info.plist` version comes from the release script)
- [ ] Notes added to `docs/release-notes.md`
- [ ] Swift core suite passes on oci1 (`flock /mnt/sdb/data/switch/build.lock`)
- [ ] Mac gates pass: `scripts/check-native.sh`, `scripts/check-mac-gui-contract.sh`,
      `scripts/check-mac-gui-production.sh`, `scripts/check-mac-gui-lint.sh`
- [ ] CLI checks pass: `scripts/check-npm-tui.sh`, `scripts/check-linux.sh`, `scripts/check-installer.sh`
- [ ] `scripts/check-release-readiness.sh` passes

## Ship

- [ ] `scripts/release-macos.sh --notarized vX.Y.Z` (or `--xcode`): signed, notarized,
      tag, and GitHub Release with ZIP, DMG, and checksums
- [ ] Linux CLI archives under `cli-vX.Y.Z` (each built on its own CPU architecture), when they ship
- [ ] Windows package, when it ships
- [ ] npm: `scripts/prepare-npm-tui.sh`, publish `@smdl/switch@X.Y.Z`, then `npm view @smdl/switch version`
- [ ] GitHub Release notes copied from `docs/release-notes.md`

## After the tag

- [ ] Pinned public versions updated in a PR: `install.sh`, `scripts/check-installer.sh`,
      `packages/website/public/` (`site.js`, `index.html`, download toasts, security page), `docs/development.md`
- [ ] README updated if features or screenshots changed
- [ ] apps.samhq `releases.json` entry for `switch` (repo `app_backend`, `docs/clients.md` "Adding an app")
- [ ] Fresh install check: `install.sh` and `npm install -g @smdl/switch` report X.Y.Z; the installed app runs
