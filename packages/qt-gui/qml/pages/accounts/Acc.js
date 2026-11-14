.pragma library

// Pure presentation rules of the Accounts page (accounts.md 2.4, 2.5, 3, 8; account-window.md 3, 5.6).

var BUILT_IN = { "codex": "Codex CLI", "grok-build": "Grok Build", "droid": "Droid", "claude-code": "Claude Code" }
var MONTHS = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
var MONTHS_LONG = ["January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December"]
var DAYS = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]

function isBuiltIn(p) { return BUILT_IN.hasOwnProperty(p) }
function providerName(p, names) { return (names && names[p]) || BUILT_IN[p] || p }
// AccountCopy.open: "Codex" for Codex, else the display name (AW:760-765).
function toolName(p, names) { return p === "codex" ? "Codex" : providerName(p, names) }

// Window shown in the table, card and popover: the first one with a value (VM:321-356).
function firstWindow(row) {
  var ws = row && row.windows ? row.windows : []
  for (var i = 0; i < ws.length; ++i) if (ws[i].usedPercent !== undefined && ws[i].usedPercent !== null) return ws[i]
  return null
}
function hasValue(w) { return w && w.usedPercent !== undefined && w.usedPercent !== null }

// 8.2: left (default) clamps at 0, used keeps overage. Unknown "–".
function pct(used, showUsed) {
  if (used === undefined || used === null) return "–"
  var u = Math.round(used)
  return String(showUsed ? u : Math.max(100 - u, 0))
}
function pctWord(used, showUsed) { var p = pct(used, showUsed); return p === "–" ? p : p + "% " + (showUsed ? "used" : "left") }

function pad2(n) { return n < 10 ? "0" + n : String(n) }
// timeFormat: "12h" | "24h"; auto is resolved by the caller from the system locale.
function clock(d, h24) {
  if (h24) return pad2(d.getHours()) + ":" + pad2(d.getMinutes())
  var h = d.getHours() % 12
  return (h === 0 ? 12 : h) + ":" + pad2(d.getMinutes()) + " " + (d.getHours() < 12 ? "AM" : "PM")
}
function startOfDay(t) { var d = new Date(t); d.setHours(0, 0, 0, 0); return d.getTime() }

// 8.4 reset text. Returns the full form ("Resets in 1h 45m", "Resets tomorrow 5:30 PM") or a past rule.
function resetText(resetIso, now, used, exact, h24) {
  if (!resetIso) return ""
  var t = Date.parse(resetIso)
  if (t <= now) return Math.round(used || 0) <= 0 ? "Not started" : "Resetting…"
  if (exact) {
    var d = new Date(t), days = Math.round((startOfDay(t) - startOfDay(now)) / 86400000), c = clock(d, h24)
    if (days <= 0) return "Resets " + c
    if (days === 1) return "Resets tomorrow " + c
    if (days < 7) return "Resets " + DAYS[d.getDay()] + " " + c
    return "Resets " + MONTHS[d.getMonth()] + " " + d.getDate() + ", " + c
  }
  var m = Math.floor((t - now) / 60000)
  if (m <= 0) return "Resets in <1m"
  var dd = Math.floor(m / 1440), hh = Math.floor((m % 1440) / 60), mm = m % 60
  if (dd > 0) return "Resets in " + dd + (dd === 1 ? " day " : " days ") + hh + "h " + mm + "m"
  if (hh > 0) return "Resets in " + hh + "h " + mm + "m"
  return "Resets in " + mm + "m"
}
// OverviewFormat.compactReset (ACC:1103-1119): "in 6d 8h", "in 1h 45m", "in 12m", "in <1m", or the exact text.
function compactReset(resetIso, now, used, exact, h24) {
  if (!resetIso) return ""
  var t = Date.parse(resetIso)
  if (t <= now || exact) { var s = resetText(resetIso, now, used, exact, h24); return s.indexOf("Resets ") === 0 ? s.substring(7) : s }
  var m = Math.floor((t - now) / 60000)
  if (m <= 0) return "in <1m"
  var dd = Math.floor(m / 1440), hh = Math.floor((m % 1440) / 60), mm = m % 60
  if (dd > 0) return "in " + dd + "d " + hh + "h"
  if (hh > 0) return "in " + hh + "h " + mm + "m"
  return "in " + mm + "m"
}

