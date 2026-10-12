# Provider brand marks

Official provider logos that `ProviderMark` draws on each brand's tile (`AIManagerBrand.providerBrands`
holds the same table). The marks are 24-unit vectors: `<key>.pdf`, plus `<key>-mono.pdf` (the official
single-color mark, used by the small glyph) when the main mark is multicolor. `antigravity.png` is a
384-pixel PNG because its SVG uses mask and blur filters that PDF export drops.

Sources, retrieved 2026-10-13:

- Lobe Icons, npm `@lobehub/icons-static-svg` 1.90.0, MIT (`../ProviderGlyphs/LICENSE-LobeHub.txt`).
- Simple Icons, npm `simple-icons` 16.35.0, CC0-1.0.
- Brand site icons, for providers that have neither: `https://kiro.dev/icon.svg`,
  `https://devin.ai/favicon.svg`, `https://factory.ai/favicon.svg`, `https://augmentcode.com/favicon.svg`.
  The tile rectangle was removed from Kiro and Factory so every tile shares one size and padding.

Rebuild: copy the source SVG, set `width`/`height` to 24, then
`rsvg-convert -f pdf -o <key>.pdf <svg>`. Tiles share one size scale, a corner radius of size x 0.22, and
an inset of size x 0.2. All marks remain trademarks of their owners and only identify the provider.

