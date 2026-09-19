# macOS package

Switch uses an ordinary app bundle with no extra entitlements. It does not
request Full Disk Access, Accessibility, Automation, or network access.

The app reads a selected Codex home through native file APIs. A denied path is
reported to the user. The app does not inspect the login Keychain.

The package records the source revision in `AIManagerSourceRevision` and marks
uncommitted source in `AIManagerSourceDirty`. The default build uses an ad hoc
signature. Set `AI_MANAGER_SIGNING_IDENTITY` only when a maintainer explicitly
provides a signing identity. Identity builds enable hardened runtime and secure
timestamping for both the app and CLI. Trusted direct distribution additionally
requires a Developer ID Application identity and Apple notarization. That path
fails before publication when its signing or notary credentials are absent or
its public readiness check does not pass. The separate preview path uses an
ad hoc signature and clear manual Gatekeeper instructions. The local script
uploads either verified archive with `gh release create`. See
[`docs/development.md`](../../docs/development.md#packaging-and-release).

Production builds never define `AI_MANAGER_PREVIEW`. The sample account model,
mock actions, and Preview-only interface are compiled only by the uninstalled
developer launcher, `scripts/launch-switch.sh --preview`. The release readiness
gate rejects a production executable that contains Preview-only sample data.
