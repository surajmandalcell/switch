# Provider icons

The 96 `ProviderIcon-<id>.svg` files are vendored unchanged from CodexBar
(`Sources/CodexBar/Resources`, https://github.com/steipete/CodexBar). Their MIT
license is in `LICENSE-CodexBar.txt`. Brand marks remain the trademarks of their owners
and only identify the matching provider.

The marks are monochrome (`currentColor`). Switch renders them as template images, so
macOS tints them for the current appearance. `AIManagerBrand.providerIcon(for:)` loads
each file once, on first use, and caches the image. It tries the older `ProviderGlyphs`
first, then the file named by the provider id or by `providerIconAliases` (for example
`gemini-cli` uses `ProviderIcon-gemini.svg`), then a monogram. `scripts/check-icon-assets.sh`
and the Mac GUI contract check every file.
