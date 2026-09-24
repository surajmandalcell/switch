Switch is a native macOS app for keeping multiple AI coding-tool accounts ready
and switching the account used by new sessions.

This release removes an accidental fan-monitoring and fan-control module that belonged
to another app. Switch no longer opens AppleSMC, talks to smctld, ships fan-control code,
or shows fan controls in its menu-bar popover.

Switch retains the idle CPU fix, three-minute usage refresh, Open at Login,
provider-scoped defaults, and custom grouped controls added in 3.1.x.

Download the Mac ZIP, unzip it, and move `Switch.app` to Applications. Switch
requires macOS 14 or later on Apple Silicon. Install Codex CLI or Grok Build for
the provider you use. Grok Build does not expose subscription quota data to
Switch, so Grok support is account switching only.

The terminal interface remains available through the `@smdl/switch` npm package.
