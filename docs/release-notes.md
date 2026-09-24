Switch is a native macOS app for keeping multiple AI coding-tool accounts ready
and switching the account used by new sessions.

This release fixes the idle CPU spikes caused by Chat History reacting to unrelated
provider-home writes and repeatedly rereading growing transcripts. Switch now filters
and coalesces relevant file events, resumes JSONL parsing from a verified append
boundary, and reapplies thread metadata only when it changes.

Usage in the app and menu bar still refreshes at launch and every three minutes.
Open at Login and the compact Switch grouped controls remain available in Settings.

Download the Mac ZIP, unzip it, and move `Switch.app` to Applications. Switch
requires macOS 14 or later on Apple Silicon. Install Codex CLI or Grok Build for
the provider you use. Grok Build does not expose subscription quota data to
Switch, so Grok support is account switching only.

The terminal interface remains available through the `@smdl/switch` npm package.
