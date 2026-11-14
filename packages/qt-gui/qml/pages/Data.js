.pragma library

// Synthetic data for the slice: tokens(d, t) = round(1e6 * (1.2 + sin(0.7 d + t) + 0.3 t)), d in 0..29, t in 0..2.
var MONTHS = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
var WEEKDAYS = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
var DAY0 = Date.UTC(2026, 9, 16) // d = 0 is Oct 16, d = 29 is Nov 14 (UTC)

var TOOLS = [
  { id: "codex", tool: "Codex CLI", label: "ada@example" },
  { id: "claude-code", tool: "Claude Code", label: "ada@work" },
  { id: "droid", tool: "Droid", label: "Droid 1" }
]

function tokens(d, t) { return Math.round(1e6 * (1.2 + Math.sin(d * 0.7 + t) + 0.3 * t)) }

function dayDate(d) { return new Date(DAY0 + d * 86400000) }
function shortDay(d) { var x = dayDate(d); return MONTHS[x.getUTCMonth()] + " " + x.getUTCDate() }
function weekday(d) { return WEEKDAYS[dayDate(d).getUTCDay()] }

// UsagePresentation.formatTokens: 950, 1.2K, 12K, 123K, 3.2M ...
function fmt(n) {
  if (n < 1000) return String(n)
  var units = [[1e12, "T"], [1e9, "B"], [1e6, "M"], [1e3, "K"]]
  for (var i = 0; i < units.length; ++i) {
    if (n >= units[i][0]) {
      var v = n / units[i][0]
      var s = v < 10 ? (Math.round(v * 10) / 10).toFixed(1) : String(Math.round(v))
      return s.replace(/\.0$/, "") + units[i][1]
    }
  }
  return String(n)
}

// Series for the last `count` days of the 30, largest first. daily[] covers those days.
function series(count) {
  var first = 30 - count, out = []
  for (var t = 0; t < 3; ++t) {
    var daily = [], total = 0
    for (var d = first; d < 30; ++d) { var v = tokens(d, t); daily.push(v); total += v }
    out.push({ id: TOOLS[t].id, tool: TOOLS[t].tool, label: TOOLS[t].label, daily: daily, total: total, first: first })
  }
  out.sort(function (a, b) { return b.total - a.total })
  return out
}

function totals(ser) {
  var n = ser[0].daily.length, tot = [], best = 0, bestV = -1, sum = 0
  for (var i = 0; i < n; ++i) {
    var s = 0
    for (var k = 0; k < ser.length; ++k) s += ser[k].daily[i]
    tot.push(s); sum += s
    if (s > bestV) { bestV = s; best = i }
  }
  return { perDay: tot, sum: sum, busiest: ser[0].first + best, busiestV: bestV }
}

// Stacked silhouette around a centered axis (2.4): tops[k][i], bots[k][i] in plot y.
function stack(ser, plotH) {
  var n = ser[0].daily.length, tot = totals(ser).perDay, mx = 0
  for (var i = 0; i < n; ++i) mx = Math.max(mx, tot[i])
  var scale = (plotH - 12) / mx, mid = plotH / 2, tops = [], bots = []
  for (var k = 0; k < ser.length; ++k) { tops.push([]); bots.push([]) }
  for (var j = 0; j < n; ++j) {
    var y = mid - tot[j] * scale / 2
    for (var b = 0; b < ser.length; ++b) {
      tops[b].push(y)
      y += ser[b].daily[j] * scale
      bots[b].push(y)
    }
  }
  return { tops: tops, bots: bots, n: n }
}

// Path.addMonotone (2.9): returns the cubic segments through the points.
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
    segs.push([xs[i] + third, ys[i] + t[i] * third, xs[i + 1] - third, ys[i + 1] - t[i + 1] * third, xs[i + 1], ys[i + 1]])
  }
  return segs
}

function f(v) { return Math.round(v * 100) / 100 }

// Closed band path: top edge left to right, then the bottom edge back.
function band(xs, top, bot) {
  var a = monotone(xs, top), b = monotone(xs, bot), n = xs.length, i
  var d = "M" + f(xs[0]) + " " + f(top[0])
  for (i = 0; i < a.length; ++i) d += "C" + f(a[i][0]) + " " + f(a[i][1]) + " " + f(a[i][2]) + " " + f(a[i][3]) + " " + f(a[i][4]) + " " + f(a[i][5])
  d += "L" + f(xs[n - 1]) + " " + f(bot[n - 1])
  for (i = b.length - 1; i >= 0; --i) d += "C" + f(b[i][2]) + " " + f(b[i][3]) + " " + f(b[i][0]) + " " + f(b[i][1]) + " " + f(i === 0 ? xs[0] : b[i - 1][4]) + " " + f(i === 0 ? bot[0] : b[i - 1][5])
  return d + "Z"
}

// Axis labels (2.3): 7 days or fewer = indices 0,2,4,6 weekday names; else 5 labels "Oct 3".
function axis(first, count) {
  var out = [], i
  if (count <= 7) {
    for (i = 0; i < count; i += 2) out.push({ i: i, text: weekday(first + i) })
  } else {
    var last = count - 1
    for (i = 0; i < 5; ++i) { var idx = Math.floor(i * last / 4 + 0.5); out.push({ i: idx, text: shortDay(first + idx) }) }
  }
  return out
}
