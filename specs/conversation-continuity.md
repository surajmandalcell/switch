# Account and conversation continuity

## Contract and proof

Account switching, local history, native resume, and a new model response are separate results. Usage-token selection does not switch a native app. Retained files cannot grant cloud access.

Proof classes:

- **Storage:** A synthetic switch changes auth identity, retains history content/IDs, and preserves unrelated files/rows.
- **Native load:** The versioned real tool loads the original session and prior user/assistant/tool content.
- **Model turn:** The selected account completes a new response in that session.

Unit tests, stubs, file existence, and usage responses cannot prove native continuation. Unsupported actions must fail without data changes.

## Tool coverage

| Tool | Native auth and history boundary | Switch scope and remaining limit |
|---|---|---|
| Droid | Login; `--resume <id>`; `.factory/sessions/<project>/<id>.jsonl` has an organization header. [CLI][droid] | Auth snapshot plus original-ID header binding. Isolated native loader proof exists; cloud missions and model continuation remain separate. |
| Codex | File-backed `CODEX_HOME/auth.json`; sessions, archives, indexes, and state DBs share the home. [Auth][codex] | Auth-only replacement preserves files. Running processes can cache identity. Development account gates can restrict native visibility/resume; see below. |
| Claude Code | `claude auth login`; separate `CLAUDE_CONFIG_DIR` accounts; `projects/<project>/<id>.jsonl`. [Auth][claude-auth], [sessions][claude] | Stable managed profiles share history links, not credentials/policy caches. Keyless Console profiles outside the config root are not isolated. Native cross-profile load still needs proof. |
| Gemini CLI | `/auth`; `.gemini/tmp/<project>/chats`; registry IDs/Seatbelt can change roots. [Sessions][gemini] | Swaps OAuth/account files; native exact-ID resume unproved. |
| OpenCode | `auth login/logout`; legacy auth.json or current DB credentials; local JSON history or opencode.db session rows. [CLI][opencode] | Legacy selected JSON member only. Different database-owned login fails closed; stale JSON cannot restore a logged-out DB account. No successful OpenCode 2 account switch claim. |
| Grok Build | OAuth; `--resume <id>`; `.grok/sessions` by workspace. [Sessions][grok] | Auth-only shared-home switch; native resume unproved. `--session-id` creates a new session. |
| GitHub Copilot | File-backed integrations differ from CLI `/login`. CLI uses COPILOT_HOME/session-state and session-store.db; synced data belongs to an account. [Session data][copilot] | Legacy apps.json only; [auth.db-based clients][copilot-auth-store] refuse switching without mutation. CLI Cleanup is not CLI account switching. |
| Cursor | Editor login/SQLite history differs from CLI `agent login`/local chats and cloud agents. [Auth][cursor] | Selected editor state.vscdb auth rows only; no CLI account switch. |
| Windsurf / Devin Desktop | Native logout/login; `.codeium/windsurf/cascade` retains local conversations/settings. [Official troubleshooting][windsurf] | Usage session bundle or local plan reader only. No native account switch or cross-account Cascade load proof. |
| Amp | `amp account list/switch`; accounts separate per server; existing processes keep starting identity. Threads have server access rules. [CLI][amp], [threads][amp-threads] | Usage token only. Native switching is documented but not integrated; exports/sharing do not prove private-thread transfer. |
| Kimi Code CLI | `kimi login/logout`; local `--continue/--session`. [Sessions][kimi] | Swaps default/custom KIMI_CODE_HOME auth; native resume unproved. Usage device ID still uses default home. |
| Kiro CLI | `kiro-cli login/logout`; local resume and separate managed cloud sessions. [CLI][kiro] | Swaps selected local data.sqlite3 auth/profile rows. Kiro IDE/Web and managed-session ownership remain separate. |
| Cline | Local resumable tasks; Cline OAuth, ClinePass, provider keys, or local models. [Tasks][cline] | ClinePass usage only. No task/account adapter; extension-owned Secret Storage stays outside Switch. |
| Roo Code | Local tasks/profiles; editor secrets. [Profiles][roo] | Unsupported; official project archived. |
| Aider | Provider keys; `.aider.chat.history.md`, `--restore-chat-history`. [Config][aider] | Unsupported; no Aider-owned login to switch. |
| Continue | `/login`; model configs/secrets differ; `cn --resume`. [CLI][continue] | Unsupported; no cloud-history transfer promise. |
| Augment / Auggie | AUGMENT_SESSION_AUTH; --session-dir; --cloud uses Cosmos. [CLI][augment] | Cookie usage only; no CLI switch or Cosmos transfer. |
| Qwen Code | QwenCloud/ModelStudio/API; local `/resume`. [Auth][qwen] | Usage only; Qwen OAuth retired. |
| CodeRabbit | PR/IDE/CLI reviews. [CLI][coderabbit] | Unsupported; reviews are not agent conversations. |
| Pi coding agent | `.pi/agent/auth.json`; branched JSONL sessions; `/resume`. [Sessions][pi] | Session usage reader only; no credential switch. |
| Antigravity CLI | `agy`; SSH file token vs local keyring; `--conversation <id>` or -c; workspace cache is not the conversation. [Auth][agy-auth], [resume][agy] | Swaps `.gemini/antigravity-cli/antigravity-oauth-token`, login uses SSH_TTY=1. Cache retention is storage proof only; backend verifies the ID before loading. |

