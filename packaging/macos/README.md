# macOS package

IIA Directeur uses an ordinary app bundle with no extra entitlements. It does not
request Full Disk Access, Accessibility, Automation, or network access.

The app reads a selected Codex home through native file APIs. A denied path is
reported to the user. The app does not inspect the login Keychain.

The package records the source revision in `AIManagerSourceRevision` and marks
uncommitted source in `AIManagerSourceDirty`. The default build uses an ad hoc
signature. Set `AI_MANAGER_SIGNING_IDENTITY` only when a maintainer explicitly
provides a signing identity.
