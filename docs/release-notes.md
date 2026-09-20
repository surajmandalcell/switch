Switch is a native macOS app for keeping multiple AI coding-tool accounts ready
and switching the account used by new sessions.

This release adds Grok Build subscription-account switching through the
official CLI's OAuth login and `~/.grok/auth.json`. It also includes Codex usage
limits, token activity, conversation history, imports, and Cleanup.

Download the Mac ZIP, unzip it, and move `Switch.app` to Applications. Switch
requires macOS 14 or later on Apple Silicon. Install Codex CLI or Grok Build for
the provider you use. Grok Build does not expose subscription quota data to
Switch, so Grok support is account switching only.

The release also includes the `@smdl/switch` npm package for terminal use.
