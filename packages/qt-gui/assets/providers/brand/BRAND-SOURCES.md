# Provider brand icons

`ProviderMark` draws each provider's own icon (`AIManagerBrand.providerBrands` holds the same table).
Three looks, the same in Light and Dark Mode:

- Full icon (`full-<id>.png` or `.pdf`): the brand's own app, apple-touch, or site icon with its real
  background. It fills the tile edge to edge, clipped to the tile corner radius (size x 0.22). Tile
  color in the loader table = the icon's own edge color, so a rounded or circular icon has no gap.
- Mark on a tile (`<name>.pdf`, `.png`): a transparent official mark with 0.2 padding on the brand's
  tile color (white unless listed).
- Template glyph (`<name>-mono.pdf`, or the mark itself): the single-color mark for dense rows and the
  menu bar.

Retrieved 2026-10-13. Every icon is a trademark of its owner and only identifies the provider. Icons
from a brand's own site are used as the site publishes them (no license grant). Lobe Icons (npm
`@lobehub/icons-static-svg` 1.90.0) is MIT (`../ProviderGlyphs/LICENSE-LobeHub.txt`). Simple Icons
(npm `simple-icons` 16.35.0) is CC0-1.0. Rebuild a PDF with `rsvg-convert -f pdf`; PNG icons are the
source resized to at most 256 pixels.

## Full icons

| Provider id | File | Source |
| --- | --- | --- |
| codex, openai | full-openai.png | https://openai.com/apple-touch-icon.png |
| claude-code | full-claude-code.png | https://claude.ai/apple-touch-icon.png |
| grok-build | full-grok-build.png | https://grok.com/images/apple-touch-icon.png |
| cursor | full-cursor.png | https://cursor.com/apple-touch-icon.png |
| amp | full-amp.png | https://ampcode.com/app-icon.png |
| opencodego | full-opencodego.png | https://opencode.ai/apple-touch-icon.png |
| kilo | full-kilo.pdf | https://kilo.ai/favicon/favicon.svg |
| ollama | full-ollama.png | https://ollama.com/public/apple-touch-icon.png |
| perplexity | full-perplexity.png | https://www.perplexity.ai/apple-touch-icon.png |
| groq | full-groq.png | https://groq.com/apple-touch-icon.png |
| v0 | full-v0.png | https://v0.app/assets/apple-icon.png |
| replicate | full-replicate.png | https://static.replicateassets.com/fe/4fa86b07de3ad4ea584bc1f339cff05cc96889c9/favicon-CKiqAkf2.png |
| elevenlabs | full-elevenlabs.png | https://elevenlabs.io/apple-icon.png |
| notion | full-notion.png | https://www.notion.com/front-static/logo-ios.png |
| poe | full-poe.png | https://poe.com/apple-touch-icon.png |
| raycast | full-raycast.png | https://www.raycast.com/favicon-production.png |
| warp | full-warp.png | https://www.warp.dev/favicon-196x196.png |
| deepgram | full-deepgram.png | https://console.deepgram.com/apple-touch-icon.png |
| gitkraken | full-gitkraken.png | https://gitkraken.com/wp-content/uploads/2021/03/android-chrome-144x144-1.png |
| jetbrains | full-jetbrains.png | https://www.jetbrains.com/apple-touch-icon.png |
| openrouter | full-openrouter.png | https://openrouter.ai/favicon/glyph.png |
| kimi, kimi-api, moonshot | full-kimi.png | https://www.kimi.com/pwa-192.png |
| minimax | full-minimax.png | https://filecdn.minimax.chat/public/58eca777-e31f-448a-9823-e2220e49b426.png |
| tavily | full-tavily.png | https://www.tavily.com/apple-icon.png |
| venice | full-venice.png | https://venice.ai/apple-touch-icon.png |
| doubao | full-doubao.png | https://lf-flow-web-cdn.doubao.com/obj/flow-doubao/favicon/new-doubao/192x192.png |
| exa | full-exa.png | https://exa.ai/favicon.ico (256 px frame) |
| fireworks | full-fireworks.png | https://fireworks.ai/apple-icon.png |
| qoder | full-qoder.png | https://img.alicdn.com/imgextra/i4/O1CN01QkSxiCocd3D0prc8_!!6000000008124-2-tps-412-412.png |
| manus | full-manus.png | https://manus.im/icon.png |
| nous | full-nous.png | https://nousresearch.com/apple-touch-icon.png |
| mimo | full-mimo.png | https://platform.xiaomimimo.com/favicon.png |
| devin | full-devin.png | https://devin.ai/apple-icon.png |
| abacus | full-abacus.png | https://abacus.ai/apple-touch-icon.png |
| aerostack | full-aerostack.png | https://aerostack.dev/apple-icon-180x180.png |
| aiand | full-aiand.png | https://framerusercontent.com/images/CjnWM5i4l3rTtLs9FmP8NPB5uUY.png |
| aixy | full-aixy.pdf | https://aixy-gateway.com/favicon.svg |
| bifrost | full-bifrost.png | https://bifrost-website.getmaxim.workers.dev/marketing/k49dViw06yckDjJt5uERdfTSjU.png |
| chutes | full-chutes.png | https://chutes.ai/favicon.png |
| codebuff | full-codebuff.png | https://www.codebuff.com/favicon/apple-touch-icon.png |
| commandcode | full-commandcode.png | https://commandcode.ai/apple-touch-icon.png |
| helmcode | full-helmcode.png | https://helmcode.com/apple-touch-icon.png |
| langdock | full-langdock.png | https://cdn.prod.website-files.com/69358127577725733df731fb/6a11853390eb949858f56e21_langdock-sticker-blau.png |
| linkup | full-linkup.png | https://www.linkup.so/_next/static/immutable/media/favicon-dark.2yl18p4jwc-6u.png |
| litellm | full-litellm.png | https://cdn.prod.website-files.com/69eb241da3f923869c226875/6abea4e104dd1bb48c09b81a_litellm_webclip_256_1.png |
| sofya | full-sofya.pdf | https://sofya.co/static/favicon.svg |
| synthetic | full-synthetic.png | https://synthetic.new/apple-touch-icon.png |
| t3chat | full-t3chat.png | https://t3.chat/apple-touch-icon.png |
| tinyapi | full-tinyapi.png | https://tinyapi.rest/android-chrome-512x512.png |
| typesafe | full-typesafe.png | https://framerusercontent.com/images/kcuF2BEp5XaVfkmFB634IPRKQH0.png |
| workbuddy | full-workbuddy.png | https://assets.workbuddy.cn/web/workbuddy/f4728a12fe9cfe5a34da6b2fa827614041c84386/assets/logo.svg (rendered at 256 px) |

