import QtQuick
import QtQuick.Window
import "Search.js" as Search

// Main window (shell.md 1, 2): 1200 wide, height-only resizable (min 800), custom 52 pt bar with the
// window buttons, 220 sidebar, page host. Pages build on first visit and stay alive; a switch swaps them
// in one frame with no animation (2.4).
Window {
  id: win
  width: 1200
  height: Math.max(800, Number(App.arg("height", "900")))   // --height 800 for the Mac reference captures
  minimumWidth: 1200
  maximumWidth: 1200
  minimumHeight: 800
  visible: !App.flag("background")
  color: "transparent"
  title: "Switch"
  flags: Qt.Window | Qt.FramelessWindowHint

  readonly property var pages: {
    var p = [
      { title: "Overview", route: "Overview", icon: "house" },
      { title: "Accounts", route: "Accounts", icon: "people" },
      { title: "Settings", route: "Settings", icon: "gearFill" },
      { title: "Maintenance", route: "Maintenance", icon: "tools" },
      { title: "History", route: "Conversations", icon: "history" }
    ]
    if (App.flag("gallery")) p.push({ title: "Gallery", route: "Gallery", icon: "gear" })
    return p
  }
  property int pageIndex: 0
  property string searchQuery: ""
  property var popover: null
  property var restoreRect: null
  property real popoverClosedAt: 0

  function show(i) { if (i >= 0 && i < pages.length) { pageIndex = i; launched = true; Prefs.set("lastPage", pages[i].route) } }
  // shell.md 3.1: the launch page is Overview for launchPlace "overview", else lastPage. Settings arrive
  // after the window, so the choice applies once when they do, unless a --page flag or a click came first.
  property bool launched: App.arg("page") !== ""
  function launchPage() {
    if (launched || !Helper.topics.settings) return
    launched = true
    var want = Prefs.value("launchPlace") === "overview" ? "Overview" : Prefs.value("lastPage")
    for (var i = 0; i < pages.length; ++i) if (pages[i].route === want) pageIndex = i
  }
  Connections {
    target: Helper
    function onTopicChanged(t) { if (t === "settings") win.launchPage() }
    function onStatusChanged() {
      if (Helper.status === "ready" || Helper.status === "demo") win.loadCatalogs()
      // blocked (another helper holds the data folder) or failed (bad arguments): the client does not restart
      if ((Helper.status === "blocked" || Helper.status === "failed") && Theme.alert) {
        console.error("helper " + Helper.status + ": " + Helper.error)
        Theme.alert.open({ title: "Switch cannot start", message: Helper.error, action: "Quit", onAccept: function () { Qt.quit() } })
      }
    }
  }

  // Global search (shell.md 4): one query for the window; the Settings index comes from the helper's
  // app.searchIndex (demo.json in --demo), so Settings hits stay empty until it answers.
  property var providerNames: ({})
  property var searchIndex: []
  property string selectedAccountID: ""   // Accounts reads this: a search pick selects that account
  readonly property bool searchBlank: Search.blank(searchQuery)
  readonly property var settingsHits: Search.settings(searchQuery, searchIndex)
  readonly property var accountHits: Search.accounts(searchQuery, Helper.topics.accounts ? Helper.topics.accounts.rows : [], providerNames)
  function loadCatalogs() {
    Helper.call("providers.list", {}, function (r, err) {
      if (err || !r) return
      var n = {}
      for (var i = 0; i < r.length; ++i) n[r[i].id] = r[i].displayName
      win.providerNames = n
    })
    if (Helper.hasMethod("app.searchIndex"))
      Helper.call("app.searchIndex", {}, function (r, err) { if (!err && r && r.length) win.searchIndex = r })
  }
  function pickAccount(id) { selectedAccountID = id; show(1) }
  readonly property bool dropdownPage: ["Overview", "Maintenance", "Conversations"].indexOf(pages[pageIndex].route) >= 0
  property bool searchFocused: false
  property int searchHot: 0
  onSearchQueryChanged: searchHot = 0
  // Drop-down rows in key order: up to 4 accounts, "Show all N" when more match, then up to 4 settings.
  readonly property var dropRows: {
    var r = []
    for (var i = 0; i < Math.min(4, accountHits.length); ++i) r.push({ kind: "account", item: accountHits[i] })
    if (accountHits.length > 4) r.push({ kind: "all", count: accountHits.length })
    for (var k = 0; k < Math.min(4, settingsHits.length); ++k) r.push({ kind: "setting", item: settingsHits[k] })
    return r
  }
  function searchMove(d) { searchHot = Math.max(0, Math.min(dropRows.length - 1, searchHot + d)) }
  function searchChoose(row) {
    searchFocused = false
    pageHost.forceActiveFocus()
    if (row.kind === "account") pickAccount(row.item.id)
    else if (row.kind === "all") show(1)
    else show(2)
  }
  function searchAccept() {
    if (dropdownPage && !searchBlank && dropRows.length > 0) searchChoose(dropRows[searchHot])
    else if (pages[pageIndex].route === "Accounts" && accountHits.length > 0
             && accountHits.every(function (a) { return a.id !== selectedAccountID })) selectedAccountID = accountHits[0].id
  }
  function page(i) { var l = loaders.itemAt(i); return l ? l.item : null }
  function pageFailure(i) { var l = loaders.itemAt(i); return l ? l.failure : "" }
  function present() { win.visible = true; if (win.visibility === Window.Minimized) win.showNormal(); win.raise(); win.requestActivate() }
  // popover.md 4.2: refresh every account shown in the menu bar (the per-account choice, else the global
  // one); `done` runs when every reply is in. Requests in one group keep their order in the helper, so
  // Codex accounts still refresh one after another.
  property int refreshesLeft: 0
  property var refreshDone: []
  function refreshAll(done) {
    if (done) refreshDone.push(done)
    if (refreshesLeft > 0) return
    // the tray topic's account eye (showsInTray) already folds in the per-account and global choice
    var groups = Helper.topics.tray && Helper.topics.tray.groups ? Helper.topics.tray.groups : []
    var ids = []
    for (var g = 0; g < groups.length; ++g)
      for (var i = 0; i < groups[g].rows.length; ++i) if (groups[g].rows[i].showsInTray) ids.push(groups[g].rows[i].id)
    if (!Helper.hasMethod("usage.refresh") || ids.length === 0) { finishRefresh(); return }
    refreshesLeft = ids.length
    for (var k = 0; k < ids.length; ++k)
      Helper.call("usage.refresh", { accountID: ids[k] }, function () { if (--win.refreshesLeft === 0) win.finishRefresh() })
  }
  function finishRefresh() { var d = refreshDone; refreshDone = []; for (var i = 0; i < d.length; ++i) d[i]() }
  function focusSearch() { present(); var p = page(pageIndex); if (p) p.header.focusSearch() }
  // The Add Account and Import sheets belong to the Accounts page (account-window.md 1.3); any page opens them.
  function openAccountSheet(mode) {
    for (var i = 0; i < pages.length; ++i) if (pages[i].route === "Accounts") { present(); show(i); var p = page(i); if (p && p.openSheet) p.openSheet(mode) }
  }
  // Cross-page hooks (agreed API): showPage takes a route or a title and returns the page item (or null when
  // it failed to load), so a caller can go on with that page's own hook, such as showBackupTab() or selectChat(id).
  function showPage(name) {
    for (var i = 0; i < pages.length; ++i) if (pages[i].route === name || pages[i].title === name) { present(); show(i); return page(i) }
    return null
  }
  function beginAddAccount() { openAccountSheet("add") }
  function beginAdvancedImport() { openAccountSheet("import") }
  // Zoom fills the screen height at width 1200; a second press restores (shell.md 1.1).
  function zoom() {
    if (restoreRect) { win.y = restoreRect.y; win.height = restoreRect.height; restoreRect = null; return }
    var a = App.workArea(win)
    restoreRect = { y: win.y, height: win.height }
    win.y = a.y
    win.height = Math.max(a.height, 800)
  }
  function closeWindow() { if (Tray.available) win.hide(); else Qt.quit() }

  // Tray popover: icon click toggles; a click that just closed it by focus loss does not reopen it (8.2 rule 5).
  // "<file>:<line>: <message>" of the first error, for a page or popover that failed to load
  function loadError(url) {
    var c = Qt.createComponent(url)
    var e = c.status === Component.Error ? c.errorString().split("\n")[0] : String(url)
    return e.replace(/^qrc:\/qt\/qml\/SwitchUI\//, "")
  }
  // The popover also loads by URL, so an error in its files leaves the window and pages working.
  function makePopover() {
    var c = Qt.createComponent("PopoverWindow.qml")
    if (c.status !== Component.Ready) { console.error("popover failed to load: " + loadError("PopoverWindow.qml")); return null }
    var p = c.createObject(null)
    p.openMain.connect(function () { p.close(); win.present() })
    p.openSettings.connect(function () { p.close(); win.present(); win.show(2) })
    p.quit.connect(function () { Qt.quit() })
    p.refresh.connect(function () { win.refreshAll(function () { p.refreshing = false }) })
    p.visibleChanged.connect(function () { if (!p.visible) win.popoverClosedAt = Date.now() })
    // popover.md 5.1: Switch closes on success; Open, Sign in, and Allow access close at once
    p.rowAction.connect(function (name, acct, provider) {
      var row = { id: acct.id, providerID: provider, label: acct.label }
      if (name === "Switch")
        Helper.call("accounts.setDefault", { accountID: acct.id }, function (r, e) { if (!e && !(r && r.error)) p.close() })
      else if (name === "Sign in") { p.close(); var a = win.showPage("Accounts"); if (a && a.signIn) a.signIn(row) }
      else if (name === "Allow access") { p.close(); win.present(); Helper.call("usage.refresh", { accountID: acct.id }, function () {}) }
      else { p.close(); Helper.call("accounts.open", { accountID: acct.id }, function () {}) }
    })
    // The eyes flip one id in a sorted settings list; the Mac writes account ids in upper case, the helper reads both.
    p.toggleHidden.connect(function (key, id) {
      var l = (Prefs.value(key) || []).slice(), i = l.indexOf(id), j = l.indexOf(String(id).toUpperCase())
      if (i >= 0 || j >= 0) l = l.filter(function (x) { return x !== id && x !== String(id).toUpperCase() })
      else l.push(id)
      l.sort()
      Prefs.set(key, l)
    })
    return p
  }
  function togglePopover(rect) {
    if (!popover) popover = makePopover()
    if (!popover) return
    if (popover.visible) popover.close()
    else if (Date.now() - popoverClosedAt > 150) {
      popover.open(rect)
      // shell.md 5.2 "Refresh when the menu opens": the helper's tray.opened runs app.refresh when that setting is on
      var p = popover, spin = Prefs.value("refreshWhenMenuOpens") === true
      if (Helper.hasMethod("tray.opened")) {
        if (spin) p.refreshing = true
        Helper.call("tray.opened", {}, function () { if (spin) p.refreshing = false })
      } else if (spin) { p.refreshing = true; p.refresh() }
    }
  }
  // popover.md 1.4 and 8.1: the status item cannot show the percent strip off the Mac, so its tooltip carries
  // one line per tray account (the helper's tray.tooltip); "Switch" when the list is empty.
  Binding { target: Tray; property: "tooltip"; value: (Helper.topics.tray && Helper.topics.tray.tooltip) || "Switch" }
  Connections { target: Notify; function onActivated() { win.present() } }   // a click on a Switch notification
  Connections {
    target: Tray
    function onToggleRequested(rect) { win.togglePopover(rect) }
    function onOpenRequested() { win.present() }
    function onRefreshRequested() { win.refreshAll() }
    function onSettingsRequested() { win.present(); win.show(2) }
    function onQuitRequested() { Qt.quit() }
  }
  // shell.md 5.2: register the stored menu shortcut at launch and on every change; a press toggles the popover
  // like a tray click; a refused combo is stored as none.
  QtObject {
    property var combo: Prefs.value("globalShortcut") || null
    onComboChanged: App.applyShortcut(combo)
    Component.onCompleted: App.applyShortcut(combo)
  }
  Connections {
    target: App
    function onShortcutActivated() { win.togglePopover(Tray.iconRect()) }
    function onShortcutRefused() { Prefs.set("globalShortcut", null) }
  }

  Shortcut { sequences: ["Ctrl+1"]; onActivated: win.show(0) }
  Shortcut { sequences: ["Ctrl+2"]; onActivated: win.show(1) }
  Shortcut { sequences: ["Ctrl+3", "Ctrl+,"]; onActivated: win.show(2) }
  Shortcut { sequences: ["Ctrl+4"]; onActivated: win.show(3) }
  Shortcut { sequences: ["Ctrl+5"]; onActivated: win.show(4) }
  Shortcut { sequence: "Ctrl+K"; onActivated: win.focusSearch() }
  Shortcut { sequence: "Ctrl+N"; onActivated: win.openAccountSheet("add") }
  Shortcut { sequence: "Ctrl+Shift+I"; onActivated: win.openAccountSheet("import") }
  Shortcut { sequence: "Ctrl+R"; onActivated: win.refreshAll() }
  Shortcut { sequence: "Ctrl+W"; onActivated: win.closeWindow() }
  Shortcut { sequence: "Ctrl+M"; onActivated: win.showMinimized() }
  Shortcut { sequence: "Ctrl+Q"; onActivated: Qt.quit() }

  Driver { id: driver; win: win }

  Component.onCompleted: {
    Theme.dpr = Screen.devicePixelRatio
    Theme.fontFamily = App.fontFamily
    // A --theme flag pins the appearance for captures; otherwise Settings > Appearance drives it.
    if (App.arg("theme") !== "") Theme.mode = App.arg("theme")
    else Theme.mode = Qt.binding(function () { return Prefs.value("windowAppearance") })
    Theme.showUsed = Qt.binding(function () { return Prefs.value("showUsageAsUsed") === true })
    Theme.motion = !App.flag("no-motion")
    if (App.flag("content-only")) Theme.windowRadius = 0
    Theme.pageHost = pageHost
    Theme.menu = menu
    Theme.tooltip = tooltip
    Theme.alert = alert
    var want = App.arg("page", "Overview").toLowerCase()
    for (var i = 0; i < pages.length; ++i) if (pages[i].title.toLowerCase() === want || pages[i].route.toLowerCase() === want) pageIndex = i
    launchPage()
    if (Helper.status === "demo") loadCatalogs()   // the demo was ready before this window existed
    driver.start(App.arg("script", ""))
  }
  onScreenChanged: Theme.dpr = Screen.devicePixelRatio

  Item {
    id: shell
    anchors.fill: parent

    // page region: page color; the window clips its right corners to the window radius
    Item {
      id: pageHost
      x: 220
      width: parent.width - 220
      height: parent.height
      clip: true
      Rectangle { x: -12; width: parent.width + 12; height: parent.height; radius: Theme.windowRadius; color: Theme.page }

      Repeater {
        id: loaders
        model: win.pages
        delegate: Loader {
          id: ld
          readonly property bool current: win.pageIndex === index
          property bool visited: false
          onCurrentChanged: if (current) visited = true
          Component.onCompleted: if (current) visited = true
          anchors.fill: parent
          active: visited
          visible: current
          enabled: current
          // Each page loads by URL, so a page with a QML error fails alone: its slot shows the error and
          // every other page, the popover, and the capture harness keep working.
          source: ({ Overview: "OverviewPage.qml", Accounts: "AccountsPage.qml", Settings: "SettingsPage.qml", Gallery: "GalleryPage.qml",
                     Conversations: "HistoryPage.qml", Maintenance: "MaintenancePage.qml" })[modelData.route] || "PlaceholderPage.qml"
          property string failure: ""
          onStatusChanged: if (status === Loader.Error) {
            failure = win.loadError(source)
            console.error("page failed to load: " + failure)
          }
          onLoaded: if (modelData.spec) { item.title = modelData.title; item.spec = modelData.spec; if (modelData.placeholder) item.placeholder = modelData.placeholder }
          Txt { visible: ld.failure !== ""; x: 20; y: 64; width: parent.width - 40; wrapMode: Text.Wrap; color: Theme.secondary
                text: "This page failed to load: " + ld.failure }
        }
      }
    }

    Sidebar {
      id: sidebar
      height: parent.height
      pages: win.pages
      current: win.pageIndex
      onSelect: function (i) { win.show(i) }
    }

    // window drag on the 52 pt bar, behind every control
    MouseArea {
      width: parent.width
      height: 52
      z: -1
      onPressed: win.startSystemMove()
      onDoubleClicked: win.zoom()
    }
    // Close center x 20 (shell.md 1.2): 12 pt discs, 20 apart, centered on the 52 pt bar.
    TrafficLights {
      x: 14
      y: 20
      visible: !App.flag("content-only")   // the Mac captures are content-view renders: no buttons, no outline
      onClose: win.closeWindow()
      onMinimize: win.showMinimized()
      onZoom: win.zoom()
    }
    // height-only resize from the bottom edge
    MouseArea {
      anchors.bottom: parent.bottom
      width: parent.width
      height: 5
      cursorShape: Qt.SizeVerCursor
      onPressed: win.startSystemResize(Qt.BottomEdge)
    }

    // 1 px window outline
    Rectangle {
      visible: !App.flag("content-only")
      anchors.fill: parent
      radius: 10
      color: "transparent"
      border.width: Theme.hair
      border.color: Theme.windowBorder
    }

    Item { id: overlay; anchors.fill: parent }
    SearchDropdown { parent: overlay; win: win }
    MenuPanel { id: menu; parent: overlay }
    Tooltip { id: tooltip; parent: overlay }
    Alert { id: alert; parent: overlay }
  }
}
