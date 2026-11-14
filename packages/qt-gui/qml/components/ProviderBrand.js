.pragma library
// Provider marks (accounts.md 2.8), ported from the Mac AIManagerBrand.swift tables. Files live in
// assets/providers/: brand/<file>.png (the Mac PDFs as 128 px PNGs), glyph/<name>.png, icon/ProviderIcon-<name>.svg.
// kind: "full" fills the tile; "color" keeps the art's colors with padding; "tint" recolors the art's alpha.

function full(file, bg) { return { kind: "full", file: file, tile: bg } }
function color(file, tile) { return { kind: "color", file: file, tile: tile || "#FFFFFF" } }
function tinted(file, mark, tile) { return { kind: "tint", file: file, mark: mark, tile: tile } }
function mono(file) { return tinted(file, "#000000", "#FFFFFF") }

var BRANDS = {
  "codex": full("full-openai", "#FFFFFF"), "openai": full("full-openai", "#FFFFFF"),
  "claude-code": full("full-claude-code", "#D96F4C"), "grok-build": full("full-grok-build", "#050505"),
  "cursor": full("full-cursor", "#000000"), "amp": full("full-amp", "#2C3A2A"),
  "opencodego": full("full-opencodego", "#131010"), "kilo": full("full-kilo", "#FFDD00"),
  "ollama": full("full-ollama", "#FFFFFF"), "perplexity": full("full-perplexity", "#000000"),
  "groq": full("full-groq", "#F43E01"), "vercel": tinted("vercel", "#FFFFFF", "#000000"),
  "v0": full("full-v0", "#000000"), "replicate": full("full-replicate", "#ED5759"),
  "elevenlabs": full("full-elevenlabs", "#FFFFFF"), "notion": full("full-notion", "#FFFFFF"),
  "poe": full("full-poe", "#000000"), "raycast": full("full-raycast", "#151515"),
  "warp": full("full-warp", "#000000"), "deepgram": full("full-deepgram", "#0C0C0D"),
  "gitkraken": full("full-gitkraken", "#131322"), "jetbrains": full("full-jetbrains", "#FFFFFF"),
  "openrouter": full("full-openrouter", "#03080A"), "kimi": full("full-kimi", "#000000"),
  "kimi-api": full("full-kimi", "#000000"), "moonshot": full("full-kimi", "#000000"),
  "minimax": full("full-minimax", "#E3177F"), "tavily": full("full-tavily", "#1F1E1E"),
  "venice": full("full-venice", "#FFFFFF"), "doubao": full("full-doubao", "#CAE4FF"),
  "exa": full("full-exa", "#1F40ED"), "fireworks": full("full-fireworks", "#F2F2F2"),
  "qoder": full("full-qoder", "#F3F3F3"), "manus": full("full-manus", "#FFFFFF"),
  "nous": full("full-nous", "#FFFFFF"), "mimo": full("full-mimo", "#000000"),
  "devin": full("full-devin", "#0E1015"), "abacus": full("full-abacus", "#0A0E1C"),
  "aerostack": full("full-aerostack", "#F7F7F7"), "aiand": full("full-aiand", "#FFFFFF"),
  "aixy": full("full-aixy", "#123650"), "bifrost": full("full-bifrost", "#40DBB6"),
  "chutes": full("full-chutes", "#121212"), "codebuff": full("full-codebuff", "#000000"),
  "commandcode": full("full-commandcode", "#000000"), "helmcode": full("full-helmcode", "#0A0A0A"),
  "langdock": full("full-langdock", "#4469FC"), "linkup": full("full-linkup", "#FFFFFF"),
  "litellm": full("full-litellm", "#0117BE"), "sofya": full("full-sofya", "#0A0806"),
  "synthetic": full("full-synthetic", "#FFFFFF"), "t3chat": full("full-t3chat", "#C21789"),
  "tinyapi": full("full-tinyapi", "#CF7600"), "typesafe": full("full-typesafe", "#E551BA"),
  "workbuddy": full("full-workbuddy", "#FFFFFF"),
  "azureopenai": color("azure"), "gemini-cli": color("gemini"), "antigravity-cli": color("antigravity"),
  "deepseek": color("deepseek"), "qwencloud": color("qwen"), "alibaba": color("alibabacloud"),
  "alibabatokenplan": color("bailian"), "mistral": color("mistral"), "huggingface": color("huggingface"),
  "zed": color("zed"), "stepfun": color("stepfun"), "vertexai": color("vertexai"), "bedrock": color("bedrock"),
  "deepinfra": color("deepinfra"), "longcat": color("longcat"), "kiro": color("kiro", "#9046FF"),
  "ibmbob": color("ibmbob"), "devpass": color("devpass", "#09090B"), "neuralwatt": color("neuralwatt"),
  "xkiro": color("xkiro"), "cosmic": color("cosmic"), "pi": color("pi"), "muse": color("meta"),
  "zoommate": tinted("zoom", "#FFFFFF", "#0B5CFF"), "xai": mono("xai"), "xapi": tinted("x", "#FFFFFF", "#000000"),
  "zai": tinted("zai", "#FFFFFF", "#2D2D2D"), "zenmux": mono("zenmux"), "windsurf": mono("windsurf"),
  "copilot": mono("githubcopilot"), "clinepass": mono("cline"), "atlascloud": mono("atlascloud"),
  "augment": mono("augment"), "factory": tinted("factory", "#FAFAFA", "#020202"),
  "droid": tinted("factory", "#FAFAFA", "#020202")
}

