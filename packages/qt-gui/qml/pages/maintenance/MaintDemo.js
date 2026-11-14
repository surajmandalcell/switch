.pragma library

// Synthetic Maintenance data for --demo and the captures. `--maint <state>` picks a variant
// (maintenance.md 6): reply() returns {result}, {error}, or null for a call that never answers.

var DAY = 86400000
function ago(days) { return new Date(Date.now() - days * DAY).toISOString() }
var USER = "/home/ada"

function item(id, path, title, project, days, bytes, extra) {
  var it = { id: id, path: path, companions: [], title: title, project: project, updatedAt: ago(days), bytes: bytes,
             isDirectory: false, isRewrite: false, protectedReason: null }
  for (var k in extra || {}) it[k] = extra[k]
  return it
}

var P1 = USER + "/dev/weather-app", P2 = USER + "/dev/recipe-box/web", P3 = USER + "/notes",
    P4 = USER + "/dev/oss/a-very-long-project-folder-name-that-needs-middle-truncation/packages/server"

function codexScan() {
  var conv = [
    item("cv1", "sessions/2026/07/01/rollout-1.jsonl", "Add an hourly forecast chart and match the design mockups", P1, 36, 48200000),
    item("cv2", "sessions/2026/06/20/rollout-2.jsonl", "Fix the login form validation", P1, 47, 9120000),
    item("cv3", "sessions/2026/05/11/rollout-3.jsonl", "Why does the image upload stall on slow networks", P2, 87, 132400000),
    item("cv4", "sessions/2026/04/02/rollout-4.jsonl", "Shopping list sync", P2, 126, 2210000),
    item("cv5", "sessions/2026/03/18/rollout-5.jsonl", "Summarize meeting notes", P3, 141, 380000),
    item("cv6", "sessions/2026/02/01/rollout-6.jsonl", "Refactor the request router so every handler shares one retry and one log line", P4, 186, 77300000),
    item("cv7", "sessions/2026/01/12/rollout-7.jsonl", "Release notes draft", P1, 206, 1240000),
    item("cv8", "sessions/2025/12/24/rollout-8.jsonl", "Holiday list", null, 325, 64000),
    item("cv9", "sessions/2026/11/12/rollout-9.jsonl", "Current work", P1, 2, 5400000),
    item("cv10", "sessions/2026/11/14/rollout-10.jsonl", "Open chat", P1, 0, 2100000, { protectedReason: "In use now." })
  ]
  var archived = [
    item("ar1", "archived_sessions/rollout-a1.jsonl", "Old prototype of the settings screen", P1, 64, 15500000),
    item("ar2", "archived_sessions/rollout-a2.jsonl", "First recipe importer", P2, 220, 41000000)
  ]
  var agents = [
    item("ag1", "sessions/2026/08/02/review-1.jsonl", "Auto review: forecast cache", P1, 104, 820000),
    item("ag2", "sessions/2026/08/02/review-2.jsonl", "Sub-agent: icon redraw", P1, 104, 410000),
    item("ag3", "sessions/2026/07/22/review-3.jsonl", "Auto review: search filters", P2, 115, 1960000)
  ]
  var images = [
    item("im1", "sessions/2026/05/11/rollout-3.jsonl", "Why does the image upload stall on slow networks", P2, 87, 61800000, { isRewrite: true }),
    item("im2", "sessions/2026/03/02/rollout-11.jsonl", "Mockup review", P1, 157, 8800000, { isRewrite: true })
  ]
  var gen = [
    item("gi1", "generated_images/ig_01.png", "ig_01.png", null, 40, 2400000),
    item("gi2", "generated_images/ig_02.png", "ig_02.png", null, 71, 2100000),
    item("gi3", "generated_images/ig_03.png", "ig_03.png", null, 99, 1900000)
  ]
  var logs = []
  for (var i = 0; i < 16; ++i) logs.push(item("lg" + i, "log/codex-tui-" + (i + 1) + ".log", "codex-tui-" + (i + 1) + ".log", null, 31 + i * 9, 180000 + i * 52000))
  var caches = [
    item("ca1", "cache/models", "models", null, 45, 312000000, { isDirectory: true }),
    item("ca2", "shell_snapshots/snapshot-1.sh", "snapshot-1.sh", null, 52, 18000),
    item("ca3", "cache/ripgrep", "ripgrep", null, 33, 0, { isDirectory: true, protectedReason: "Another app links this file, so it stays." })
  ]
  var versions = [
    item("ve1", "packages/standalone/releases/0.61.0", "Standalone 0.61.0", null, 12, 168000000, { isDirectory: true }),
    item("ve2", "packages/standalone/releases/0.60.2", "Standalone 0.60.2", null, 30, 166000000, { isDirectory: true }),
    item("ve3", "packages/standalone/releases/0.62.0", "Standalone 0.62.0", null, 1, 171000000, { isDirectory: true, protectedReason: "A running app uses this version." })
  ]
  var history = [ item("hi1", "history.jsonl", "history.jsonl", null, 0, 2400000) ]
  var cats = [
    cat("conversations", "Conversations", "Saved chats you can resume, by project. Dates are the last activity.", "caution", false, true, true, conv),
    cat("archived", "Archived conversations", "Chats you archived in Codex.", "caution", false, true, true, archived),
    cat("agents", "Review and agent sessions", "Short sessions Codex starts for auto-reviews and sub-agents. They are not chats you can open.", "caution", false, true, true, agents),
    cat("images", "Pasted images in old conversations", "Removes pasted screenshots from old chats. The text stays and chats still open.", "caution", false, true, true, images),
    cat("generated-images", "Generated images", "Pictures Codex made for you, by age. Removing them deletes the saved copies.", "caution", true, false, true, gen),
    cat("logs", "Logs and temp files", "Run logs the tool rewrites. Nothing user-facing is lost.", "safe", true, false, true, logs),
    cat("caches", "Caches", "Downloads and scratch files the tool fetches again.", "safe", true, false, true, caches),
    cat("versions", "Old app versions", "Older copies of the tool. The current version stays.", "safe", true, false, false, versions),
    cat("history", "Prompt history", "The prompts you typed. Removing it clears the up-arrow history.", "caution", false, false, true, history)
  ]
  var total = 0
  cats.forEach(function (c) { if (c.id !== "images") c.items.forEach(function (it) { total += it.bytes }) })
  return { scanID: "5f0c3b1e-0000-4000-8000-000000000001", sourceID: "codex", totalBytes: total,
           untouchedText: "3 items stay untouched: 1 a running app uses this version, 1 linked by another app, 1 running now.",
           categories: cats }
}
function cat(id, title, detail, risk, pre, byProject, ageBased, items) {
  return { id: id, title: title, detail: detail, risk: risk, preselected: pre, byProject: byProject, ageBased: ageBased, items: items }
}

