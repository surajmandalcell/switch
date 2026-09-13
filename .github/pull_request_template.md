## Summary

Describe the user-visible Switch behavior.

## Validation

- [ ] `scripts/check-native.sh`
- [ ] `scripts/build-native.sh`
- [ ] `git diff --check`
- [ ] No credentials, transcripts, private config, backups, or build output

## Safety

- [ ] Source Codex homes remain unchanged by tests.
- [ ] Credential bytes stay out of logs, errors, process arguments, and docs.
- [ ] Recovery behavior is preserved for every mutation.
- [ ] Mac GUI and CLI use the same core operation and contract.
