# Switch instructions

For implementation, tests, UI, packaging, or documentation, read `goals.md` when present.
It is the ignored local active ledger. Move old completed detail to the adjacent
`goals.archive.md`; the `dev-workflow` skill owns this convention.

The existing Electron gateway and its provider, routing, platform, and branch-cleanup requirements are legacy.
Where they conflict with `goals.md`, follow the native app plan.
Preserve general security and data-recovery requirements from the existing documents.

Use synthetic credentials and temporary homes for automated tests.
Never commit real auth, transcripts, private config, or workstation backups.

## Branches, PRs, and releases

Never push to `master`. Put each change on a short feature branch and merge it
through a PR that fills `.github/pull_request_template.md`. This rule allows
those branches. After app or shared-core changes, rebuild and test the matching
CLI and update the installed commands; do not publish per change.

Ship feature releases (`X.Y.0`). Ship a patch release only for a real
production bug. Each release has a GitHub milestone with its PRs, a
version-bump PR, a release issue from `.github/ISSUE_TEMPLATE/release.md`, a
tag, and a GitHub Release with notes. The `@smdl/switch` npm CLI ships with the
same release. At release time, verify the registry version and a fresh package
install. Keep required signing, notarization, validation, and password or OTP stops.
Versions shown on the site come from api.samhq.app/v1/releases; the release
script runs samhq_backend/scripts/publish-release.zsh `--no-upload`, which updates and pushes
releases.json and the Homebrew cask.

Do not execute or push the inherited remote branch-deletion workflow.
Remove that workflow behavior in G1 before an implementation push.
