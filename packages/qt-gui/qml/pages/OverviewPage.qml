import QtQuick
import "Overview.js" as O
import "OverviewDemo.js" as Demo

// Overview page (specs/port/overview.md): Usage totals, Tokens per day, Activity, Trends, Share of
// tokens, Recent backups; or only the "Add your first account" card when there is nothing to show.
// Data: usage.history twice (the chosen period and grouping, and the year by model for the heatmap),
// usage.day for the day sheet, backup.list + backup.history and accounts.status for the backups card.
Item {
  id: page
  property alias header: header
  property alias scroll: scroll
  property alias chart: stream
  property alias sheet: sheet
  property string period: "week"          // today | week | month
  property string grouping: "account"     // account | model | project
  // Capture states for --demo: "", "loading", "empty", "nousage", "nobackups".
  property string demoState: App.arg("overview-state", "")
  readonly property bool demo: Helper.status === "demo"
  readonly property var app: Helper.topics.app || ({})
  readonly property var rows: demo && demoState === "empty" ? [] : demo && demoState.indexOf("mac") === 0 ? Demo.MAC.rows
                              : (Helper.topics.accounts ? Helper.topics.accounts.rows || [] : [])
  readonly property var pal: ({ brands: Theme.brands, dark: Theme.dark, other: Theme.tertiary, h24: h24 })
  // The Settings time format; demo captures use 12-hour so they stay stable.
  readonly property bool h24: {
    var f = Prefs.value("timeFormat")
    if (f === "12h" || f === "24h") return f === "24h"
    var s = Qt.locale().timeFormat(Locale.ShortFormat)
    return !demo && s.indexOf("AP") < 0 && s.indexOf("ap") < 0
  }
  readonly property bool today: period === "today"

  property var sum: null
  property var year: null
  property bool loading: false
  property bool historyLoaded: false
  property int seq: 0
  readonly property var ds: sum && year ? O.make(sum, year, rows, pal) : null
  // A cached empty dataset while a load runs shows skeletons, not "No usage".
  readonly property var shown: loading && ds && ds.totals.tokens === 0 ? null : ds
  readonly property bool emptyPage: !!app.hasLoaded && !app.isBusy && !loading && (historyLoaded || !!app.isUnavailable)
                                    && rows.length === 0 && (!year || year.dailyTotals.every(function (t) { return t === 0 }))
  readonly property string groupNote: "(by " + O.noun(grouping) + ")"

  property var backups: []
  property bool backupsLoaded: false
  property int pending: 0

  onVisibleChanged: if (visible) { scroll.appear(); reload(); loadBackups() }
  onPeriodChanged: { reload(); save("overviewPeriod", period) }
  onGroupingChanged: { reload(); save("overviewGrouping", grouping) }
  // The topics map only signals QML writes, so follow its values through bindings.
  readonly property bool appLoaded: !!app.hasLoaded
  onAppLoadedChanged: if (appLoaded && !historyLoaded) { reload(); loadBackups() }
  // usageHistory.version goes up when the data behind usage.history changed (architecture.md 2.7).
  Connections { target: Helper; function onTopicChanged(t) { if (t === "usageHistory.version" && page.historyLoaded) page.reload() } }
  readonly property var settingsTopic: Helper.topics.settings || null
  onSettingsTopicChanged: applyPrefs()
  Component.onCompleted: { applyPrefs(); reload(); loadBackups() }

  property bool prefsApplied: false
  function applyPrefs() {
    var v = Helper.topics.settings ? Helper.topics.settings.values : null
    if (prefsApplied || !v) return
    prefsApplied = true
    if (v.overviewPeriod === "month" || v.overviewPeriod === "today") period = v.overviewPeriod   // a stored "year" loads as week
    if (["account", "model", "project"].indexOf(v.overviewGrouping) >= 0) grouping = v.overviewGrouping
  }
  // Today's hours start over at local midnight (NSCalendarDayChanged on the Mac).
  Timer {
    id: midnight
    running: !page.demo
    interval: page.toMidnight()
    onTriggered: { page.reload(); interval = page.toMidnight(); start() }
  }
  function toMidnight() { var n = new Date(), m = new Date(n.getFullYear(), n.getMonth(), n.getDate() + 1); return m - n + 1000 }
  function save(key, value) { if (!demo && prefsApplied) Helper.call("settings.set", { key: key, value: value }, function () {}) }

  // Both summaries swap in together; the old charts stay until then.
  function reload() {
    if (!app.hasLoaded) return
    var n = ++seq
    loading = true
    if (demo) {
      if (demoState === "loading") return
      sum = Demo.summary(period, grouping, demoState)
      year = Demo.summary("year", "model", demoState)
      loading = false
      historyLoaded = true
      return
    }
    var got = { }
    function done() {
      if (n !== seq || got.s === undefined || got.y === undefined) return
      // A helper without hourly data errors on Today: show the cards' empty state, not last week's charts.
      if (!got.s && got.y && period === "today")
        got.s = { period: "today", grouping: grouping, days: [], dailyTotals: [], groups: [], startedHours: 0,
                  totals: { tokens: 0, costUSD: null, activeAccounts: 0, busiestDay: null, busiestDayTokens: 0 } }
      if (got.s && got.y) { sum = got.s; year = got.y; historyLoaded = true }
      loading = false
    }
    // points: false leaves out the raw points (a year of them per reply); older helpers ignore it.
    Helper.call("usage.history", { period: period, grouping: grouping, points: false }, function (r, e) { got.s = e ? null : r.summary; done() })
    Helper.call("usage.history", { period: "year", grouping: "model", points: false }, function (r, e) { got.y = e ? null : r.summary; done() })
  }

  function loadBackups() {
    if (demo) {
      backups = Demo.backups(demoState)
      backupsLoaded = demoState !== "loading"
      pending = demoState === "" ? 1 : 0
      return
    }
    Helper.call("accounts.status", {}, function (r, e) { if (!e) page.pending = (r.pendingRecovery || []).length })
    Helper.call("backup.list", {}, function (sets, e) {
      if (e || !sets.length) { page.backups = []; page.backupsLoaded = true; return }
      var all = [], left = sets.length
      sets.forEach(function (set) {
        Helper.call("backup.history", { setID: set.id }, function (h, e2) {
          if (!e2) h.snapshots.forEach(function (s) {
            all.push({ date: new Date(s.date), source: set.name, bytes: s.totalBytes,
                       state: s.safety ? "Safety copy" : s.state, isSafety: !!s.safety })
          })
          if (--left > 0) return
          all.sort(function (a, b) { return b.date - a.date })
          page.backups = all.slice(0, 3)
          page.backupsLoaded = true
        })
      })
    })
  }

  // Cross-page hooks (agreed API): Main.showPage(name) returns that page; the page's own hook does the rest.
  function go(route) { var w = page.Window.window; return w && w.showPage ? w.showPage(route) : null }
  function openBackup() { var p = go("Maintenance"); if (p && typeof p.showBackupTab === "function") p.showBackupTab() }
  function openChat(id) { var p = go("Conversations"); if (p && typeof p.selectChat === "function") p.selectChat(id) }
  function openDay(day, tokens) { gate.endAll(); sheet.open(day, tokens) }
  function loadDay(day, done) {
    if (demo) { done(Demo.usageDay(day)); return }
    Helper.call("usage.day", { day: day }, function (r, e) { done(e ? { points: [], sessions: null, threads: [] } : r) })
  }

  // Hover gate (2.9): a scroll ends every chart hover and blocks new ones for 150 ms; so does losing focus.
  QtObject {
    id: gate
    property real until: 0
    signal endAll()
    function blocked() { return Date.now() < until }
  }
  Connections { target: scroll.flick; function onContentYChanged() { gate.until = Date.now() + 150; gate.endAll() } }
  Connections { target: page.Window.window; function onActiveChanged() { if (!page.Window.window.active) gate.endAll() } }

  PageHeader { id: header; width: parent.width; placeholder: "Search accounts and settings…" }

  ScrollArea {
    id: scroll
    anchors.top: header.bottom
    anchors.bottom: parent.bottom
    width: parent.width
    gutter: 20

    // 6. Empty card: no account and no history
    Card {
      visible: page.emptyPage
      Item {
        width: parent.width
        height: 8 + 16 + 8 + 14 + 8 + 28 + 8
        Column {
          x: 16
          y: 8
          spacing: 8
          Txt { role: "section"; text: "Add your first account" }
          Txt { role: "secondary"; color: Theme.secondary
                text: "Switch found no saved account. Sign in to Codex or Grok Build, or use Advanced Import for an existing Codex folder." }
          Row {
            spacing: 8
            PushButton { prominent: true; icon: "plus"; text: "Add Account"; enabled: !page.app.isBusy
                         onClicked: page.Window.window.beginAddAccount() }
            PushButton { icon: "folder"; text: "Advanced Import…"; enabled: !page.app.isBusy
                         onClicked: page.Window.window.beginAdvancedImport() }
          }
        }
      }
    }

    // 1. Usage
    Card {
      visible: !page.emptyPage
      title: "Usage"
      note: page.today ? "(today)" : page.period === "month" ? "(last 30 days)" : "(last 7 days)"
      divider: false
      accessory: [
        Segmented { name: "Period"; model: ["Today", "Week", "Month"]; current: ["today", "week", "month"].indexOf(page.period)
                    onPicked: function (i) { page.period = ["today", "week", "month"][i] } },
        Segmented { name: "Group by"; model: ["Accounts", "Models", "Projects"]
                    current: ["account", "model", "project"].indexOf(page.grouping)
                    onPicked: function (i) { page.grouping = ["account", "model", "project"][i] } }
      ]
      Item {
        width: parent.width
        height: 73 + 16
        Row {
          x: 16
          spacing: 12
          readonly property real tw: (parent.width - 32 - 36) / 4
          readonly property var t: page.shown ? page.shown.totals : null
          StatTile { width: parent.tw; label: "Tokens"; loading: !page.shown
                     value: parent.t ? O.tokens(parent.t.tokens) : "–"; detail: page.today ? "Today so far" : "In the last " + (page.period === "month" ? 30 : 7) + " days" }
          StatTile { width: parent.tw; label: "Estimated cost"; loading: !page.shown
                     value: parent.t && parent.t.costUSD !== null && parent.t.costUSD !== undefined ? O.currency(parent.t.costUSD) : "–"
                     detail: "API-rate estimate, not billed" }
          StatTile { width: parent.tw; label: "Active accounts"; loading: !page.shown
                     value: parent.t ? String(parent.t.activeAccounts) : "–"; detail: page.today ? "With usage today" : "With usage in this period" }
          StatTile { width: parent.tw; label: page.today ? "Busiest hour" : "Busiest day"; loading: !page.shown
                     value: parent.t && parent.t.busiestDay ? O.bucket(parent.t.busiestDay, page.h24) : "–"
                     detail: !parent.t ? " " : (parent.t.busiestDay ? O.tokens(parent.t.busiestDayTokens) + " tokens" : "No usage yet") }
        }
      }
    }

    // 2. Tokens per day
    Card {
      visible: !page.emptyPage
      title: page.today ? "Tokens per hour" : "Tokens per day"
      note: page.groupNote
      Item {
        width: parent.width
        height: 14 + 220 + 10 + 18 + (hourNote.visible ? 6 + hourNote.height : 0) + 14
        readonly property bool has: !!page.shown && page.shown.series.length > 0
        StreamChart {
          id: stream
          visible: parent.has
          y: 14
          width: parent.width
          series: parent.has ? page.shown.series : []
          days: parent.has ? page.shown.days : []
          h24: page.h24
          gate: gate
          summary: page.shown ? O.streamSummary(page.shown) : ""
        }
        OverviewSlot { visible: !parent.has; y: 14; width: parent.width; height: 220; loading: !page.shown
                       text: page.shown ? O.emptyText(page.shown) : "" }
        OverviewLegend { visible: !!page.shown; x: 16; y: 14 + 220 + 10; width: parent.width - 32
                         series: page.shown ? page.shown.series : []; active: stream.hover ? stream.hoverKey : "" }
        Skeleton { visible: !page.shown; x: 16; y: 14 + 220 + 10; width: 180; height: 18 }
        Txt {
          id: hourNote
          visible: page.today
          x: 16; y: 14 + 220 + 10 + 18 + 6
          width: parent.width - 32
          role: "caption"; color: Theme.secondary; elide: Text.ElideRight
          text: O.HOURLY_NOTE
          ToolTipArea { text: O.HOURLY_HELP }
        }
      }
    }

    // 3. Activity
    Card {
      visible: !page.emptyPage
      title: "Activity"
      note: "(last 12 months, all accounts)"
      Item {
        width: parent.width
        readonly property bool has: !!page.shown && page.shown.yearTokens > 0
        height: 14 + (has ? heat.height : heatSlot.implicitHeight) + 14
        OverviewHeatmap {
          id: heat
          visible: parent.has
          x: 16
          y: 14
          width: parent.width - 32
          ds: parent.has ? page.shown : null
          gate: gate
          summary: page.shown ? O.heatmapSummary(page.shown) : ""
          onSelected: function (day, tokens) { page.openDay(day, tokens) }
        }
        OverviewSlot { id: heatSlot; visible: !parent.has; y: 14; width: parent.width; shape: "heatmap"; loading: !page.shown
                       height: implicitHeight; text: "No activity in the last 12 months." }
      }
    }

    // 4. Trends
    Card {
      visible: !page.emptyPage
      title: "Trends"
      note: page.groupNote
      Item {
        width: parent.width
        height: 14 + 300 + 14
        readonly property bool has: !!page.shown && page.shown.series.length > 0
        OverviewRidgeline {
          id: ridges
          visible: parent.has
          y: 14
          width: parent.width
          series: parent.has ? page.shown.series : []
          days: parent.has ? page.shown.days : []
          h24: page.h24
          gate: gate
          summary: page.shown ? O.ridgeSummary(page.shown) : ""
        }
        OverviewSlot { visible: !parent.has; y: 14; width: parent.width; height: 300; loading: !page.shown
                       text: page.shown ? O.emptyText(page.shown) : "" }
      }
    }

    // 5. Share of tokens
    Card {
      visible: !page.emptyPage
      title: "Share of tokens"
      note: page.groupNote
      Item {
        width: parent.width
        readonly property bool has: !!page.shown && page.shown.series.length > 0
        height: 14 + (has ? waffle.height : waffleSlot.implicitHeight) + 14
        OverviewWaffle {
          id: waffle
          visible: parent.has
          x: 16
          y: 14
          width: parent.width - 32
          series: parent.has ? page.shown.series : []
          gate: gate
          summary: page.shown ? O.waffleSummary(page.shown) : ""
        }
        OverviewSlot { id: waffleSlot; visible: !parent.has; y: 14; width: parent.width; shape: "waffle"; loading: !page.shown
                       height: implicitHeight; text: page.shown ? O.emptyText(page.shown) : "" }
      }
    }

    // 6. Recent backups
    OverviewBackups {
      id: backupsCard
      visible: !page.emptyPage
      rows: page.backups
      loaded: page.backupsLoaded
      pending: page.pending
      onOpenBackup: page.openBackup()
    }
  }

  OverviewDaySheet {
    id: sheet
    parent: Theme.menu ? Theme.menu.parent : page
    load: page.loadDay
    accounts: page.rows
    pal: page.pal
    onOpenChat: function (id) { page.openChat(id) }
  }

  // Capture states (Driver "states" script): every card, hover on each chart, the day sheet, other states.
  function captureSteps(d) {
    var w = Window.window, s = []
    function at(item, fx, fy) { var p = item.mapToItem(null, item.width * fx, item.height * fy); return p }
    function shot(name) { s.push(function () { d.shot(w, "overview-" + name) }) }
    function scrollTo(item) { s.push(function () { scroll.scrollTo(item.mapToItem(scroll.flick.contentItem, 0, 0).y - 14 - 45 - 12) }); s.push(400) }
    function hover(item, fx, fy, name) {
      s.push(function () { var p = at(item, fx, fy); Harness.move(w, p.x, p.y) }); s.push(300)
      s.push(function () { var p = at(item, fx, fy); Harness.move(w, p.x + 1, p.y) }); s.push(500)
      s.push(function () { var p = at(item, fx, fy); Harness.log("HOVER " + name + " " + p.x + "," + p.y + " " + (item.hover ? item.hover.tip.title : "none")) })
      shot(name)
      s.push(function () { Harness.move(w, 5, w.height - 5) }); s.push(500)
    }
    s.push(function () { Harness.log("SELFCHECK " + JSON.stringify(O.selfCheck())) })
    s.push(function () {   // the locale-dependent strings, for a check under other LANG values
      var t = new Date("2026-11-14T21:05:00Z")
      Harness.log("LOCALE " + Qt.locale().name + " | " + backupsCard.when(t) + " | " + t.toLocaleTimeString(Qt.locale(), Locale.ShortFormat)
                  + " | " + O.tokens(1234567) + " | " + O.currency(1900) + " | " + O.currency(7.01) + " | " + O.bytes(48213504))
    })
    function clickDay(back) {   // a real click on the newest day with tokens, `back` days before today
      s.push(function () {
        if (!page.shown || !heat.lay) { Harness.log("CLICK no heatmap"); return }
        var ys = page.shown.yearTotals, i = ys.length - 1 - back; while (i > 0 && ys[i] <= 0) --i
        var r = O.heatRect(heat.lay, i), p = heat.mapToItem(null, r.x + r.w / 2, r.y + r.h / 2)
        Harness.move(w, p.x, p.y); Harness.click(w, p.x, p.y)
      })
    }
    function state(tag) {
      return tag + " period=" + page.period + " grouping=" + page.grouping + " tokens=" + (page.shown ? page.shown.totals.tokens : -1)
             + " series=" + (page.shown ? page.shown.series.length : -1) + " heatDays=" + (page.shown ? page.shown.yearTotals.filter(function (t) { return t > 0 }).length : -1)
             + " backups=" + page.backups.length
    }
    // --overview-state real: the real helper on a seeded root. Charts, a heatmap click into the day sheet, one
    // backup made with backup.run into --backupTo, then Month and Models, which settings.set keeps.
    if (demoState === "real") {
      s.push(5000); s.push(function () { Harness.log(state("REAL load")) }); shot("real-top")
      hover(stream, 0.62, 0.35, "real-hover-stream")
      scrollTo(heat); clickDay(1)
      s.push(2500); s.push(function () {
        var d = sheet.detail
        Harness.log("REAL sheet " + sheet.shown + " " + sheet.day + " sessions=" + (d && d.sessions ? d.sessions.length : "none"))
      })
      shot("real-day-sheet")
      s.push(function () { sheet.close() }); s.push(400)
      s.push(function () {
        Helper.call("backup.checklist", {}, function (c, e) {
          if (e || !c.rows || !c.rows.length) { Harness.log("REAL backup checklist " + (e ? e.message : "no rows")); return }
          Helper.call("backup.configure", { sourceID: c.rows[0].sourceID, destination: App.arg("backupTo", "") }, function (r2, e2) {
            if (e2) { Harness.log("REAL backup configure " + e2.message); return }
            Helper.call("backup.run", {}, function (r3, e3) { Harness.log("REAL backup run " + (e3 ? e3.message : "ok")); page.loadBackups() }, 0)
          })
        })
      })
      s.push(20000); s.push(function () { Harness.log(state("REAL backup")); scroll.scrollTo(1e6) }); s.push(500); shot("real-bottom")
      s.push(function () { scroll.scrollTo(0); page.period = "today" }); s.push(3000)
      s.push(function () { Harness.log(state("REAL today")) }); shot("real-today")
      s.push(function () { scroll.scrollTo(0); page.period = "month"; page.grouping = "model" }); s.push(3000)
      s.push(function () { Harness.log(state("REAL month")) }); shot("real-month-models")
      return s
    }
    if (demoState === "real-check") { s.push(5000); s.push(function () { Harness.log(state("REAL restart")) }); shot("real-restart"); return s }
    // --overview-state mac-light|mac-dark: the Mac reference window (1200 x 800), top and scrolled to the end.
    if (demoState.indexOf("mac") === 0) {
      shot("mac-top")
      s.push(function () { scroll.scrollTo(1e6) }); s.push(500); shot("mac-bottom")
      s.push(function () {   // a real click on Open Backup: Maintenance, Backup tab
        var b = backupsCard.openButton, p = b.mapToItem(null, b.width / 2, b.height / 2)
        Harness.move(w, p.x, p.y); Harness.click(w, p.x, p.y)
      })
      s.push(1200)
      s.push(function () { var m = w.page(w.pageIndex); Harness.log("OPENBACKUP page=" + w.pages[w.pageIndex].route + " tab=" + (m ? m.tab : "none")) })
      shot("open-backup")
      return s
    }
    shot("top")
    hover(stream, 0.62, 0.35, "hover-stream")
    scrollTo(heat); shot("activity")
    var cell = O.heatRect(heat.lay, page.shown.yearDays.length - 40)   // a cell center, not a gap
    hover(heat, (cell.x + cell.w / 2) / heat.width, (cell.y + cell.h / 2) / heat.height, "hover-heatmap")
    s.push(function () { var p = heat.mapToItem(null, heat.width - 50, heat.height - 8); Harness.move(w, p.x, p.y) }); s.push(400)
    shot("hover-heat-legend")
    s.push(function () { Harness.move(w, 5, w.height - 5) }); s.push(300)
    hover(ridges, 0.45, 0.33, "hover-ridge")
    hover(waffle, 0.2, 0.5, "hover-waffle")
    s.push(function () { scroll.scrollTo(1e6) }); s.push(400); shot("bottom")
    // Today: 24 hour slots, the started hours drawn, then Month below
    s.push(function () { scroll.scrollTo(0); page.period = "today" }); s.push(600)
    s.push(function () { Harness.log(state("TODAY") + " axis=" + JSON.stringify(O.axis(page.shown.days, page.h24).map(function (a) { return a.text }))) })
    shot("today-top")
    hover(stream, 0.4, 0.5, "today-hover-stream")
    hover(stream, 0.95, 0.5, "today-hover-clamp")
    scrollTo(ridges); hover(ridges, 0.3, 0.33, "today-hover-ridge")
    s.push(function () { scroll.scrollTo(0); page.period = "month"; page.grouping = "model" }); s.push(600); shot("month-models")
    s.push(function () { page.grouping = "project" }); s.push(600)
    s.push(function () { scroll.scrollTo(1e6) }); s.push(400); shot("projects-bottom")
    s.push(function () { scroll.scrollTo(0); page.period = "week"; page.grouping = "account" }); s.push(500)
    scrollTo(heat)
    clickDay(1)
    s.push(800); s.push(function () { Harness.log("SHEET click " + sheet.shown + " " + sheet.day) }); shot("day-sheet")
    s.push(function () { sheet.split = 1 }); s.push(500); shot("day-sheet-model")
    s.push(function () { sheet.close(); Harness.move(w, 5, w.height - 5) }); s.push(400)
    // keyboard: focus the grid (newest day), two weeks back, one day up, then Return
    s.push(function () { heat.forceActiveFocus() }); s.push(200)
    s.push(function () { Harness.key(w, Qt.Key_Left) }); s.push(100)
    s.push(function () { Harness.key(w, Qt.Key_Left) }); s.push(100)
    s.push(function () { Harness.key(w, Qt.Key_Up) }); s.push(400)
    s.push(function () { Harness.log("KEY ring " + heat.hoverIndex + " " + (heat.hover ? heat.hover.tip.title : "none")) }); shot("heat-keyboard")
    s.push(function () { Harness.key(w, Qt.Key_Return) }); s.push(800)
    s.push(function () { Harness.log("SHEET key " + sheet.shown + " " + sheet.day) }); shot("day-sheet-keyboard")
    s.push(function () { sheet.close(); scroll.scrollTo(0) }); s.push(400)
    var states = ["loading", "nousage", "nobackups", "empty"]
    states.forEach(function (st) {
      s.push(function () { page.demoState = st; page.sum = null; page.year = null; page.historyLoaded = false; page.reload(); page.loadBackups() })
      s.push(600); shot("state-" + st)
      s.push(function () { scroll.scrollTo(1e6) }); s.push(400); shot("state-" + st + "-bottom")
      s.push(function () { scroll.scrollTo(0) }); s.push(200)
    })
    return s
  }
}
