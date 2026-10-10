Switch is a native macOS app for keeping multiple AI coding-tool accounts ready
and switching the account used by new sessions.

Switch 3.4 adds every usage provider from OpenUsage and CodexBar that works without
the macOS Keychain or browser cookie stores, about 95 in total, and gives each one the
quick account switch.

- Command-line tools such as Gemini CLI, Antigravity CLI, Cursor, GitHub Copilot, Kiro,
  Kimi Code, Kilo, Codebuff, Devin, OpenCode Go, Ollama, and Vertex AI switch by
  swapping only their login file, JSON entry, or database rows. Conversations and
  settings stay. The previous login is saved first and the replaced bytes are backed up.
- API and plan providers such as OpenRouter, z.ai, DeepSeek, MiniMax, Mistral, Groq,
  OpenAI, AWS Bedrock, Warp, and Factory save a key or pasted session per account.
- Grok Build and Claude Code now show usage. Claude Code profiles share one history in
  `~/.claude`, and an optional setting makes a plain `claude` command use the selected
  account.
- Usage pages and menu cards show reset countdowns and a pace color that warns before a
  window runs out. Optional notifications, provider incident dots, and a setting to hide
  email addresses are new.
- The terminal adds `switch usage --json`, `switch guard`, `switch add`, and
  `switch import`.

Hooks, the plugin engine, browser cookie import, widgets, sync, and telemetry from those
apps are left out on purpose.

Download the Mac ZIP, unzip it, and move `Switch.app` to Applications. Switch
requires macOS 14 or later on Apple Silicon.

The terminal interface remains available through the `@smdl/switch` npm package.
