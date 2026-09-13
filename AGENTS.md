# Switch instructions

For implementation, tests, UI, packaging, or documentation, read [goals.md](goals.md) first.
It owns the current native macOS Codex account-manager scope and acceptance gates.

The existing Electron gateway and its provider, routing, platform, and branch-cleanup requirements are legacy.
Where they conflict with `goals.md`, follow the native app plan.
Preserve general security and data-recovery requirements from the existing documents.

Use synthetic credentials and temporary homes for automated tests.
Never commit real auth, transcripts, private config, or workstation backups.
Do not access the user's login Keychain for account discovery or testing.

Work on the existing branch. Do not execute or push the inherited remote branch-deletion workflow.
Remove that workflow behavior in G1 before an implementation push.
Record completed milestones and their verification in `goals.md`.
