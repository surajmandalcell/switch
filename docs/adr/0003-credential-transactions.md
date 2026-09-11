# ADR 0003: Credential transaction order

- Status: Accepted
- Date: 2026-09-11

## Context

Codex credentials, account metadata, settings, and history use separate
files. One file rename cannot commit them as one operation. A crash must not
leave a visible account that points to missing credentials.

## Decision

Use this order for each native account operation:

1. Inspect the source and destination without mutation.
2. Create a private backup of every file that may change.
3. Stage the credential and selected durable data on the destination volume.
4. Validate the staged files, permissions, links, and recognized metadata.
5. Publish the account home.
6. Commit the non-secret registry record.
7. Verify the published identity and record the operation result.

For credential replacement:

- Capture the current credential before replacing it.
- Recheck the destination identity and file contents before commit.
- Publish the incoming credential with private permissions.
- Retain the outgoing credential in the protected backup until recovery is
  no longer needed.

For a failed operation, preserve the old usable state. Restore only files
whose state still matches the failed operation's expected output. If a user
changed a file after the failure, preserve both versions and report a
conflict.

## Results

The registry never points to an unpublished account home. A failed cleanup
may leave a protected backup or staging directory. This is safer than
removing the only known-good credential or history copy.
