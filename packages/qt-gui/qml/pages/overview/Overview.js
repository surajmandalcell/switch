.pragma library

// Overview data and geometry (specs/port/overview.md 2, 3): pure functions, no QML types.

var MONTHS = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
var MONTHS_LONG = ["January", "February", "March", "April", "May", "June", "July", "August", "September",
                   "October", "November", "December"]
var WEEKDAYS = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
var WEEKDAYS_LONG = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]
var RAMP = ["#5B8DEF", "#F0883E", "#3FB68B", "#B26BE0", "#E5638B", "#D9B43A",
            "#2FB5C7", "#7A6BE0", "#9BCB4A", "#E0705A", "#5CA0D3", "#C98A5E"]
var MAX_SERIES = 6
var DIMMED = 0.38

// MARK: days (OverviewDay, UTC, English names)

function parts(day) { var p = day.split("-"); return [Number(p[0]), Number(p[1]), Number(p[2])] }
function epoch(day) { var p = parts(day); return Math.round(Date.UTC(p[0], p[1] - 1, p[2]) / 86400000) }
function weekday(day) { return ((epoch(day) + 4) % 7 + 7) % 7 }
function short(day) { var p = parts(day); return MONTHS[p[1] - 1] + " " + p[2] }
function long(day) { var p = parts(day); return WEEKDAYS[weekday(day)] + ", " + MONTHS[p[1] - 1] + " " + p[2] + ", " + p[0] }
function title(day) { var p = parts(day); return WEEKDAYS_LONG[weekday(day)] + ", " + MONTHS_LONG[p[1] - 1] + " " + p[2] }
function month(day) { return MONTHS[parts(day)[1] - 1] }
function dayString(e) {
  var d = new Date(e * 86400000)
  return d.getUTCFullYear() + "-" + ("0" + (d.getUTCMonth() + 1)).slice(-2) + "-" + ("0" + d.getUTCDate()).slice(-2)
}

// MARK: numbers (UsagePresentation)

// The client locale's decimal separator ("1,2K" in German), as the Mac formatters use the user's locale.
// shortcut: K/M/B/T suffixes stay English (Foundation writes "1,2 Mio."); port ICU compact-short before a translated release.
function num(v) { return String(v).replace(".", typeof Qt !== "undefined" ? Qt.locale().decimalPoint : ".") }

// formatTokens: "950", "1.2K", "12K", "123K", "3.2M", "1.3B".
function tokens(n) {
  n = Number(n) || 0
  if (Math.abs(n) < 1000) return String(Math.round(n))
  var units = ["K", "M", "B", "T"], v = n, u = -1
  while (Math.abs(v) >= 1000 && u < units.length - 1) { v /= 1000; ++u }
  var r = Math.abs(v) < 10 ? Math.round(v * 10) / 10 : Math.round(v)
  if (Math.abs(r) >= 1000 && u < units.length - 1) { r = Math.round(r / 100) / 10; ++u }
  return num(r) + units[u]
}

// formatCurrency: "$1.9K", "$12K", "$338", "$7.01", "$0.5".
function currency(v) {
  if (v >= 1000) return "$" + num(Number((v / 1000).toFixed(1))) + "K"
  if (v >= 10) return "$" + String(Math.round(v))
  return "$" + num(Number(v.toFixed(2)))
}

// ByteCountFormatter .file (decimal): "0 KB" for zero.
function bytes(b) {
  if (!b) return "0 KB"
  if (b < 1000) return b + " bytes"
  var units = ["KB", "MB", "GB", "TB"], v = b, u = -1
  while (v >= 1000 && u < units.length - 1) { v /= 1000; ++u }
  var digits = u === 0 ? 0 : (u === 1 ? 1 : 2)
  return num(Number(v.toFixed(digits))) + " " + units[u]
}

// MARK: names

function displayName(service) {
  var fixed = { "codex": "Codex CLI", "grok-build": "Grok Build", "claude-code": "Claude Code",
                "gemini-cli": "Gemini CLI", "antigravity-cli": "Antigravity CLI" }
  if (fixed[service]) return fixed[service]
  return service.split("-").map(function (w) { return w.charAt(0).toUpperCase() + w.slice(1) }).join(" ")
}
function toolName(service) { return displayName(service) }
function sharedName(key) { return key.indexOf("shared:") === 0 ? displayName(key.slice(7)) + " (shared)" : null }
function projectLabel(p) {
  var name = p.replace(/\/+$/, "").split("/").pop()
  return p.charAt(0) === "/" && name !== "" ? name : p
}
function tipLabel(s) {
  return s.service && !/ \(shared\)$/.test(s.label) ? toolName(s.service) + " · " + s.label : s.label
}