## Transparent marks on the brand's tile color

| Provider id | File | Source | Tile |
| --- | --- | --- | --- |
| ibmbob | ibmbob.png | https://bob.ibm.com/apple-touch-icon.png | white |
| devpass | devpass.png | https://llmgateway.io/favicon/apple-touch-icon.png (white mark) | #09090B |
| neuralwatt | neuralwatt.png | https://neuralwatt.com/static/images/Neuralwatt-Logomark-Black.png | white |
| xkiro | xkiro.png | https://xkiro.com/images/logo/logo-xt-green.png | white |
| cosmic | cosmic.pdf | https://www.cosmicjs.com/favicon.svg | white |
| pi | pi.pdf | https://pi.dev/favicon.svg (light-scheme fill) | white |
| muse | meta.pdf | Simple Icons `meta` (fill #0081FB), CC0-1.0 | white |
| zoommate | zoom.pdf | Simple Icons `zoom` (white), CC0-1.0 | #0B5CFF |
| azureopenai | azure.pdf | Lobe Icons `azure-color` | white |
| gemini-cli | gemini.pdf | Lobe Icons `gemini-color` | white |
| antigravity-cli | antigravity.png | Lobe Icons `antigravity-color` (384 px; its SVG uses blur filters) | white |
| deepseek | deepseek.pdf | Lobe Icons `deepseek-color` | white |
| qwencloud | qwen.pdf | Lobe Icons `qwen-color` | white |
| alibaba | alibabacloud.pdf | Lobe Icons `alibabacloud-color` | white |
| alibabatokenplan | bailian.pdf | Lobe Icons `bailian-color` | white |
| mistral | mistral.pdf | Lobe Icons `mistral-color` | white |
| huggingface | huggingface.pdf | Lobe Icons `huggingface-color` | white |
| zed | zed.pdf | Simple Icons `zedindustries` (fill #084CCF) | white |
| stepfun | stepfun.pdf | Lobe Icons `stepfun-color` | white |
| vertexai | vertexai.pdf | Lobe Icons `vertexai-color` | white |
| bedrock | bedrock.pdf | Lobe Icons `bedrock-color` | white |
| deepinfra | deepinfra.pdf | Lobe Icons `deepinfra-color` | white |
| longcat | longcat.pdf | Lobe Icons `longcat-color` | white |
| kiro | kiro.pdf | https://kiro.dev/icon.svg (tile rectangle removed) | #9046FF |
| vercel | vercel.pdf | Lobe Icons `vercel`, white mark | black |
| xai | xai.pdf | Lobe Icons `xai`, black mark | white |
| xapi | x.pdf | Simple Icons `x`, white mark | black |
| zai | zai.pdf | Lobe Icons `zai`, white mark | #2D2D2D |
| zenmux | zenmux.pdf | Lobe Icons `zenmux`, black mark | white |
| windsurf | windsurf.pdf | Lobe Icons `windsurf`, black mark (windsurf.com now serves Devin's icon) | white |
| copilot | githubcopilot.pdf | Lobe Icons `githubcopilot`, black mark | white |
| clinepass | cline.pdf | Lobe Icons `cline`, black mark | white |
| atlascloud | atlascloud.pdf | Lobe Icons `atlascloud`, black mark | white |
| augment | augment.pdf | https://augmentcode.com/favicon.svg, black mark | white |
| factory, droid | factory.pdf | https://factory.ai/favicon.svg (tile rectangle removed), #FAFAFA mark | #020202 |

## Dense-row glyphs

The remaining `*.pdf` files (`<name>-mono.pdf`, `openai`, `grok`, `cursor`, `devin`, `v0`, `kilocode`,
`manus`, `elevenlabs`, `notion`, `ollama`, `opencode`, `nousresearch`, `xiaomimimo`, `groq`, `raycast`,
`warp`, `replicate`, `jetbrains`) are the official single-color marks from Lobe Icons or Simple Icons,
used as template glyphs in lists and the menu bar. `ibm-mono.pdf` is the IBM mark for IBM Bob.

## No full icon found (template glyph on a neutral tile)

clawrouter (console host only), hyper (Charm Hyper: only a 1200x628 share image), lithosai (site down; 16 px favicon), llmman and llmproxy (sites down), sailresearch (32 px favicon),
sakana (48 px favicon), sub2api and wayfinder (open-source projects with no own icon).
