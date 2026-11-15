import QtQuick

// Capture run for the Accounts page (--page Accounts --script accounts, harness builds only). Pointer
// input goes through the harness, so hover, menus and clicks take the real event path.
Item {
  id: s
  property var page
  property var sheet
  property var steps: []
  property int idx: 0
  readonly property var win: page.win
  readonly property string id0: "0b1c6a52-7a0e-4d3c-9a51-0f6f1d3c00"

  Timer { id: tm; onTriggered: s.next() }
  function next() {
    while (idx < steps.length) {
      var f = steps[idx++]
      if (typeof f === "number") { tm.interval = f; tm.start(); return }
      f()
    }
  }
  function tag() { return (Theme.dark ? "dark" : "light") + "@" + App.arg("scale", "1") + "x" }
  function shot(w, name) { Harness.log("SHOT " + name + "-" + tag() + " " + Harness.shot(w, name + "-" + tag())) }
  function row(n) { return page.find(id0 + n) }
  function detail(n, name) {
    return [function () { page.select(id0 + n) }, 400,
            function () { page.scroll.scrollTo(page.table.height + 12) }, 300,
            function () { shot(win, name) }]
  }

  // Synthetic data for the cards the demo replies do not cover (helper shapes from rpc.md).
  function codexDetail() {
    var daily = [], end = Date.parse("2026-11-14T00:00:00Z")
    for (var i = 0; i < 365; ++i) {
      var t = (i * 7919) % 13 < 4 ? 0 : ((i * 104729) % 9000000) + 400000
      daily.push({ startDate: new Date(end - i * 86400000).toISOString().slice(0, 10), tokens: t })
    }
    return { accountID: id0 + "01", providerID: "codex", daily: daily,
      codex: { fetchedAt: "2026-11-14T13:58:00Z", account: { email: "ada@example.com" },
        rateLimits: { ordinaryUsageAllowed: true,
          defaultBucket: { id: "codex", plan: "pro", primary: { usedPercent: 38, windowDurationMinutes: 300, resetsAt: "2026-11-14T16:10:00Z" },
                     secondary: { usedPercent: 61, windowDurationMinutes: 10080, resetsAt: "2026-11-18T09:00:00Z" },
                     credits: { hasCredits: true, unlimited: false, balance: "125" }, spendControlReached: false },
          buckets: {
          "codex_bengalfox": { id: "codex_bengalfox", name: "GPT-5.3 Codex Spark", model: "gpt-5.3-codex-spark", plan: "pro",
                     primary: { usedPercent: 12, windowDurationMinutes: 300, resetsAt: "2026-11-14T17:40:00Z" },
                     secondary: { usedPercent: 4, windowDurationMinutes: 10080, resetsAt: "2026-11-20T09:00:00Z" } } } },
        extras: { monthlyCredits: { limit: 1000, used: 420, remainingPercent: 58, resetsAt: "2026-12-01T00:00:00Z" } },
        usage: { lifetimeTokens: 182400000, peakDailyTokens: 9100000, currentStreakDays: 12, longestStreakDays: 41, longestRunningTurnSeconds: 1843 } } }
  }
  function chart() {
    var p = []
    for (var i = 29; i >= 0; --i) { var d = new Date(Date.parse("2026-11-14T00:00:00Z") - i * 86400000)
      p.push({ label: d.toISOString().slice(5, 10), date: d.toISOString().slice(0, 10), value: ((i * 7919) % 17) * 120000 }) }
    return { id: "tokens", title: "Last 30 days", unit: "tokens", points: p }
  }
  function summary(k) {
    return { rows: [ { label: "Today", tokens: 1240000 * k, costUSD: 3.1 * k, detail: "Input, output, and cache tokens" },
                     { label: "Yesterday", tokens: 2810000 * k, costUSD: 6.75 * k, detail: "" },
                     { label: "Last 30 days", tokens: 48200000 * k, costUSD: 118.4 * k, detail: "" } ],
             unpricedModels: k > 1 ? ["glm-4.6"] : [], computedAt: "2026-11-14T13:50:00Z", chart: chart() }
  }
  readonly property var demoTopics: ({
    providerStatus: { entries: [ { providerID: "claude-code", indicator: "minor", severity: "warning", text: "Elevated errors on Claude Opus",
                                   updatedAt: "2026-11-14T13:20:00Z", checkedAt: "2026-11-14T13:55:00Z" } ] },
    activity: { claude: summary(1), droid: summary(2), claudeLoading: false, droidLoading: false } })

  // --script accounts-real: the sign-in flows against the real helper in a temporary root, synthetic values only.
  function entry(test) { var c = sheet.catalog; for (var i = 0; i < c.length; ++i) if (test(c[i])) return c[i]; return null }
  function state(name) { Harness.log("STATE " + name + " step=" + sheet.step + " kind=" + sheet.kind + " err=" + sheet.err + " done=" + sheet.doneID
                                     + " login=" + JSON.stringify(sheet.login) + " live=" + JSON.stringify(sheet.live)) }
  property var api: null
  property var filesP: null
  // add the picked API-key provider with one synthetic value in every field, then capture the result
  function secret(value, name) {
    return [function () { sheet.hide(); page.openSheet("add") }, 900,
            function () { sheet.selID = s.api.id; sheet.cont() }, 400,
            function () { var f = {}; s.api.fields.forEach(function (x) { f[x.key] = value }); sheet.fields = f; sheet.save() }, 6000,
            function () { state(name); shot(sheet, name) }]
  }
  function realSteps() {
    var key = "sk-synthetic-00000000000000000000000000000000000000000000"
    var q = [3000, function () { shot(win, "real-empty") },
      function () { page.openSheet("add") }, 2000,
      function () { s.api = entry(function (p) { return p.style === "secret" && p.fields && p.fields.length === 1 && sheet.usable(p) })
                    s.filesP = entry(function (p) { return p.style === "files" && !!p.login && sheet.usable(p) })
                    Harness.log("SAMPLE " + JSON.stringify(sheet.catalog[4]) + " | " + JSON.stringify(sheet.catalog[0]))
                    Harness.log("PICK api=" + (s.api && s.api.id) + " files=" + (s.filesP && s.filesP.id) + " catalog=" + sheet.catalog.length)
                    if (!s.api || !s.filesP) Harness.quit(1) },
      function () { shot(sheet, "real-sheet-add") },
      function () { sheet.selID = s.api.id; sheet.cont() }, 400, function () { shot(sheet, "real-secret") }]
    q = q.concat(secret(key, "real-secret-saved"), secret(key, "real-secret-duplicate"), secret("x", "real-secret-rejected"))
    q = q.concat([
      function () { sheet.hide(); page.openSheet("add") }, 900,
      function () { sheet.selID = s.filesP.id; sheet.cont() }, 3000, function () { state("files"); shot(sheet, "real-files") },
      function () { sheet.startLogin({ providerID: s.filesP.id }) }, 5000, function () { state("files-login"); shot(sheet, "real-files-noemulator") },
      function () { sheet.hide(); page.openSheet("add") }, 900,
      function () { sheet.selID = "droid"; sheet.cont() }, 400, function () { shot(sheet, "real-droid") },
      function () { sheet.setField("key", "fk-synthetic-000000000000000000000000"); sheet.save() }, 8000,
      function () { state("droid"); shot(sheet, "real-droid-saved") },
      function () { sheet.hide(); page.openSheet("import") }, 4000, function () { state("import"); shot(sheet, "real-import") },
      function () { Helper.call("import.discover", { folder: App.arg("codex-home", "") }, function (r, e) {
                      Harness.log("RAW " + JSON.stringify(r) + " isArray=" + Array.isArray(r) + " err=" + JSON.stringify(e)) })
                    sheet.discover(App.arg("codex-home", "")) }, 4000,
      function () { state("import-folder"); Harness.log("SOURCES " + JSON.stringify(sheet.sources)); shot(sheet, "real-import-folder") },
      function () { sheet.review() }, 4000, function () { state("import-review"); shot(sheet, "real-import-review") },
      function () { sheet.commit() }, 5000, function () { state("import-done"); Harness.log("RESULT " + JSON.stringify(sheet.result)); shot(sheet, "real-import-done") },
      function () { sheet.dismiss() }, 1500, function () { shot(win, "real-after") },
      function () { Harness.quit(0) }])
    steps = q
    next()
  }

  // Keyboard path: Tab until test(focus item) holds, logging each stop.
  function focusName(it) { return it ? (it.Accessible.name || it.objectName || String(it).split("(")[0]) : "none" }
  function tabTo(w, test, max, back) {
    for (var i = 0; i < max; ++i) {
      Harness.key(w, Qt.Key_Tab, back ? Qt.ShiftModifier : 0)
      Harness.log("TAB " + i + " " + focusName(w.activeFocusItem))
      if (test(w.activeFocusItem)) return true
    }
    return false
  }
  function keySteps() {
    return [
      // select a later row so the first row shows the focus tint (the tint draws only when not selected)
      function () { page.scroll.scrollTo(0); page.select(id0 + "02"); win.requestActivate() }, 300,
      function () { tabTo(win, function (it) { return !!it && it.row !== undefined && it.ctl !== undefined }, 30) }, 300,
      function () { Harness.log("ROWFOCUS " + focusName(win.activeFocusItem)); shot(win, "accounts-focus-row") },
      function () { tabTo(win, function (it) { return !!it && it.Accessible.name === "More actions" }, 4) }, 200,
      function () { Harness.key(win, Qt.Key_Space, 0, " ") }, 300,
      function () { Harness.key(Theme.menu.Window.window || win, Qt.Key_Down); Harness.key(Theme.menu.Window.window || win, Qt.Key_Down) }, 200,
      function () { shot(win, "accounts-focus-menu") },
      function () { Harness.key(Theme.menu.Window.window || win, Qt.Key_Escape) }, 300,
      function () { Harness.log("AFTERMENU " + focusName(win.activeFocusItem) + " menuOpen=" + Theme.menu.visible) },
      function () { Theme.alert.open({ title: "Delete grace@example?", message: "Remove this account's saved sign-in from Switch.", action: "Delete account", destructive: true }) }, 300,
      function () { Harness.key(win, Qt.Key_Tab) }, 200, function () { Harness.log("ALERT " + focusName(win.activeFocusItem)); shot(win, "accounts-focus-alert") },
      function () { Harness.key(win, Qt.Key_Escape) }, 300, function () { Harness.log("ALERTCLOSED " + !Theme.alert.visible) },
      // the focused card's percent is a button now: Tab reaches it and shows the tint
      function () { tabTo(win, function (it) { return !!it && /left$|used$/.test(it.Accessible.name) }, 80) }, 300,
      function () { Harness.log("PCTFOCUS " + focusName(win.activeFocusItem)); shot(win, "accounts-focus-percent") },
      function () { page.openSheet("add") }, 900,
      function () { Harness.key(sheet, Qt.Key_Down); Harness.key(sheet, Qt.Key_Down) }, 200,
      function () { Harness.log("SHEETSEL " + sheet.selID); shot(sheet, "sheet-focus-list") },
      function () { tabTo(sheet, function (it) { return !!it && it.text === "Continue" }, 8) }, 200,
      function () { shot(sheet, "sheet-focus-continue") },
      function () { Harness.key(sheet, Qt.Key_Escape) }, 400, function () { Harness.log("SHEETCLOSED " + !sheet.visible) }]
  }

  Component.onCompleted: {
    if (Harness && App.arg("script") === "accounts-real") { realSteps(); return }
    if (!Harness || App.arg("script") !== "accounts") return
    var q = [1500,
      function () { shot(win, "accounts") },
      function () { Harness.move(win, 500, 194) }, 300, function () { shot(win, "accounts-hover") },
      function () { Harness.click(win, 1153, 158) }, 300, function () { shot(win, "accounts-more") },
      function () { Theme.menu.close() }, 200,
      function () { Harness.rightClick(win, 500, 194) }, 300, function () { shot(win, "accounts-context") },
      function () { Theme.menu.close() }, 200,
      function () { Harness.rightClick(win, 330, 124) }, 300, function () { shot(win, "accounts-group-menu") },
      function () { Theme.menu.close(); Harness.move(win, 5, 400) }, 200]
    q = q.concat(detail("01", "accounts-detail-codex"), detail("07", "accounts-detail-copilot"), detail("0a", "accounts-detail-signin"),
                 detail("09", "accounts-detail-outdated"), detail("0b", "accounts-detail-failed"), detail("02", "accounts-detail-claude"),
                 detail("06", "accounts-detail-droid-access"))
    // round 2 cards: Codex buckets, facts and heatmap; activity; incident dot; repair; Droid key and missions
    q = q.concat([
      function () { page.topicOverride = s.demoTopics; page.select(id0 + "01") }, 400,
      function () { Prefs.set("usageTokenPeriod", "Yearly"); page.detail = codexDetail() }, 400, function () { page.scroll.scrollTo(page.table.height + 12) }, 300,
      function () { shot(win, "accounts-codex-usage") },
      function () { page.scroll.scrollTo(page.table.height + 700) }, 300, function () { shot(win, "accounts-codex-daily") },
      function () { page.scroll.scrollTo(0) }, 200, function () { shot(win, "accounts-incident") },
      function () { page.divergences = [{ accountID: id0 + "02", relativePath: "settings.json", fingerprint: "f1",
                                          localPath: "/home/demo/.local/share/switch/claude-profiles/ada-work/settings.json" }] }, 100])
    q = q.concat(detail("02", "accounts-claude-activity"))
    q = q.concat([function () { page.scroll.scrollTo(page.table.height + 600) }, 300, function () { shot(win, "accounts-repair") }])
    q = q.concat(detail("06", "accounts-droid-activity"))
    q = q.concat([function () { page.scroll.scrollTo(page.table.height + 700) }, 300, function () { shot(win, "accounts-droid-key") },
      function () { page.divergences = []; page.topicOverride = ({}) }, 200])
    q = q.concat(keySteps())
    q = q.concat([
      function () { page.scroll.scrollTo(0); page.select(id0 + "01"); win.searchQuery = "zzz" }, 400, function () { shot(win, "accounts-nomatch") },
      function () { win.searchQuery = "" }, 200,
      function () { page.fail("Couldn’t change the default account. The usage cache could not open. Resolve any item in Backup, then try again.") }, 300,
      function () { shot(win, "accounts-errorbar") },
      function () { page.dismissed = page.errorText; page.localError = "" }, 200,
      function () { Theme.alert.open({ title: "Delete grace@example?", message: "Remove this account's saved sign-in from Switch. Conversations and settings stay.",
                                       action: "Delete account", destructive: true }) }, 300,
      function () { shot(win, "accounts-delete") },
      function () { Theme.alert.close(); page.rename(row("03")) }, 300, function () { shot(win, "accounts-rename") },
      function () { Theme.alert.close(); page.rowsOverride = [] }, 400, function () { shot(win, "accounts-empty") },
      function () { page.rowsOverride = "loading" }, 400, function () { shot(win, "accounts-loading") },
      function () { page.rowsOverride = null }, 300,
      function () { page.openSheet("add") }, 900, function () { shot(sheet, "sheet-add") },
      function () { sheet.query = "co" }, 300, function () { shot(sheet, "sheet-search") },
      function () { sheet.query = ""; sheet.selID = "codex"; sheet.cont() }, 400, function () { shot(sheet, "sheet-start-error") },
      function () { sheet.err = ""; sheet.selID = "droid"; sheet.cont() }, 400, function () { shot(sheet, "sheet-droid") },
      function () { sheet.back(); sheet.selID = "gemini-cli"; sheet.cont() }, 600, function () { shot(sheet, "sheet-files") },
      function () { sheet.hide() }, 300,
      function () { page.signIn(row("0a")) }, 900, function () { shot(sheet, "sheet-signin") },
      function () { sheet.err = ""; sheet.providerID = "codex"; sheet.finish(id0 + "04", "") }, 400, function () { shot(sheet, "sheet-done") },
      function () { sheet.hide() }, 300,
      function () { page.openSheet("import") }, 900, function () { shot(sheet, "sheet-import") },
      function () { sheet.hide(); Harness.quit(0) }
    ])
    steps = q
    next()
  }
}
