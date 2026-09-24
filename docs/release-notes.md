Switch is a native macOS app for keeping multiple AI coding-tool accounts ready
and switching the account used by new sessions.

This release adds a compact fan row to the menu-bar popover. It shows live RPM and
percentage of maximum speed, with a contiguous Auto, Cool, and Max control matching
Switch's Ivory and Espresso popover styles. Fan sensors are read only while the
popover is visible, on a three-second cadence, so the feature adds no idle polling.

Monitoring works directly through the Mac's SMC. Fan writes remain read-only unless
the optional smctl daemon is available; when enabled, Switch uses smctl's verified,
thermal-guarded control path instead of writing fan state directly.

This release also retains the idle CPU fix, three-minute usage refresh, Open at Login,
provider-scoped defaults, and the custom grouped controls added in 3.1.x.

Download the Mac ZIP, unzip it, and move `Switch.app` to Applications. Switch
requires macOS 14 or later on Apple Silicon. Install Codex CLI or Grok Build for
the provider you use. Grok Build does not expose subscription quota data to
Switch, so Grok support is account switching only.

The terminal interface remains available through the `@smdl/switch` npm package.