## Ten selected storage-switch contracts

These requirements do not claim ten working native continuations. Tests call public Switch operations with synthetic accounts/isolated homes, then compare complete history content.

| Provider | Required auth and history assertions |
|---|---|
| Droid | Both directions preserve ID/body/settings/owner/dates; only eligible header organization changes. Writer/recovery conflicts retain data. |
| Codex | Only auth changes; retain all history/config/DB content; capture rotated outgoing auth; version native scope tests. |
| Claude Code | Profile identity changes; auth/policy stay separate; shared complete transcripts survive link repair/migration. |
| Grok Build | Auth changes; exact IDs, user/assistant/tool chain, sidecars, and settings remain. |
| Gemini CLI | OAuth/account files change; JSON/JSONL project histories and registry/runtime state remain; check custom roots. |
| Cursor editor | Selected auth rows change; all unrelated global/workspace rows and chats remain; CLI identity stays separate. |
| Copilot file-backed integration | Legacy apps.json changes; history stays. If auth.db exists, refuse without changing auth/default/history. No current CLI or keyring switch claim. |
| Kimi Code | Default/custom-root auth changes; parsed state/wire history, index, and device ID remain; unsafe roots fail closed. |
| Kiro CLI | Only auth/profile rows change; local sessions/unrelated DB state remain; no cloud transfer. |
| Antigravity CLI | SSH_TTY file token changes; cache/conversation fixtures remain; cached ID is not backend authorization. |

Storage tests exist; only Droid has isolated native loader evidence. Other native continuations remain unproved.

## Native and cloud limits

**Droid:** Discover destination organization from one disposable empty native session. Binding never resumes a user session or sends a model request. Skip active writers, unsafe/malformed paths, and cloud missions/descendants. Keep recovery copies on conflicts and earlier copied histories separate. [Peer source][droid-peer] supports header-edit precedent, not cloud transfer; its Keychain handling is excluded.

**Codex:** Development SHA `faeb379646bdbad016e11f7c9ca91113cad4bc9d` adds creator IDs and scoped [discovery][codex-scope]. [Resume checks][codex-check] cover ID/path and loaded attachment for codex-tui/codex_exec with ChatGPT auth. [cli_resume_account_check][codex-feature] is under development and default-disabled. Release 0.167.0 (`086ccc833bc9cf01024ad2dd6af7dbd421b6bf9a`) lacks those modules/feature. Do not infer installed-release failures. Never rewrite creator IDs/private ownership DB fields. On native refusal, retain ownership and offer the original account or a verified native copy/import route.

**Amp:** AMP_API_KEY overrides saved accounts. Creator JSON export/read-only sharing do not transfer ownership. Switch must not change Contribute permissions during selection. No local cache override was established.

**Antigravity:** -c reads workspace-keyed `.gemini/antigravity-cli/cache/last_conversations.json`, then queries the backend. Missing IDs can start fresh. Native App import clones context after confirmation; it does not transfer ownership. Local keyring auth is outside the file-mode adapter.