var SOURCES = [
  { id: "codex", tool: "codex", title: "Codex CLI", detail: "2 accounts", providerID: "codex", home: USER + "/.codex" },
  { id: "claude", tool: "claude", title: "Claude Code", detail: "Shared history · 3 accounts", providerID: "claude-code", home: USER + "/.claude" },
  { id: "claude:7A1C", tool: "claude", title: "Claude Code", detail: "Own profile", providerID: "claude-code", home: USER + "/.local/share/switch/claude-code-profiles/7A1C/config" },
  { id: "grok-build", tool: "grok", title: "Grok Build", detail: "1 account", providerID: "grok-build", home: USER + "/.grok" },
  { id: "droid", tool: "droid", title: "Droid", detail: "1 account", providerID: "droid", home: USER + "/.factory" },
  { id: "gemini", tool: "gemini", title: "Gemini CLI", detail: "Found on this Mac", providerID: "gemini-cli", home: USER + "/.gemini" },
  { id: "copilot", tool: "copilot", title: "GitHub Copilot CLI", detail: "Found on this Mac", providerID: "copilot", home: USER + "/.copilot" },
  { id: "opencode", tool: "opencode", title: "opencode", detail: "Found on this Mac", providerID: "opencode", home: USER + "/.local/share/opencode" }
]