// MARK: colors (OverviewPalette)

// FNV-1a 32-bit over the UTF-8 bytes.
function hash(key) {
  var h = 2166136261
  function put(b) { h = Math.imul((h ^ b) >>> 0, 16777619) >>> 0 }
  for (var i = 0; i < key.length; ++i) {
    var c = key.codePointAt(i)
    if (c > 0xFFFF) ++i
    if (c < 0x80) put(c)
    else if (c < 0x800) { put(0xC0 | c >> 6); put(0x80 | c & 63) }
    else if (c < 0x10000) { put(0xE0 | c >> 12); put(0x80 | c >> 6 & 63); put(0x80 | c & 63) }
    else { put(0xF0 | c >> 18); put(0x80 | c >> 12 & 63); put(0x80 | c >> 6 & 63); put(0x80 | c & 63) }
  }
  return h
}
function hashed(key) { return RAMP[hash(key) % 12] }
function slotColor(key, taken) {
  var slot = hash(key) % 12
  while (taken[slot] && Object.keys(taken).length < 12) slot = (slot + 1) % 12
  taken[slot] = true
  return RAMP[slot]
}
function hex2(v) { return ("0" + Math.round(Math.max(0, Math.min(255, v))).toString(16)).slice(-2) }
// The blend runs on Display P3 components, not sRGB: the Mac captures show codex 0AA17D at +0.38 as
// #81C7B3, which a P3 blend gives within 3 levels (#7EC5AF) and an sRGB blend misses (#6BC6AE). The spec
// (2.2) says sRGB; the captures win.
var S2P = [[0.8225, 0.1774, 0], [0.0332, 0.9669, 0], [0.0171, 0.0724, 0.9108]]
var P2S = [[1.2249, -0.2247, 0], [-0.0420, 1.0419, 0], [-0.0197, -0.0786, 1.0979]]
function toLin(c) { return c <= 0.04045 ? c / 12.92 : Math.pow((c + 0.055) / 1.055, 2.4) }
function toGam(c) { return c <= 0.0031308 ? c * 12.92 : 1.055 * Math.pow(c, 1 / 2.4) - 0.055 }
function mat(m, v) { return m.map(function (r) { return r[0] * v[0] + r[1] * v[1] + r[2] * v[2] }) }
function blend(hex, f, toWhite) {
  var s = [1, 3, 5].map(function (i) { return toLin(parseInt(hex.substr(i, 2), 16) / 255) })
  var p = mat(S2P, s).map(function (c) { c = toGam(c); return c + ((toWhite ? 1 : 0) - c) * f })
  return "#" + mat(P2S, p.map(toLin)).map(function (c) { return hex2(toGam(Math.max(0, Math.min(1, c))) * 255) }).join("")
}
// Color.opacity(a): multiplies the color's own alpha (the tertiary "Other" color is translucent).
function fade(c, a) { var q = Qt.tint(c, "transparent"); return Qt.rgba(q.r, q.g, q.b, q.a * a) }
// pal: { brands: Theme.brands, dark }
function accountColor(service, rank, pal) {
  var b = pal.brands[service]
  if (!b) return hashed(service)
  var base = b[pal.dark ? 1 : 0]
  var step = [0, 0.38, -0.3, 0.62, -0.5][rank % 5]
  return rank > 0 && step !== 0 ? blend(base, Math.abs(step), step > 0) : base
}

// MARK: dataset (OverviewDataset.make)