| Provider id | Source | License | Tile look |
| --- | --- | --- | --- |
| codex | Lobe Icons `openai` | MIT | black on white; white on black in Dark Mode |
| openai | Lobe Icons `openai` | MIT | black on white; white on black in Dark Mode |
| azureopenai | Lobe Icons `azure-color` | MIT | own colors on #FFFFFF |
| claude-code | Lobe Icons `claude-color` | MIT | own colors on #FAF9F5 |
| gemini-cli | Lobe Icons `gemini-color` | MIT | own colors on #FFFFFF |
| antigravity-cli | Lobe Icons `antigravity-color` | MIT | own colors on #FFFFFF |
| grok-build | Lobe Icons `grok` | MIT | black on white; white on black in Dark Mode |
| xai | Lobe Icons `xai` | MIT | black on white; white on black in Dark Mode |
| xapi | Simple Icons `x` | CC0-1.0 | black on white; white on black in Dark Mode |
| cursor | Lobe Icons `cursor` | MIT | black on white; white on black in Dark Mode |
| windsurf | Lobe Icons `windsurf` | MIT | black on white; white on black in Dark Mode |
| copilot | Lobe Icons `githubcopilot` | MIT | black on white; white on black in Dark Mode |
| clinepass | Lobe Icons `cline` | MIT | black on white; white on black in Dark Mode |
| amp | Lobe Icons `amp-color` | MIT | own colors on #FFFFFF |
| opencodego | Lobe Icons `opencode` | MIT | black on white; white on black in Dark Mode |
| kilo | Lobe Icons `kilocode` | MIT | black on white; white on black in Dark Mode |
| deepseek | Lobe Icons `deepseek-color` | MIT | own colors on #FFFFFF |
| qwencloud | Lobe Icons `qwen-color` | MIT | own colors on #FFFFFF |
| alibaba | Lobe Icons `alibabacloud-color` | MIT | own colors on #FFFFFF |
| alibabatokenplan | Lobe Icons `bailian-color` | MIT | own colors on #FFFFFF |
| mistral | Lobe Icons `mistral-color` | MIT | own colors on #FFFFFF |
| ollama | Lobe Icons `ollama` | MIT | black on white; white on black in Dark Mode |
| perplexity | Lobe Icons `perplexity-color` | MIT | own colors on #FFFFFF |
| groq | Lobe Icons `groq` | MIT | #FFFFFF mark on #F55036 tile |
| huggingface | Lobe Icons `huggingface-color` | MIT | own colors on #FFFFFF |
| vercel | Lobe Icons `vercel` | MIT | black on white; white on black in Dark Mode |
| v0 | Lobe Icons `v0` | MIT | black on white; white on black in Dark Mode |
| replicate | Lobe Icons `replicate` | MIT | black on white; white on black in Dark Mode |
| elevenlabs | Lobe Icons `elevenlabs` | MIT | black on white; white on black in Dark Mode |
| notion | Lobe Icons `notion` | MIT | black on white; white on black in Dark Mode |
| poe | Lobe Icons `poe-color` | MIT | own colors on #FFFFFF |
| raycast | Simple Icons `raycast` | CC0-1.0 | #FFFFFF mark on #FF6363 tile |
| warp | Simple Icons `warp` | CC0-1.0 | #FFFFFF mark on #01A4FF tile |
| deepgram | Simple Icons `deepgram` (fill #13EF93) | CC0-1.0 | own colors on #0A0A0A |
| gitkraken | Simple Icons `gitkraken` (fill #179287) | CC0-1.0 | own colors on #FFFFFF |
| jetbrains | Simple Icons `jetbrains` | CC0-1.0 | black on white; white on black in Dark Mode |
| zed | Simple Icons `zedindustries` (fill #084CCF) | CC0-1.0 | own colors on #FFFFFF |
| openrouter | Simple Icons `openrouter` (fill #94A3B8) | CC0-1.0 | own colors on #FFFFFF |
| kimi | Lobe Icons `kimi-color` (white fill recolored black) | MIT | own colors on #FFFFFF |
| kimi-api | Lobe Icons `kimi-color` (white fill recolored black) | MIT | own colors on #FFFFFF |
| moonshot | Lobe Icons `kimi-color` (white fill recolored black) | MIT | own colors on #FFFFFF |
| minimax | Lobe Icons `minimax-color` | MIT | own colors on #FFFFFF |
| stepfun | Lobe Icons `stepfun-color` | MIT | own colors on #FFFFFF |
| tavily | Lobe Icons `tavily-color` | MIT | own colors on #FFFFFF |
| venice | Lobe Icons `venice-color` | MIT | own colors on #FFFFFF |
| vertexai | Lobe Icons `vertexai-color` | MIT | own colors on #FFFFFF |
| bedrock | Lobe Icons `bedrock-color` | MIT | own colors on #FFFFFF |
| doubao | Lobe Icons `doubao-color` | MIT | own colors on #FFFFFF |
| exa | Lobe Icons `exa-color` | MIT | own colors on #FFFFFF |
| fireworks | Lobe Icons `fireworks-color` | MIT | own colors on #FFFFFF |
| deepinfra | Lobe Icons `deepinfra-color` | MIT | own colors on #FFFFFF |
| longcat | Lobe Icons `longcat-color` | MIT | own colors on #FFFFFF |
| qoder | Lobe Icons `qoder-color` | MIT | own colors on #FFFFFF |
| atlascloud | Lobe Icons `atlascloud` | MIT | black on white; white on black in Dark Mode |
| ibmbob | Lobe Icons `ibm` (fill #0F62FE) | MIT | own colors on #FFFFFF |
| zai | Lobe Icons `zai` | MIT | black on white; white on black in Dark Mode |
| manus | Lobe Icons `manus` | MIT | black on white; white on black in Dark Mode |
| nous | Lobe Icons `nousresearch` | MIT | black on white; white on black in Dark Mode |
| mimo | Lobe Icons `xiaomimimo` | MIT | black on white; white on black in Dark Mode |
| zenmux | Lobe Icons `zenmux` | MIT | black on white; white on black in Dark Mode |
| kiro | site icon kiro | Brand site icon | own colors on #9046FF |
| devin | site icon devin | Brand site icon | black on white; white on black in Dark Mode |
| augment | site icon augment | Brand site icon | black on white; white on black in Dark Mode |
| factory | site icon factory | Brand site icon | #FAFAFA mark on #020202 tile |

## No official mark found (keep the template glyph on a neutral tile)

abacus, aerostack, aiand, aixy, bifrost, chutes, clawrouter, codebuff, commandcode, cosmic, devpass,
helmcode, hyper, langdock, linkup, litellm, lithosai, llmman, llmproxy, muse, neuralwatt, pi,
sailresearch, sakana, sofya, sub2api, synthetic, t3chat, tinyapi, typesafe, wayfinder, workbuddy,
xkiro, zoommate. Lobe Icons, Simple Icons, and the brand's own site had no vector logo.