var TRASH = [
  { id: "9b7e6a52-0000-4000-8000-000000000002", createdAt: ago(3), bytes: 28400000, items: [item("t1", "log/a.log", "a.log", null, 40, 1), item("t2", "log/b.log", "b.log", null, 40, 1), item("t3", "cache/x", "x", null, 40, 1)] },
  { id: "9b7e6a52-0000-4000-8000-000000000003", createdAt: ago(19), bytes: 1240000000, items: [item("t4", "sessions/old.jsonl", "old", null, 90, 1)] }
]
var SAMPLES = [ { id: 1, accountID: "a", fetchedAt: ago(45), bytes: 4200 }, { id: 2, accountID: "a", fetchedAt: ago(60), bytes: 4100 },
                { id: 3, accountID: "b", fetchedAt: ago(2), bytes: 3900 } ]

var SETS = [
  { id: "1d0e0000-0000-4000-8000-00000000c0de", name: "Codex CLI", sourceID: "codex", destination: "/run/media/ada/Backup Drive", profiles: {}, retired: false,
    includeLogins: false, promptsOnly: false, schedule: "daily", keep: 10 },
  { id: "1d0e0000-0000-4000-8000-00000000c1a0", name: "Claude Code", sourceID: "claude", destination: "/run/media/ada/Backup Drive",
    profiles: { "7A1C": "", "B2F4": "" }, retired: false, includeLogins: false, promptsOnly: false, schedule: "daily", keep: 10 },
  { id: "1d0e0000-0000-4000-8000-00000000d201", name: "Droid", sourceID: "droid", destination: "/run/media/ada/Old Drive", profiles: {}, retired: true,
    includeLogins: false, promptsOnly: false, schedule: "off", keep: 10 }
]

function groups(list) { return list.map(function (g) { return { id: g[0], files: g[1], bytes: g[2] } }) }
var CODEX_GROUPS = groups([["AGENTS.md", 1, 4200], ["archived_sessions", 41, 98000000], ["config.toml", 1, 1900], ["prompts", 6, 22000], ["rules", 3, 8100], ["sessions", 1240, 1630000000]])
var CLAUDE_GROUPS = groups([["CLAUDE.md", 1, 6100], ["_profiles", 380, 412000000], ["agents", 9, 51000], ["commands", 14, 38000], ["plugins/installed_plugins.json", 1, 900],
                            ["projects", 2210, 2980000000], ["settings.json", 1, 3400], ["skills", 22, 640000]])

function snap(id, days, files, bytes, state, extra) {
  var s = { id: id, folder: "/run/media/ada/Backup Drive/Switch Backups/" + id, date: ago(days), files: files, totalBytes: bytes,
            newBytes: Math.round(bytes / 9), state: state || "Complete" }
  for (var k in extra || {}) s[k] = extra[k]
  return s
}

function history(setID, state) {
  var waiting = state === "backup-waiting"
  var base = { state: waiting ? "waiting" : "ready", waitingFor: waiting ? "Backup Drive" : null, lastError: null,
               nextDue: new Date(Date.now() + 0.4 * DAY).toISOString() }
  if (state === "backup-empty" || waiting) { base.snapshots = []; return base }
  if (setID === SETS[0].id) {
    base.lastError = "File changed or vanished: sessions/2026/11/14/rollout-10.jsonl"
    base.snapshots = [snap("2026-11-14T08-00-00Z-c1", 0.3, 1292, 1730000000, "Complete with skipped items", { groups: CODEX_GROUPS }),
                      snap("2026-11-13T08-00-00Z-c2", 1.3, 1288, 1726000000, null, { groups: CODEX_GROUPS }),
                      snap("2026-11-12T08-00-00Z-c3", 2.3, 1280, 1719000000, null, { groups: CODEX_GROUPS }),
                      snap("2026-11-11T08-00-00Z-c4", 3.3, 1271, 1702000000, null, { groups: CODEX_GROUPS })]
  } else if (setID === SETS[1].id) {
    base.snapshots = [snap("2026-11-14T08-01-00Z-l1", 0.29, 2638, 3393000000, null, { groups: CLAUDE_GROUPS }),
                      snap("2026-11-13T19-40-00Z-l2", 0.8, 214, 61000000, null, { safety: true, groups: groups([["projects", 214, 61000000]]) }),
                      snap("2026-11-13T08-01-00Z-l3", 1.29, 2601, 3370000000, null, { groups: CLAUDE_GROUPS }),
                      snap("2026-11-10T08-01-00Z-l4", 4.29, 512, 2100000, null, { promptsOnly: true, groups: groups([["prompts", 512, 2100000]]) })]
  } else {
    base.snapshots = [snap("2026-09-02T10-00-00Z-d1", 73, 318, 84000000, null, { groups: groups([["droids", 4, 12000], ["sessions", 312, 83900000], ["settings.json", 1, 2100]]) })]
  }
  return base
}