// summary, year: usage.history `summary` values; rows: the accounts topic rows; other: tertiary label color.
function make(summary, year, rows, pal) {
  var named = {}
  for (var r = 0; r < rows.length; ++r) if (named[rows[r].id.toLowerCase()] === undefined) named[rows[r].id.toLowerCase()] = rows[r].label
  var live = summary.groups.filter(function (g) { return g.tokens > 0 })
  var ranks = {}, taken = {}, series = []
  for (var i = 0; i < Math.min(live.length, MAX_SERIES); ++i) {
    var g = live[i], service = g.services && g.services.length ? g.services[0] : ""
    var rank = ranks[service] || 0
    ranks[service] = rank + 1
    var s
    if (summary.grouping === "account") {
      var shared = sharedName(g.key)
      var label = shared || named[g.key.toLowerCase()]
      s = { id: g.key, label: label !== undefined ? label : "Removed account", color: accountColor(service, rank, pal),
            tokens: g.tokens, daily: g.daily, service: service || null }
    } else {
      s = { id: g.key, label: g.label, color: slotColor(g.key, taken), tokens: g.tokens, daily: g.daily, service: null }
    }
    s.tip = tipLabel(s)
    series.push(s)
  }
  if (live.length > MAX_SERIES) {
    var daily = summary.days.map(function () { return 0 }), tok = 0
    for (var k = MAX_SERIES; k < live.length; ++k) {
      tok += live[k].tokens
      for (var d = 0; d < daily.length; ++d) daily[d] += live[k].daily[d]
    }
    series.push({ id: "other", label: "Other", color: pal.other, tokens: tok, daily: daily, service: null, tip: "Other" })
  }
  var active = year.dailyTotals.filter(function (t) { return t > 0 }).sort(function (a, b) { return a - b })
  // the Mac-reference demo pins its cuts
  var cuts = year.heatCuts || [0.25, 0.5, 0.75].map(function (q) { return active.length ? active[Math.min(Math.floor(active.length * q), active.length - 1)] : 0 })
  var tools = {}
  for (var y = 0; y < year.groups.length; ++y) {
    var yg = year.groups[y], sv = yg.services && yg.services.length ? yg.services[0] : ""
    if (!sv) continue
    if (!tools[sv]) tools[sv] = yg.daily.map(function () { return 0 })
    for (var j = 0; j < yg.daily.length; ++j) tools[sv][j] += yg.daily[j]
  }
  var yearTools = Object.keys(tools).map(function (k) {
    return { service: k, daily: tools[k], total: tools[k].reduce(function (a, b) { return a + b }, 0) }
  }).sort(function (a, b) { return b.total - a.total || (a.service < b.service ? -1 : a.service > b.service ? 1 : 0) })
  var yearTokens = year.dailyTotals.reduce(function (a, b) { return a + b }, 0)
  return {
    period: summary.period, grouping: summary.grouping, days: summary.days, series: series, totals: summary.totals,
    yearDays: year.days, yearTotals: year.dailyTotals, yearTools: yearTools, heatCuts: cuts, yearTokens: yearTokens,
    yearOffset: year.days.length ? weekday(year.days[0]) : 0
  }
}

function heatLevel(ds, t) {
  if (t <= 0) return 0
  var n = 1
  for (var i = 0; i < ds.heatCuts.length; ++i) if (t > ds.heatCuts[i]) ++n
  return n
}

function noun(g) { return g === "account" ? "account" : (g === "model" ? "model" : "project") }

function emptyText(ds) {
  if (ds.grouping === "account" && ds.series.length === 0 && ds.totals.tokens > 0)
    return "By account needs history that belongs to one account. Claude Code profiles that share history show under Models and Projects."
  return "No usage in the last " + ds.days.length + " days. Use Codex, Claude Code, or Grok Build and it shows here."
}

// VoiceOver values of the four charts (5.1).
function streamSummary(ds) {
  var t = ds.totals
  return "Last " + ds.days.length + " days, " + tokens(t.tokens) + " tokens by " + noun(ds.grouping)
         + (t.busiestDay ? ", most on " + short(t.busiestDay) : "")
}
function heatmapSummary(ds) {
  var best = -1, bv = 0
  for (var i = 0; i < ds.yearTotals.length; ++i) if (ds.yearTotals[i] > bv) { bv = ds.yearTotals[i]; best = i }
  return "Last 12 months, " + tokens(ds.yearTokens) + " tokens" + (best >= 0 ? ", most on " + short(ds.yearDays[best]) : "")
}
function ridgeSummary(ds) {
  return "Daily usage by " + noun(ds.grouping) + ". "
         + ds.series.slice(0, 3).map(function (s) { return s.label + ", " + tokens(s.tokens) + " tokens" }).join(". ")
}
function waffleSummary(ds) {
  var c = cells(ds.series.map(function (s) { return s.tokens }))
  return "Share of tokens by " + noun(ds.grouping) + ". "
         + ds.series.map(function (s, i) { return s.label + ", " + percent(c[i]).slice(0, -1) + " percent" }).join(". ")
}

// MARK: curves (Path.addMonotone)

