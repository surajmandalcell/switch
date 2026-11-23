import QtQuick
import QtQuick.Effects
import QtQuick.Window
import QtCore
import "ChatMarkdown.js" as MD
import "HistoryDemo.js" as Demo

// History page (specs/port/history.md): the thread list card (300) and the detail card, 16 apart. Reads
// history.list and history.detail from the helper (demo data with --demo) and keeps the Mac app's saved state
// (selection, both searches, the role filter, reading places, block toggles, the list offset).
Item {
  id: page
  property alias header: header
  property alias threadList: threadList
  property alias messageList: messageList
  property alias threadSearch: threadSearch
  property alias messageSearch: messageSearch
  property alias titleSel: titleSel
  property alias msgModel: msgModel
  property alias copyAll: copyAll
  property alias filterButton: filterButton
  property alias filterPanel: filterPanel
  readonly property bool demo: Helper.status === "demo"

  // thread list
  property var threads: []
  property var threadIndex: ({})
  property int total: 0
  property int matching: 0
  property int skipped: 0
  property int unreadable: 0
  property string listError: ""
  property bool listLoading: true
  property string threadQuery: ""
  property int listGen: 0
  property bool threadsRestored: false

  // selected conversation
  property string selectedID: ""
  property var detail: null              // { thread, matching, nextOffset }
  property var messages: []              // loaded messages, each with its parsed `pres`
  property string messageQuery: ""
  property int filterMask: 15
  property bool chatLoading: false
  property bool pageLoading: false
  property bool searching: false
  property int detailGen: 0
  property string loadedKey: ""
  property var toggled: ({})             // message id -> block ids moved away from their default
  property int toggledRev: 0
  property var restoreTarget: null       // { id, offset }
  property bool pinned: false
  property var faded: ({})
  property string lastCopied: ""         // test hook: the last text sent to the clipboard
  property bool selecting: false
  property int delegatesMade: 0          // test hook: thread rows and message rows created so far

  property bool openFailed: false        // the selected chat could not open: the header shows nothing for it
  readonly property var summary: detail ? detail.thread : (openFailed ? null : (threadIndex[selectedID] || null))
  readonly property string trimmedQuery: messageQuery.trim()

  // ---- saved state (history.md 8.3) -------------------------------------------------------------------
  Settings {
    id: store
    location: App.arg("root") !== "" ? "file://" + App.arg("root") + "/gui/history.ini"
                                     : StandardPaths.writableLocation(StandardPaths.AppConfigLocation) + "/history.ini"
  }
  function load(k, d) { if (demo) return d; var v = store.value(k, d); return v === undefined || v === null ? d : v }
  function save(k, v) { if (!demo) store.setValue(k, v) }
  function loadMap(k) { try { return JSON.parse(load(k, "{}")) || {} } catch (e) { return {} } }

  function savedMessageQuery(id) {
    try { var s = JSON.parse(load("chat.messageQuery", "[]")); return s.length === 2 && s[0] === id ? s[1] : "" } catch (e) { return "" }
  }
  function savedAnchor(id) {
    var s = loadMap("chat.anchor")[id]
    if (!s) return null
    var parts = s.split("\n"), off = Number(parts[1])
    return parts.length === 2 && !isNaN(off) ? { id: parts[0], offset: off } : null
  }
  function storeAnchor(a) {
    if (!selectedID) return
    var all = loadMap("chat.anchor")
    var keys = Object.keys(all)
    // shortcut: arbitrary eviction past 60 conversations as the Mac app does; a recency list if reopening old ones matters
    if (keys.length >= 60 && all[selectedID] === undefined) delete all[keys[0]]
    all[selectedID] = a.id + "\n" + a.offset
    save("chat.anchor", JSON.stringify(all))
  }
  function normalizedMask(v) { var m = Number(v) & 15; return m === 0 ? 15 : m }

  // ---- helper calls (demo answers a turn later, like a real reply) ---------------------------------------
  property var demoQueue: []
  Timer { id: demoTick; interval: 1; onTriggered: { var q = page.demoQueue; page.demoQueue = []; for (var k = 0; k < q.length; ++k) q[k]() } }
  function hcall(method, params, cb) {
    if (!demo) { Helper.call(method, params, cb); return }
    var r = method === "history.list" ? Demo.list(params) : Demo.detail(params)
    demoQueue.push(function () { r ? cb(r, null) : cb(null, { code: -32003, message: "No conversation has that ID." }) })
    demoTick.restart()
  }

  // ---- formats (history.md 7.4) ----------------------------------------------------------------------------
  function num(n) { return Number(n).toLocaleString(Qt.locale(), "f", 0) }
  // The time follows the locale's short format, so its 12 or 24 hour clock. Qt has no date skeletons, so the
  // Mac templates (EEEMMMd, MMMd, MMMdyyyy) are cut from the locale's long date: its order and separators stay.
  function fmtTime(d) { return d.toLocaleTimeString(Qt.locale(), Locale.ShortFormat) }
  function datePattern(weekday, year) {
    var f = Qt.locale().dateFormat(Locale.LongFormat)
    f = weekday ? f.replace("dddd", "ddd") : f.replace(/d{3,4}[,\s]*|[,\s]*d{3,4}/, "")
    if (!year) f = f.replace(/y+年|[,.\s]*y+/, "")
    return f.replace("MMMM", "MMM").trim()
  }
  // shortcut: the joiner is " at " in English and ", " elsewhere, upgrade to ICU's per-language word ("um", "à") when the app is translated
  readonly property string atWord: Qt.locale().name.indexOf("en") === 0 ? " at " : ", "
  function fmtDate(d, weekday, year) { return d.toLocaleDateString(Qt.locale(), datePattern(weekday, year)) }
  function sameDay(a, b) { return a.getFullYear() === b.getFullYear() && a.getMonth() === b.getMonth() && a.getDate() === b.getDate() }
  function dayTitle(d) {
    var now = new Date(), y = new Date(now.getFullYear(), now.getMonth(), now.getDate() - 1)
    if (sameDay(d, now)) return "Today"
    if (sameDay(d, y)) return "Yesterday"
    var cur = d.getFullYear() === now.getFullYear()
    return fmtDate(d, cur, !cur)
  }
  function msgDate(iso) {
    if (!iso) return ""
    var d = new Date(iso)
    return fmtDate(d, false, d.getFullYear() !== new Date().getFullYear()) + atWord + fmtTime(d)
  }
  readonly property var appLabels: ({ codex: "Codex", cli: "Codex CLI", exec: "Codex exec", app: "Codex app", chrome: "Codex Chrome",
                                      subagent: "Subagent", vscode: "VS Code", claude: "Claude Code" })
  function context(t) {
    var parts = [appLabels[t.appSource] || "Codex"]
    if (t.workingDirectory) { var p = t.workingDirectory.replace(/\/+$/, "").split(/[\\/]/).pop(); if (p) parts.push(p) }
    if (t.model) parts.push(t.model)
    var d = new Date(t.updatedAt)
    parts.push(fmtDate(d, false, false) + atWord + fmtTime(d))
    if (t.archived) parts.push("Archived")
    return parts.join(" · ")
  }
  readonly property string countText: threadQuery === "" && appFilter.length === 0 ? num(total) + " conversations"
                                                                                  : num(matching) + " of " + num(total) + " conversations"
  readonly property string warningText: {
    var parts = []
    if (skipped > 0) parts.push(skipped + " transcript file" + (skipped === 1 ? " was" : "s were") + " skipped")
    if (unreadable > 0) parts.push(unreadable + " oversized or malformed record" + (unreadable === 1 ? " was" : "s were") + " skipped")
    return parts.join("; ") + "."
  }

  // ---- clipboard: plain text, never moves focus ----------------------------------------------------------------
  TextEdit { id: clip; visible: false; textFormat: TextEdit.PlainText }
  function copyText(t) { lastCopied = t; clip.text = t; clip.selectAll(); clip.copy(); clip.text = "" }

  // ---- right-click copy menus: each copy shows the "Copied" note at the bottom --------------------------------
  property bool copiedNote: false
  Timer { id: copiedNoteTimer; interval: 1200; onTriggered: page.copiedNote = false }
  function copyMenu(anchor, items) {
    Theme.menu.open(anchor, items.map(function (i) { return i[0] }), -1, function (k) {
      copyText(items[k][1]); copiedNote = true; copiedNoteTimer.restart()
    })
  }
  function threadMenu(anchor, t) {
    var items = [["Copy Title", t.title || ""]]
    if (t.workingDirectory) items.push(["Copy Path", t.workingDirectory])
    items.push(["Copy Thread ID", t.threadID || t.id])
    if (t.model) items.push(["Copy Model", t.model])
    copyMenu(anchor, items)
  }
  function messageMenu(anchor, m) {
    var items = [["Copy Message", m.text || ""]]
    if (m.model) items.push(["Copy Model", m.model])
    if (m.timestamp) items.push(["Copy Date", msgDate(m.timestamp)])
    copyMenu(anchor, items)
  }

  // ---- app filter (Mac HistoryThreadFilter): the apps whose conversations show; empty shows all -------------------
  readonly property var allSources: ["codex", "cli", "exec", "app", "chrome", "subagent", "vscode", "claude"]
  property var appFilter: []
  property var appCounts: ({})           // matching conversations per app, before the filter and the limit
  function setAppFilter(next) {
    appFilter = next.slice().sort()
    save("history.appFilter", JSON.stringify(appFilter))
    listDebounce.stop()
    refreshList()
  }
  // Every app present checked again means All (empty); unchecking the last app keeps the selection.
  function toggleApps(sources) {
    var present = allSources.filter(function (s) { return appCounts[s] !== undefined })
    var next = (appFilter.length ? appFilter : present).slice()
    var all = sources.every(function (s) { return next.indexOf(s) >= 0 })
    if (all) next = next.filter(function (s) { return sources.indexOf(s) < 0 })
    else sources.forEach(function (s) { if (next.indexOf(s) < 0) next.push(s) })
    if (next.length === 0) return
    setAppFilter(present.every(function (s) { return next.indexOf(s) >= 0 }) ? [] : next)
  }
  function listKey() { return threadQuery + "\u0001" + appFilter.join(",") }

  // ---- thread list ----------------------------------------------------------------------------------------------
  ListModel { id: threadModel }
  Timer { id: listDebounce; interval: 120; onTriggered: page.refreshList() }
  // The helper has no change topic for the library: a rescan every 30 s sends the last libraryRevision back and
  // gets `unchanged` (no rows) when nothing moved, so the poll is cheap.
  Timer { id: rescan; interval: 30000; repeat: true; running: page.visible && !page.demo; onTriggered: page.refreshList() }
  property var listRev: undefined        // libraryRevision of the last full reply for listRevQuery
  property string listRevQuery: ""
  Connections { target: page.demo ? null : Helper; function onStatusChanged() { page.listRev = undefined } }  // a restart resets it

  onThreadQueryChanged: {
    save("chat.threadQuery", threadQuery)
    // an empty query applies at once; typing waits 120 ms and drops stale results
    if (threadQuery === "") { listDebounce.stop(); refreshList() } else listDebounce.restart()
  }

  function refreshList() {
    var gen = ++listGen, q = threadQuery, key = listKey(), apps = appFilter, params = { query: q, limit: 1000 }
    if (apps.length) params.apps = apps
    if (listRev !== undefined && listRevQuery === key && listSig !== "") params.libraryRevision = listRev
    hcall("history.list", params, function (r, err) {
      if (gen !== listGen || key !== listKey()) return
      listLoading = false
      if (err) { listError = "The chat library could not refresh. " + (err.message || ""); return }
      listError = ""
      if (r.unchanged) return
      listRev = r.libraryRevision
      listRevQuery = key
      applyList(r, apps)
    })
  }

  function signature(r) {
    var s = [r.total, r.matching, r.skippedFiles, r.unreadableRecords, r.threads.length]
    for (var k = 0; k < Math.min(r.threads.length, 50); ++k) s.push(r.threads[k].id, r.threads[k].updatedAt, r.threads[k].messageCount)
    return s.join("|")
  }
  property string listSig: ""
  property string listSigQuery: "\u0000"
  function applyList(r, apps) {
    if (r.appCounts) appCounts = r.appCounts
    else {
      // a helper without app counts: count the loaded rows and filter them here
      var c = {}
      for (var n = 0; n < r.threads.length; ++n) { var s = r.threads[n].appSource || "codex"; c[s] = (c[s] || 0) + 1 }
      appCounts = c
      if (apps && apps.length) {
        var kept = r.threads.filter(function (t) { return apps.indexOf(t.appSource || "codex") >= 0 })
        r = { total: r.total, matching: kept.length, skippedFiles: r.skippedFiles, unreadableRecords: r.unreadableRecords, threads: kept }
      }
    }
    var sig = signature(r), key = listKey()
    if (sig === listSig && listSigQuery === key) return
    var queryChanged = listSigQuery !== key
    listSig = sig
    listSigQuery = key
    total = r.total; matching = r.matching; skipped = r.skippedFiles; unreadable = r.unreadableRecords
    var list = r.threads.slice().sort(function (a, b) {
      var d = new Date(b.updatedAt) - new Date(a.updatedAt)
      return d !== 0 ? d : (a.id < b.id ? -1 : a.id > b.id ? 1 : 0)
    })
    var idx = {}, rows = []
    for (var k = 0; k < list.length; ++k) { idx[list[k].id] = list[k]; rows.push({ tid: list[k].id, dayTitle: dayTitle(new Date(list[k].updatedAt)) }) }
    var keepY = threadList.view.contentY
    threadIndex = idx
    threads = list
    threadModel.clear()
    threadModel.append(rows)
    if (!threadsRestored) {
      threadsRestored = true
      Qt.callLater(function () { threadList.scrollTo(Number(load("chat.threadsScroll", 0))) })
    } else if (queryChanged) threadList.scrollTo(-1e9)
    else threadList.scrollTo(keepY)
    selectVisible()
  }

  function selectVisible() {
    // the saved or open thread stays open while listed, or while a search hides it
    var hidden = threadQuery.trim() !== "" || appFilter.length > 0
    if (selectedID !== "" && (threadIndex[selectedID] || hidden) && !detail && !chatLoading) { selectChat(selectedID); return }
    if (selectedID !== "" && threadIndex[selectedID]) {
      var t = threadIndex[selectedID]
      // the open thread grew: reload it from the start with the current search and filter
      if (detail && (t.messageCount !== detail.thread.messageCount || t.fileByteCount !== detail.thread.fileByteCount)) loadDetail(false)
      return
    }
    if (selectedID !== "" && hidden) return
    if (threads.length) selectChat(threads[0].id)
  }

  // ---- selected conversation -------------------------------------------------------------------------------------
  ListModel { id: msgModel }
  Timer { id: searchDebounce; interval: 120; onTriggered: page.runMessageSearch() }
  Timer { id: anchorTimer; interval: 250; onTriggered: page.saveAnchor() }
  Timer { id: threadsScrollTimer; interval: 500; onTriggered: page.save("chat.threadsScroll", threadList.view.contentY) }

  function searchKey() { return selectedID + "|" + messageQuery + "|" + filterMask }
  onMessageQueryChanged: if (!selecting) { save("chat.messageQuery", JSON.stringify([selectedID, messageQuery])); restoreTarget = null; queueSearch() }
  onFilterMaskChanged: if (!selecting) { save("chat.messageFilterMask", filterMask); restoreTarget = null; queueSearch() }
  function queueSearch() { if (!selectedID) return; searching = true; searchDebounce.restart() }
  function runMessageSearch() {
    if (searchKey() === loadedKey) { searching = false; return }
    loadDetail(false)
  }
  function toggleFilter(bit) { var next = filterMask ^ bit; if (next !== 0) filterMask = next }

  function selectChat(id) {
    if (id === selectedID && detail) return
    if (selectedID && detail) saveAnchor()
    selecting = true
    selectedID = id
    openFailed = false
    save("chat.selectedID", id)
    detail = null
    messages = []
    msgModel.clear()
    messageQuery = savedMessageQuery(id)
    messageSearch.text = messageQuery
    selecting = false
    searchDebounce.stop()
    searching = false
    var bs = loadMap("chat.blockStates")[id] || {}
    toggled = bs
    toggledRev++
    restoreTarget = savedAnchor(id)
    pinned = false
    loadDetail(false)
  }


  function loadDetail(append) {
    if (selectedID === "") return
    if (append && (pageLoading || !detail || detail.nextOffset === null || detail.nextOffset === undefined)) return
    var gen = ++detailGen, id = selectedID, q = messageQuery, mask = filterMask
    var offset = append ? detail.nextOffset : 0
    if (append) pageLoading = true; else { chatLoading = true; loadedKey = searchKey() }
    hcall("history.detail", { id: id, offset: offset, limit: 100, query: q, roles: mask }, function (r, err) {
      if (gen !== detailGen || id !== selectedID) return
      pageLoading = false
      chatLoading = false
      searching = false
      if (err) {
        listError = "The selected chat could not open. " + (err.message || "")
        if (!append) {
          detail = null; msgModel.clear(); openFailed = true
          // the transcript is gone (-32003): read the list again now, so its row goes away too
          if (err.code === -32003) { listSig = ""; refreshList() }
        }
        return
      }
      var got = r.messages
      for (var k = 0; k < got.length; ++k) got[k].pres = MD.parse(got[k].role, got[k].text)
      var start = append ? messages.length : 0
      messages = append ? messages.concat(got) : got
      detail = { thread: r.thread, matching: r.matching, nextOffset: r.nextOffset === undefined ? null : r.nextOffset }
      rebuildRows(append, start)
    })
  }

  function loadMore() { loadDetail(true) }

  function rebuildRows(append, start) {
    if (append) { while (msgModel.count && msgModel.get(msgModel.count - 1).kind !== "message") msgModel.remove(msgModel.count - 1) }
    else msgModel.clear()
    var rows = []
    if (messages.length === 0) rows.push({ kind: "empty", mid: "", idx: -1, sep: false, fade: false })
    for (var k = start; k < messages.length; ++k)
      rows.push({ kind: "message", mid: messages[k].id, idx: k, sep: k === 0 || messages[k - 1].role !== messages[k].role, fade: append })
    if (detail.nextOffset !== null) rows.push({ kind: "loadMore", mid: "", idx: -1, sep: false, fade: false })
    rows.push({ kind: "bottom", mid: "", idx: -1, sep: false, fade: false })
    msgModel.append(rows)
    if (!append) {
      messageList.view.positionViewAtBeginning()
      listFade.restart()
    }
    Qt.callLater(applyRestore)
  }
  function fadeOnce(id) { if (faded[id] || !Theme.motion) return false; faded[id] = true; return true }

  function toggleBlock(mid, block) {
    var cur = (toggled[mid] || []).slice()
    var at = cur.indexOf(block)
    if (at >= 0) cur.splice(at, 1); else cur.push(block)
    cur.sort(function (a, b) { return a - b })
    toggled[mid] = cur
    toggledRev++
    var all = loadMap("chat.blockStates")
    all[selectedID] = toggled
    save("chat.blockStates", JSON.stringify(all))
  }

  // Reading place (history.md 4.3): the first message row at the view top, or the last one at the very end.
  function saveAnchor() {
    if (!selectedID || !messages.length || restoreTarget) return
    var v = messageList.view, top = v.contentY
    var atEnd = top >= messageList.maxY - 0.5 && detail && detail.nextOffset === null
    var row = atEnd ? messages.length - 1 : v.indexAt(1, top + 0.5)
    if (row < 0) return
    while (row < msgModel.count && msgModel.get(row).kind !== "message") row++
    if (row >= msgModel.count) return
    var it = v.itemAtIndex(row)
    if (!it) return
    storeAnchor({ id: msgModel.get(row).mid, offset: Math.round((top - it.y) * 10) / 10 })
  }

  function applyRestore() {
    var a = restoreTarget
    if (!a || !detail) return
    var idx = -1
    for (var k = 0; k < messages.length; ++k) if (messages[k].id === a.id) { idx = k; break }
    if (idx < 0) {
      if (detail.nextOffset !== null) loadMore()
      else restoreTarget = null
      return
    }
    var v = messageList.view
    v.positionViewAtIndex(idx, ListView.Beginning)
    var it = v.itemAtIndex(idx)
    if (it) messageList.scrollTo(it.y + a.offset)
    restoreTarget = null
    pinned = idx === messages.length - 1 && detail.nextOffset === null
    if (pinned) messageList.scrollTo(1e9)
  }

  function copyVisible() { copyText(MD.exportText(messages)) }

  // Tab inside the message list walks the controls on screen (copy buttons, section folds, "Show all" links)
  // from top to bottom. The default chain follows delegate creation order, which is not the visual order.
  // A focused control eats Tab in its own handler, so window shortcuts take Tab while focus is in the list
  // (the ListView is a focus scope, so its activeFocus covers its rows).
  Shortcut { sequences: ["Tab"]; enabled: page.visible && messageList.view.activeFocus; onActivated: page.tabInMessages(true) }
  Shortcut { sequences: ["Backtab", "Shift+Tab"]; enabled: page.visible && messageList.view.activeFocus; onActivated: page.tabInMessages(false) }
  function tabInMessages(fwd) {
    var v = messageList.view, found = []
    function walk(it) {
      for (var k = 0; k < it.children.length; ++k) {
        var c = it.children[k]
        if (!c.visible) continue
        if (c.activeFocusOnTab && c.enabled) found.push(c)
        walk(c)
      }
    }
    walk(v.contentItem)
    var items = []
    for (var k = 0; k < found.length; ++k) {
      var p = found[k].mapToItem(v, 0, 0)
      if (p.y + found[k].height > 0 && p.y < v.height) items.push({ it: found[k], y: p.y, x: p.x })
    }
    items.sort(function (a, b) { return Math.abs(a.y - b.y) > 1 ? a.y - b.y : a.x - b.x })
    var cur = -1
    for (k = 0; k < items.length; ++k) if (items[k].it.activeFocus) { cur = k; break }
    var next = cur < 0 ? (fwd ? 0 : -1) : cur + (fwd ? 1 : -1)
    if (next >= 0 && next < items.length) items[next].it.forceActiveFocus(Qt.TabFocusReason)
    else if (!fwd && cur >= 0) v.forceActiveFocus(Qt.BacktabFocusReason)
    else if (fwd) threadSearch.input.forceActiveFocus(Qt.TabFocusReason)   // past the last control: wrap to the page start
    else copyAll.forceActiveFocus(Qt.BacktabFocusReason)  // before the list: the copy button
  }

  // ---- lifecycle ---------------------------------------------------------------------------------------------------
  property bool appeared: false
  onVisibleChanged: {
    if (visible && !appeared) { appeared = true; appear.restart() }
    if (!visible) { save("chat.threadsScroll", threadList.view.contentY); saveAnchor() }
  }
  Component.onCompleted: {
    filterMask = normalizedMask(load("chat.messageFilterMask", 15))
    selectedID = load("chat.selectedID", "")
    try { appFilter = (JSON.parse(load("history.appFilter", "[]")) || []).filter(function (s) { return allSources.indexOf(s) >= 0 }).sort() } catch (e) {}
    threadSearch.text = load("chat.threadQuery", "")
    if (threadQuery === "") refreshList()
    if (visible) { appeared = true; appear.restart() }
  }
  Component.onDestruction: if (!demo) { save("chat.threadsScroll", threadList.view.contentY); saveAnchor() }
  ParallelAnimation {
    id: appear
    NumberAnimation { target: listCard; property: "opacity"; from: 0.4; to: 1; duration: Theme.dAppear; easing.type: Easing.Bezier; easing.bezierCurve: Theme.easeOut }
    NumberAnimation { target: detailCard; property: "opacity"; from: 0.4; to: 1; duration: Theme.dAppear; easing.type: Easing.Bezier; easing.bezierCurve: Theme.easeOut }
  }

  // ---- layout ------------------------------------------------------------------------------------------------------
  PageHeader { id: header; width: parent.width }

  Card {
    id: listCard
    x: 20
    y: header.height + 12
    width: 300
    height: page.height - y - 20
    title: "History"
    divider: false
    accessory: [
      Row {
        spacing: 6
        height: 20
        ChatCopyIcon {
          visible: page.skipped > 0 || page.unreadable > 0
          anchors.verticalCenter: parent.verticalCenter
          label: "Copy history warning"
          tint: Theme.amber
          glyph: 14
          hold: 900
          tip: page.warningText
          onCopy: page.copyText(page.warningText)
        }
        ChatSpinner { visible: page.listLoading && page.threads.length === 0; size: 16; anchors.verticalCenter: parent.verticalCenter }
        Rectangle {
          visible: !(page.listLoading && page.threads.length === 0) && page.listError !== ""
          width: 6; height: 6; radius: 3; color: Theme.red
          anchors.verticalCenter: parent.verticalCenter
          Accessible.name: page.listError
          ToolTipArea { text: page.listError }
        }
        RollText {
          visible: !(page.listLoading && page.threads.length === 0)
          anchors.verticalCenter: parent.verticalCenter
          role: "secondary"
          color: Theme.secondary
          text: page.countText
          ToolTipArea { text: page.countText }
        }
        // a ghost icon button: the glyph fills and takes the accent color while a filter is on
        IconButton {
          id: filterButton
          width: 20
          height: 20
          glyph: 16
          anchors.verticalCenter: parent.verticalCenter
          icon: page.appFilter.length ? "filterCircleFill" : "filterCircle"
          tone: page.appFilter.length ? "active" : "normal"
          tip: page.appFilter.length ? "Filter conversations, " + page.appFilter.length + " on" : "Filter conversations"
          onClicked: filterPanel.visible ? filterPanel.close() : filterPanel.open(filterButton)
        }
      }
    ]

    Item {
      width: parent.width
      height: listCard.height - 44 - 1
      ChatSearchField {
        id: threadSearch
        x: 16
        width: parent.width - 32
        placeholder: "Search conversations"
        onTextChanged: page.threadQuery = text
      }
      Item {
        id: listArea
        y: threadSearch.height + 8
        width: parent.width
        height: parent.height - y

        ChatSkeletonRows { visible: page.listLoading && page.threads.length === 0; width: parent.width; count: 8; rowHeight: 44 }
        Column {
          visible: !page.listLoading && page.threads.length === 0
          anchors.centerIn: parent
          spacing: 4
          readonly property bool filtered: page.appFilter.length > 0
                                          && Object.keys(page.appCounts).some(function (s) { return page.appCounts[s] > 0 })
          Icon { anchors.horizontalCenter: parent.horizontalCenter; name: "history"; size: 15; color: Theme.secondary }
          Txt { anchors.horizontalCenter: parent.horizontalCenter
                text: parent.filtered ? "No conversations in this filter" : page.threadQuery === "" ? "No conversations yet" : "No matching conversations" }
          Txt { visible: !parent.filtered; anchors.horizontalCenter: parent.horizontalCenter; role: "secondary"; color: Theme.secondary
                text: page.threadQuery === "" ? "New Codex chats appear here." : "Try another word or thread ID." }
          Txt {
            id: resetLink
            visible: parent.filtered
            anchors.horizontalCenter: parent.horizontalCenter
            role: "secondary"
            color: Theme.link
            text: "Reset filter"
            activeFocusOnTab: visible
            Accessible.role: Accessible.Button
            Accessible.name: text
            Accessible.onPressAction: page.setAppFilter([])
            Keys.onSpacePressed: page.setAppFilter([])
            FocusFill { visible: resetLink.activeFocus && App.keyboardMode }
            MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: page.setAppFilter([]) }
          }
        }
        ChatList {
          id: threadList
          visible: page.threads.length > 0
          anchors.fill: parent
          leftInset: 10
          accessibleName: "Conversations"
          view.model: threadModel
          view.bottomMargin: 10
          view.activeFocusOnTab: true
          view.keyNavigationEnabled: false
          view.section.property: "dayTitle"
          view.section.delegate: Item {
            required property string section
            width: 280
            height: 26
            Txt { x: 6; y: 6; role: "secondary"; color: Theme.secondary; text: parent.section; Accessible.role: Accessible.Heading }
          }
          view.delegate: ChatThreadRow {
            id: tr
            required property int index
            width: 280
            thread: page.threads[index] || ({})
            time: thread.updatedAt ? page.fmtTime(new Date(thread.updatedAt)) : ""
            selected: thread.id === page.selectedID
            onActivated: { threadList.view.forceActiveFocus(); page.selectChat(thread.id) }
            onMenuRequested: page.threadMenu(tr, tr.thread)
            Component.onCompleted: page.delegatesMade++
          }
          onKeyPressed: function (e) {
            if (e.key !== Qt.Key_Up && e.key !== Qt.Key_Down) return
            e.accepted = true
            var i = -1
            for (var k = 0; k < page.threads.length; ++k) if (page.threads[k].id === page.selectedID) { i = k; break }
            i = Math.max(0, Math.min(page.threads.length - 1, i + (e.key === Qt.Key_Up ? -1 : 1)))
            threadList.view.positionViewAtIndex(i, ListView.Contain)
            page.selectChat(page.threads[i].id)
          }
        }
      }
    }
  }

  Card {
    id: detailCard
    x: listCard.x + listCard.width + 16
    y: listCard.y
    width: page.width - x - 20
    height: listCard.height
    Item {
      width: parent.width
      height: detailCard.height - 1

      Item {
        id: dhead
        width: parent.width
        height: 58
        Column {
          visible: !!page.summary
          x: 12
          width: parent.width - 24
          anchors.verticalCenter: parent.verticalCenter
          spacing: 2
          // Selectable title (Mac: one line, tail ellipsis, textSelection): the elided label at rest, the full
          // text in a read-only field once a press or Tab gives it focus, so a drag can select past the ellipsis.
          Txt {
            id: titleT
            width: parent.width
            role: "section"
            elide: Text.ElideRight
            opacity: titleSel.activeFocus ? 0 : 1
            text: page.summary ? page.summary.title : ""
            Accessible.role: Accessible.StaticText
            Accessible.name: text
            ToolTipArea { text: titleT.text }
            TextInput {
              id: titleSel
              anchors.fill: parent
              opacity: activeFocus ? 1 : 0
              readOnly: true
              selectByMouse: true
              activeFocusOnTab: true
              clip: true
              verticalAlignment: TextInput.AlignVCenter
              font: titleT.font
              color: Theme.label
              selectionColor: Theme.dark ? Theme.w(0.25) : Theme.rgba(Theme.accent, 0.3)
              selectedTextColor: Theme.label
              text: titleT.text
              onActiveFocusChanged: if (!activeFocus) { deselect(); ensureVisible(0) }
              Accessible.role: Accessible.StaticText
              Accessible.name: titleT.text
              Keys.onPressed: function (e) { if (e.matches(StandardKey.Copy) && selectedText === "") { page.copyText(text); e.accepted = true } }
            }
            MouseArea { anchors.fill: parent; acceptedButtons: Qt.RightButton
                        onClicked: page.threadMenu(titleT, page.summary) }
          }
          Item {
            width: parent.width
            height: 14
            Txt { id: ctxT; width: Math.max(0, parent.width - counts.width - 8); role: "secondary"; color: Theme.secondary; elide: Text.ElideRight
                  text: page.summary ? page.context(page.summary) : ""; ToolTipArea { text: ctxT.text }
                  MouseArea { anchors.fill: parent; acceptedButtons: Qt.RightButton; onClicked: page.threadMenu(ctxT, page.summary) } }
            Row {
              id: counts
              x: parent.width - width
              spacing: 6
              Txt { role: "secondary"; tabular: true; color: Theme.secondary; text: page.summary ? page.num(page.summary.messageCount) + " messages" : ""
                    ToolTipArea { text: parent.text } }
              Txt { visible: !!page.summary && page.summary.totalTokens !== null && page.summary.totalTokens !== undefined; role: "secondary"; color: Theme.secondary; text: "·" }
              Txt { visible: !!page.summary && page.summary.totalTokens !== null && page.summary.totalTokens !== undefined
                    role: "secondary"; tabular: true; color: Theme.secondary
                    text: visible ? MD.compact(page.summary.totalTokens) + " tokens" : ""
                    ToolTipArea { text: page.summary && page.summary.totalTokens !== null && page.summary.totalTokens !== undefined ? page.num(page.summary.totalTokens) + " recorded tokens" : "" } }
            }
          }
        }
      }
      Hair { y: 58; width: parent.width }

      Item {
        id: sbar
        y: 58 + Theme.hair
        width: parent.width
        height: 96
        // four filter toggles share the width; the copy action sits apart after a divider (Mac: (w - 36 - 57) / 456)
        readonly property real unit: Math.max(0, width - 24 - 36 - 57) / 456
        ChatSearchField {
          id: messageSearch
          x: 12
          y: 12
          width: parent.width - 24
          placeholder: "Search this chat"
          busy: page.searching || (page.chatLoading && !!page.detail)
          status: page.trimmedQuery !== "" && page.detail ? page.num(page.detail.matching) + " matches" : ""
          onTextChanged: page.messageQuery = text
        }
        Row {
          x: 12
          y: 52
          spacing: 12
          Repeater {
            id: filterButtons
            model: [{ t: "Prompts", i: "curlybraces", b: 1, w: 110 }, { t: "Responses", i: "bubbleRight", b: 2, w: 126 },
                    { t: "Tools", i: "tools", b: 4, w: 98 }, { t: "Other", i: "layers3d", b: 8, w: 122 }]
            ChatToolbarButton {
              width: modelData.w * sbar.unit
              text: modelData.t
              icon: modelData.i
              selected: (page.filterMask & modelData.b) !== 0
              Accessible.name: "Show " + modelData.t.toLowerCase()
              Accessible.description: selected ? "Shown" : "Hidden"
              onClicked: page.toggleFilter(modelData.b)
            }
          }
          Rectangle { width: 1; height: 20; color: Theme.separator; anchors.verticalCenter: parent.verticalCenter }
          // an action, not a filter: a ghost icon with no rim and no selected fill
          IconButton {
            id: copyAll
            width: 24
            height: 24
            glyph: 15
            anchors.verticalCenter: parent.verticalCenter
            icon: copied ? "check" : "copy"
            tone: copied ? "success" : "normal"
            tip: copied ? "Copied" : "Copy conversation"
            enabled: page.messages.length > 0
            property bool copied: false
            Timer { id: copiedTimer; interval: 1200; onTriggered: copyAll.copied = false }
            onClicked: { page.copyVisible(); copied = true; copiedTimer.restart() }
          }
        }
      }
      Hair { y: sbar.y + sbar.height; width: parent.width }

      Item {
        id: body
        y: sbar.y + sbar.height + Theme.hair
        width: parent.width
        height: parent.height - y

        ChatSkeletonRows { visible: !page.detail && (page.chatLoading || page.listLoading); width: parent.width; count: 5; rowHeight: 64 }
        Column {
          visible: !page.detail && !page.chatLoading && !page.listLoading
          anchors.centerIn: parent
          spacing: 4
          Icon { anchors.horizontalCenter: parent.horizontalCenter; name: "history"; size: 15; color: Theme.secondary }
          Txt { anchors.horizontalCenter: parent.horizontalCenter; text: "Select a chat" }
          Txt { anchors.horizontalCenter: parent.horizontalCenter; role: "secondary"; color: Theme.secondary
                text: "Messages open here without changing the transcript." }
        }
        ChatList {
          id: messageList
          visible: !!page.detail
          anchors.fill: parent
          accessibleName: "Messages"
          view.model: msgModel
          view.cacheBuffer: Math.max(0, messageList.height)
          view.activeFocusOnTab: true
          onUserScrolled: if (page.pinned && view.contentY < maxY - 1) page.pinned = false
          onKeyPressed: function (e) {
            var h = messageList.view.height * 0.9
            if (e.key === Qt.Key_Home) messageList.scrollTo(-1e9)
            else if (e.key === Qt.Key_End) messageList.scrollTo(1e9)
            else if (e.key === Qt.Key_Up) messageList.scrollBy(-40)
            else if (e.key === Qt.Key_Down) messageList.scrollBy(40)
            else if (e.key === Qt.Key_PageUp) messageList.scrollBy(-h)
            else if (e.key === Qt.Key_PageDown || e.key === Qt.Key_Space) messageList.scrollBy(h)
            else return
            e.accepted = true
            messageList.reveal()
          }
          view.delegate: Loader {
            id: dl
            required property string kind
            required property string mid
            required property int idx
            required property bool sep
            required property bool fade
            width: ListView.view ? ListView.view.width + messageList.gutter : 0
            sourceComponent: kind === "message" ? msgRow : (kind === "empty" ? emptyRow : (kind === "loadMore" ? moreRow : bottomRow))

            Component {
              id: msgRow
              ChatMessageRow {
                width: dl.width
                msg: page.messages[dl.idx] || ({})
                separated: dl.sep
                toggled: { page.toggledRev; return page.toggled[dl.mid] || [] }
                dateText: page.msgDate(msg.timestamp)
                fadeIn: dl.fade && page.fadeOnce(dl.mid)
                onToggle: function (id) { page.toggleBlock(dl.mid, id) }
                onCopy: function (t) { page.copyText(t) }
                onMetaMenu: function (at) { page.messageMenu(at, msg) }
                Component.onCompleted: page.delegatesMade++
              }
            }
            Component {
              id: emptyRow
              Item {
                width: dl.width - messageList.gutter
                height: 120
                Column {
                  visible: !page.searching
                  anchors.centerIn: parent
                  spacing: 6
                  Icon { anchors.horizontalCenter: parent.horizontalCenter; name: "search"; size: 15; color: Theme.secondary }
                  Txt { anchors.horizontalCenter: parent.horizontalCenter
                        text: page.trimmedQuery !== "" ? "No matching messages" : "No messages in this filter" }
                }
              }
            }
            Component {
              id: moreRow
              Item {
                width: dl.width - messageList.gutter
                height: 32
                Row {
                  anchors.centerIn: parent
                  spacing: 6
                  ChatSpinner { visible: page.pageLoading; size: 10; anchors.verticalCenter: parent.verticalCenter }
                  PushButton { text: page.pageLoading ? "Loading messages" : "Load more messages"; enabled: !page.pageLoading
                               onClicked: page.loadMore() }
                }
              }
            }
            Component { id: bottomRow; Item { width: dl.width; height: 12 } }
          }
        }
        NumberAnimation { id: listFade; target: messageList; property: "opacity"; from: 0.4; to: 1; duration: Theme.dAppear
                          easing.type: Easing.Bezier; easing.bezierCurve: Theme.easeOut }
      }
    }
  }

  Connections { target: threadList.view; function onContentYChanged() { threadsScrollTimer.restart() } }
  Connections {
    target: messageList.view
    function onContentYChanged() {
      anchorTimer.restart()
      if (page.detail && page.detail.nextOffset !== null && messageList.maxY - messageList.view.contentY < 180) page.loadMore()
    }
    function onContentHeightChanged() { if (page.pinned) messageList.scrollTo(1e9) }
    function onHeightChanged() { if (page.pinned) messageList.scrollTo(1e9) }
  }

  HistoryFilterPanel { id: filterPanel; page: page }

  // the brief "Copied" note after a menu copy: a capsule 20 above the bottom, no clicks
  Rectangle {
    id: copiedToast
    anchors.horizontalCenter: parent.horizontalCenter
    y: page.height - 20 - height
    z: 95
    width: toastRow.implicitWidth + 24
    height: 28
    radius: 14
    color: Theme.card
    border.width: Theme.hair
    border.color: Theme.separator
    enabled: false
    opacity: page.copiedNote ? 1 : 0
    visible: opacity > 0
    Behavior on opacity { NumberAnimation { duration: Theme.dState } }
    Accessible.role: Accessible.AlertMessage
    Accessible.name: page.copiedNote ? "Copied" : ""
    layer.enabled: true
    layer.effect: MultiEffect { shadowEnabled: true; shadowColor: "black"; shadowOpacity: 0.15; shadowBlur: 0.5; shadowVerticalOffset: 2 }
    Row {
      id: toastRow
      anchors.centerIn: parent
      spacing: 6
      Icon { name: "check"; size: 13; color: Theme.label; anchors.verticalCenter: parent.verticalCenter }
      Txt { text: "Copied"; anchors.verticalCenter: parent.verticalCenter }
    }
  }

  // --script states --page History: the filter, the copy menus, the Copied note, and the bottom bar
  function captureSteps(d) {
    var w = Window.window, s = [], p = page
    function shot(name) { s.push(function () { d.shot(w, "history-" + name) }) }
    function at(item, fx, fy) { return item.mapToItem(null, item.width * fx, item.height * fy) }
    s.push(function () { if (p.appFilter.length) p.setAppFilter([]); p.threadSearch.text = "" })
    s.push(1500)
    s.push(function () { Harness.log("STATE count=" + p.countText + " apps=" + JSON.stringify(p.appCounts)) })
    shot("default")
    s.push(function () { var q = at(p.filterButton, 0.5, 0.5); Harness.click(w, q.x, q.y) })
    s.push(500)
    shot("filter-open")
    // a click on the Claude Code row (real input): the popover stays open with only Claude checked
    s.push(function () {
      Harness.log("FILTER rows=" + p.filterPanel.rows.map(function (x) { return x.t || "-" }).join("|"))
      var q = at(p.filterPanel.rowItem("codex"), 0.5, 0.5); Harness.click(w, q.x, q.y)
    })
    s.push(900)
    s.push(function () { Harness.log("FILTER after codex click appFilter=" + JSON.stringify(p.appFilter) + " count=" + p.countText) })
    shot("filter-claude-open")
    s.push(function () { p.filterPanel.close() })
    s.push(500)
    shot("filtered")
    // a filter with no rows: one Codex thread searched, Claude only
    s.push(function () { p.threadSearch.text = "reference-0" })
    s.push(1200)
    shot("filter-empty")
    s.push(function () { p.threadSearch.text = ""; p.setAppFilter([]) })
    s.push(1200)
    // a row's right-click menu (the harness clicks only the left button), pick Copy Thread ID
    s.push(function () { var it = p.threadList.view.itemAtIndex(1); p.threadMenu(it, it.thread) })
    s.push(400)
    shot("thread-menu")
    s.push(function () { Theme.menu.choose(2) })
    s.push(250)
    s.push(function () { Harness.log("COPY menu=" + JSON.stringify(p.lastCopied)) })
    shot("copied-toast")
    s.push(1800)
    // the message strip's menu, then the bottom-bar copy button (real click)
    s.push(function () { p.messageList.scrollTo(-1e9) })
    s.push(400)
    s.push(function () { var it = p.messageList.view.itemAtIndex(0).item; p.messageMenu(it.children[0].children[0], it.msg) })
    s.push(400)
    shot("message-menu")
    s.push(function () { Theme.menu.close() })
    s.push(300)
    s.push(function () { var q = at(p.copyAll, 0.5, 0.5); Harness.click(w, q.x, q.y) })
    s.push(250)
    s.push(function () { Harness.log("COPY bar=" + p.lastCopied.length + " chars copied=" + p.copyAll.copied) })
    shot("bottom-bar-copied")
    s.push(1500)
    shot("bottom-bar")
    return s
  }

  HistoryShots { page: page }
}
