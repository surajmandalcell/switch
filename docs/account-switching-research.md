# Account switching and upstream review

## Droid continuity

Native resume looks up the original session UUID. The retired copy engine created another UUID,
so resuming the original still read its old organization. Switch now binds original local session
headers after authentication changes. It keeps paths, UUIDs, owner, settings, body bytes, and dates.
One disposable native session supplies the target organization. A wrapper around resume was
rejected because Orca, Factory, and plain shell commands can bypass Switch.

The community [droid-switcher implementation](https://github.com/shariqriazz/droid-switcher/blob/d25a27baa29c02ed0182dbf9b540930e56240928/internal/switcher/sessions.go)
also rewrites the first header and streams the body into the same path. Its default removes the
organization field; Switch explicitly sets the target organization. This is community precedent,
not a Factory-supported cloud transfer. Switch does not borrow its Keychain repair or its
move-and-delete migration. Cloud missions and their descendants remain owned by their creator.
Earlier copies remain separate histories; this repair never merges or deletes them.

| Provider | Switch boundary | History behavior |
| --- | --- | --- |
| Droid | Replace saved authentication, then bind local organization headers | Original UUIDs and files stay; active writers block changes |
| Codex | Replace only live `auth.json` | One shared home; running processes can cache authentication |
| Grok Build | Replace only live `auth.json` | Sessions and settings stay; requests can reload authentication |
| Claude Code | Select the managed profile | Shared history links; credentials and policy caches remain per profile |

## CodexBar upstream

Reviewed [CodexBar revision 897bff3](https://github.com/steipete/CodexBar/tree/897bff31731bb4b21b105f6e8bf4c32a8a8bf095),
which declares 111 provider IDs. Switch has no recorded original import revision, so this is a
provider inventory and targeted correctness audit, not a complete commit-range merge.

The update covers missing Bedrock data, LiteLLM member budgets, Perplexity organization credits,
WorkBuddy reward expiry, Grok unknown usage, OpenCode active login selection, and Copilot
ended-subscription diagnostics. Each change has a synthetic regression fixture. Abliteration
and Soniox add explicit API-key usage checks; their authentication does not require browser or
Keychain access. The root MIT notice includes the CodexBar copyright for compiled distribution.

Other new upstream providers are not part of these two additions:

| Authentication | Providers | Additional boundary to verify |
| --- | --- | --- |
| API or license key | fal, FLORA, FutureAGI, Munito, Chatbox | Provider-specific billing and workspace or license validation |
| Pasted cookie | Claude Platform, MuseAI, OpenDesign, Parallel, Trae CN, OpenCode | Session expiry, organization selection, and private dashboard schemas |
| Official CLI | CodeRabbit | File-backed account identity and bounded, stateless probing |

Kiro chat-probe fixes do not apply: Switch already reads the usage API directly. Cursor Safe
Storage decryption and automatic browser-cookie import remain excluded by the credential policy.
Kimi gift breakdown, Codex compressed archives, and additional pricing tiers are separate
capabilities; this update does not claim them. The earlier Codex review below remains pinned
to its stated source versions.

## Earlier Codex source review

Research date: 2026-09-13

## Decision

Switch keeps one live Codex home at `~/.codex`. It stores one complete
authentication record per account at `~/.switch/codex/<account-UUID>.json` and
atomically copies the selected record over `~/.codex/auth.json`. It leaves config,
instructions, skills, hooks, sessions, history, indexes, and databases unchanged.

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
   session records. This is intentional for Switch.

The live file is deliberately not a symbolic link. Current Codex opens
`auth.json` with truncate-and-write, so a link happens to receive token refreshes
today. That also lets `codex login` overwrite whichever saved account the link
targets. Logout can remove the link, and a future atomic writer could replace the
link itself. A regular live file plus outgoing refresh capture avoids all three
failure modes.

## Official Codex contract

The current official documentation describes `auth.json` as the file credential
store inside `CODEX_HOME`, with file, Keychain, automatic, and ephemeral storage
modes. It documents `config.toml`, instructions, and other configuration as
separate state. The implementation below is pinned so later Codex changes can be
reviewed against the exact behavior used for this decision.

- [Authentication documentation](https://developers.openai.com/codex/auth)
- [Configuration basics](https://developers.openai.com/codex/config-basic)
- [Advanced configuration](https://developers.openai.com/codex/config-advanced)
- [Codex 0.154.0 release](https://github.com/openai/codex/releases/tag/rust-v0.154.0)

The source review was refreshed against OpenAI Codex commit
[`7efa9d96`](https://github.com/openai/codex/commit/7efa9d96fb34c3cafe108a3c870bfc33e5635772).

- [`AuthDotJson`](https://github.com/openai/codex/blob/7efa9d96fb34c3cafe108a3c870bfc33e5635772/codex-rs/login/src/auth/storage.rs)
  is one complete active auth record for a `CODEX_HOME`.
- [`create_auth_storage`](https://github.com/openai/codex/blob/7efa9d96fb34c3cafe108a3c870bfc33e5635772/codex-rs/login/src/auth/storage.rs)
  selects file, Keychain, automatic, or ephemeral storage. Automatic storage
  prefers Keychain when available.
- [`FileAuthStorage`](https://github.com/openai/codex/blob/7efa9d96fb34c3cafe108a3c870bfc33e5635772/codex-rs/login/src/auth/storage.rs)
  resolves the file as `CODEX_HOME/auth.json`, creates it with mode `0600`, and
  currently saves with `truncate(true)`, `write(true)`, and `create(true)`.
- [`AuthManager`](https://github.com/openai/codex/blob/7efa9d96fb34c3cafe108a3c870bfc33e5635772/codex-rs/login/src/auth/manager.rs)
  caches auth. External file changes do not update a running manager until it
  reloads.
- [`same_owner`](https://github.com/openai/codex/blob/7efa9d96fb34c3cafe108a3c870bfc33e5635772/codex-rs/login/src/auth/change_state.rs)
  compares auth mode, ChatGPT user ID, and workspace account ID. Missing owner
  fields do not count as equality.
- [`history.jsonl`](https://github.com/openai/codex/blob/7efa9d96fb34c3cafe108a3c870bfc33e5635772/codex-rs/message-history/src/lib.rs)
  stores prompt history under `CODEX_HOME` independently of auth.
- [`sessions`](https://github.com/openai/codex/blob/7efa9d96fb34c3cafe108a3c870bfc33e5635772/codex-rs/rollout/src/recorder.rs)
  stores full transcripts under `CODEX_HOME/sessions` independently of auth.
- [`state` databases](https://github.com/openai/codex/blob/7efa9d96fb34c3cafe108a3c870bfc33e5635772/codex-rs/state/src/sqlite.rs)
  include thread, log, goal, and memory SQLite files under `CODEX_HOME`.
- [`codex login`](https://github.com/openai/codex/blob/7efa9d96fb34c3cafe108a3c870bfc33e5635772/codex-rs/cli/src/login.rs)
  clears and revokes the old credential before sign-in. It is not a safe saved
  account switch operation.

OpenAI merged account-session protocol data types, but current main does not
register or implement the switch routes. The related lifecycle
[`PR #25383`](https://github.com/openai/codex/pull/25383) closed without merge.
Switch cannot depend on that proposed interface.

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
- [CodexSwitch](https://github.com/ScWen7/CodexSwitch/tree/65469fc42160ae89a16c8829dd9babe2950d569e)
  keeps saved profiles under `~/.codex-switch`, then uses backup, temporary-file,
  and rename steps to replace the regular live auth file.
- [codex-accounts](https://github.com/omarhoumz/codex-accounts/tree/9f636ab11d3e1b33ced4c8909ce0cf368ca0aaeb)
  intentionally uses a live symlink for refresh write-through, but documents that
  running `codex login` can overwrite the active saved account through that link.

## Switch safety contract

1. Lock each target home before inspection or mutation.
2. Reject an unresolved owner. For ChatGPT, compare auth mode,
   `chatgpt_user_id`, and `chatgpt_account_id`.
3. Re-read and save refreshed outgoing credentials before switching.
4. Validate and stage the complete incoming auth record from
   `~/.switch/codex/<account-UUID>.json`.
5. Back up, atomically replace, verify, then commit registry metadata.
6. Roll back auth and metadata after any interrupted phase.
7. Never call login or logout during a switch. Switching must not revoke access.
8. Never modify non-auth files during an auth-only switch, and never link the
   live credential to a saved record.
9. Refuse a default-home mutation while an identified Codex writer is active.
10. Test only with synthetic credentials and isolated temporary homes.

The review inspected source and vendor documentation. It did not install third-
party binaries, use real accounts, access Keychain, or call private usage APIs.