// AccountUsageSummary.reason (ACC:1184-1210). form: "short" | "table" | "full".
function reason(row, pname, form) {
  if (row.needsSignIn || row.verification === "needsSignIn") return "Sign in to see usage"
  if (row.needsDroidAccess) return "Allow access to see usage"
  if (row.error && !firstWindow(row))
    return form === "full" ? "Couldn't check usage: " + row.error : (form === "table" ? "Couldn't check usage" : "Couldn't check")
  if (row.availability === "noPlan") return form === "full" ? "No Go subscription on this key" : "No Go plan"
  if (row.fetchedAt || row.checkedAt) return form === "full" ? pname + " reports no usage" : "No usage available"
  return "Not checked yet"
}

function needsSignIn(row) { return !!row && (row.needsSignIn || row.verification === "needsSignIn") }
function canSwitch(row) { return !!row && row.verification !== "needsSignIn" && row.verification !== "unsupported" }
// Row action (ACC:1121-1130): first match wins.
function rowAction(row) {
  if (row.needsDroidAccess) return "Allow"
  if (row.isDefault) return "Default"
  if (needsSignIn(row)) return "Sign in"
  return "Switch"
}
// Sign in again is offered for built-ins; generic file providers with a login command need the catalog (helper need).
function canSignInAgain(p) { return isBuiltIn(p) }

// Eligible replacement: same provider, needs no sign-in, supported (VM:1499-1520).
function canDelete(row, rows) {
  if (!row.isDefault) return true
  for (var i = 0; i < rows.length; ++i)
    if (rows[i].id !== row.id && rows[i].providerID === row.providerID && canSwitch(rows[i]) && !rows[i].needsSignIn) return true
  return false
}

// Group order: saved service order, then providers in order of first appearance (ACC:1604-1606).
function groups(rows, order) {
  var seen = [], by = {}
  for (var i = 0; i < rows.length; ++i) {
    var p = rows[i].providerID
    if (!by[p]) { by[p] = []; seen.push(p) }
    by[p].push(rows[i])
  }
  var out = [], used = {}
  for (var k = 0; k < (order || []).length; ++k) if (by[order[k]] && !used[order[k]]) { out.push(order[k]); used[order[k]] = true }
  for (var j = 0; j < seen.length; ++j) if (!used[seen[j]]) out.push(seen[j])
  return out.map(function (p) { return { provider: p, rows: by[p] } })
}

// Placeholder window titles when an account has none (ACC:1212-1237).
function emptyTitles(p, rows) {
  for (var i = 0; i < rows.length; ++i) {
    if (rows[i].providerID !== p || !rows[i].windows || !rows[i].windows.length) continue
    return rows[i].windows.map(function (w) { return w.title })
  }
  if (p === "opencodego") return ["5 hours", "Weekly", "Monthly"]
  if (p === "codex" || p === "claude-code" || p === "grok-build") return ["Session", "Weekly"]
  if (p === "droid") return ["Standard tokens"]
  if (p === "gemini-cli") return ["Pro models", "Flash models"]
  return ["Usage"]
}

// UsagePace (core Providers/UsagePace.swift, account-window.md 3.2). Returns { badge, level, tooltip, tick }.
function duration(sec) {
  var m = Math.floor(sec / 60), d = Math.floor(m / 1440), h = Math.floor((m % 1440) / 60)
  if (d > 0) return d + "d " + h + "h"
  if (h > 0) return h + "h " + (m % 60) + "m"
  return m + "m"
}
function pace(w, now, showUsed) {
  var out = { badge: "", level: "none", tooltip: "", tick: -1 }
  if (!hasValue(w)) return out
  var used = Math.round(w.usedPercent)
  var band = used >= 90 ? "critical" : (used >= 80 ? "warning" : "normal")
  if (Math.round(100 - w.usedPercent) <= 0) return { badge: "Limit reached", level: "spent", tooltip: "Limit reached", tick: -1 }
  out.level = band
  if (!w.resetsAt || !w.windowMinutes) return out
  var reset = Date.parse(w.resetsAt), period = w.windowMinutes * 60, left = (reset - now) / 1000
  if (left <= 0) return out
  if (used === 0 && period <= 86400) return { badge: "Not started", level: "healthy", tooltip: "", tick: -1 }
  var elapsed = period - left
  if (elapsed < Math.max(60, period * 0.01)) return out
  var fraction = w.usedPercent / 100 / elapsed * period   // projected share at reset
  var tickAt = showUsed ? elapsed / period : 1 - elapsed / period
  if (fraction <= 0.9) return { badge: "", level: "healthy", tooltip: "~" + Math.round((1 - fraction) * 100) + "% left at reset", tick: -1 }
  if (fraction <= 1) {
    if (w.usedPercent < 5) return out
    var spare = Math.round((1 - fraction) * 100)
    if (spare >= 1) return { badge: "~" + spare + "% spare", level: "close", tooltip: "~" + Math.round(fraction * 100) + "% used at reset", tick: tickAt }
  } else if (w.usedPercent < 5) return out
  var tip = fraction > 1 ? "~" + Math.max(1, Math.round((fraction - 1) * 100)) + "% over limit at reset" : "~100% used at reset"
  var rate = w.usedPercent / elapsed, eta = rate > 0 ? (100 - w.usedPercent) / rate : -1
  return { badge: eta >= 0 && eta < left ? "Limit in " + duration(eta) : "", level: "runningOut", tooltip: tip, tick: tickAt }
}

