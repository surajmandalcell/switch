# Switch instructions

For implementation, tests, UI, packaging, or documentation, read `goals.md` when present.
It is the ignored local active ledger. Move old completed detail to the adjacent
`goals.archive.md`; the `dev-workflow` skill owns this convention.

The existing Electron gateway and its provider, routing, platform, and branch-cleanup requirements are legacy.
Where they conflict with `goals.md`, follow the native app plan.
Preserve general security and data-recovery requirements from the existing documents.

Use synthetic credentials and temporary homes for automated tests.
Never commit real auth, transcripts, private config, or workstation backups.

After app or shared-core changes, rebuild and test the matching CLI, update the
installed commands, and publish the matching `@smdl/switch` npm version.
The owner authorizes these routine CLI updates without another approval step.
Verify the registry version and a fresh package install before reporting completion.
Keep required signing, validation, and password or OTP stops.

Work on the existing branch. Do not execute or push the inherited remote branch-deletion workflow.
Remove that workflow behavior in G1 before an implementation push.
