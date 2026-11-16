import QtQuick
import QtQuick.Window
import "MaintFmt.js" as F
import "MaintDemo.js" as Demo

// Maintenance page (maintenance.md 2.1): one scroll page with the Cleanup / Backup segmented control and the
// source picker on the card edges, then the tab's cards. Each tab keeps its own scroll offset. Backup and
// restore errors use the red bar under the top row; Cleanup errors use its amber card.
Item {
  id: page
  property alias header: header
  property alias scroll: scrollArea
  property alias cleanup: cleanupTab
  property alias backup: backupTab

  readonly property bool demo: Helper.status === "demo"
  readonly property string demoState: App.arg("maint", "")
  readonly property bool helperUp: demo || Helper.status === "ready"
  readonly property var app: Helper.topics.app
  readonly property bool modelLoaded: demo || (!!app && app.hasLoaded)
  readonly property bool modelBusy: !demo && !!app && app.isBusy

  property string tab: "Cleanup"
  property string shownTab: "Cleanup"
  property var sources: []
  property bool sourcesLoaded: false
  property string sourceID: ""
  property string barError: ""

  // Cleanup hides the Claude profile rows and drops "Shared history · " from Claude Code (3.1).
  readonly property var cleanupSources: sources.filter(function (s) { return s.id.indexOf("claude:") !== 0 }).map(function (s) {
    return s.id === "claude" ? Object.assign({}, s, { detail: s.detail.replace("Shared history · ", "") }) : s
  })
  readonly property var source: {
    var list = cleanupSources, want = sourceID.indexOf("claude:") === 0 ? "claude" : sourceID
    for (var i = 0; i < list.length; ++i) if (list[i].id === want) return list[i]
    return list.length > 0 ? list[0] : null
  }
  readonly property string userHome: {
    for (var i = 0; i < sources.length; ++i) {
      var h = sources[i].home || ""
      if (sources[i].id === "codex" && h.slice(-7) === "/.codex") return h.slice(0, -7)
      if (sources[i].id === "claude" && h.slice(-8) === "/.claude") return h.slice(0, -8)
    }
    return ""
  }

  // MARK: helper access

  // Demo answers come from MaintDemo.js at once; a null answer never arrives (a loading state).
  function rpc(method, params, cb, timeoutMs) {
    if (demo) {
      var r = Demo.reply(method, params, demoState)
      if (r) cb(r.result === undefined ? null : r.result, r.error || null)
      return -1
    }
    return Helper.call(method, params, cb, timeoutMs === undefined ? -1 : timeoutMs)
  }
  function save(key, value) { Prefs.set(key, value) }
  function showError(text) { barError = text || "" }
  function copyText(text) { clipText.text = text; clipText.selectAll(); clipText.copy() }
  function ask(title, message, action, destructive, accepted) {
    Theme.alert.open({ title: title, message: message, action: action, destructive: destructive, onAccept: function () { accepted() } })
  }
  function pickFolder(title, button, start, done) {
    folderDialog.setSource("MaintFolderDialog.qml", start ? { title: title, acceptLabel: button, currentFolder: "file://" + start } : { title: title, acceptLabel: button })
    if (folderDialog.status !== Loader.Ready) { showError("The folder picker is not available on this system."); return }
    folderDialog.item.done = done
    folderDialog.item.open()
  }
  // Interrupted work (rpc.md recovery.*). An action may ask first (a running Factory app): show its text, then
  // repeat the call with the token.
  function act(method, params) {
    rpc(method, params, function (r, e) {
      if (Harness && demoState === "live") Harness.log("LIVE reply " + method + " " + JSON.stringify(e ? { error: e } : r))
      if (e) { showError(e.message); return }
      if (r && r.status === "needsConfirmation") {
        var c = r.confirmation
        ask(c.title, c.message, c.action, false, function () { act(method, Object.assign({}, params, { confirm: c.token })) })
        return
      }
      if (r && r.error) showError(r.error)
      backupTab.load()
    })
  }
  function resolve(op, choice) { act("recovery.resolve", { operationID: op.id, choice: choice }) }
  function recover() { act("recovery.recover", {}) }

  // Other pages (Overview "Open Backup") open this tab; a settings read that is still on its way must not undo it.
  property bool tabPicked: false
  function showBackupTab() { tabPicked = true; tab = "Backup" }

  function load() {
    if (!helperUp) return
    var keys = ["maintenanceTab", "maintenanceSource", "cleanupRange", "cleanupFrom", "cleanupThrough", "cleanupExpanded", "cleanupProjects", "cleanupTitle"]
    var go = function (v) {
      v = v || {}
      cleanupTab.restoring = true
      if (v.maintenanceTab && !tabPicked) tab =String(v.maintenanceTab).toLowerCase() === "backup" ? "Backup" : "Cleanup"
      if (v.maintenanceSource) sourceID = v.maintenanceSource
      if (v.cleanupRange && F.RANGES.indexOf(v.cleanupRange) >= 0) cleanupTab.range = v.cleanupRange
      if (v.cleanupFrom) cleanupTab.from = v.cleanupFrom * 1000
      if (v.cleanupThrough) cleanupTab.through = v.cleanupThrough * 1000
      if (v.cleanupExpanded) { var e = {}; String(v.cleanupExpanded).split("\n").forEach(function (k) { if (k) e[k] = true }); cleanupTab.expanded = e }
      if (Array.isArray(v.cleanupProjects)) cleanupTab.projects = v.cleanupProjects
      if (v.cleanupTitle) cleanupTab.titleQuery = v.cleanupTitle
      cleanupTab.restoring = false
      rpc("cleanup.sources", {}, function (list, err) {
        sources = list || []
        sourcesLoaded = true
        if (err) cleanupTab.error = err.message
      })
      backupTab.load()
    }
    if (demo) go(demoState.indexOf("backup") === 0 ? { maintenanceTab: "Backup" } : {})
    else rpc("settings.get", { keys: keys }, function (res) { go(res ? res.values : {}) })
  }
  onHelperUpChanged: load()
  Component.onCompleted: load()
  onVisibleChanged: if (visible) scrollArea.appear()

  // Each tab keeps its scroll offset in the shared `scrollOffsets` setting (maintenance-Cleanup,
  // maintenance-Backup), written 0.5 s after the last scroll (maintenance.md 2.1).
  function savedOffset(name) { var o = Prefs.value("scrollOffsets"); return o && o["maintenance-" + name] ? Number(o["maintenance-" + name]) : 0 }
  function saveOffset() {
    var o = Object.assign({}, Prefs.value("scrollOffsets") || {})
    var y = Math.round(scrollArea.flick.contentY)
    if (o["maintenance-" + shownTab] === y) return
    o["maintenance-" + shownTab] = y
    save("scrollOffsets", o)
  }
  Timer { id: offsetTimer; interval: 500; onTriggered: page.saveOffset() }
  Connections { target: scrollArea.flick; function onContentYChanged() { if (!page.restoringOffset) offsetTimer.restart() } }
  property bool restoringOffset: false
  function restoreOffset() {
    restoringOffset = true
    scrollArea.scrollTo(savedOffset(tab))
    restoringOffset = false
  }
  onTabChanged: {
    if (offsetTimer.running) { offsetTimer.stop(); saveOffset() }
    shownTab = tab
    Qt.callLater(restoreOffset)
    save("maintenanceTab", tab)
  }
  Component.onDestruction: if (offsetTimer.running) saveOffset()

  // Keyboard focus that moves to a control outside the visible part of the page scrolls it into view.
  function inside(it, root) { for (var p = it; p; p = p.parent) if (p === root) return true; return false }
  Connections {
    target: page.Window.window
    function onActiveFocusItemChanged() {
      var it = page.Window.activeFocusItem, f = scrollArea.flick
      if (!it || !App.keyboardMode || !page.inside(it, f.contentItem)) return
      var y = it.mapToItem(f.contentItem, 0, 0).y
      if (y - 12 < f.contentY) scrollArea.scrollTo(y - 12)
      else if (y + it.height + 12 > f.contentY + f.height) scrollArea.scrollTo(y + it.height + 12 - f.height)
    }
  }
  // The first restore waits for the shown tab's content, which a live helper sends later.
  property bool offsetRestored: false
  readonly property bool contentReady: tab === "Backup" ? backupTab.loaded : !!cleanupTab.scan
  onContentReadyChanged: if (contentReady && !offsetRestored) { offsetRestored = true; Qt.callLater(restoreOffset) }

  TextEdit { id: clipText; visible: false }
  Loader { id: folderDialog }

  // MARK: layout

  PageHeader { id: header; width: parent.width }

  // Error bar (maintenance.md 6 "Error"): under the top row, above the page, not a card of the page.
  MaintCard {
    id: errorBar
    visible: page.barError !== ""
    x: 20
    y: header.height
    width: parent.width - 40
    MaintRow {
      Item {
        width: parent.width
        height: Math.max(28, barText.height)
        Icon { anchors.verticalCenter: parent.verticalCenter; name: "warnTriangle"; size: 15; color: Theme.red }
        TextEdit {
          id: barText
          x: 15 + 8
          width: parent.width - x - 8 - 14 - 16 - dismiss.width
          anchors.verticalCenter: parent.verticalCenter
          readOnly: true
          selectByMouse: true
          wrapMode: TextEdit.Wrap
          text: page.barError
          color: Theme.label
          selectionColor: Theme.rgba(Theme.accent, 0.3)
          font.family: Theme.fontFamily
          font.pointSize: 13 * Theme.fontScale * 0.75
          ToolTipArea { text: page.barError }
        }
        IconButton { anchors.right: dismiss.left; anchors.rightMargin: 12; anchors.verticalCenter: parent.verticalCenter; icon: "copy"; tip: "Copy error"
                     onClicked: page.copyText(page.barError) }
        PushButton { id: dismiss; anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter; text: "Dismiss"; onClicked: page.barError = "" }
      }
    }
  }

  ScrollArea {
    id: scrollArea
    anchors.top: errorBar.visible ? errorBar.bottom : header.bottom
    anchors.topMargin: errorBar.visible ? 12 : 0
    anchors.bottom: parent.bottom
    width: parent.width
    gutter: 20

    Item {
      width: parent.width
      height: 28
      Segmented {
        id: tabs
        name: "Maintenance section"
        model: ["Cleanup", "Backup"]
        icons: ["eraser", "archivebox"]
        segmentWidth: 120
        current: page.tab === "Backup" ? 1 : 0
        onPicked: function (i) { page.tab = i === 1 ? "Backup" : "Cleanup"; current = Qt.binding(function () { return page.tab === "Backup" ? 1 : 0 }) }
      }
      MaintSourcePicker {
        id: picker
        visible: page.tab === "Cleanup"
        anchors.right: parent.right
        sources: page.cleanupSources
        current: page.source
        loaded: page.sourcesLoaded
        onChose: function (id) { page.sourceID = id; page.save("maintenanceSource", id) }
      }
    }

    MaintCleanup {
      id: cleanupTab
      visible: page.tab === "Cleanup"
      page: page
      source: page.source
      sourcesLoaded: page.sourcesLoaded
      modelLoaded: page.modelLoaded
      modelBusy: page.modelBusy
      active: page.tab === "Cleanup" && page.visible && page.helperUp
    }
    MaintBackup {
      id: backupTab
      visible: page.tab === "Backup"
      page: page
      modelLoaded: page.modelLoaded
      modelBusy: page.modelBusy
    }
  }

  MaintRestoreSheet {
    id: sheet
    host: page.Window.contentItem
    page: page
    request: backupTab.restoreRequest
    restoring: backupTab.restoring
    onOpenChanged: if (!open && !backupTab.restoring) backupTab.restoreRequest = null
    onRestore: function (items, destination) { backupTab.restore(backupTab.restoreRequest, items, destination) }
  }
  Connections { target: backupTab; function onRestoreRequestChanged() { sheet.open = !!backupTab.restoreRequest } }

  // MARK: capture steps (--demo --script states --page Maintenance [--maint <data variant>], maintenance.md 6)

  // --maint live with a real helper on a synthetic root: scan, review, move to trash, restore, purge (both
  // steps), then choose a backup folder, check Codex, back up, and restore into a folder. Logs LIVE lines.
  function liveSteps(d, shot) {
    var c = cleanupTab, b = backupTab
    var log = function (what) { return function () {
      Harness.log("LIVE " + what + " trash=" + c.trash.length + " cats=" + (c.scan ? c.scan.categories.length : -1)
                  + " sets=" + b.sets.length + " history=" + b.history.length + " folder=" + b.folder
                  + " checked=" + b.checkedRows.map(function (r) { return r.sourceID }).join(",") + " shared=" + JSON.stringify(b.shared)
                  + " running=" + JSON.stringify(b.running) + " free=" + b.free + " caches=" + JSON.stringify(c.cacheSizes)
                  + " groups=" + (b.history[0] ? JSON.stringify(b.history[0].snapshot.groups) : "none")
                  + " error=" + JSON.stringify(c.error) + " bar=" + JSON.stringify(page.barError)) } }
    var selectAll = function () {
      var next = {}
      c.view.cats.forEach(function (x) { x.items.forEach(function (it) { next[it.id] = true }) })
      c.selection = next; ++c.rev
    }
    var bottom = function () { scrollArea.scrollTo(10000) }
    var row = function (id) { return b.rows.filter(function (r) { return r.sourceID === id })[0] }
    // A wait step: the run goes on when `cond` is true, or after `ms` with a LIVE timeout line.
    var until = function (name, cond, ms) { return { name: name, cond: cond, ms: ms || 30000 } }
    var cancelAt = 0
    var idle = function () { return !c.loading && !c.modelBusy }
    var steps = [
      until("scan", function () { return !!c.scan && idle() }), log("scanned"), shot("cleanup"),
      function () { c.range = "All time"; selectAll(); c.makeReview() }, until("review", function () { return !!c.review }), bottom, 300, log("reviewed"), shot("review"),
      function () { c.confirmApply() }, until("alert", function () { return Theme.alert.visible }), shot("alert"),
      function () { Theme.alert.accept() }, until("apply", function () { return idle() && c.trash.length > 0 }), bottom, 300, log("applied"), shot("trash"),
      function () { c.restoreBatch(c.trash[0]) }, until("restore", function () { return idle() && c.trash.length === 0 }), bottom, 300, log("restored"), shot("restored"),
      function () { selectAll(); c.makeReview() }, until("review 2", function () { return !!c.review }),
      function () { c.apply() }, until("apply 2", function () { return idle() && c.trash.length > 0 }),
      function () { c.purgeBatch(c.trash[0]) }, until("purge alert", function () { return Theme.alert.visible }), shot("purge-alert"),
      function () { Theme.alert.accept() }, until("purge", function () { return idle() && c.trash.length === 0 }), bottom, 300, log("purged"), shot("purged"),
      function () { tab = "Backup" }, until("checklist", function () { return b.loaded && b.rows.length > 0 }), 500, log("backup"), shot("backup"),
      function () { b.setChecked(row("codex"), true) }, 300,
      function () { b.useFolder(App.arg("backupTo", "")) }, until("configure", function () { return b.folder !== "" && b.checkedSets.length === 1 }), 500, log("configured"), shot("backup-folder"),
      function () { b.backUpNow() }, until("backup", function () { return !b.running && b.history.length > 0 }, 60000), 500, log("backed-up"), shot("backup-done"),
      function () { var h = b.history[0]; if (h) b.restoreRequest = { snapshot: h.snapshot, set: h.set, title: h.title } }, 800, shot("restore-sheet"),
      function () { if (b.restoreRequest) b.restore(b.restoreRequest, null, App.arg("restoreTo", "")) }, until("restore", function () { return !b.restoring }, 60000), 500, log("restore"), shot("backup-restored"),
      // restore of chosen items: the first group of the snapshot only, into its own folder
      function () { var h = b.history[0], g = h && h.snapshot.groups
                    if (g && g.length) b.restore({ snapshot: h.snapshot, set: h.set }, [g[0].id], App.arg("restoreTo", "") + "/chosen")
                    else Harness.log("LIVE no groups on the snapshot") },
      until("restore chosen", function () { return !b.restoring }, 60000), log("restore-chosen"),
      // shared settings, one change each, read back from the helper's checklist
      function () { b.setShared("schedule", "daily") }, until("schedule", function () { return b.shared.schedule === "daily" }),
      function () { b.setShared("keep", 5) }, until("keep", function () { return b.shared.keep === 5 }),
      function () { b.setShared("promptsOnly", true) }, until("prompts on", function () { return b.shared.promptsOnly === true }), 300, log("shared-on"), shot("backup-shared"),
      function () { b.setShared("promptsOnly", false) }, until("prompts off", function () { return b.shared.promptsOnly === false }),
      function () { b.setShared("includeLogins", true) }, until("logins on", function () { return b.shared.includeLogins === true }), log("logins-on"),
      function () { b.setShared("includeLogins", false) }, until("logins off", function () { return b.shared.includeLogins === false }),
      // a second tool with large files, then Cancel in the middle of the run
      function () { b.setChecked(row("claude"), true) }, until("claude on", function () { return b.checkedSets.length === 2 }), log("claude-checked"),
      function () { b.backUpNow() }, until("progress", function () { return !!b.running && b.running.index === b.running.count - 1 && b.running.bytes > 0 }, 60000), log("running"), shot("backup-running"),
      function () { cancelAt = Date.now(); b.cancelBackup() }, until("cancel", function () { return !b.running }),
      function () { Harness.log("LIVE cancel took " + (Date.now() - cancelAt) + " ms") }, 1000, log("cancelled"), shot("backup-cancelled"),
      // the next run of the same sets removes the cancelled run's .in-progress folder (BackupEngine.cleanup)
      function () { b.backUpNow() }, 1000, until("second run", function () { return !b.running }, 180000), 500, log("after-second-run"),
      // Cancel a restore of the large Claude snapshot (only quitting cancels a restore in the app)
      function () { var h = b.history.filter(function (x) { return x.set.sourceID === "claude" })[0]
                    if (h) b.restore({ snapshot: h.snapshot, set: h.set }, null, App.arg("restoreTo", "") + "/big")
                    else Harness.log("LIVE no claude snapshot") }, 300,
      function () { Harness.log("LIVE restore running=" + b.restoring + " bar=" + JSON.stringify(page.barError)); cancelAt = Date.now(); Helper.cancelCall(b.restoreCall) },
      until("restore cancel", function () { return !b.restoring }),
      function () { Harness.log("LIVE restore cancel took " + (Date.now() - cancelAt) + " ms") }, 500,
      function () { b.setChecked(row("claude"), false) }, until("claude off", function () { return b.checkedSets.length === 1 }), 500, log("claude-unchecked"), shot("backup-unchecked")
    ]
    // Interrupted work first (seed-recovery.sh): the helper blocks cleanup while it is pending.
    // Finish pending work, then Keep current and Restore backup on the two conflicts.
    var recoverySteps = [
      function () { tab = "Backup"; b.load() }, until("recovery rows", function () { return b.recovery.length > 0 }), 500,
      function () { Harness.log("LIVE recovery " + JSON.stringify(b.recovery.map(function (o) { return o.phase }))) }, shot("recovery"),
      function () { page.recover() }, 1500, function () { if (Theme.alert.visible) Theme.alert.accept() },
      until("finish", function () { return b.recovery.every(function (o) { return o.phase === "conflicted" }) }), 500,
      function () { Harness.log("LIVE after finish " + JSON.stringify(b.recovery.map(function (o) { return o.id.slice(0, 8) + ":" + o.phase }))) },
      function () { var o = b.recovery.filter(function (x) { return x.id.indexOf("22222222") === 0 })[0]; if (o) page.resolve(o, "preserveCurrent") }, 1500,
      function () { if (Theme.alert.visible) Theme.alert.accept() },
      until("keep", function () { return !b.recovery.some(function (x) { return x.id.indexOf("22222222") === 0 }) }),
      function () { var o = b.recovery.filter(function (x) { return x.id.indexOf("33333333") === 0 })[0]; if (o) page.resolve(o, "restoreBackup") }, 1500,
      function () { if (Theme.alert.visible) Theme.alert.accept() },
      until("restore backup", function () { return b.recovery.length === 0 }), 500,
      // Keep current needs the current credential to match a registered account; a refused one is cleared here
      // with Restore backup so the rest of the run is not blocked by pending recovery.
      function () { b.recovery.forEach(function (o) { page.resolve(o, "restoreBackup") }) },
      until("recovery cleared", function () { return b.recovery.length === 0 }), 500,
      function () { Harness.log("LIVE recovery left " + b.recovery.length + " bar=" + JSON.stringify(page.barError)) }, shot("recovery-done"),
      function () { page.barError = ""; tab = "Cleanup"; cleanupTab.reload() }
    ]
    steps = recoverySteps.concat(steps)
    // A small sequencer of its own: the Driver knows only numbers and functions, these steps also wait on conditions.
    var i = 0, deadline = 0
    var next = function () {
      while (i < steps.length) {
        var s = steps[i]
        if (typeof s === "number") { i++; liveTimer.interval = s; liveTimer.start(); return }
        if (typeof s === "object") {
          if (!deadline) deadline = Date.now() + s.ms
          var ok = false
          try { ok = s.cond() } catch (e) { Harness.log("LIVE wait error " + s.name + " " + e) }
          if (!ok && Date.now() < deadline) { liveTimer.interval = 200; liveTimer.start(); return }
          if (!ok) Harness.log("LIVE timeout waiting for " + s.name)
          deadline = 0; i++
          continue
        }
        i++
        try { s() } catch (e) { Harness.log("LIVE step error " + e) }
      }
      Harness.log("LIVE done")
      Harness.quit(0)
    }
    return [function () { page.liveTick = next; next() }, 600000]
  }
  property var liveTick: null
  Timer { id: liveTimer; onTriggered: page.liveTick() }

  function focusName(w) { var a = w.activeFocusItem; return a ? String(a).split("(")[0] + " '" + (a.text || a.label || a.objectName || "") + "' activeFocus=" + a.activeFocus + " keyboardMode=" + App.keyboardMode : "none" }

  function captureSteps(d) {
    var c = cleanupTab, b = backupTab, w = d.win, v = demoState
    var shot = function (name) { return function () { d.shot(w, "maint" + (v ? "-" + v : "") + "-" + name) } }
    if (v === "live") return liveSteps(d, shot)
    // --maint parity: the real helper on a seed-synthetic root, both tabs as the Mac references show them
    if (v === "parity") return [5000, shot("cleanup"), function () { tab = "Backup" }, 3000, shot("backup")]
    if (v !== "") return [400, shot("main"), function () { scrollArea.scrollTo(10000) }, 300, shot("bottom")]
    return [
      shot("cleanup"),
      function () { scrollArea.scrollTo(10000) }, 300, shot("cleanup-bottom"),
      function () { scrollArea.scrollTo(0); c.toggleExpanded("conversations"); c.toggleExpanded("conversations/" + Demo.P1); c.toggleExpanded("logs") }, 400,
      function () { scrollArea.scrollTo(200) }, 300, shot("cleanup-open"),
      function () { c.toggleExpanded("conversations"); c.toggleExpanded("conversations/" + Demo.P1); c.toggleExpanded("logs"); c.makeReview(); c.showReviewItems = true }, 300,
      function () { scrollArea.scrollTo(10000) }, 300, shot("cleanup-review"),
      function () { c.confirmApply() }, 300, shot("cleanup-alert"),
      function () { Theme.alert.close(); c.review = null; c.purgeBatch(c.trash[0]) }, 300, shot("cleanup-purge"),
      function () { Theme.alert.close(); scrollArea.scrollTo(0); picker.clicked() }, 400, shot("cleanup-picker"),
      function () { picker.open = false; d.clickItem("cleanup-time-range") }, 400, shot("cleanup-range"),
      function () { Theme.menu.close(); c.range = "Custom dates" }, 300, shot("cleanup-custom"),
      function () { d.clickItem("date-From") }, 300, shot("cleanup-calendar"),
      function () { d.clickItem("date-From") }, 100,
      function () { c.range = "Last hour" }, 300, shot("cleanup-empty"),
      function () { c.range = "Older than 30 days"; c.titleQuery = "forecast" }, 300, shot("cleanup-filter"),
      function () { c.titleQuery = ""; d.clickItem("cleanup-projects") }, 400, shot("cleanup-projects"),
      function () { Theme.menu.close(); scrollArea.scrollTo(0) }, 200,
      // keyboard: Tab from Reload lands on the project menu (focus tint); the calendar by keys
      function () { var r = d.find(w.contentItem, "cleanup-reload"); if (r) r.forceActiveFocus(); Harness.key(w, Qt.Key_Tab) }, 300,
      function () { Harness.log("FOCUS " + focusName(w)) }, shot("focus-cleanup"),
      function () { c.range = "Custom dates" }, 200,
      function () { var r = d.find(w.contentItem, "date-From"); if (r) r.forceActiveFocus(); Harness.key(w, Qt.Key_Space, 0, " ") }, 300,
      function () { Harness.key(w, Qt.Key_Right); Harness.key(w, Qt.Key_Right); Harness.key(w, Qt.Key_Down) }, 300, shot("focus-calendar"),
      function () { Harness.key(w, Qt.Key_Escape); c.range = "Older than 30 days" }, 300,
      function () { c.titleQuery = ""; page.barError = "Waiting for Backup Drive. Connect the destination and try again." }, 300, shot("error"),
      function () { page.barError = ""; page.showBackupTab() }, 500, shot("backup"),
      function () { scrollArea.scrollTo(10000) }, 300, shot("backup-bottom"),
      function () { scrollArea.scrollTo(0); b.running = { setID: b.sets[1].id, index: 1, count: 2, files: 1284, bytes: 912000000 } }, 300, shot("backup-running"),
      function () { b.running = null; b.restoreRequest = { snapshot: b.history[0].snapshot, set: b.history[0].set, title: b.history[0].set.name } }, 400, shot("backup-sheet"),
      function () { sheet.whole = false; var ch = {}; ch[sheet.groups[1].id] = true; ch[sheet.groups[5].id] = true; sheet.chosen = ch; ++sheet.rev }, 300, shot("backup-sheet-items"),
      function () { sheet.whole = true; sheet.inPlace = false; sheet.folder = "/home/ada/Restored" }, 300, shot("backup-sheet-folder"),
      // keyboard in the sheet: Tab reaches its first control; Shift-Tab from there wraps to its last (Restore)
      function () { sheet.inPlace = true; Harness.key(w, Qt.Key_Tab) }, 300,
      function () { Harness.log("FOCUS " + focusName(w)) }, shot("focus-sheet"),
      function () { Harness.key(w, Qt.Key_Backtab, Qt.ShiftModifier) }, 300,
      function () { Harness.log("FOCUS " + focusName(w)) }, shot("focus-sheet-wrap"),
      function () { Harness.key(w, Qt.Key_Escape) }, 400,
      function () { Harness.log("FOCUS after close " + focusName(w)) },
      // the real folder dialog (Qt Quick Dialogs)
      function () { b.chooseFolder() }, 1200, shot("backup-folder-dialog"),
      function () { if (folderDialog.item) folderDialog.item.close() }, 300
    ]
  }
}