// Fmt.money (en_US): "$12.40", sub-cent up to 4 decimals.
// "" + s, not String(s): the compiled cache called replace on the raw number
function group3(s) { return ("" + s).replace(/\B(?=(\d{3})+(?!\d))/g, ",") }
function money(v, cur) {
  if (v === undefined || v === null) return ""
  var sym = !cur || cur === "USD" ? "$" : cur + " ", neg = v < 0, a = Math.abs(v), s
  if (a > 0 && a < 0.01) s = a.toFixed(4).replace(/0+$/, "").replace(/(\.\d\d)$/, "$1")
  else { var p = a.toFixed(2).split("."); s = group3(p[0]) + "." + p[1] }
  return (neg ? "-" : "") + sym + s
}
function number(v) { return v === Math.floor(v) ? group3(String(v)) : group3(v.toFixed(2).split(".")[0]) + "." + v.toFixed(2).split(".")[1] }
function tokens(n) {
  if (n < 1000) return String(Math.round(n))
  var u = [[1e12, "T"], [1e9, "B"], [1e6, "M"], [1e3, "K"]]
  for (var i = 0; i < u.length; ++i) if (n >= u[i][0]) {
    var v = n / u[i][0]
    return (v < 10 ? (Math.round(v * 10) / 10).toFixed(1) : String(Math.round(v))).replace(/\.0$/, "") + u[i][1]
  }
  return String(n)
}
function chartValue(v, unit) {
  if (unit === "tokens") return tokens(v)
  if (unit === "requests" || unit === "credits") return number(Math.round(v * 100) / 100)
  return money(v, unit)
}
// "Nov 14, 2026 at 3:42 PM" (abbreviated date, short time).
function dateTime(iso, h24) {
  if (!iso) return ""
  var d = new Date(Date.parse(iso))
  return MONTHS[d.getMonth()] + " " + d.getDate() + ", " + d.getFullYear() + " at " + clock(d, h24)
}
function dayLabel(iso) { var d = new Date(Date.parse(iso)); return MONTHS[d.getUTCMonth()] + " " + d.getUTCDate() }

// realAccountLabel: no privacy, full domains (8.2). From accounts.status identity.
function realLabel(acc, pname) {
  if (!acc || !acc.identity) return ""
  var id = acc.identity
  if (acc.identity.providerID === "droid" && id.accountID) return id.accountID + (id.email ? " · " + id.email : "")
  if (id.email) return id.email
  if (id.accountID) return id.accountID
  if (id.userID && id.providerID !== "codex") return pname + " ···" + id.userID.slice(-4)
  return "Unresolved account"
}

// Search (WIN:247-262): every whitespace term must appear in the real label, email, ids, provider name.
function matches(row, acc, pname, query) {
  var terms = query.toLowerCase().split(/\s+/).filter(function (t) { return t !== "" })
  if (!terms.length) return true
  var id = acc && acc.identity ? acc.identity : {}
  var hay = [row.label, id.email, id.accountID, id.userID, pname, id.workspaceID].join(" ").toLowerCase()
  for (var i = 0; i < terms.length; ++i) if (hay.indexOf(terms[i]) < 0) return false
  return true
}

