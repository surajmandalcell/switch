import QtQuick
import QtQuick.Window
import "Acc.js" as A

// Accounts page (specs/port/accounts.md, account-window.md): the table card, the focused account card and
// its detail cards, or the loading / empty card. Data: the `accounts`, `app`, `notices` and `settings`
// topics, plus accounts.status (paths, dates, identity), providers.list (names) and usage.detail.
Item {
  id: page
  property alias header: header
  property alias scroll: scroll
  property alias table: tableCard
  readonly property var win: Window.window
  onVisibleChanged: if (visible) { scroll.appear(); load() }
  Component.onCompleted: { load(); ensureSelection() }

  // ---- data --------------------------------------------------------------------------------------
  readonly property bool demo: Helper.status === "demo"
  property var rowsOverride: null          // capture runs only: [] (empty) or "loading"
  readonly property var app: Helper.topics.app || ({})
  readonly property bool loaded: rowsOverride === "loading" ? false : !!app.hasLoaded
  readonly property var allRows: rowsOverride !== null ? (rowsOverride === "loading" ? [] : rowsOverride)
                                                       : (Helper.topics.accounts && Helper.topics.accounts.rows ? Helper.topics.accounts.rows : [])
  property var statusMap: ({})
  property var names: ({})
  // the live tool folders (`app.homes`), keyed by provider id
  readonly property var homes: { var h = app.homes || {}; return { "codex": h.codex, "grok-build": h.grok, "droid": h.droid } }
  property var detail: null
  property var missions: []
  property bool pending: false
  readonly property bool busy: !!app.isBusy || pending || !loaded
  readonly property string query: win && win.searchQuery ? win.searchQuery : ""
  readonly property var rows: allRows.filter(function (r) { return A.matches(r, page.statusMap[r.id], page.pname(r.providerID), page.query) })
  readonly property var groups: A.groups(rows, pref("menuBarServiceOrder", []))

  function pref(k, d) { var v = Prefs.value(k); return v === undefined || v === null ? d : v }
  function pname(p) { return A.providerName(p, names) }
  function statusOf(id) { return statusMap[id] || null }
  function find(id) { for (var i = 0; i < allRows.length; ++i) if (allRows[i].id === id) return allRows[i]; return null }

  // time: a fixed clock in demo runs so captures are stable; else ticks each minute (countdowns)
  property real tick: Date.now()
  Timer { interval: 60000; repeat: true; running: !page.demo; onTriggered: page.tick = Date.now() }
  readonly property real now: demo ? Date.parse(app.refreshedAt || "2026-11-14T14:00:00Z") : tick
  readonly property bool exact: pref("resetTimesExact", false) === true
  readonly property bool h24: {
    var f = pref("timeFormat", "auto")
    if (f !== "auto") return f === "24h"
    var s = Qt.locale().timeFormat(Locale.ShortFormat)
    return !demo && s.indexOf("AP") < 0 && s.indexOf("ap") < 0
  }
  function compact(w) { return A.compactReset(w.resetsAt, now, w.usedPercent, exact, h24) }
  function toggleShowUsed() { Prefs.set("showUsageAsUsed", !Theme.showUsed) }
  function toggleExact() { Prefs.set("resetTimesExact", !exact) }

  function load() {
    Helper.call("accounts.status", {}, function (r, e) {
      if (e || !r || !r.accounts) return
      var m = {}
      r.accounts.forEach(function (a) { m[a.id] = a })
      page.statusMap = m
      page.statusIDs = r.accounts.map(function (a) { return a.id })
      page.divergences = r.linkedSettingsDivergences || []
    })
    Helper.call("providers.list", {}, function (r, e) {
      if (e || !r) return
      var m = {}
      r.forEach(function (p) { m[p.id] = p.displayName })
      page.names = m
      page.providers = r
    })
  }
  property var providers: []
  property var divergences: []
  function provider(id) { for (var i = 0; i < providers.length; ++i) if (providers[i].id === id) return providers[i]; return null }
  // Open incident of a provider (`providerStatus` topic): {severity "warning" | "critical", text, updatedAt}, else null.
  property var topicOverride: ({})         // capture runs only: { providerStatus, activity } in place of the topics
  function topic(name) { return topicOverride[name] || Helper.topics[name] || null }
  function incident(p) {
    var s = topic("providerStatus"), e = s && s.entries ? s.entries : []
    for (var i = 0; i < e.length; ++i) if (e[i].providerID === p && e[i].severity) return e[i]
    return null
  }
  function incidentText(e) { return e ? e.text + (e.updatedAt ? " · updated " + A.ago(e.updatedAt, now) : "") : "" }
  Timer { id: reloadTimer; interval: 250; onTriggered: page.load() }
  Connections {
    target: Helper
    function onTopicChanged(t) { if (t === "accounts") reloadTimer.restart() }
    function onStatusChanged() { if (Helper.status === "ready") page.load() }
  }

  // ---- selection (ACC:63-83) ---------------------------------------------------------------------
  property string selectedID: ""
  property bool restored: false
  // reads allRows and selectedID directly: through find() alone the binding went stale on first load
  readonly property var selected: { var l = allRows, id = selectedID; for (var i = 0; i < l.length; ++i) if (l[i].id === id) return l[i]; return null }
  function select(id) { selectedID = id; Prefs.set("accountsFocus", id) }
  function fallback() {
    for (var i = 0; i < allRows.length; ++i) if (allRows[i].isDefault) return allRows[i].id
    return allRows.length ? allRows[0].id : ""
  }
  onAllRowsChanged: ensureSelection()
  function ensureSelection() {
    if (!restored && allRows.length) {
      restored = true
      var saved = String(pref("accountsFocus", "")).toLowerCase()
      selectedID = find(saved) ? saved : fallback()
    } else if (allRows.length && !find(selectedID)) selectedID = fallback()
  }
  // The window's search drop-down picks an account through win.selectedAccountID (shell.md 2.3).
  Connections {
    target: page.win
    ignoreUnknownSignals: true
    function onSelectedAccountIDChanged() { if (page.win.selectedAccountID && page.find(page.win.selectedAccountID)) page.select(page.win.selectedAccountID) }
  }
  onQueryChanged: {
    if (query.trim() === "" || !rows.length) return
    for (var i = 0; i < rows.length; ++i) if (rows[i].id === selectedID) return
    select(rows[0].id)
  }
  function loadMissions() {
    Helper.call("droid.missions", {}, function (r, e) { if (!e && Array.isArray(r)) page.missions = r.slice().sort(function (a, b) { return (b.createdAt || "") < (a.createdAt || "") ? -1 : 1 }) })
  }
  onSelectedIDChanged: {
    detail = null
    detailFade.restart()
    if (selectedID === "" || !(demo || Helper.hasMethod("usage.detail"))) return
    var id = selectedID
    if (selected && selected.providerID === "droid") loadMissions()
    Helper.call("usage.detail", { accountID: id }, function (r, e) { if (!e && r && r.accountID === id && page.selectedID === id) page.detail = r })
  }

  // ---- tray visibility, hidden rows, menu bar overrides (settings keys, accounts.md 9.3) -----------
  function listPref(k) { var v = pref(k, []); return Array.isArray(v) ? v : [] }
  function toggleIn(k, id) {
    var l = listPref(k).slice(), i = l.indexOf(id)
    if (i >= 0) l.splice(i, 1); else l.push(id)
    l.sort()
    Prefs.set(k, l)
  }
  function serviceHidden(p) { return listPref("menuBarHiddenServices").indexOf(p) >= 0 }
  function accountHidden(id) { var l = listPref("menuBarHiddenAccounts"); return l.indexOf(id) >= 0 || l.indexOf(id.toUpperCase()) >= 0 }
  function toggleService(p) { toggleIn("menuBarHiddenServices", p) }
  function toggleAccount(id) { toggleIn("menuBarHiddenAccounts", id) }
  // The Mac writes the uppercase UUID; the helper reads both.
  function rowsKey(id) { var up = "hiddenUsageRows." + id.toUpperCase(); return Prefs.value(up) !== undefined && Prefs.value(up) !== null ? up : "hiddenUsageRows." + id }
  function hiddenRows(id) { return String(pref(rowsKey(id), "")).split("\n").filter(function (s) { return s !== "" }) }
  function hideRow(id, wid) { var l = hiddenRows(id); if (l.indexOf(wid) < 0) l.push(wid); l.sort(); Prefs.set(rowsKey(id), l.join("\n")) }
  function showAllRows(row) { Prefs.set(rowsKey(row.id), null) }
  function menubarKey(id) { return "showAccountUsageInMenuBar.account." + id }
  function menubarOverride(id) { var v = Prefs.value(menubarKey(id)); return v === undefined || v === null ? null : v }
  function moveService(p, d) {
    var order = A.groups(allRows, pref("menuBarServiceOrder", [])).map(function (g) { return g.provider })
    var i = order.indexOf(p), j = i + d
    if (i < 0 || j < 0 || j >= order.length) return
    order.splice(i, 1)
    order.splice(j, 0, p)
    Prefs.set("menuBarServiceOrder", order)
  }
  // The global account order (accounts.status order, else the topic's); Move up/down and drops use it (4.1).
  property var statusIDs: []
  function order() { return statusIDs.length ? statusIDs : allRows.map(function (r) { return r.id }) }
  function neighbor(id, d) { var o = order(), i = o.indexOf(id); return i >= 0 && i + d >= 0 && i + d < o.length ? o[i + d] : "" }
  function moveAccount(id, target) {
    var ids = order().slice(), from = ids.indexOf(id), to = ids.indexOf(target)
    if (from < 0 || to < 0 || from === to) return
    ids.splice(from, 1)
    ids.splice(to, 0, id)
    act("accounts.reorder", { accountIDs: ids }, function () { page.statusIDs = ids; page.load() })
  }

  // ---- actions (accounts.md 3; rpc.md User actions and two-step confirmations) ---------------------
  property string localError: ""
  property string dismissed: ""
  readonly property string errorText: {
    var e = (Helper.topics.notices && Helper.topics.notices.error) || localError
    return e && e !== dismissed ? e : ""
  }
  function fail(t) { localError = t; dismissed = "" }
  function act(method, params, done) {
    if (busy) return
    pending = true
    localError = ""
    Helper.call(method, params, function (r, e) {
      page.pending = false
      if (e) {
        // busy: another action holds the lane; the Mac drops the click silently (rpc.md rule 7)
        if (!(e.data && e.data.kind === "busy")) page.fail(e.message)
        return
      }
      if (r && r.status === "needsConfirmation" && r.confirmation) {
        var c = r.confirmation
        Theme.alert.open({ title: c.title, message: c.message, action: c.action, destructive: c.kind === "delete",
                           onAccept: function () { var p = Object.assign({}, params); p.confirm = c.token; page.act(method, p, done) } })
        return
      }
      if (r && r.error) page.fail(r.error)
      if (done) done(r)
    })
  }
  function switchDefault(row) { act("accounts.setDefault", { accountID: row.id }) }
  function check(row) { act("accounts.check", { accountID: row.id }) }
  function refresh(row) { act("usage.refresh", { accountID: row.id }) }
  function allow(row) { act("usage.refresh", { accountID: row.id }) }
  function signIn(row) { sheet.openSignIn(row) }
  function openAccount(row) { act("accounts.open", { accountID: row.id }) }
  function copy(t) { App.copy(t) }
  function copyName(row) { copy(row.realLabel || A.realLabel(statusOf(row.id), pname(row.providerID)) || row.label) }
  function copyAuthPath(row) {
    var fallbackPath = statusOf(row.id) ? statusOf(row.id).credentialFile : ""
    Helper.call("accounts.savedAuthPath", { accountID: row.id }, function (r, e) { var p = !e && r ? r.path : fallbackPath; if (p) page.copy(p) })
  }
  function rename(row) {
    var cur = statusOf(row.id) && statusOf(row.id).identity ? statusOf(row.id).identity.accountID || "" : ""
    Theme.alert.open({ title: "Rename " + (cur || "account"), message: "Its sign-in, default, and missions stay the same.",
                       action: "Rename", field: cur, fieldLabel: "Account name",
                       onAccept: function (name) { page.act("accounts.rename", { accountID: row.id, name: String(name || "").trim() }) } })
  }
  function del(row) {
    if (!A.canDelete(row, allRows)) { fail("No saved account is available as a replacement."); return }
    act("accounts.delete", { accountID: row.id })
  }

  // ---- menus (3.2 More, 3.3 row, 3.4 group, 3.6 usage row) ----------------------------------------
  Item { id: ctxAnchor; width: 0; height: 0 }
  function menuAt(item, x, y) { var p = item.mapToItem(page, x, y); ctxAnchor.x = p.x; ctxAnchor.y = p.y - 4; return ctxAnchor }
  function openMenu(anchor, items) {
    var labels = [], acts = []
    items.forEach(function (it) { if (it) { labels.push(it.a ? { text: it.text, enabled: it.enabled !== false, checked: it.checked } : it); acts.push(it.a || null) } })
    Theme.menu.open(anchor, labels, -1, function (i) { if (acts[i]) acts[i]() })
  }
  function moreMenu(row, anchor) {
    var p = row.providerID, b = A.isBuiltIn(p), ovr = menubarOverride(row.id)
    var on = ovr !== null ? ovr === true : pref("showAccountUsageInMenuBar", true) === true
    openMenu(anchor, [
      { text: "Copy Name", a: function () { copyName(row) } },
      p === "droid" ? { text: "Rename…", enabled: !busy && !pref("privacyMode", false), a: function () { rename(row) } } : null,
      b ? { text: p === "claude-code" ? "Copy Config Path" : "Copy auth path", a: function () { copyAuthPath(row) } } : null,
      "-",
      { text: "Show in Menubar", checked: on, a: function () { Prefs.set(menubarKey(row.id), !on) } },
      { text: "Use Settings Default", enabled: ovr !== null, a: function () { Prefs.set(menubarKey(row.id), null) } },
      "-",
      { text: "Refresh Usage", enabled: !busy, a: function () { refresh(row) } },
      A.canSignInAgain(p) ? { text: "Sign in again", enabled: !busy, a: function () { signIn(row) } } : null,
      b ? { text: "Check Account", enabled: !busy, a: function () { check(row) } } : null,
      "-",
      { text: "Delete…", enabled: !busy && A.canDelete(row, allRows), a: function () { del(row) } }
    ])
  }
  function rowMenu(item, x, y, row) {
    var p = row.providerID, b = A.isBuiltIn(p), tool = A.toolName(p, names)
    openMenu(menuAt(item, x, y), [
      { text: row.isDefault ? "Using as default" : "Make Default", enabled: !busy, a: function () { switchDefault(row) } },
      A.canSignInAgain(p) ? { text: "Sign in again", enabled: !busy, a: function () { signIn(row) } } : null,
      !b ? { text: "Refresh usage", enabled: !busy && !row.isRefreshing, a: function () { refresh(row) } } : null,
      b ? { text: (row.isDefault ? "Open " : "Use & Open ") + tool, enabled: !busy, a: function () { openAccount(row) } } : null,
      b ? { text: "Check account files", enabled: !busy, a: function () { check(row) } } : null,
      b ? { text: p === "claude-code" ? "Copy config path" : "Copy auth path", a: function () { copyAuthPath(row) } } : null,
      p === "droid" ? { text: "Rename…", enabled: !busy && !pref("privacyMode", false), a: function () { rename(row) } } : null,
      "-",
      { text: "Move up", enabled: !busy && neighbor(row.id, -1) !== "", a: function () { moveAccount(row.id, neighbor(row.id, -1)) } },
      { text: "Move down", enabled: !busy && neighbor(row.id, 1) !== "", a: function () { moveAccount(row.id, neighbor(row.id, 1)) } },
      "-",
      { text: "Delete account", enabled: !busy && A.canDelete(row, allRows), a: function () { del(row) } }
    ])
  }
  function groupMenu(item, x, y, p) {
    var order = groups.map(function (g) { return g.provider }), i = order.indexOf(p), canMove = query.trim() === ""
    openMenu(menuAt(item, x, y), [
      { text: serviceHidden(p) ? "Show in menu bar" : "Hide from menu bar", a: function () { toggleService(p) } },
      canMove ? { text: "Move service up", enabled: i > 0, a: function () { moveService(p, -1) } } : null,
      canMove ? { text: "Move service down", enabled: i < order.length - 1, a: function () { moveService(p, 1) } } : null
    ])
  }
  function meterMenu(item, x, y, wid) {
    var row = selected
    if (!row) return
    openMenu(menuAt(item, x, y), [
      { text: "Hide this row", a: function () { hideRow(row.id, wid) } },
      { text: "Show all hidden rows", enabled: hiddenRows(row.id).length > 0, a: function () { showAllRows(row) } },
      "-",
      { text: "Refresh usage", a: function () { refresh(row) } }
    ])
  }
  // Mission More menu: "Set owner" opens a second menu with the saved Droid accounts (no submenus in MenuPanel).
  function missionMenu(anchor, m) {
    openMenu(anchor, [{ text: "Set owner ›", a: function () {
      Qt.callLater(function () {
        openMenu(anchor, allRows.filter(function (r) { return r.providerID === "droid" }).map(function (r) {
          return { text: r.label, checked: r.id === m.owner, enabled: !busy,
                   a: function () { act("droid.setMissionOwner", { missionID: m.id, accountID: r.id }, loadMissions) } }
        }))
      })
    } }])
  }
  function openSheet(mode) { if (mode === "import") sheet.openImport(); else sheet.openAdd() }

  // ---- layout ------------------------------------------------------------------------------------
  PageHeader { id: header; width: parent.width; placeholder: "Search accounts…" }
  AccErrorBar {
    id: errorBar
    visible: page.errorText !== "" && !sheet.visible
    x: 20
    y: header.height
    width: parent.width - 40
    text: page.errorText
    onDismiss: { page.dismissed = page.errorText; page.localError = "" }
    onCopy: page.copy(page.errorText)
  }

  ScrollArea {
    id: scroll
    anchors.top: errorBar.visible ? errorBar.bottom : header.bottom
    anchors.bottom: parent.bottom
    width: parent.width
    gutter: 20

    AccTable { id: tableCard; ctl: page }
    // Settings matches (account-window.md 2.2): a non-blank search with fewer than 3 matching accounts
    MatchCard {
      visible: page.query.trim() !== "" && page.rows.length < 3 && rows.length > 0
      accounts: false
      rows: page.win && page.win.settingsHits ? page.win.settingsHits : []
      onPicked: function () { page.win.showPage("Settings") }
    }

    Column {
      id: detailCol
      width: parent.width
      spacing: 12
      NumberAnimation { id: detailFade; target: detailCol; property: "opacity"; from: 0.4; to: 1; duration: Theme.dAppear
                        easing.type: Easing.Bezier; easing.bezierCurve: Theme.easeOut }

      Loader {
        width: parent.width
        active: !!page.selected
        visible: active
        sourceComponent: Column {
          id: dc
          spacing: 12
          readonly property var row: page.selected
          readonly property string p: row.providerID
          AccFocusedCard { ctl: page; row: dc.row }
          AccUsageCard { ctl: page; row: dc.row; detail: page.detail }
          AccFactsCard {
            readonly property var snap: dc.p === "codex" && page.detail && page.detail.codex ? page.detail.codex : null
            facts: snap ? A.codexFacts(snap) : []
            visible: facts.length > 0
          }
          AccDailyCard {
            readonly property var daily: dc.p === "codex" && page.detail && page.detail.daily ? page.detail.daily : []
            visible: daily.length > 0
            ctl: page
            accountID: dc.row.id
            rows: daily
          }
          AccActivityCard { visible: dc.p === "claude-code" || dc.p === "droid"; ctl: page; provider: dc.p }
          AccMissionsCard { visible: dc.p === "droid" && page.missions.length > 0; ctl: page; missions: page.missions }
          AccKeyCard { visible: dc.p === "droid"; ctl: page; row: dc.row }
          AccDetailsCard { ctl: page; row: dc.row }
          AccRepairCard {
            readonly property var mine: page.divergences.filter(function (d) { return d.accountID === dc.row.id })
            visible: mine.length > 0
            ctl: page
            items: mine
          }
        }
      }

      // no selection: loading card, else the empty state (ACC:183-212)
      Card {
        visible: !page.selected && (!page.loaded || !!page.app.isBusy)
        title: "Account"
        Item { width: parent.width; height: 36; Skeleton { x: 16; y: 13; width: 160; height: 10 } Skeleton { x: parent.width - 86; y: 13; width: 70; height: 10 } }
        Item { width: parent.width; height: 36 + 7; Skeleton { x: 16; y: 13; width: 110; height: 10 } Skeleton { x: parent.width - 86; y: 13; width: 70; height: 10 } }
      }
      Card {
        visible: !page.selected && page.loaded && !page.app.isBusy
        title: "Account"
        AccSecRow {
          last: true
          Column {
            width: parent.width
            spacing: 8
            Txt { role: "section"; text: "Add your first account" }
            Txt { role: "secondary"; color: Theme.secondary; width: parent.width; wrapMode: Text.Wrap
                  text: "Switch found no saved account. Sign in to Codex or Grok Build, or use Advanced Import for an existing Codex folder." }
            Row {
              spacing: 8
              PushButton { icon: "plus"; text: "Add account"; prominent: true; enabled: !page.busy; onClicked: sheet.openAdd() }
              PushButton { icon: "folder"; text: "Advanced Import…"; enabled: !page.busy; onClicked: sheet.openImport() }
            }
          }
        }
      }
    }
  }

  // The Account window loads by URL, so an error in it leaves this page working; the stub keeps the buttons safe.
  readonly property var sheet: sheetLd.item ? sheetLd.item : ({ visible: false, openAdd: function () {}, openImport: function () {}, openSignIn: function () {} })
  Loader {
    id: sheetLd
    Component.onCompleted: setSource("AddAccountSheet.qml", { ctl: page })
    onStatusChanged: if (status === Loader.Error) console.error("account window failed to load: " + Window.window.loadError("AddAccountSheet.qml"))
  }
  AccShots { page: page; sheet: page.sheet }
}
