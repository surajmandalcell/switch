.pragma library

// Maintenance formats and rules (maintenance.md 3.2, 3.4, 4.7, 7.1, 7.3). Pure functions, no state.

// ByteCountFormatter, file style: decimal units, adaptive digits (KB 0, MB 1, GB and up 2), no zero padding.
function size(bytes) {
  var b = Number(bytes) || 0
  if (b === 0) return "0 KB"
  if (b < 1000) return num(b) + (b === 1 ? " byte" : " bytes")
  var units = ["KB", "MB", "GB", "TB", "PB"], digits = [0, 1, 2, 2, 2]
  var v = b / 1000, i = 0
  while (i < units.length - 1 && Number(v.toFixed(digits[i])) >= 1000) { v /= 1000; ++i }
  var s = v.toFixed(digits[i])
  if (s.indexOf(".") >= 0) s = s.replace(/0+$/, "").replace(/\.$/, "")
  return s.replace(".", Qt.locale().decimalPoint) + " " + units[i]
}

function num(n) { return Number(n || 0).toLocaleString(Qt.locale(), "f", 0) }
function plural(n, one, many) { return num(n) + " " + (n === 1 ? one : many) }

function toDate(x) { return x instanceof Date ? x : new Date(x) }
// .abbreviated date + .shortened time: "Nov 14, 2026 at 3:07 PM" in en-US.
function dateOnly(x) { return toDate(x).toLocaleDateString(Qt.locale(), "MMM d, yyyy") }
function dateTime(x) { var d = toDate(x); return dateOnly(d) + " at " + d.toLocaleTimeString(Qt.locale(), 1 /* Locale.ShortFormat */) }

function home(path, userHome) {
  if (!userHome || !path) return path || ""
  if (path === userHome) return "~"
  return path.indexOf(userHome + "/") === 0 ? "~" + path.slice(userHome.length) : path
}
function lastComponent(path) { var p = String(path).replace(/\/+$/, ""); return p.slice(p.lastIndexOf("/") + 1) }

// 3.2 time ranges, in pop-up order; "-" is a menu divider.
var RANGES = ["Last hour", "Last 24 hours", "Last 7 days", "Last 4 weeks", "-",
              "Older than 7 days", "Older than 30 days", "Older than 90 days", "Older than 1 year", "-",
              "All time", "Before a date", "Custom dates"]
var DAY = 86400000
var SPAN = { "Last hour": 3600000, "Last 24 hours": DAY, "Last 7 days": 7 * DAY, "Last 4 weeks": 28 * DAY,
             "Older than 7 days": 7 * DAY, "Older than 30 days": 30 * DAY, "Older than 90 days": 90 * DAY, "Older than 1 year": 365 * DAY }

function startOfDay(ms) { var d = new Date(ms); d.setHours(0, 0, 0, 0); return d.getTime() }

function inRange(range, date, now, from, through) {
  var t = toDate(date).getTime()
  if (range === "All time") return true
  if (range === "Before a date") return t < startOfDay(from)
  if (range === "Custom dates") {
    var end = new Date(startOfDay(through)); end.setDate(end.getDate() + 1)
    return startOfDay(from) <= t && t < end.getTime()
  }
  var span = SPAN[range]
  if (span === undefined) return false
  var cutoff = now - span
  return range.indexOf("Older") === 0 ? t < cutoff : cutoff <= t && t <= now
}

// 7.3: what the Files card says when the range hides everything.
function nothingText(range, tool, total) {
  var s = size(total)
  if (total === 0) return "Nothing to clear. " + tool + " has no files that Cleanup lists."
  if (range === "All time") return "Nothing to clear. " + tool + " uses " + s + ", but every item is in use or owned by another app."
  if (range.indexOf("Older") === 0) return "Nothing " + range.toLowerCase() + ". " + tool + " uses " + s + "; choose a shorter range to see it."
  if (range === "Before a date" || range === "Custom dates") return "Nothing in these dates. " + tool + " uses " + s + "; choose other dates to see it."
  return "Nothing in the " + range.toLowerCase() + ". " + tool + " uses " + s + "; choose a longer range to see it."
}

// 7.4
function reviewNote(review, tool, isCodex) {
  var ids = review.groups.map(function (g) { return g.id })
  var note = "Items move to Switch's recoverable trash inside the tool folder. Moving does not free disk space until you remove them for good."
  if (ids.indexOf("images") >= 0) note += " A chat that loses its pasted images keeps a copy without them; the original waits in the trash."
  if (!isCodex && (ids.indexOf("conversations") >= 0 || ids.indexOf("archived") >= 0))
    note += " Usage totals for " + tool + " are read from its saved chats, so removed chats lower them."
  return note
}

// 4.7 names in the restore sheet and the checklist.
var LABELS = {
  "sessions": "Conversations", "projects": "Conversations", "session-state": "Conversations", "storage": "Conversations",
  "archived_sessions": "Archived conversations", "tmp": "Conversations and project data",
  "config.toml": "Settings", "settings.json": "Settings",
  "AGENTS.md": "Global instructions", "CLAUDE.md": "Global instructions", "GEMINI.md": "Global instructions",
  "prompts": "Custom prompts", "rules": "Rules", "commands": "Custom commands", "agents": "Agents", "droids": "Custom droids",
  "skills": "Skills", "extensions": "Extensions", "plugins/installed_plugins.json": "Installed plugins",
  "plugins/known_marketplaces.json": "Plugin marketplaces", "backups": "Settings backups", "history.jsonl": "Prompt history",
  "_profiles": "Claude Code profile folders"
}
function label(path) { return LABELS[path] || path }

// 4.2 non-login preset items per tool, for "what is included" (4.7).
var PRESETS = {
  "codex": ["sessions", "archived_sessions", "config.toml", "AGENTS.md", "prompts", "rules"],
  "grok-build": ["sessions", "archived_sessions", "config.toml", "AGENTS.md", "prompts", "rules"],
  "droid": ["sessions", "settings.json", "droids", "commands"],
  "gemini": ["tmp", "settings.json", "GEMINI.md", "commands", "extensions", "skills"],
  "copilot": ["session-state"],
  "opencode": ["storage"]
}
function included(sourceID, profiles) {
  if (sourceID === "claude") return profiles === 0 ? "Shared history" : "Shared history + " + plural(profiles, "profile", "profiles")
  var items = PRESETS[sourceID]
  if (!items) return "Not supported yet"
  var names = []
  for (var i = 0; i < items.length; ++i) { var n = LABELS[items[i]]; if (n && names.indexOf(n) < 0) names.push(n) }
  return names.slice(0, 3).join(", ")
}
function backupButton(n) { return "Back up " + plural(n, "tool", "tools") + " now" }

// 3.1 brand tile of a source (ProviderTile ids).
function provider(source) {
  var p = source.providerID || source.tool || source.sourceID || ""
  return p === "claude" ? "claude-code" : p
}
