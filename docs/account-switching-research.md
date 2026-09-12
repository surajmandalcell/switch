# Codex account-switching research

Research date: 2026-09-12

## Decision

IIA Directeur will change only the complete active authentication record. It will
leave config, instructions, skills, hooks, sessions, history, indexes, and
databases in the selected `CODEX_HOME` unchanged.

This is the dominant design among current open-source Codex account switchers.
Eight of the ten inspected tools replace only authentication. One isolates a
complete home per account. One offers both an auth-only switch and a hybrid
launch mode.

The auth-only model has three strict limits:

1. It supports file-backed ChatGPT authentication. A Keychain or higher-priority
   environment credential can mask `auth.json`.
2. The switch applies to new Codex processes. A running process caches its
   current identity and must reload or restart.
3. Shared history means every managed account can see the same local chat and
   session records. This is intentional for IIA Directeur.

## Official Codex contract

The source review used OpenAI Codex commit
[`53ff712a`](https://github.com/openai/codex/commit/53ff712a48379ce8df605e292afd6046ca88ae9b).

- [`AuthDotJson`](https://github.com/openai/codex/blob/53ff712a48379ce8df605e292afd6046ca88ae9b/codex-rs/login/src/auth/storage.rs#L39)
  is one complete active auth record for a `CODEX_HOME`.
- [`create_auth_storage`](https://github.com/openai/codex/blob/53ff712a48379ce8df605e292afd6046ca88ae9b/codex-rs/login/src/auth/storage.rs#L502)
  selects file, Keychain, automatic, or ephemeral storage. Automatic storage
  prefers Keychain when available.
- [`AuthManager`](https://github.com/openai/codex/blob/53ff712a48379ce8df605e292afd6046ca88ae9b/codex-rs/login/src/auth/manager.rs#L2041)
  caches auth. External file changes do not update a running manager until it
  reloads.
- [`same_owner`](https://github.com/openai/codex/blob/53ff712a48379ce8df605e292afd6046ca88ae9b/codex-rs/login/src/auth/change_state.rs#L15)
  compares auth mode, ChatGPT user ID, and workspace account ID. Missing owner
  fields do not count as equality.
- [`history.jsonl`](https://github.com/openai/codex/blob/53ff712a48379ce8df605e292afd6046ca88ae9b/codex-rs/message-history/src/lib.rs#L51-L66)
  stores prompt history under `CODEX_HOME` independently of auth.
- [`sessions`](https://github.com/openai/codex/blob/53ff712a48379ce8df605e292afd6046ca88ae9b/codex-rs/rollout/src/recorder.rs#L1700-L1721)
  stores full transcripts under `CODEX_HOME/sessions` independently of auth.
- [`state` databases](https://github.com/openai/codex/blob/53ff712a48379ce8df605e292afd6046ca88ae9b/codex-rs/state/src/sqlite.rs#L29-L35)
  include thread, log, goal, and memory SQLite files under `CODEX_HOME`.
- [`codex login`](https://github.com/openai/codex/blob/53ff712a48379ce8df605e292afd6046ca88ae9b/codex-rs/cli/src/login.rs#L122)
  clears and revokes the old credential before sign-in. It is not a safe saved
  account switch operation.

OpenAI merged account-session protocol data types, but current main does not
register or implement the switch routes. The related lifecycle
[`PR #25383`](https://github.com/openai/codex/pull/25383) closed without merge.
IIA Directeur cannot depend on that proposed interface.

## Current tools

| Tool | Signal at review | Model | Shared config and history |
|---|---:|---|---|
| [Loongphy/codex-auth](https://github.com/Loongphy/codex-auth/blob/0fde29598c2e02e28e0e8bcc33a4bb8d45d7b23a/src/registry/account_ops.zig) | 2,667 stars | Copies a saved auth file over live `auth.json` | Yes |
| [Lampese/codex-switcher](https://github.com/Lampese/codex-switcher/blob/9b13442428559f267b418d34a87cc7f0905ad70f/src-tauri/src/auth/switcher.rs) | 761 stars | Captures outgoing auth, then writes selected auth | Yes |
| [Ducksss/codex-profiles](https://github.com/Ducksss/codex-profiles/blob/919df6025e92a1f6bf0c4af2065dcc23836c1793/bin/codex-profile) | 144 stars | Uses a complete `CODEX_HOME` per profile | No, unless selected paths are linked |
| [midhunmonachan/codex-profiles](https://github.com/midhunmonachan/codex-profiles/blob/b41403ad150660ac9fc74d0398e022a254f45990/src/profiles.rs) | 95 stars | Atomically replaces live `auth.json` | Yes |
| [xjoker/codex-switch](https://github.com/xjoker/codex-switch/blob/a3392f6155f137149f44cd3a81337d35ec6739b5/src/profile.rs) | 69 stars | Locks, backs up, and atomically replaces auth | Yes |
| [Sls0n/codex-account-switcher](https://github.com/Sls0n/codex-account-switcher/blob/fad1a4199d448ed9dee7661eab3769aabb15235f/src/lib/accounts/account-service.ts) | 56 stars | Symlinks or copies selected auth | Yes |
| [WoozyMasta/codex-switch](https://github.com/WoozyMasta/codex-switch/blob/05b243315afacfa451f33068e946f4fe266b998c/src/auth/codex-auth-sync.ts) | 17 stars | Preserves rotated auth, then replaces it | Yes |
| [errhythm/cc-swap](https://github.com/errhythm/cc-swap/blob/e5063a319bf5211f67df6351bf2d5d0919a132b8/src/claude_swap/codex.py) | 12 stars | Captures outgoing auth and uses atomic replace | Yes |
| [Sawmills/codexctl](https://github.com/Sawmills/codexctl/blob/fba4c6b5bf46d6b9fa091fbb96441457b479f6d5/src/profile.rs) | 6 stars | Auth-only switch or a linked child home | Yes |
| [sasanktumpati/codex-auth-switcher](https://github.com/sasanktumpati/codex-auth-switcher/blob/433534e46a3e78018851264cf7a7db2df5223b4cdb/internal/manager.go) | 2 stars | Locks, captures, decrypts, and replaces auth | Yes |

The broader product review found the same split:

- [CodexBar](https://codexbar.app/) uses separate homes for managed accounts,
  but its “Promote to System Account” action atomically replaces only live auth.
- [Codex Account Switcher](https://liuzhao1225.github.io/codex-account-switcher/)
  replaces only auth and explicitly tests that config, sessions, and databases
  do not enter profile copies.
- [CodexSwitcher](https://github.com/senoldogann/codex-switcher) replaces
  `~/.codex/auth.json` and reads analytics from shared sessions.
- [Relay](https://github.com/ark-daemon/relay) keeps sessions and databases
  shared but treats config and personalization as account-owned.

## IIA Directeur safety contract

1. Lock each target home before inspection or mutation.
2. Reject an unresolved owner. For ChatGPT, compare auth mode,
   `chatgpt_user_id`, and `chatgpt_account_id`.
3. Re-read and save refreshed outgoing credentials before switching.
4. Validate and stage the complete incoming auth record.
5. Back up, atomically replace, verify, then commit registry metadata.
6. Roll back auth and metadata after any interrupted phase.
7. Never call login or logout during a switch. Switching must not revoke access.
8. Never modify non-auth files during an auth-only switch.
9. Refuse a default-home mutation while an identified Codex writer is active.
10. Test only with synthetic credentials and isolated temporary homes.

The review inspected source and vendor documentation. It did not install third-
party binaries, use real accounts, access Keychain, or call private usage APIs.
