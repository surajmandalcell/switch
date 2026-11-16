import QtQuick
import "MaintFmt.js" as F

// The Backup tab (maintenance.md 2.4, 4): what to back up, folder and schedule with the run row, History
// with Restore, and Interrupted work. Reads backup.checklist, backup.list, backup.history; runs backup.run
// with $/progress and $/cancelRequest. Set editing has no helper method yet (rpc.md "Not built yet"): the
// controls call the planned methods and keep their value when the call fails ("fail closed", 4.1).
Column {
  id: bk
  spacing: 12
  width: parent ? parent.width : 0

  property var page: null
  property bool modelBusy: false
  property bool modelLoaded: true

  property var checklist: null
  property var sets: []
  property var statuses: ({})
  property int rev: 0
  property bool loaded: false
  property var local: ({ checked: {}, shared: {}, folder: "" })   // demo-only edits
  property var running: null          // {setID, index, count, files, bytes}
  property real runCall: -1
  property real restoreCall: -1
  property string runToken: ""
  property bool restoring: false
  property var free: null
  property var recovery: []
  property var restoreRequest: null   // {snapshot, set, title}

  readonly property var rows: checklist ? checklist.rows : []
  readonly property var shared: {
    var r = rev, s = Object.assign({ schedule: "off", keep: 10, includeLogins: false, promptsOnly: false }, checklist && checklist.shared ? checklist.shared : {})
    return Object.assign(s, local.shared)
  }
  readonly property string folder: { var r = rev; return local.folder || (checklist && checklist.folder) || "" }
  function isChecked(row) { var r = rev; return local.checked[row.sourceID] !== undefined ? local.checked[row.sourceID] : row.checked }
  readonly property var checkedRows: rows.filter(function (r) { return bk.isChecked(r) })
  readonly property var checkedSets: {
    var ids = {}
    checkedRows.forEach(function (r) { if (r.setID) ids[r.setID] = true })
    return sets.filter(function (s) { return !s.retired && ids[s.id] })
  }
  function status(setID) { var r = rev; return statuses[setID] || null }
  readonly property string waiting: {
    var r = rev
    for (var i = 0; i < checkedSets.length; ++i) { var st = status(checkedSets[i].id); if (st && st.state === "waiting") return st.waitingFor || "" }
    return ""
  }
  readonly property bool isWaiting: { var r = rev; return checkedSets.some(function (s) { var st = bk.status(s.id); return st && st.state === "waiting" }) }
  readonly property string lastError: {
    var r = rev
    for (var i = 0; i < checkedSets.length; ++i) { var st = status(checkedSets[i].id); if (st && st.lastError) return st.lastError }
    return ""
  }
  readonly property var history: {
    var r = rev, out = []
    sets.forEach(function (s) {
      var st = bk.statuses[s.id]
      if (!st) return
      var row = bk.rows.filter(function (x) { return x.sourceID === s.sourceID })[0]
      st.snapshots.forEach(function (snap) { out.push({ snapshot: snap, set: s, title: row ? row.title : s.name, provider: F.provider({ sourceID: s.sourceID }) }) })
    })
    out.sort(function (a, b) { return new Date(b.snapshot.date) - new Date(a.snapshot.date) })
    return out
  }
  readonly property string scheduleLine: {
    if (shared.schedule === "off") return "Off. Back up when you choose."
    var due = null, r = rev
    checkedSets.forEach(function (s) { var st = bk.status(s.id); if (st && st.nextDue) { var t = new Date(st.nextDue).getTime(); if (due === null || t < due) due = t } })
    if (due === null) return "Runs when Switch is open."
    return due <= Date.now() ? "Due now. Runs while Switch is open." : "Next backup " + F.dateTime(due)
  }
  readonly property string progressLine: {
    if (!running) return ""
    var set = sets.filter(function (s) { return s.id === bk.running.setID })[0]
    var row = set ? rows.filter(function (x) { return x.sourceID === set.sourceID })[0] : null
    var name = row ? row.title : (set ? set.name : "")
    var step = running.count > 1 ? " (" + (running.index + 1) + " of " + running.count + ")" : ""
    return "Backing up " + name + step + " · " + F.num(running.files) + " files · " + F.size(running.bytes)
  }
  function lastBackup(row) {
    var r = rev, best = row.lastBackup ? new Date(row.lastBackup).getTime() : 0
    return best > 0 ? best : null
  }
  function profiles(sourceID) {
    var s = sets.filter(function (x) { return x.sourceID === sourceID && !x.retired })[0]
    return s && s.profiles ? Object.keys(s.profiles).length : 0
  }

  // MARK: loading

  function load() {
    if (!page) return
    page.rpc("backup.checklist", {}, function (res, err) {
      if (err) { page.showError(err.message); bk.loaded = true; return }
      checklist = res
      loaded = true
      ++rev
    })
    page.rpc("backup.list", {}, function (list, err) {
      if (err) { page.showError(err.message); return }
      sets = list || []
      sets.forEach(function (s) {
        page.rpc("backup.history", { setID: s.id }, function (st, e2) {
          if (e2) { page.showError("The backups of " + s.name + " could not be read. " + e2.message); return }
          var next = Object.assign({}, bk.statuses)
          next[s.id] = st
          statuses = next
          ++rev
        })
      })
    })
    page.rpc("accounts.status", {}, function (st) { recovery = st && st.pendingRecovery ? st.pendingRecovery : [] })
  }
  onFolderChanged: if (page && folder !== "") page.rpc("backup.freeSpace", { path: folder }, function (r) { free = r && r.bytes !== undefined && r.bytes !== null ? r.bytes : null })

  // MARK: actions

  // Checklist changes (rpc.md backup.configure/setChecked/setShared). Each returns the new checklist; a failed
  // save changes nothing and shows the error.
  function configure(method, params, demoApply, done) {
    if (page.demo) { demoApply(); ++rev; return }
    page.rpc(method, params, function (res, err) {
      if (err) { page.showError(err.message); return }
      if (res && res.rows) { checklist = res; ++rev }
      if (done) done(); else load()
    })
  }
  function setChecked(row, on) {
    // Without a folder a checked tool stays pending until a folder is chosen (maintenance.md "No folder yet").
    if (!page.demo && folder === "" && on) { local.checked[row.sourceID] = true; ++rev; return }
    if (!page.demo && !on && local.checked[row.sourceID]) { delete local.checked[row.sourceID]; ++rev; return }
    configure("backup.setChecked", { sourceID: row.sourceID, checked: on }, function () { bk.local.checked[row.sourceID] = on })
  }
  function setShared(key, value) {
    var p = {}; p[key] = value
    configure("backup.setShared", p, function () { bk.local.shared[key] = value })
  }
  function chooseFolder() {
    page.pickFolder("Choose a backup folder", "Choose", folder || page.userHome, useFolder)
  }
  function useFolder(path) {
    if (page.demo) { bk.local.folder = path; ++rev; return }
    var pending = Object.keys(local.checked).filter(function (k) { return bk.local.checked[k] })
    var first = pending.length > 0 ? pending[0] : (checkedRows.length > 0 ? checkedRows[0].sourceID : (rows.length > 0 ? rows[0].sourceID : ""))
    configure("backup.configure", { sourceID: first, destination: path }, null, function () {
      var rest = pending.slice(1)
      bk.local = { checked: {}, shared: {}, folder: "" }
      rest.forEach(function (id) { page.rpc("backup.setChecked", { sourceID: id, checked: true }, function (r, e) { if (e) page.showError(e.message); bk.load() }) })
      load()
    })
  }

  Connections {
    target: Helper
    function onNotification(method, params) {
      if (method === "$/progress" && params.token === bk.runToken) bk.running = params.value
    }
  }
  function backUpNow() {
    var ids = checkedSets.map(function (s) { return s.id })
    if (ids.length === 0) return
    var token = "backup-" + Date.now()
    runToken = token
    running = { setID: ids[0], index: 0, count: ids.length, files: 0, bytes: 0 }
    if (page.demo) { demoRun.ids = ids; demoRun.start(); return }
    // backup.run has no time limit in the helper; $/cancelRequest stops it (rpc.md).
    runCall = page.rpc("backup.run", { setIDs: ids, progressToken: token }, function (res, err) {
      if (bk.runToken !== token) return
      running = null
      runCall = -1
      if (err && err.code !== -32800) page.showError(err.message)
      load()
    }, 0)
  }
  function cancelBackup() {
    if (page.demo) { demoRun.stop(); running = null; return }
    if (runCall >= 0) Helper.cancelCall(runCall)
  }
  Timer {
    id: demoRun
    property var ids: []
    interval: 100
    repeat: true
    onTriggered: {
      var r = bk.running
      if (!r) { stop(); return }
      var next = { setID: r.setID, index: r.index, count: r.count, files: r.files + 37, bytes: r.bytes + 21000000 }
      if (next.files > 400) {
        if (r.index + 1 >= r.count) { stop(); bk.running = null; return }
        next = { setID: ids[r.index + 1], index: r.index + 1, count: r.count, files: 0, bytes: 0 }
      }
      bk.running = next
    }
  }
  function restore(req, items, destination) {
    restoring = true
    var p = { setID: req.set.id, snapshotID: req.snapshot.id, includeLogins: shared.includeLogins && !shared.promptsOnly }
    if (items) p.items = items
    if (destination) p.destination = destination
    // The Mac has no Cancel for a restore (maintenance.md 4.2); the call id lets quitting, or a live test, stop it.
    restoreCall = page.rpc("backup.restore", p, function (res, err) {
      restoreCall = -1
      restoring = false
      restoreRequest = null
      if (err) page.showError(err.message)
      load()
    }, 0)
  }

  // MARK: parts

  component Label: Column {
    property string title: ""
    property string detail: ""
    property color detailColor: Theme.secondary
    spacing: 2
    Txt { width: parent.width; text: parent.title }
    Txt { width: parent.width; visible: parent.detail !== ""; role: "secondary"; color: parent.detailColor; tabular: true; wrapMode: Text.Wrap; text: parent.detail }
  }
  component TableRow: Item {
    property bool hover: false
    width: parent ? parent.width : 0
    height: 36
    Rectangle {
      x: 6; y: 2
      width: parent.width - 12
      height: parent.height - 4
      radius: 6
      color: Theme.rowHover
      opacity: parent.hover && rowHover.hovered ? 1 : 0
      Behavior on opacity { NumberAnimation { duration: Theme.dHover } }
    }
    HoverHandler { id: rowHover }
  }

  // MARK: (a) loading and (b) no tools

  MaintCard {
    visible: (!bk.loaded || !bk.modelLoaded) && bk.rows.length === 0
    title: "What to back up"
    MaintRow { MaintLoadingLine {} }
    MaintRow { MaintLoadingLine {} }
    MaintRow { MaintLoadingLine {} }
  }
  MaintCard {
    visible: bk.loaded && bk.modelLoaded && bk.rows.length === 0
    MaintRow { Txt { role: "secondary"; color: Theme.secondary; text: "No supported tool was found on this Mac." } }
  }

  // MARK: 1 what to back up

  MaintCard {
    id: whatCard
    visible: bk.rows.length > 0
    title: "What to back up"
    readonly property var supported: bk.rows.filter(function (r) { return F.included(r.sourceID, 0) !== "Not supported yet" })
    accessory: RollText { role: "secondary"; color: Theme.secondary
                          text: F.num(whatCard.supported.filter(function (r) { return bk.isChecked(r) }).length) + " of " + F.num(whatCard.supported.length) + " checked" }
    Repeater {
      model: bk.rows
      delegate: MaintRow {
        id: crow
        readonly property bool supported: F.included(modelData.sourceID, 0) !== "Not supported yet"
        readonly property string what: F.included(modelData.sourceID, bk.profiles(modelData.sourceID))
        readonly property string line2: supported ? what + " · " + (modelData.bytes === null || modelData.bytes === undefined ? "Calculating…" : F.size(modelData.bytes)) : what
        readonly property bool runningHere: !!bk.running && modelData.setID === bk.running.setID
        readonly property var last: bk.lastBackup(modelData)
        Item {
          width: parent.width
          height: 32
          enabled: crow.supported && !bk.running
          opacity: enabled ? 1 : 0.45
          Accessible.role: Accessible.CheckBox
          Accessible.name: modelData.title
          Accessible.checked: bk.isChecked(modelData)
          MaintCheck { anchors.verticalCenter: parent.verticalCenter; label: modelData.title; value: bk.isChecked(modelData) ? 2 : 0
                       onClicked: bk.setChecked(modelData, !bk.isChecked(modelData)) }
          MouseArea { anchors.fill: parent; z: -1; onClicked: bk.setChecked(modelData, !bk.isChecked(modelData)) }
          ProviderTile { id: mark; x: 22; anchors.verticalCenter: parent.verticalCenter; size: 28; provider: F.provider(modelData); name: modelData.title }
          Column {
            x: mark.x + 28 + 8
            width: parent.width - x - 8 - 150
            anchors.verticalCenter: parent.verticalCenter
            spacing: 2
            Txt { width: parent.width; text: modelData.title; elide: Text.ElideRight; ToolTipArea { text: modelData.title } }
            Txt { width: parent.width; role: "secondary"; color: Theme.secondary; tabular: true; text: crow.line2; elide: Text.ElideRight; ToolTipArea { text: crow.line2 } }
          }
          Item {
            anchors.right: parent.right
            width: 150
            height: parent.height
            Badge { visible: crow.runningHere; anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter; text: "Backing up"; dot: Theme.accent }
            Txt {
              visible: !crow.runningHere && crow.supported
              width: parent.width
              anchors.verticalCenter: parent.verticalCenter
              horizontalAlignment: Text.AlignRight
              role: "secondary"; color: Theme.secondary; tabular: true; elide: Text.ElideRight
              text: crow.last ? F.dateTime(crow.last) : "Never backed up"
              ToolTipArea { text: parent.text }
            }
          }
        }
      }
    }
  }

  // MARK: 2 folder and schedule

  MaintCard {
    visible: bk.rows.length > 0
    title: "Folder and schedule"
    accessory: [
      Badge { visible: !!bk.running; text: "Backing up"; dot: Theme.accent },
      Badge { visible: !bk.running && bk.isWaiting; text: "Waiting for " + bk.waiting; dot: Theme.amber },
      Badge { visible: !bk.running && !bk.isWaiting && bk.folder !== ""; text: "Ready"; dot: Theme.green }
    ]
    MaintRow {
      Item {
        width: parent.width
        height: Math.max(folderLabel.height, 28)
        Column {
          id: folderLabel
          width: parent.width - folderBtn.width - 16
          anchors.verticalCenter: parent.verticalCenter
          spacing: 2
          Txt { text: "Backup folder" }
          MaintCopyPath { visible: bk.folder !== ""; width: Math.min(implicitWidth, parent.width); path: F.home(bk.folder, bk.page ? bk.page.userHome : "") }
          Txt { width: parent.width; role: "secondary"; color: Theme.secondary; tabular: true; wrapMode: Text.Wrap
                text: bk.folder === "" ? "A drive or folder outside your tools. Nothing is copied yet."
                      : (bk.isWaiting ? "The drive is not connected. Backups wait for it." : (bk.free !== null ? F.size(bk.free) + " free" : "Free space unknown")) }
        }
        PushButton { id: folderBtn; anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter
                     text: bk.folder === "" ? "Choose a folder" : "Change"; icon: "folder"; prominent: bk.folder === ""
                     enabled: !bk.running; onClicked: bk.chooseFolder() }
      }
    }
    MaintRow {
      Item {
        width: parent.width
        height: 32
        Label { width: parent.width - pops.width - 16; anchors.verticalCenter: parent.verticalCenter; title: "Schedule"; detail: bk.scheduleLine }
        Row {
          id: pops
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          spacing: 8
          PopUp {
            name: "Backup schedule"
            readonly property var values: ["off", "daily", "weekly"]
            options: ["Schedule off", "Every day", "Every week"]
            current: values.indexOf(bk.shared.schedule)
            onPicked: function (i) { bk.setShared("schedule", values[i]); current = Qt.binding(function () { return values.indexOf(bk.shared.schedule) }) }
          }
          PopUp {
            name: "Backups to keep"
            readonly property var values: [3, 5, 10, 20, 50]
            options: values.map(function (v) { return "Keep " + v })
            current: values.indexOf(bk.shared.keep)
            onPicked: function (i) { bk.setShared("keep", values[i]); current = Qt.binding(function () { return values.indexOf(bk.shared.keep) }) }
          }
        }
      }
    }
    MaintRow {
      Item {
        width: parent.width
        height: promptLabel.height
        Label { id: promptLabel; width: parent.width - 38 - 16; title: "Prompt-only backup"
                detail: "Save only your prompts as Markdown, grouped by project, with one file per conversation and an index. Responses, tools, login files, and settings stay out." }
        Switch { anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter; name: "Prompt-only backup"
                 enabled: !bk.running && !bk.restoring; checked: bk.shared.promptsOnly === true
                 onToggled: function (v) { bk.setShared("promptsOnly", v); checked = Qt.binding(function () { return bk.shared.promptsOnly === true }) } }
      }
    }
    MaintRow {
      Item {
        width: parent.width
        height: loginLabel.height
        readonly property bool on: bk.shared.includeLogins && bk.shared.promptsOnly !== true
        Label { id: loginLabel; width: parent.width - 38 - 16; title: "Include login files"
                detailColor: parent.on ? Theme.amber : Theme.secondary
                detail: bk.shared.promptsOnly === true ? "Prompt-only backups always exclude login files."
                        : "Off keeps sign-in files out. On, anyone who can read the backup folder can use your accounts, so keep the drive private." }
        Switch { anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter; name: "Include login files"
                 enabled: bk.shared.promptsOnly !== true; checked: parent.on
                 onToggled: function (v) { bk.setShared("includeLogins", v); checked = Qt.binding(function () { return bk.shared.includeLogins && bk.shared.promptsOnly !== true }) } }
      }
    }
    MaintRow {
      Item {
        visible: !!bk.running
        width: parent.width
        height: visible ? 28 : 0
        MaintSpinner { anchors.verticalCenter: parent.verticalCenter }
        Txt { x: 24; anchors.verticalCenter: parent.verticalCenter; width: parent.width - x - 8 - cancelBtn.width - 8; role: "secondary"; color: Theme.secondary
              tabular: true; text: bk.progressLine; elide: Text.ElideRight; ToolTipArea { text: bk.progressLine } }
        PushButton { id: cancelBtn; anchors.right: parent.right; text: "Cancel"; onClicked: bk.cancelBackup() }
      }
      Item {
        visible: !bk.running
        width: parent.width
        height: visible ? Math.max(28, runLabel.height) : 0
        Column {
          id: runLabel
          width: parent.width - runBtn.width - 16
          anchors.verticalCenter: parent.verticalCenter
          spacing: 2
          Txt { visible: bk.lastError !== ""; width: parent.width; role: "secondary"; color: Theme.amber; wrapMode: Text.Wrap; maximumLineCount: 2
                elide: Text.ElideRight; text: "Last error: " + bk.lastError; ToolTipArea { text: "Last error: " + bk.lastError } }
          Txt { width: parent.width; role: "secondary"; color: Theme.secondary; wrapMode: Text.Wrap
                text: bk.shared.promptsOnly === true ? "Prompt backups use this folder, schedule, and retention count. Restore exports them into a folder."
                      : "The first backup copies everything. Later backups copy only what changed." }
        }
        PushButton { id: runBtn; anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter
                     text: F.backupButton(bk.checkedRows.length); icon: "archivebox"; prominent: true
                     enabled: bk.folder !== "" && bk.checkedSets.length > 0 && !bk.isWaiting && !bk.restoring
                     onClicked: bk.backUpNow() }
      }
    }
  }

  // MARK: 3 history

  MaintCard {
    id: histCard
    visible: bk.rows.length > 0
    title: "History"
    bottomInset: 7
    readonly property var shown: bk.history.slice(0, 20)
    accessory: RollText { role: "secondary"; color: Theme.secondary; text: F.num(bk.history.length) + " kept" }
    Column {
      visible: !bk.loaded && histCard.shown.length === 0
      width: parent.width
      Repeater { model: 3; delegate: Item { width: parent.width; height: 36; MaintLoadingLine { x: 16; width: parent.width - 32; anchors.verticalCenter: parent.verticalCenter } } }
    }
    Item {
      visible: bk.loaded && histCard.shown.length === 0
      width: parent.width
      height: visible ? 14 + emptyText.height + 14 - 7 : 0
      Txt { id: emptyText; x: 16; y: 14; width: parent.width - 32; role: "secondary"; color: Theme.secondary; wrapMode: Text.Wrap
            text: bk.isWaiting ? "Backups appear again when the drive is connected." : "No backups yet. Check a tool, then choose " + F.backupButton(bk.checkedRows.length) + "." }
    }
    Column {
      visible: histCard.shown.length > 0
      width: parent.width
      readonly property real flex: width - 32 - 200 - 72 - 88 - 150 - 84 - 5 * 12
      TableRow {
        Row {
          x: 16
          height: parent.height
          spacing: 12
          Txt { width: parent.parent.parent.flex; anchors.verticalCenter: parent.verticalCenter; role: "secondary"; color: Theme.secondary; text: "Tool" }
          Txt { width: 200; anchors.verticalCenter: parent.verticalCenter; role: "secondary"; color: Theme.secondary; text: "Date" }
          Txt { width: 72; anchors.verticalCenter: parent.verticalCenter; role: "secondary"; color: Theme.secondary; text: "Files"; horizontalAlignment: Text.AlignRight }
          Txt { width: 88; anchors.verticalCenter: parent.verticalCenter; role: "secondary"; color: Theme.secondary; text: "Size"; horizontalAlignment: Text.AlignRight }
          Txt { width: 150; anchors.verticalCenter: parent.verticalCenter; role: "secondary"; color: Theme.secondary; text: "State" }
        }
      }
      Repeater {
        model: histCard.shown
        delegate: Column {
          id: hrow
          width: parent.width
          readonly property var snap: modelData.snapshot
          readonly property real flex: parent.flex
          Behavior on opacity { NumberAnimation { duration: Theme.dAppear } }
          Rectangle { x: 16; width: parent.width - 32; height: Theme.hair; color: Theme.tableSeparator }
          TableRow {
            hover: true
            Row {
              x: 16
              height: parent.height
              spacing: 12
              Item {
                width: hrow.flex
                height: parent.height
                ProviderTile { id: hmark; size: 20; anchors.verticalCenter: parent.verticalCenter; provider: modelData.provider; name: modelData.title }
                Txt { x: 28; width: parent.width - x; anchors.verticalCenter: parent.verticalCenter; text: modelData.title; elide: Text.ElideRight; ToolTipArea { text: modelData.title } }
              }
              Txt { width: 200; anchors.verticalCenter: parent.verticalCenter; tabular: true; text: F.dateTime(hrow.snap.date); elide: Text.ElideRight; ToolTipArea { text: parent.text } }
              Txt { width: 72; anchors.verticalCenter: parent.verticalCenter; tabular: true; text: F.num(hrow.snap.files); horizontalAlignment: Text.AlignRight }
              Txt { width: 88; anchors.verticalCenter: parent.verticalCenter; tabular: true; text: F.size(hrow.snap.totalBytes); horizontalAlignment: Text.AlignRight }
              Item {
                width: 150
                height: parent.height
                readonly property bool complete: hrow.snap.state === "Complete"
                Badge {
                  anchors.verticalCenter: parent.verticalCenter
                  text: hrow.snap.safety ? "Safety copy" : (parent.complete ? (hrow.snap.promptsOnly ? "Prompts only" : "Complete") : "Some skipped")
                  dot: hrow.snap.safety || !parent.complete ? Theme.amber : Theme.green
                }
              }
              Item {
                width: 84
                height: parent.height
                PushButton { anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter; controlHeight: 22; text: "Restore"
                             enabled: !bk.running && !bk.restoring && !bk.isWaiting
                             onClicked: bk.restoreRequest = { snapshot: hrow.snap, set: modelData.set, title: modelData.set.name } }
              }
            }
          }
        }
      }
    }
  }

  // MARK: 4 interrupted work

  MaintCard {
    visible: bk.recovery.length > 0
    title: "Interrupted work"
    Repeater {
      model: bk.recovery
      delegate: MaintRow {
        Column {
          width: parent.width
          spacing: 8
          Item {
            width: parent.width
            height: 32
            Icon { name: "warnTriangle"; size: 15; color: Theme.amber; anchors.verticalCenter: parent.verticalCenter }
            Column {
              x: 15 + 16
              width: parent.width - x - 16 - 14 - 8 - phase.width
              anchors.verticalCenter: parent.verticalCenter
              spacing: 2
              Txt { text: modelData.kind.charAt(0).toUpperCase() + modelData.kind.slice(1) }
              MaintCopyPath { width: Math.min(implicitWidth, parent.width); path: modelData.destination }
            }
            IconButton { anchors.right: phase.left; anchors.rightMargin: 16; anchors.verticalCenter: parent.verticalCenter; icon: "copy"; tip: "Copy backup warning"
                         onClicked: bk.page.copyText("Pending " + modelData.kind + " operation (" + modelData.phase + ")\nDestination: " + modelData.destination) }
            Badge { id: phase; anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter; text: modelData.phase; dot: Theme.amber }
          }
          Item {
            visible: modelData.phase === "conflicted"
            width: parent.width
            height: visible ? 28 : 0
            Txt { anchors.verticalCenter: parent.verticalCenter; role: "secondary"; color: Theme.secondary; text: "Both versions are protected. Choose which version to keep." }
            Row {
              anchors.right: parent.right
              spacing: 6
              PushButton { text: "Keep current"; enabled: !bk.modelBusy; onClicked: bk.page.resolve(modelData, "preserveCurrent") }
              PushButton { text: "Restore backup"; enabled: !bk.modelBusy; onClicked: bk.page.resolve(modelData, "restoreBackup") }
            }
          }
        }
      }
    }
    MaintRow {
      Item {
        width: parent.width
        height: 28
        Txt { anchors.verticalCenter: parent.verticalCenter; role: "secondary"; color: Theme.secondary; text: "Account imports that stopped part way can finish here." }
        PushButton { anchors.right: parent.right; text: "Finish pending work"; icon: "archivebox"
                     enabled: !bk.modelBusy && bk.recovery.some(function (r) { return r.phase !== "conflicted" })
                     onClicked: bk.page.recover() }
      }
    }
  }
}