function plural(n, one, many) { return n + " " + (n === 1 ? one : many) }
// ---- Codex usage panel (accounts.md 2.10 AccountUsagePanel, ACC:728-874; core CodexUsageExtras) -----------
var PLANS = { prolite: "Pro 100", pro: "Pro 200", promax: "Pro 500", self_serve_business_prolite: "Business Premium" }
function planName(p) { if (!p || !String(p).trim()) return ""; p = String(p).trim(); return PLANS[p] || p.charAt(0).toUpperCase() + p.slice(1) }
function bucketTitle(b, key) {
  var vals = [b.id, b.name, b.model].filter(function (v) { return v && String(v).trim() })
  if (vals.some(function (v) { return String(v).toLowerCase().indexOf("spark") >= 0 })) return "Spark"
  if (b.name && String(b.name).trim()) return String(b.name).trim()
  var raw = b.id && String(b.id).trim() ? String(b.id).trim() : key
  return raw.toLowerCase() === "codex" ? "Codex" : raw.replace(/_/g, " ").replace(/\b\w/g, function (c) { return c.toUpperCase() })
}
function windowTitle(min, fallback) {
  if (!min || min <= 0) return fallback
  if (min === 300) return "Session"
  if (min === 10080) return "Weekly"
  if (min % 1440 === 0) return (min / 1440) + "-day window"
  if (min % 60 === 0) return (min / 60) + "-hour window"
  return min + "-minute window"
}
function creditsText(balance) {
  var c = Math.floor(Number(balance))
  if (isNaN(c)) return null
  return money(c * 0.04, "USD") + " · " + group3(c) + (c === 1 ? " credit" : " credits")
}
function bucketCredits(cr) {
  if (!cr) return null
  if (cr.unlimited === true) return "Unlimited"
  if (cr.balance && String(cr.balance).trim()) return creditsText(cr.balance) || cr.balance
  if (cr.hasCredits === true || cr.hasCredits === false) return cr.hasCredits ? "Available" : "None"
  return null
}
function hasWin(w) { return !!w && w.usedPercent !== null && w.usedPercent !== undefined }
// One bucket's window meters (shorter first) with the Mac row ids "<key>/primary" and "<key>/secondary".
function bucketWindows(b, key) {
  var ws = [b.primary, b.secondary].filter(hasWin)
  if (ws.length === 2 && ws[0].windowDurationMinutes && ws[1].windowDurationMinutes && ws[0].windowDurationMinutes > ws[1].windowDurationMinutes) ws = [ws[1], ws[0]]
  return ws.map(function (w, i) {
    var slot = i === 0 ? "primary" : "secondary"
    return { id: key + "/" + slot, title: windowTitle(w.windowDurationMinutes, i === 0 ? "Current window" : "Secondary window"),
             usedPercent: w.usedPercent, resetsAt: w.resetsAt, windowMinutes: w.windowDurationMinutes }
  })
}
// The panel's items: one per bucket with content, then the monthly credits meter, or "Rate limits unavailable".
function codexItems(snap, hidden) {
  var rl = snap.rateLimits || null, out = [], seen = {}, titles = {}
  function content(b) { return hasWin(b.primary) || hasWin(b.secondary) || bucketCredits(b.credits) !== null || (b.spendControlReached === true || b.spendControlReached === false) }
  function add(key, b) {
    var kv = []
    var cr = bucketCredits(b.credits)
    if (cr !== null) kv.push({ label: "Credits", value: cr })
    if (b.spendControlReached === true || b.spendControlReached === false) kv.push({ label: "Spend control", value: b.spendControlReached ? "Reached" : "Not reached" })
    out.push({ k: "bucket", key: key, title: bucketTitle(b, key), model: b.model || "", plan: planName(b.plan),
               meters: bucketWindows(b, key).filter(function (w) { return hidden.indexOf(w.id) < 0 }), kv: kv, limits: hasWin(b.primary) || hasWin(b.secondary) })
    titles[bucketTitle(b, key)] = true
  }
  if (rl) {
    if (rl.defaultBucket) { var dk = rl.defaultBucket.id || "default"; if (content(rl.defaultBucket)) { seen[dk] = true; add(dk, rl.defaultBucket) } }
    Object.keys(rl.buckets || {}).sort(function (a, b) { return a.localeCompare(b, undefined, { numeric: true }) }).forEach(function (k) {
      var b = rl.buckets[k], ident = b.id || k
      if (seen[ident]) return
      seen[ident] = true
      if (content(b)) add(k, b)
    })
  }
  var ex = snap.extras || null
  ;(ex && ex.additionalBuckets ? ex.additionalBuckets : []).forEach(function (b) {
    var k = b.id || b.name || "extra"
    if (seen[k] || titles[bucketTitle(b, k)]) return
    seen[k] = true
    add(k, b)
  })
  var mc = ex && ex.monthlyCredits ? ex.monthlyCredits : null
  if (mc && hidden.indexOf("monthly-credits") < 0)
    out.push({ k: "meter", w: { id: "monthly-credits", title: "Monthly credits", usedPercent: 100 - mc.remainingPercent, resetsAt: mc.resetsAt,
                                detail: group3(Math.round(mc.used)) + " / " + group3(Math.round(mc.limit)) + " credits" } })
  if (!mc && !out.some(function (i) { return i.limits })) out.push({ k: "ph", title: "Usage", tip: "Rate limits unavailable" })
  return out
}
function codexHasLimits(snap) {
  if (!snap) return false
  if (snap.extras && snap.extras.monthlyCredits) return true
  return codexItems(snap, []).some(function (i) { return i.k === "bucket" })
}
function dayText(iso) { var d = new Date(Date.parse(iso)); return MONTHS[d.getMonth()] + " " + d.getDate() + ", " + d.getFullYear() }
function hms(sec) {
  var h = Math.floor(sec / 3600), m = Math.floor(sec % 3600 / 60), s = Math.floor(sec % 60), p = []
  if (h) p.push(h + " hr"); if (m) p.push(m + " min"); if (s || !p.length) p.push(s + " sec")
  return p.join(", ")
}
// "Usage facts" rows: {label, value, help}
function codexFacts(snap) {
  var f = [], rl = snap.rateLimits || {}, ex = snap.extras || {}, u = snap.usage || null
  if (rl.ordinaryUsageAllowed === true || rl.ordinaryUsageAllowed === false) f.push({ label: "Ordinary usage", value: rl.ordinaryUsageAllowed ? "Available" : "Restricted" })
  if (snap.account) f.push({ label: "Authentication", value: "Signed in" })
  else if (snap.requiresOpenAIAuthentication === true || snap.requiresOpenAIAuthentication === false)
    f.push({ label: "Authentication", value: snap.requiresOpenAIAuthentication ? "Sign-in required" : "Not required" })
  var rc = ex.resetCredits
  if (rc) f.push({ label: "Reset credits", value: rc.count + (rc.expiries && rc.expiries.length ? " · next expires " + dayText(rc.expiries[0]) : ""),
                   help: rc.expiries && rc.expiries.length ? "Expires: " + rc.expiries.map(dayText).join(", ") : "" })
  var bucketCr = codexItems(snap, []).some(function (i) { return i.k === "bucket" && i.kv.some(function (r) { return r.label === "Credits" }) })
  if (ex.creditsBalance && !bucketCr && creditsText(ex.creditsBalance)) f.push({ label: "Credits", value: creditsText(ex.creditsBalance) })
  if (u) {
    if (u.lifetimeTokens != null) f.push({ label: "Lifetime", value: tokens(u.lifetimeTokens) })
    if (u.peakDailyTokens != null) f.push({ label: "Peak day", value: tokens(u.peakDailyTokens) })
    if (u.currentStreakDays != null) f.push({ label: "Current streak", value: plural(u.currentStreakDays, "day", "days") })
    if (u.longestStreakDays != null) f.push({ label: "Longest streak", value: plural(u.longestStreakDays, "day", "days") })
    if (u.longestRunningTurnSeconds != null) f.push({ label: "Longest turn", value: hms(u.longestRunningTurnSeconds) })
  }
  return f
}

// Relative age like the Mac RelativeDateTimeFormatter: "3 minutes ago", "2 hours ago", "just now".
function ago(iso, now) {
  var s = Math.max(0, (now - Date.parse(iso)) / 1000)
  if (s < 60) return "just now"
  if (s < 3600) return plural(Math.floor(s / 60), "minute", "minutes") + " ago"
  if (s < 86400) return plural(Math.floor(s / 3600), "hour", "hours") + " ago"
  return plural(Math.floor(s / 86400), "day", "days") + " ago"
}
