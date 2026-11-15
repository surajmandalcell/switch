.pragma library
// Global search logic (shell.md 4.1). The Settings index (4.4) comes from the helper's app.searchIndex.

// Case and accent folding: "Café" and "cafe" match.
function fold(s) { return String(s || "").normalize("NFD").replace(/[̀-ͯ]/g, "").toLowerCase() }
function terms(q) { return fold(q).split(/\s+/).filter(function (t) { return t !== "" }) }
function blank(q) { return terms(q).length === 0 }

// Every term in section, title, help, or keywords; rank 0 title starts with the query, 1 every term in the
// title, 2 the rest; ties keep the index order.
function settings(query, entries) {
  var ts = terms(query)
  if (ts.length === 0) return entries.slice()
  var whole = ts.join(" "), ranked = []
  for (var i = 0; i < entries.length; ++i) {
    var e = entries[i], hay = fold([e.section, e.title, e.help, e.keywords].join(" "))
    if (!ts.every(function (t) { return hay.indexOf(t) >= 0 })) continue
    var title = fold(e.title)
    var rank = title.indexOf(whole) === 0 ? 0 : (ts.every(function (t) { return title.indexOf(t) >= 0 }) ? 1 : 2)
    ranked.push({ rank: rank, index: i, entry: e })
  }
  ranked.sort(function (a, b) { return a.rank - b.rank || a.index - b.index })
  return ranked.map(function (r) { return r.entry })
}

// shortcut: the accounts topic carries the shown label, id, and provider only; email, user id, and workspace
// id join the match once the topic has them.
function accounts(query, rows, names) {
  var ts = terms(query)
  if (ts.length === 0) return []
  return (rows || []).filter(function (r) {
    var hay = fold([r.label, r.id, names[r.providerID] || r.providerID].join(" "))
    return ts.every(function (t) { return hay.indexOf(t) >= 0 })
  })
}

function count(n) { return n + (n === 1 ? " match" : " matches") }