function f(v) { return Math.round(v * 100) / 100 }
function monotone(xs, ys) {
  var n = xs.length, s = [], t = [], segs = [], i
  for (i = 0; i < n - 1; ++i) { var dx = xs[i + 1] - xs[i]; s.push((ys[i + 1] - ys[i]) / (dx === 0 ? 0.0001 : dx)) }
  for (i = 0; i < n; ++i) {
    if (i === 0) t.push(s[0])
    else if (i === n - 1) t.push(s[n - 2])
    else { var a = s[i - 1], b = s[i]; t.push(a * b > 0 ? 2 * a * b / (a + b) : 0) }
  }
  for (i = 0; i < n - 1; ++i) {
    var third = (xs[i + 1] - xs[i]) / 3
    segs.push(" C" + f(xs[i] + third) + " " + f(ys[i] + t[i] * third) + " " + f(xs[i + 1] - third) + " "
              + f(ys[i + 1] - t[i + 1] * third) + " " + f(xs[i + 1]) + " " + f(ys[i + 1]))
  }
  return segs.join("")
}
// A curve through the points; `connect` draws a line to the first point instead of moving there.
function curve(xs, ys, connect) { return (connect ? " L" : "M") + f(xs[0]) + " " + f(ys[0]) + monotone(xs, ys) }
function reversed(a) { return a.slice().reverse() }

function xs(width, count) {
  var a = []
  for (var i = 0; i < count; ++i) a.push(width * i / Math.max(1, count - 1))
  return a
}

// MARK: stream (OverviewStreamLayout, silhouette baseline)

function stack(series, h) {
  var n = series.length ? series[0].daily.length : 0, tot = [], mx = 1, i, k
  for (i = 0; i < n; ++i) { var s = 0; for (k = 0; k < series.length; ++k) s += series[k].daily[i]; tot.push(s); mx = Math.max(mx, s) }
  var scale = (h - 12) / mx, mid = h / 2, tops = [], bots = [], cur = tot.map(function (t) { return mid - t * scale / 2 })
  for (k = 0; k < series.length; ++k) {
    var top = [], bot = []
    for (i = 0; i < n; ++i) { top.push(cur[i]); cur[i] += series[k].daily[i] * scale; bot.push(cur[i]) }
    tops.push(top); bots.push(bot)
  }
  return { tops: tops, bots: bots, totals: tot }
}
function bandPath(x, top, bot) { return curve(x, top, false) + curve(reversed(x), reversed(bot), true) + " Z" }

// MARK: date axis (OverviewDateAxis)

function axis(days) {
  if (days.length < 2) return []
  var last = days.length - 1, out = [], i
  if (days.length <= 7) for (i = 0; i <= last; i += 2) out.push({ i: i, text: WEEKDAYS[weekday(days[i])] })
  else for (i = 0; i < 5; ++i) { var idx = Math.round(i * last / 4); out.push({ i: idx, text: short(days[idx]) }) }
  return out
}

// MARK: heatmap (OverviewHeatLayout)

var HEAT = { gap: 3, left: 30, top: 18, aspect: 6.6 }
function heatLayout(w, h, offset, count) {
  var columns = Math.floor((offset + count + 6) / 7)
  return { offset: offset, count: count, columns: columns,
           cw: Math.max((w - HEAT.left - HEAT.gap * (columns - 1)) / columns, 1),
           ch: Math.max((h - HEAT.top - HEAT.gap * 6) / 7, 1) }
}
function heatRect(L, index) {
  var col = Math.floor((L.offset + index) / 7), row = (L.offset + index) % 7
  return { x: HEAT.left + col * (L.cw + HEAT.gap), y: HEAT.top + row * (L.ch + HEAT.gap), w: L.cw, h: L.ch }
}
function heatIndex(L, px, py) {
  var x = px - HEAT.left, y = py - HEAT.top
  if (x < 0 || y < 0) return -1
  var col = Math.floor(x / (L.cw + HEAT.gap)), row = Math.floor(y / (L.ch + HEAT.gap))
  if (col >= L.columns || row >= 7 || x - col * (L.cw + HEAT.gap) > L.cw || y - row * (L.ch + HEAT.gap) > L.ch) return -1
  var i = col * 7 + row - L.offset
  return i >= 0 && i < L.count ? i : -1
}
// Month labels: above the first day of a month, at least 3 columns after the last label.
function heatMonths(ds) {
  var out = [], last = -4
  for (var i = 0; i < ds.yearDays.length; ++i) {
    if (ds.yearDays[i].slice(-3) !== "-01") continue
    var col = Math.floor((ds.yearOffset + i) / 7)
    if (col < last + 3) continue
    last = col
    out.push({ i: i, text: month(ds.yearDays[i]) })
  }
  return out
}