## Security and recovery

Lock targets; validate identity/complete auth; capture outgoing refreshes; stage, back up, atomically replace, verify, then commit metadata. Recover without losing newer data. Never link live auth to saved records or revoke logins during saved-auth switching. Environment credentials/cached processes can mask file changes.

Auth-only switches preserve non-auth state and unrelated JSON/SQLite entries. Droid binding has separate recovery checks and reads opaque login bytes; browser/OS-store extraction stays outside this feature. Tests use synthetic auth/transcripts and isolated data-drive roots.

## Upstream usage scope

CodexBar SHA `897bff31731bb4b21b105f6e8bf4c32a8a8bf095` declares 111 IDs; the import baseline is unknown. Seven fixture-backed fixes cover Bedrock, LiteLLM, Perplexity, WorkBuddy, Grok, OpenCode, and Copilot. Abliteration/Soniox add API-key usage. Preserve the root MIT notice. No full parity claim.

Excluded additions: fal, FLORA, FutureAGI, Munito, Chatbox, Claude Platform, MuseAI, OpenDesign, Parallel, Trae CN, OpenCode, CodeRabbit. Auth/billing contracts need separate work. Kiro chat probes do not apply. Safe Storage/browser imports, Kimi gift details, compressed Codex archives, and extra pricing tiers are unclaimed. Inventory: `$AGENT_DATA_DIR/switch/upstream-audit/manifest.json`.

[droid]: https://docs.factory.com/droid-cli/cli-reference
[droid-peer]: https://github.com/shariqriazz/droid-switcher/blob/d25a27baa29c02ed0182dbf9b540930e56240928/internal/switcher/sessions.go
[codex]: https://learn.chatgpt.com/docs/auth
[codex-scope]: https://github.com/openai/codex/blob/faeb379646bdbad016e11f7c9ca91113cad4bc9d/codex-rs/thread-store/src/local_history_account.rs
[codex-check]: https://github.com/openai/codex/blob/faeb379646bdbad016e11f7c9ca91113cad4bc9d/codex-rs/app-server/src/request_processors/thread_resume_account.rs
[codex-feature]: https://github.com/openai/codex/blob/faeb379646bdbad016e11f7c9ca91113cad4bc9d/codex-rs/features/src/lib.rs#L1122
[claude-auth]: https://code.claude.com/docs/en/authentication#log-in-with-multiple-accounts
[claude]: https://code.claude.com/docs/en/sessions
[gemini]: https://geminicli.com/docs/cli/session-management/
[opencode]: https://opencode.ai/docs/cli/
[grok]: https://docs.x.ai/build/features/sessions
[copilot]: https://docs.github.com/en/copilot/concepts/security-governance-and-network-settings/session-data
[copilot-auth-store]: https://github.com/github/copilot.vim/issues/284
[cursor]: https://cursor.com/docs/cli/reference/authentication
[windsurf]: https://docs.devin.ai/desktop/troubleshooting/windsurf-common-issues
[amp]: https://ampcode.com/docs/cli#manage-cli-accounts
[amp-threads]: https://ampcode.com/docs/threads
[kimi]: https://github.com/MoonshotAI/kimi-code/blob/main/docs/en/guides/sessions.md
[kiro]: https://kiro.dev/docs/cli/reference/cli-commands/
[cline]: https://docs.cline.bot/core-workflows/task-management
[roo]: https://github.com/RooCodeInc/Roo-Code/blob/main/apps/docs/docs/features/api-configuration-profiles.mdx
[aider]: https://aider.chat/docs/config/aider_conf.html
[continue]: https://docs.continue.dev/cli/tui-mode
[augment]: https://docs.augmentcode.com/cli/reference
[qwen]: https://github.com/QwenLM/qwen-code/blob/main/docs/users/configuration/auth.md
[coderabbit]: https://www.coderabbit.ai/cli
[pi]: https://github.com/earendil-works/pi/blob/main/packages/coding-agent/docs/sessions.md
[agy-auth]: https://antigravity.google/docs/install/
[agy]: https://antigravity.google/docs/cli/commands/resume
