.pragma library
.import "Overview.js" as O

// Demo replies for --demo (the captures): usage.history summaries, usage.day, and the recent backups.
// One year of day totals is split over accounts, models, and projects with stable pseudo-random
// shares, so every grouping adds up to the same days. `state` picks a capture state.

var TODAY = "2026-11-14"
var ACC = "0b1c6a52-7a0e-4d3c-9a51-0f6f1d3c00"

var GROUPS = {
  account: [
    { key: ACC + "01", services: ["codex"], w: 1.0 },
    { key: ACC + "02", services: ["claude-code"], w: 0.8 },
    { key: "shared:claude-code", services: ["claude-code"], w: 0.45 },
    { key: ACC + "03", services: ["droid"], w: 0.35 },
    { key: ACC + "99", services: ["codex"], w: 0.22 },
    { key: ACC + "98", services: ["grok-build"], w: 0.16 },
    { key: ACC + "97", services: ["codex"], w: 0.06 },
    { key: ACC + "96", services: ["droid"], w: 0.04 }
  ],
  model: [
    { key: "gpt-5.1-codex", services: ["codex"], w: 1.0 },
    { key: "claude-opus-4-5", services: ["claude-code"], w: 0.7 },
    { key: "claude-sonnet-4-5-20250929-with-a-very-long-model-name", services: ["claude-code"], w: 0.45 },
    { key: "gpt-5.1", services: ["codex"], w: 0.3 },
    { key: "glm-4.6", services: ["droid"], w: 0.22 },
    { key: "grok-code-fast-1", services: ["grok-build"], w: 0.16 },
    { key: "unknown", services: ["codex"], w: 0.05 },
    { key: "gemini-2.5-pro", services: ["droid"], w: 0.03 }
  ],
  project: [
    { key: "/home/ada/src/garden-planner", services: ["codex"], w: 1.0 },
    { key: "/home/ada/src/billing-service-migration-to-the-new-ledger-and-invoicing-platform", services: ["claude-code"], w: 0.6 },
    { key: "/home/ada/src/weather-app", services: ["codex"], w: 0.4 },
    { key: "/home/ada/notes", services: ["claude-code"], w: 0.25 },
    { key: "/home/ada/src/notes-cli", services: ["droid"], w: 0.18 },
    { key: "Unknown project", services: ["grok-build"], w: 0.1 },
    { key: "/home/ada/src/dotfiles", services: ["codex"], w: 0.05 },
    { key: "/tmp/scratch", services: ["codex"], w: 0.03 }
  ]
}

function rnd(seed) {   // mulberry32
  var a = seed >>> 0
  return function () {
    a = (a + 0x6D2B79F5) >>> 0
    var t = Math.imul(a ^ (a >>> 15), 1 | a)
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296
  }
}

var cache = null
function year() {
  if (cache) return cache
  var e0 = O.epoch(TODAY) - 364, days = [], totals = [], r = rnd(7)
  for (var i = 0; i < 365; ++i) {
    var day = O.dayString(e0 + i), wd = O.weekday(day)
    var ramp = i < 40 ? 0 : 0.25 + 0.75 * (i / 364)
    var idle = r() < (wd === 0 || wd === 6 ? 0.45 : 0.08) && i < 330   // the last month has usage every day
    days.push(day)
    totals.push(idle || ramp === 0 ? 0 : Math.round(ramp * (0.6 + r() * 1.4) * 2.4e7))
  }
  var split = {}
  for (var g in GROUPS) {
    var list = GROUPS[g]
    split[g] = list.map(function () { return [] })
    for (var d = 0; d < 365; ++d) {
      var shares = list.map(function (x, k) { return x.w * (0.4 + rnd(O.hash(x.key) + d)() * 1.2) })
      var sum = shares.reduce(function (a, b) { return a + b }, 0)
      for (var k = 0; k < list.length; ++k) split[g][k].push(Math.round(totals[d] * shares[k] / sum))
    }
  }
  cache = { days: days, totals: totals, split: split }
  return cache
}

function sum(a) { return a.reduce(function (s, v) { return s + v }, 0) }