// No brand: the template glyph PNG, then the generic SVG, else a monogram (BRD:238-250).
var GLYPHS = {
  "codex": "codex", "claude-code": "claudecode", "gemini-cli": "gemini", "antigravity-cli": "antigravity",
  "openai": "openai", "claude": "claude", "grok-build": "grok", "xai": "xai", "cursor": "cursor",
  "github-copilot": "githubcopilot", "copilot": "copilot", "cline": "cline", "windsurf": "windsurf",
  "opencode": "opencode", "amp": "amp", "goose": "goose", "deepseek": "deepseek", "qwen": "qwen",
  "mistral": "mistral", "ollama": "ollama", "perplexity": "perplexity"
}
var ICON_ALIASES = {
  "gemini-cli": "gemini", "antigravity-cli": "antigravity", "grok-build": "grok", "claude-code": "claude",
  "github-copilot": "copilot", "droid": "factory", "kimi-api": "kimi", "moonshot": "kimi",
  "qwencloud-team": "qwencloud", "alibabatokenplan": "alibaba", "azureopenai": "openai"
}
var ICONS = ("abacus aerostack aiand aixy alibaba amp antigravity atlascloud augment bedrock bifrost chutes claude clawrouter "
  + "clinepass codebuff coderabbit codex commandcode copilot cosmic cursor deepgram deepinfra deepseek devin devpass doubao "
  + "elevenlabs exa factory fireworks gemini gitkraken grok groq helmcode huggingface hyper ibmbob jetbrains kilo kimi kiro "
  + "langdock linkup litellm lithosai llmman llmproxy longcat manus mimo minimax mistral muse museai neuralwatt notion nous "
  + "ollama opencode opencodego openrouter perplexity pi poe qoder qwencloud raycast replicate sailresearch sakana sofya "
  + "stepfun sub2api synthetic t3chat tavily tinyapi typesafe v0 venice vercel vertexai warp wayfinder windsurf workbuddy "
  + "xai xapi xkiro zai zed zenmux zoommate").split(" ")

function brand(id) { return BRANDS[id] || null }
// The template image for a provider without a brand, or "" for the monogram.
function glyph(id) {
  if (GLYPHS[id]) return "assets/providers/glyph/" + GLYPHS[id] + ".png"
  var n = ICON_ALIASES[id] || id
  if (GLYPHS[n]) return "assets/providers/glyph/" + GLYPHS[n] + ".png"
  return ICONS.indexOf(n) >= 0 ? "assets/providers/icon/ProviderIcon-" + n + ".svg" : ""
}