// MARK: ridgeline (OverviewRidgeLayout)

var RIDGE = { axis: 20, overlap: 1.9, margin: 4, lift: 6 }
function ridgeLayout(h, n) {
  var span = Math.max(h - RIDGE.axis - 2 * RIDGE.margin - RIDGE.lift, 1)
  var peak = n > 1 ? Math.min(span / ((n - 1) + RIDGE.overlap) * RIDGE.overlap, 150) : span
  return { peak: peak, pitch: n > 1 ? (span - peak) / (n - 1) : 0 }
}
function ridgeBase(L, row) { return RIDGE.margin + RIDGE.lift + L.peak + row * L.pitch }
function ridgeRow(L, n, y) {
  var best = 0
  for (var r = 1; r < n; ++r) if (Math.abs(ridgeBase(L, r) - L.peak * 0.25 - y) < Math.abs(ridgeBase(L, best) - L.peak * 0.25 - y)) best = r
  return best
}
function ridgeYs(s, L, row) {
  var top = Math.max(1, Math.max.apply(null, s.daily)), base = ridgeBase(L, row)
  return s.daily.map(function (v) { return base - L.peak * v / top })
}

// MARK: waffle (OverviewWaffle)

var WAFFLE = { gap: 3, columns: 20, rows: 10, total: 200, share: 0.4, legendGap: 24, minRow: 20, maxRow: 28 }
function cellSide(w) { return Math.max((w - WAFFLE.gap * 19) / 20, 1) }
function waffleHeight(w) { return cellSide(w) * 10 + WAFFLE.gap * 9 }
function cells(tok) {
  var sum = tok.reduce(function (a, b) { return a + b }, 0)
  if (sum <= 0) return tok.map(function () { return 0 })
  var exact = tok.map(function (t) { return t * 200 / sum }), out = exact.map(Math.floor)
  var spare = 200 - out.reduce(function (a, b) { return a + b }, 0)
  var order = exact.map(function (_, i) { return i }).sort(function (a, b) {
    var ra = exact[a] - out[a], rb = exact[b] - out[b]
    return rb - ra || a - b
  })
  for (var i = 0; i < spare; ++i) out[order[i]] += 1
  return out
}
function owners(c) {
  var o = []
  for (var i = 0; i < c.length; ++i) for (var k = 0; k < c[i]; ++k) o.push(i)
  return o
}
function percent(c) { return c < 2 ? "<1%" : Math.floor(c / 2) + "%" }

// MARK: day sheet (OverviewDayDetail.make)

