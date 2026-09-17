# Monochrome provider glyphs

These 21 marks are vendored unchanged from `@lobehub/icons-static-svg` version
1.90.0, retrieved 2026-09-17. Source URLs use the pinned version:
`https://unpkg.com/@lobehub/icons-static-svg@1.90.0/icons/<slug>.svg`.
The package's MIT license is included in `LICENSE-LobeHub.txt`. Brand marks remain
the trademarks of their owners and identify the corresponding tool or provider.

| Tool or provider | Local SVG slug | Account support |
| --- | --- | --- |
| Codex CLI | codex | Enabled |
| Claude Code | claudecode | WIP |
| Gemini CLI | gemini | WIP |
| Antigravity CLI | antigravity | WIP |
| OpenAI | openai | Artwork only |
| Claude | claude | Artwork only |
| Grok Build | grok | Artwork only |
| xAI | xai | Artwork only |
| Cursor | cursor | Artwork only |
| GitHub Copilot | githubcopilot | Artwork only |
| Microsoft Copilot | copilot | Artwork only |
| Cline | cline | Artwork only |
| Windsurf | windsurf | Artwork only |
| OpenCode | opencode | Artwork only |
| Amp | amp | Artwork only |
| Goose | goose | Artwork only |
| DeepSeek | deepseek | Artwork only |
| Qwen | qwen | Artwork only |
| Mistral | mistral | Artwork only |
| Ollama | ollama | Artwork only |
| Perplexity | perplexity | Artwork only |

`scripts/build-icons.sh` generates 64-pixel PNGs from the unchanged SVGs using the
existing `rsvg-convert`. This avoids macOS CoreSVG rendering differences, including
Gemini's clipped shape. The menu renderer loads each PNG once, caches its native
image, and composites
remaining percentages for at most four enabled accounts into one template image,
with one 12-point glyph per service. Service order follows the first included account
in the saved sidebar order; percentages retain account order within each service.
macOS tints the complete image for menu-bar appearance and selection. No runtime
icon dependency or asset download is required. Extra catalog entries do not
change provider availability.

The outlined double check adapts Ionicons `checkmark-done-outline.svg` in native
SwiftUI, completing the second check's long arm rather than omitting its overlap.
Original source:
https://raw.githubusercontent.com/ionic-team/ionicons/main/src/svg/checkmark-done-outline.svg
Its MIT license is included at `../LICENSE-Ionicons.txt`.