function checklist(state) {
  var none = state === "backup-nofolder"
  var rows = [
    ["codex", "Codex CLI", 1730000000], ["claude", "Claude Code", 3393000000], ["grok-build", "Grok Build", 12400000],
    ["droid", "Droid", 84100000], ["gemini", "Gemini CLI", null], ["copilot", "GitHub Copilot CLI", 2900000], ["opencode", "opencode", 0]
  ].map(function (r, i) {
    var checked = !none && i < 2
    return { sourceID: r[0], title: r[1], checked: checked, setID: checked ? SETS[i].id : null, bytes: r[2],
             lastBackup: state === "backup-empty" ? null : (i === 0 ? ago(0.3) : (i === 1 ? ago(0.29) : (i === 3 ? ago(73) : null))) }
  })
  return { rows: rows, folder: none ? null : "/run/media/ada/Backup Drive",
           shared: { schedule: "daily", keep: 10, includeLogins: false, promptsOnly: false } }
}

var RECOVERY = [
  { id: "r1", kind: "import", phase: "conflicted", destination: USER + "/.codex/auth.json" },
  { id: "r2", kind: "switch", phase: "staged", destination: USER + "/.local/share/switch/claude-code-profiles/7A1C/config" }
]

function reply(method, params, state) {
  switch (method) {
  case "cleanup.sources": return state === "cleanup-nosource" ? { result: [] } : { result: SOURCES }
  case "cleanup.scan":
    if (state === "cleanup-loading") return null
    if (state === "cleanup-error") return { error: { code: -32007, message: "A folder is too large to scan." } }
    return { result: codexScan() }
  case "cleanup.trashList": return { result: params.sourceID === "codex" ? TRASH : [] }
  case "cleanup.samples": return { result: SAMPLES }
  case "cleanup.review": {
    var all = {}
    codexScan().categories.forEach(function (c) { c.items.forEach(function (it) { all[it.id] = it }) })
    var items = params.itemIDs.map(function (id) { return all[id] }).filter(function (x) { return !!x })
    return { result: { planID: "aa000000-0000-4000-8000-000000000001", bytes: items.reduce(function (s, x) { return s + x.bytes }, 0), items: items } }
  }
  case "cleanup.apply": return { result: { status: "done" } }
  case "cleanup.restore": return { result: { status: "done" } }
  case "cleanup.purge":
    if (params.confirm) return { result: { status: "done" } }
    return { result: { status: "needsConfirmation", confirmation: { kind: "purge", token: "demo-token", title: "Delete these items for good?", message: "", action: "Remove for good" } } }
  case "backup.checklist": return state === "backup-loading" ? null : { result: checklist(state) }
  case "backup.list": return { result: state === "backup-nofolder" ? [SETS[2]] : SETS }
  case "backup.history": return { result: history(params.setID, state) }
  case "backup.restore": return { result: { status: "done", notice: "Restored 12 files." } }
  case "accounts.status": return { result: { pendingRecovery: state.indexOf("backup") === 0 && state !== "backup-loading" ? RECOVERY : [] } }
  case "usage.cacheSizes": return { result: { usageBytes: 12200, conversationBytes: 3400000 } }
  case "backup.freeSpace": return { result: { bytes: 412000000000 } }
  }
  return { error: { code: -32005, message: "Not available in demo mode." } }
}