// The Mac reference captures (docs/screenshots/overview-*.png): band heights in points read off the 200 pt
// stream plot for Oct 13..20, 2026 (k = tokens per point), and the heatmap level of each day from
// Oct 20, 2025. State "mac-dark" ends on Oct 19 (overview-dark, overview-insights), "mac-light" on Oct 20.
var MAC = {
  first: "2026-10-13",
  groups: [
    { key: "mac-claude", services: ["claude-code"], k: 7.176e6, pt: [62, 15, 34, 101, 36, 0, 72.5, 52] },
    { key: "shared:droid", services: ["droid"], k: 7.176e6, pt: [80, 35, 80, 82.5, 33, 0, 0, 11] },
    { key: "mac-codex-s", services: ["codex"], k: 7.34e6, pt: [13, 0.6, 6.5, 3.5, 0.6, 3, 4, 0] },
    { key: "mac-codex-m", services: ["codex"], k: 7.176e6, pt: [0, 0, 0, 0, 0, 0.43, 0, 0] }
  ],
  rows: [
    { id: "mac-claude", label: "a••••@example", provider: "claude-code" },
    { id: "mac-codex-s", label: "a••••@example", provider: "codex" },
    { id: "mac-codex-m", label: "m••••@example", provider: "codex" }
  ],
  heat: "000001100021100101101000000111010010010011000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000011111111101111222101222222331223322112114222123332221223311132112233234312123330001001223323422331322321314322344344324442244343223344223444434334342344444433244444344444444444334443342343133",
  levelTokens: [0, 2e6, 1e7, 4e7, 1.2e8],
  totals: { "mac-dark": { tokens: 4.8e9, costUSD: 1800 }, "mac-light": { tokens: 4.2e9, costUSD: 1700 } }
}

function macSummary(period, state) {
  var light = state === "mac-light", e0 = O.epoch(MAC.first) + (light ? 1 : 0)
  if (period === "year") {
    var lv = MAC.heat.slice(light ? 1 : 0, light ? 366 : 365).split("").map(Number)
    var yd = lv.map(function (_, i) { return O.dayString(e0 + 7 - 365 + i) })   // ends on the week's last day
    var yt = lv.map(function (l) { return MAC.levelTokens[l] })
    return { period: "year", grouping: "model", days: yd, dailyTotals: yt, heatCuts: [5e6, 2e7, 8e7],
             groups: [{ key: "gpt-5-codex", label: "gpt-5-codex", services: ["claude-code"], tokens: sum(yt), costUSD: null, daily: yt }],
             totals: { tokens: sum(yt), costUSD: null, activeAccounts: 3, busiestDay: null, busiestDayTokens: 0 } }
  }
  var days = [0, 1, 2, 3, 4, 5, 6].map(function (i) { return O.dayString(e0 + i) })
  var groups = MAC.groups.map(function (g) {
    var daily = g.pt.slice(light ? 1 : 0, light ? 8 : 7).map(function (p) { return Math.round(p * g.k) })
    return { key: g.key, label: g.key, services: g.services, tokens: sum(daily), costUSD: null, daily: daily }
  })
  var t = MAC.totals[state]
  return { period: "week", grouping: "account", days: days, groups: groups,
           dailyTotals: days.map(function (_, d) { return sum(groups.map(function (g) { return g.daily[d] })) }),
           totals: { tokens: t.tokens, costUSD: t.costUSD, activeAccounts: 3, busiestDay: "2026-10-16", busiestDayTokens: 1.3e9 } }
}

