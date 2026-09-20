Switch is a native macOS app for keeping multiple AI coding-tool accounts ready
and switching the account used by new sessions.

This release gives Codex CLI and Grok Build separate default accounts while both
providers continue to use the same switching engine. It also refreshes available
usage data at launch and every three minutes, keeping the main app and menu bar
current without opening the popover. Terminal actions now begin with compact
semantic glyphs for faster scanning.

The README now explains shared account switching first and keeps provider-specific
credentials, session behavior, and feature limits in short provider notes.

Download the Mac ZIP, unzip it, and move `Switch.app` to Applications. Switch
requires macOS 14 or later on Apple Silicon. Install Codex CLI or Grok Build for
the provider you use. Grok Build does not expose subscription quota data to
Switch, so Grok support is account switching only.

The terminal interface remains available through the `@smdl/switch` npm package.