function dayDetail(day, dayTokens, input, rows, pal) {
  if (dayTokens <= 0) return null
  var points = (input.points || []).filter(function (p) { return p.day === day })
  var costs = points.filter(function (p) { return p.costUSD !== undefined && p.costUSD !== null })
  var cost = costs.length ? costs.reduce(function (a, p) { return a + p.costUSD }, 0) : null
  var byCost = (cost || 0) > 0
  var named = {}, per = {}, sole = {}
  for (var r = 0; r < rows.length; ++r) {
    named[rows[r].id.toLowerCase()] = rows[r].label
    per[rows[r].providerID] = (per[rows[r].providerID] || []).concat([rows[r].id.toLowerCase()])
  }
  for (var sv in per) if (per[sv].length === 1) sole[sv] = per[sv][0]
  var acc = {}, mod = {}
  points.forEach(function (p) {
    var key = p.accountID || sole[p.service] || "service:" + p.service
    var a = acc[key] || (acc[key] = { service: "", account: 0, transcript: 0, cost: 0 })
    a.service = p.service
    var tr = !!(p.model || p.project)
    if (tr) a.transcript += p.tokens; else a.account += p.tokens
    a.cost += p.costUSD || 0
    if (tr) {
      var mk = p.model || "unknown", m = mod[mk] || (mod[mk] = { transcript: 0, cost: 0 })
      m.transcript += p.tokens
      m.cost += p.costUSD || 0
    }
  })
  function order(a, b) { return b.value - a.value || (a.id < b.id ? -1 : a.id > b.id ? 1 : 0) }
  function cap(all) {
    if (all.length <= MAX_SERIES) return all
    var rest = all.slice(MAX_SERIES).reduce(function (s, x) { return s + x.value }, 0)
    return all.slice(0, MAX_SERIES).concat([{ id: "other", label: "Other", color: pal.other, value: rest, service: null }])
  }
  var ranks = {}
  var accounts = Object.keys(acc).map(function (k) {
    var a = acc[k]
    return { id: k, a: a, value: byCost ? a.cost : Math.max(a.account, a.transcript) }
  }).filter(function (x) { return x.value > 0 }).sort(order).map(function (x) {
    var rank = ranks[x.a.service] || 0
    ranks[x.a.service] = rank + 1
    var label = named[x.id] !== undefined ? named[x.id]
              : (x.id.indexOf("service:") === 0 ? displayName(x.a.service) : (sharedName(x.id) || "Removed account"))
    return { id: x.id, label: label, color: accountColor(x.a.service, rank, pal), value: x.value, service: x.a.service || null }
  })
  var taken = {}
  var models = Object.keys(mod).map(function (k) {
    return { id: k, value: byCost ? mod[k].cost : mod[k].transcript }
  }).filter(function (x) { return x.value > 0 }).sort(order).map(function (x) {
    return { id: x.id, label: x.id === "unknown" ? "Unknown model" : x.id, color: slotColor(x.id, taken), value: x.value, service: null }
  })
  var sessions = null
  if (input.sessions && input.sessions.length) {
    var threads = {}, e = epoch(day)
    ;(input.threads || []).forEach(function (t) { threads[t.threadID || t.id] = t })
    sessions = input.sessions.map(function (s) {
      var th = s.threadID ? threads[s.threadID] : undefined
      var start = s.start ? new Date(s.start) : null
      return {
        id: s.id, title: th && th.title ? th.title : projectLabel(s.project || ""), tool: toolName(s.service), start: start,
        continued: start ? Math.floor(start.getTime() / 86400000) !== e : true, tokens: s.tokens,
        cost: s.costUSD === undefined ? null : s.costUSD, chatID: th ? th.id : null, removed: !!s.threadID && !th
      }
    })
  }
  return { day: day, tokens: dayTokens, cost: cost, byCost: byCost, sessions: sessions, byAccount: cap(accounts), byModel: cap(models) }
}

function sharePercent(v, total) {
  var share = v / Math.max(total, 1) * 100
  return share < 1 ? "<1%" : Math.round(share) + "%"
}

// MARK: self-check (spec test vectors); returns the failures, empty when all pass.
function selfCheck() {
  var bad = []
  function eq(name, a, b) { if (JSON.stringify(a) !== JSON.stringify(b)) bad.push(name + ": " + JSON.stringify(a) + " != " + JSON.stringify(b)) }
  eq("hash empty", hash(""), 2166136261)
  eq("hash a", hash("a"), 0xE40C292C)
  eq("epoch", epoch("2026-10-03"), 20729)
  eq("long", long("2026-10-03"), "Sat, Oct 3, 2026")
  eq("title", title("2026-10-03"), "Saturday, October 3")
  eq("cells 111", cells([1, 1, 1]), [67, 67, 66])
  eq("cells 00", cells([0, 0]), [0, 0])
  eq("percent", [percent(0), percent(1), percent(2), percent(3), percent(200)], ["<1%", "<1%", "1%", "1%", "100%"])
  eq("tokens", [tokens(950), tokens(1234), tokens(12345), tokens(123456), tokens(3210000), tokens(1300000000), tokens(999999)],
     ["950", "1.2K", "12K", "123K", "3.2M", "1.3B", "1M"])
  eq("currency", [currency(1900), currency(12000), currency(338), currency(7.01), currency(0.5), currency(7)],
     ["$1.9K", "$12K", "$338", "$7.01", "$0.5", "$7"])
  eq("blend", [blend("#0AA17D", 0.38, true), blend("#FFFFFF", 0.5, true), blend("#000000", 0.3, false)], ["#7ec5af", "#ffffff", "#000000"])
  eq("axis 30", axis(Array.apply(null, Array(30)).map(function (_, i) { return dayString(20700 + i) })).map(function (a) { return a.i }), [0, 7, 15, 22, 29])
  var L = ridgeLayout(272, 7)
  eq("ridge last base", Math.round(ridgeBase(L, 6) * 1000) / 1000, 272 - 24)
  return bad
}