// The usage.history `summary` for a period and grouping; state "nousage" gives zeros.
function summary(period, grouping, state) {
  if (state.indexOf("mac") === 0) return macSummary(period, state)
  var y = year(), n = period === "month" ? 30 : (period === "year" ? 365 : 7), from = 365 - n
  var zero = state === "nousage" || state === "empty"
  var groups = GROUPS[grouping].map(function (x, k) {
    var daily = y.split[grouping][k].slice(from).map(function (v) { return zero ? 0 : v })
    var t = sum(daily)
    var label = grouping === "project" ? O.projectLabel(x.key) : (x.key === "unknown" ? "Unknown model" : x.key)
    return { key: x.key, label: label, services: x.services, tokens: t, costUSD: t ? t / 1e6 * 1.9 : null, daily: daily }
  }).sort(function (a, b) { return b.tokens - a.tokens || (a.key < b.key ? -1 : 1) })
  var dailyTotals = groups[0].daily.map(function (_, d) { return sum(groups.map(function (g) { return g.daily[d] })) })
  var best = -1, bv = 0
  for (var d = 0; d < dailyTotals.length; ++d) if (dailyTotals[d] > bv) { bv = dailyTotals[d]; best = d }
  var days = y.days.slice(from), tokens = sum(dailyTotals)
  var active = GROUPS.account.filter(function (x, k) {
    return x.key.indexOf("shared:") !== 0 && !zero && sum(y.split.account[k].slice(from)) > 0
  }).length
  return { period: period, grouping: grouping, days: days, dailyTotals: dailyTotals, groups: groups,
           totals: { tokens: tokens, costUSD: tokens ? tokens / 1e6 * 1.9 : null, activeAccounts: active,
                     busiestDay: best >= 0 ? days[best] : null, busiestDayTokens: bv } }
}

// The usage.day reply for a day.
function usageDay(day) {
  var y = year(), d = y.days.indexOf(day)
  if (d < 0) return { day: day, points: [], sessions: [], threads: [] }
  var acct = { "codex": ACC + "01", "claude-code": ACC + "02", "droid": ACC + "03" }
  var points = []
  GROUPS.model.forEach(function (x, k) {
    var t = y.split.model[k][d]
    if (t <= 0) return
    var sv = x.services[0]
    points.push({ day: day, service: sv, accountID: acct[sv] || null, model: x.key === "unknown" ? null : x.key,
                  project: "/home/ada/src/garden-planner", tokens: t, costUSD: x.key === "glm-4.6" ? null : t / 1e6 * 1.9 })
  })
  points.push({ day: day, service: "codex", accountID: ACC + "99", tokens: Math.round(y.totals[d] * 0.08), costUSD: y.totals[d] * 0.08 / 1e6 * 1.9 })
  var base = Date.UTC(Number(day.slice(0, 4)), Number(day.slice(5, 7)) - 1, Number(day.slice(8, 10)))
  var plan = [
    ["s1", "codex", "t-1", "/home/ada/src/garden-planner", 9.5, 0.31],
    ["s2", "claude-code", null, "/home/ada/src/billing-service-migration-to-the-new-ledger-and-invoicing-platform", 11.2, 0.22],
    ["s3", "codex", "t-2", "/home/ada/src/weather-app", -3, 0.14],
    ["s4", "droid", null, "/home/ada/src/notes-cli", 14.75, 0.1],
    ["s5", "codex", "t-gone", "/home/ada/src/garden-planner", 16.1, 0.08],
    ["s6", "grok-build", null, "/home/ada/notes", 18.4, 0.06],
    ["s7", "claude-code", null, "/home/ada/notes", 20.05, 0.05],
    ["s8", "codex", "t-3", "/home/ada/src/dotfiles", 21.3, 0.04]
  ]
  var sessions = plan.map(function (p) {
    var t = Math.round(y.totals[d] * p[5])
    return { id: p[0], service: p[1], accountID: acct[p[1]] || null, threadID: p[2], project: p[3], model: null,
             start: new Date(base + p[4] * 3600000).toISOString(), tokens: t, costUSD: p[1] === "droid" ? null : t / 1e6 * 1.9 }
  })
  var threads = [
    { id: "chat-1", threadID: "t-1", title: "Port the Overview page to Qt Quick" },
    { id: "chat-2", threadID: "t-2", title: "" },
    { id: "chat-3", threadID: "t-3", title: "Sync the shell config across machines" }
  ]
  return { day: day, points: points, sessions: sessions, threads: threads }
}

// The newest three backups across all sets, as the card shows them.
function backups(state) {
  if (state === "nobackups" || state.indexOf("mac") === 0) return []
  return [
    { date: new Date("2026-11-14T09:12:00Z"), source: "Codex CLI", bytes: 48213504, state: "Complete", isSafety: false },
    { date: new Date("2026-11-13T21:40:00Z"), source: "Claude Code", bytes: 1288490188, state: "Complete with skipped items", isSafety: false },
    { date: new Date("2026-11-12T08:05:00Z"), source: "Codex CLI", bytes: 0, state: "Safety copy", isSafety: true }
  ]
}
