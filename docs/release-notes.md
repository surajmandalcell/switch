Switch is a native macOS app for keeping multiple AI coding-tool accounts ready
and switching the account used by new sessions.

This release adds an Open at Login setting backed by the macOS login-item service.
When enabled, Switch starts quietly in the menu bar after sign-in. Normal launches
still open the main window, and Settings links to Login Items when macOS requires
approval.

The token-period controls now use the same compact Switch styling in the main
window and Settings, with clear selected, hover, focus, pressed, and disabled states.

Download the Mac ZIP, unzip it, and move `Switch.app` to Applications. Switch
requires macOS 14 or later on Apple Silicon. Install Codex CLI or Grok Build for
the provider you use. Grok Build does not expose subscription quota data to
Switch, so Grok support is account switching only.

The terminal interface remains available through the `@smdl/switch` npm package.
