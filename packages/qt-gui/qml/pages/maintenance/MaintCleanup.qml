import QtQuick
import "MaintFmt.js" as F

// The Cleanup tab (maintenance.md 2.3, 3): controls, conversations by filter, files by category, Switch's
// own cache, selection, review, recoverable trash, and the amber error card. Selection lives here and is
// sent as item ids; the helper keeps the scan and the reviewed plan (rpc.md cleanup.*).
Column {
  id: cl
  spacing: 12
  width: parent ? parent.width : 0

  // set by the page
  property var page: null              // rpc(), save(), alert
  property var source: null
  property bool sourcesLoaded: false
  property bool modelLoaded: true
  property bool modelBusy: false
  property bool active: false

  // saved choices (setting keys cleanupRange, cleanupFrom, cleanupThrough, cleanupExpanded, cleanupProjects, cleanupTitle)
  property string range: "Older than 30 days"
  property real from: Date.now() - 30 * F.DAY
  property real through: Date.now()
  property var expanded: ({})
  property var projects: []
  property string titleQuery: ""
  property bool restoring: false       // true while the saved choices load: no reset, no save

  property var scan: null
  property string scannedSourceID: ""
  property var trash: []
  property var samples: []
  property var cacheSizes: ({ usageBytes: 0, conversationBytes: 0 })
  property var selection: ({})
  property int rev: 0
  property bool useSamples: false
  property bool clearIndex: false
  property real anchor: Date.now()
  property bool loading: false
  property string error: ""
  property var review: null
  property bool showReviewItems: false
  property string scanToken: ""
  property real scanCall: -1
  property var removing: null          // {batch, token}
  readonly property bool busy: loading || modelBusy
  readonly property bool isCodex: !!source && source.tool === "codex"
  readonly property string toolTitle: source ? source.title : "This tool"

  // MARK: derived data

  function matches(d) { return F.inRange(range, d, anchor, from, through) }
  function convOK(it) {
    var t = titleQuery.trim().toLowerCase()
    return !it.protectedReason && !it.isRewrite && (projects.length === 0 || projects.indexOf(it.project || "") >= 0)
        && (t === "" || it.title.toLowerCase().indexOf(t) >= 0)
  }
  function isConv(id) { return id === "conversations" || id === "archived" || id === "agents" }
  function sum(items) { var s = 0; for (var i = 0; i < items.length; ++i) s += Number(items[i].bytes) || 0; return s }

  readonly property var view: {
    var r = range, f = from, t = through, a = anchor, p = projects, q = titleQuery
    if (!scan) return null
    var cats = scan.categories.map(function (c) {
      var items = c.items.filter(function (it) { return !it.protectedReason })
      if (c.ageBased) items = items.filter(function (it) { return cl.matches(it.updatedAt) })
      if (cl.isConv(c.id)) items = items.filter(cl.convOK)
      items.sort(function (x, y) { return new Date(y.updatedAt) - new Date(x.updatedAt) })
      return { c: c, items: items, bytes: cl.sum(items), groups: c.byProject ? cl.groupsOf(c.id, items) : [] }
    })
    var conversations = []
    scan.categories.forEach(function (c) { if (cl.isConv(c.id)) conversations = conversations.concat(c.items) })
    var matching = conversations.filter(function (it) { return cl.matches(it.updatedAt) && cl.convOK(it) })
    matching.sort(function (x, y) { return new Date(y.updatedAt) - new Date(x.updatedAt) })
    var choices = {}
    conversations.forEach(function (it) { choices[it.project || ""] = true })
    var shown = cats.filter(function (x) { return x.items.length > 0 })
    var counted = []
    shown.forEach(function (x) { if (x.c.id !== "images") counted = counted.concat(x.items) })
    return { cats: cats, shown: shown, matching: matching, choices: Object.keys(choices).sort(), counted: counted.length, countedBytes: cl.sum(counted),
             samples: samples.filter(function (s) { return cl.matches(s.fetchedAt) }) }
  }
  function groupsOf(catID, items) {
    var by = {}, order = []
    items.forEach(function (it) { var k = it.project || ""; if (!by[k]) { by[k] = []; order.push(k) } by[k].push(it) })
    var out = order.map(function (k) { return { id: catID + "/" + k, path: k, items: by[k], bytes: cl.sum(by[k]),
                                                newest: Math.max.apply(null, by[k].map(function (it) { return new Date(it.updatedAt).getTime() })) } })
    out.sort(function (x, y) { return y.newest - x.newest })
    return out
  }
  // A chat picked for removal drops its own pasted-images row, so one file is never handled twice.
  // Set imperatively: as a binding it re-entered itself through the selection rows that read it.
  property var picked: ({ items: [], bytes: 0 })
  function updatePicked() {
    var v = view, all = []
    if (v) v.cats.forEach(function (x) { x.items.forEach(function (it) { if (cl.selection[it.id]) all.push(it) }) })
    var removed = {}
    all.forEach(function (it) { if (!it.isRewrite) removed[it.path] = true })
    var items = all.filter(function (it) { return !it.isRewrite || !removed[it.path] })
    picked = { items: items, bytes: sum(items) }
  }
  onViewChanged: updatePicked()
  onRevChanged: updatePicked()
  readonly property bool hasSelection: { var r = rev; return Object.keys(selection).length > 0 || (useSamples && !!view && view.samples.length > 0) || clearIndex }

  function stateOf(items) {
    var r = rev, n = 0
    for (var i = 0; i < items.length; ++i) if (selection[items[i].id]) ++n
    return n === 0 ? 0 : (n === items.length ? 2 : 1)
  }
  function toggle(items) {
    var on = stateOf(items) === 2
    items.forEach(function (it) { if (on) delete cl.selection[it.id]; else cl.selection[it.id] = true })
    ++rev
    review = null
  }
  function isOpen(id) { var r = rev; return !!expanded[id] }
  function toggleExpanded(id) {
    var next = Object.assign({}, expanded)
    if (next[id]) delete next[id]; else next[id] = true
    expanded = next
    ++rev
    if (page) page.save("cleanupExpanded", Object.keys(next).sort().join("\n"))
  }
  function resetSelection() {
    var next = {}
    if (view) view.cats.forEach(function (x) { if (x.c.preselected) x.items.forEach(function (it) { next[it.id] = true }) })
    selection = next
    ++rev
    useSamples = false
    clearIndex = false
    review = null
  }
  function changed(key, value) {
    if (restoring) return
    resetSelection()
    if (page) page.save(key, value)
  }
  onRangeChanged: changed("cleanupRange", range)
  onFromChanged: changed("cleanupFrom", from / 1000)
  onThroughChanged: changed("cleanupThrough", through / 1000)
  onProjectsChanged: changed("cleanupProjects", projects)
  onTitleQueryChanged: changed("cleanupTitle", titleQuery)
  onClearIndexChanged: review = null

  // MARK: actions

  onActiveChanged: maybeScan()
  onSourceChanged: maybeScan()
  function maybeScan() { if (active && source && (!scan || scannedSourceID !== source.id)) reload() }

  function fail(err) { return err.message || String(err) }
  function reload() {
    if (!source || !page) return
    if (scanCall >= 0) Helper.cancelCall(scanCall)
    var src = source, token = "scan-" + Date.now()
    scanToken = token
    loading = true
    error = ""
    review = null
    // A scan has no time limit in the helper (rpc.md), so it gets none here either. The Mac shows no scan
    // progress, so no progressToken is sent.
    scanCall = page.rpc("cleanup.scan", { sourceID: src.id }, function (result, err) {
      if (cl.scanToken !== token) return
      scanCall = -1
      if (err) { loading = false; error = fail(err); return }
      page.rpc("cleanup.trashList", { sourceID: src.id }, function (batches, err2) {
        if (cl.scanToken !== token) return
        if (err2) { loading = false; error = fail(err2); return }
        var done = function (smp, sizes) {
          trash = batches || []
          samples = smp || []
          cacheSizes = sizes || { usageBytes: 0, conversationBytes: 0 }
          anchor = Date.now()
          scan = result
          scannedSourceID = src.id
          loading = false
          resetSelection()
        }
        if (src.tool !== "codex") { done([], null); return }
        page.rpc("cleanup.samples", {}, function (smp, err3) {
          if (cl.scanToken !== token) return
          if (err3) { loading = false; error = fail(err3); return }
          // An older helper without usage.cacheSizes answers an error; then only the samples count.
          page.rpc("usage.cacheSizes", {}, function (sizes) {
            if (cl.scanToken !== token) return
            done(smp, sizes || { usageBytes: cl.sum(smp || []), conversationBytes: 0 })
          })
        })
      })
    }, 0)
  }

  function makeReview() {
    var items = picked.items
    var finish = function (plan) {
      var catOf = {}
      scan.categories.forEach(function (c) { c.items.forEach(function (it) { catOf[it.id] = c }) })
      var by = {}, order = []
      items.forEach(function (it) { var c = catOf[it.id]; if (!c) return; if (!by[c.id]) { by[c.id] = { id: c.id, title: c.title, count: 0, bytes: 0 }; order.push(c.id) }
                                    by[c.id].count++; by[c.id].bytes += Number(it.bytes) || 0 })
      var groups = order.map(function (k) { return by[k] }).sort(function (x, y) { return y.bytes - x.bytes })
      showReviewItems = false
      var smp = useSamples ? view.samples : []
      review = { plan: plan, groups: groups, samples: smp, clearIndex: clearIndex,
                 itemCount: plan ? plan.items.length : 0, bytes: plan ? plan.bytes : 0 }
    }
    error = ""
    if (items.length === 0) { finish(null); return }
    loading = true
    page.rpc("cleanup.review", { scanID: scan.scanID, itemIDs: items.map(function (it) { return it.id }) }, function (plan, err) {
      loading = false
      if (err) { error = fail(err); return }
      finish(plan)
    })
  }
  function reviewConversations() {
    var next = {}
    view.matching.forEach(function (it) { next[it.id] = true })
    selection = next
    ++rev
    useSamples = false
    clearIndex = false
    makeReview()
  }
  function confirmApply() {
    var n = review ? review.itemCount : 0, b = review ? review.bytes : 0
    page.ask("Move " + F.num(n) + " items to the trash?",
             F.size(b) + " (" + F.num(b) + " bytes) move to Switch's recoverable trash. Restore brings them back. Nothing is deleted for good.",
             "Move to trash", false, apply)
  }
  function apply() {
    var r = review
    if (!r) return
    var params = { sampleIDs: r.samples.map(function (s) { return s.id }), clearIndex: r.clearIndex }
    if (r.plan) params.planID = r.plan.planID
    loading = true
    page.rpc("cleanup.apply", params, function (res, err) {
      review = null
      var bad = err ? fail(err) : (res && res.error ? res.error : "")
      reload()
      if (bad) error = bad + " Review again. Items already in the trash can be restored."
    })
  }
  function restoreBatch(batch) {
    loading = true
    page.rpc("cleanup.restore", { sourceID: source.id, batchID: batch.id }, function (res, err) {
      if (err) { loading = false; error = fail(err); return }
      reload()
      if (res && res.error) error = res.error
    })
  }
  // Two steps (rpc.md cleanup.purge): the helper answers needsConfirmation with a token; the alert shows the
  // Mac text, and only Remove for good repeats the call with that token.
  function purgeBatch(batch) {
    loading = true
    page.rpc("cleanup.purge", { sourceID: source.id, batchID: batch.id }, function (res, err) {
      loading = false
      if (err) { error = fail(err); return }
      if (!res || res.status !== "needsConfirmation") { reload(); if (res && res.error) error = res.error; return }
      // The alert keeps the Mac page text (maintenance.md 2.3); the helper's own title is shorter.
      var c = res.confirmation
      page.ask("Remove these items for good?",
               F.num(batch.items.length) + " items (" + F.size(batch.bytes) + ") leave the trash. This cannot be undone.",
               "Remove for good", true, function () {
        loading = true
        page.rpc("cleanup.purge", { sourceID: source.id, batchID: batch.id, confirm: c.token }, function (r2, e2) {
          if (e2) { loading = false; error = fail(e2); return }
          reload()
          if (r2 && r2.error) error = r2.error
        })
      })
    })
  }

  // MARK: parts

  component SizeCol: Txt { property real bytes: 0; width: 80; horizontalAlignment: Text.AlignRight; tabular: true; text: F.size(bytes); elide: Text.ElideRight
                           ToolTipArea { text: F.size(parent.bytes) } }
  component CountCol: Txt { property int count: 0; width: 96; horizontalAlignment: Text.AlignRight; role: "secondary"; color: Theme.secondary; tabular: true
                            text: F.plural(count, "item", "items"); ToolTipArea { text: F.plural(parent.count, "item", "items") } }
  component Disclosure: Item {
    property bool open: false
    signal toggled()
    width: 12; height: 16
    // The row around it is the keyboard and screen reader target (MaintListRow expandable).
    Accessible.ignored: true
    Icon { anchors.centerIn: parent; name: "chevronRight"; size: 11; color: Theme.secondary; rotation: parent.open ? 90 : 0
           Behavior on rotation { enabled: !Theme.reduceMotion; NumberAnimation { duration: Theme.motion ? 250 : 0; easing.type: Easing.Bezier; easing.bezierCurve: Theme.easeOut } } }
    MouseArea { anchors.fill: parent; anchors.margins: -4; onClicked: parent.toggled() }
  }
  // Inline components do not see this file's ids, so the rows get the tab as `owner`.
  component ItemRow: MaintListRow {
    id: ir
    property var item
    property var owner
    signal activeFocusInside()
    minHeight: 36
    name: ir.item ? ir.item.title : ""
    MaintCheck { anchors.verticalCenter: parent.verticalCenter; label: ir.item.title; value: ir.owner.rev >= 0 && ir.owner.selection[ir.item.id] ? 2 : 0
                 onClicked: ir.owner.toggle([ir.item]); onActiveFocusChanged: if (activeFocus) ir.activeFocusInside() }
    Txt { x: 24; anchors.verticalCenter: parent.verticalCenter; width: ir.contentWidth - x - 8 - 96 - 8 - 80; text: ir.item.title; elide: Text.ElideMiddle
          ToolTipArea { text: ir.item.title + "\n" + ir.item.path } }
    Txt { x: ir.contentWidth - 80 - 8 - 96; width: 96; anchors.verticalCenter: parent.verticalCenter; horizontalAlignment: Text.AlignRight
          role: "secondary"; color: Theme.secondary; tabular: true; text: F.dateOnly(ir.item.updatedAt); ToolTipArea { text: F.dateOnly(ir.item.updatedAt) } }
    SizeCol { x: ir.contentWidth - 80; anchors.verticalCenter: parent.verticalCenter; bytes: ir.item.bytes }
  }
  component ItemList: Item {
    id: il
    property var items: []
    property var owner
    property real indent: 28
    width: parent ? parent.width : 0
    height: items.length <= 12 ? plain.height : Math.min(items.length, 8) * 36
    Column {
      id: plain
      visible: il.items.length <= 12
      width: parent.width
      Repeater { model: il.items.length <= 12 ? il.items : []; delegate: ItemRow { indent: il.indent; item: modelData; owner: il.owner } }
    }
    ListView {
      id: longList
      visible: il.items.length > 12
      anchors.fill: parent
      clip: true
      boundsBehavior: Flickable.StopAtBounds
      cacheBuffer: 1000000      // every row exists, so Tab walks the whole list
      model: il.items.length > 12 ? il.items : []
      delegate: ItemRow { width: ListView.view.width; indent: il.indent; item: modelData; owner: il.owner
                          onActiveFocusInside: longList.positionViewAtIndex(index, ListView.Contain) }
    }
  }

  // MARK: 1 controls

  MaintCard {
    MaintRow {
      Item {
        width: parent.width
        height: 28
        Row {
          spacing: 16
          PopUp {
            objectName: "cleanup-time-range"
            name: "Time range"
            options: F.RANGES
            current: F.RANGES.indexOf(cl.range)
            enabled: !cl.busy
            // PopUp writes `current` on a pick; bind it again so "Show all time" moves it too.
            onPicked: function (i) { cl.range = F.RANGES[i]; current = Qt.binding(function () { return F.RANGES.indexOf(cl.range) }) }
          }
          MaintDateField { visible: cl.range === "Before a date"; title: "Before"; date: cl.from; onPicked: function (ms) { cl.from = ms } }
          MaintDateField { visible: cl.range === "Custom dates"; title: "From"; date: cl.from; onPicked: function (ms) { cl.from = ms; if (cl.through < ms) cl.through = ms } }
          MaintDateField { visible: cl.range === "Custom dates"; title: "Through"; date: cl.through; after: cl.from; onPicked: function (ms) { cl.through = ms } }
        }
        Row {
          anchors.right: parent.right
          spacing: 16
          MaintSpinner { visible: cl.loading; anchors.verticalCenter: parent.verticalCenter }
          PushButton { objectName: "cleanup-reload"; text: "Reload"; icon: "refresh"; enabled: !cl.busy && !!cl.source; onClicked: cl.reload() }
        }
      }
    }
  }

  // MARK: states before a scan

  MaintCard {
    visible: !cl.source
    MaintRow { visible: !cl.sourcesLoaded || !cl.modelLoaded; MaintLoadingLine {} }
    MaintRow { visible: !cl.sourcesLoaded || !cl.modelLoaded; MaintLoadingLine {} }
    MaintRow { visible: !cl.sourcesLoaded || !cl.modelLoaded; MaintLoadingLine {} }
    MaintRow { visible: cl.sourcesLoaded && cl.modelLoaded
               Txt { role: "secondary"; color: Theme.secondary; text: "No supported tool was found on this Mac." } }
  }
  MaintCard {
    visible: !!cl.source && !cl.scan && cl.error === ""
    title: "Files"
    MaintRow { MaintLoadingLine {} }
    MaintRow { MaintLoadingLine {} }
    MaintRow { MaintLoadingLine {} }
  }

  // MARK: 2 conversations by filter

  MaintCard {
    id: convCard
    visible: !!cl.source && !!cl.scan
    title: "Delete conversations by filter"
    enabled: !cl.busy
    readonly property var items: cl.view ? cl.view.matching : []
    accessory: Txt { role: "secondary"; color: Theme.secondary; tabular: true
                     text: F.num(convCard.items.length) + " conversations · " + F.size(cl.sum(convCard.items)) }
    MaintRow {
      Item {
        width: parent.width
        height: 28
        Item {
          id: projMenu
          objectName: "cleanup-projects"
          width: projRow.width
          height: 28
          opacity: enabled ? 1 : 0.45
          Accessible.role: Accessible.ButtonMenu
          Accessible.name: projText.text
          activeFocusOnTab: enabled
          Keys.onSpacePressed: openMenu()
          Keys.onReturnPressed: openMenu()
          Keys.onDownPressed: openMenu()
          FocusFill { anchors.margins: -2; radius: 5 }
          Row {
            id: projRow
            anchors.verticalCenter: parent.verticalCenter
            spacing: 4
            Txt { id: projText; text: cl.projects.length === 0 ? "All projects" : F.num(cl.projects.length) + " projects" }
            Icon { name: "chevronDown"; size: 10; color: Theme.secondary; anchors.verticalCenter: parent.verticalCenter }
          }
          MouseArea {
            anchors.fill: parent
            onClicked: projMenu.openMenu()
          }
          function openMenu() {
            var paths = cl.view ? cl.view.choices : []
            var opts = ["All projects"].concat(paths.map(function (p) { return { text: p === "" ? "No project" : p, checked: cl.projects.indexOf(p) >= 0, icon: "folder" } }))
            Theme.menu.open(projMenu, opts, -1, function (i) {
              if (i === 0) { cl.projects = []; return }
              var p = paths[i - 1], next = cl.projects.slice(), at = next.indexOf(p)
              if (at >= 0) next.splice(at, 1); else next.push(p)
              cl.projects = next.sort()
            })
          }
        }
        Txt { id: titleLabel; x: projMenu.width + 8; anchors.verticalCenter: parent.verticalCenter; role: "secondary"; color: Theme.secondary; text: "Title" }
        FieldBox {
          x: titleLabel.x + titleLabel.width + 8
          width: Math.max(300, parent.width - x)
          placeholder: "Match title text"
          text: cl.titleQuery
          input.onTextEdited: cl.titleQuery = input.text
        }
      }
    }
    MaintRow {
      Txt { width: parent.width; role: "secondary"; color: Theme.secondary; wrapMode: Text.Wrap
            text: "Use the app picker above and the date range to narrow this list. Active and protected conversations stay untouched." }
    }
    MaintRow {
      Txt { visible: convCard.items.length === 0; role: "secondary"; color: Theme.secondary
            text: "No conversations match. Change the filters or choose another app." }
      ListView {
        id: convList
        visible: convCard.items.length > 0
        width: parent.width
        height: Math.min(convCard.items.length, 5) * 48
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        model: convCard.items
        delegate: Item {
          width: convList.width
          height: 48
          Column {
            x: 4
            width: parent.width - 8 - 8 - dateText.width - 8 - 80
            anchors.verticalCenter: parent.verticalCenter
            spacing: 2
            Txt { width: parent.width; text: modelData.title; elide: Text.ElideRight; ToolTipArea { text: modelData.title } }
            Txt { width: parent.width; role: "secondary"; color: Theme.secondary; text: modelData.project || "No project"; elide: Text.ElideMiddle
                  ToolTipArea { text: modelData.project || "No project" } }
          }
          Txt { id: dateText; x: parent.width - 4 - 80 - 8 - width; anchors.verticalCenter: parent.verticalCenter
                role: "secondary"; color: Theme.secondary; tabular: true; text: F.dateTime(modelData.updatedAt) }
          SizeCol { x: parent.width - 4 - 80; anchors.verticalCenter: parent.verticalCenter; bytes: modelData.bytes }
        }
      }
    }
    MaintRow {
      Item {
        width: parent.width
        height: 28
        Txt { anchors.verticalCenter: parent.verticalCenter; role: "secondary"; color: Theme.secondary; text: "Conversation dates are the last file update." }
        PushButton { anchors.right: parent.right; text: "Review " + F.num(convCard.items.length) + " conversations"
                     enabled: !cl.busy && convCard.items.length > 0; onClicked: cl.reviewConversations() }
      }
    }
  }

  // MARK: 3 files you can clear

  MaintCard {
    id: filesCard
    visible: !!cl.source && !!cl.scan
    title: "Files you can clear"
    bottomInset: 4.5
    enabled: !cl.busy
    accessory: RollText { role: "secondary"; color: Theme.secondary
                          text: cl.view ? F.num(cl.view.counted) + " items · " + F.size(cl.view.countedBytes) + " of " + F.size(cl.scan.totalBytes) : "" }
    Item {
      visible: !!cl.view && cl.view.shown.length === 0
      width: parent.width
      height: visible ? 14 + (cl.range !== "All time" ? 28 : 14) + 14 : 0
      Txt { x: 16; y: (parent.height - height) / 2; role: "secondary"; color: Theme.secondary
            text: cl.view ? F.nothingText(cl.range, cl.toolTitle, cl.scan.totalBytes) : "" }
      PushButton { x: parent.width - 16 - width; y: 14; visible: cl.range !== "All time"; text: "Show all time"; onClicked: cl.range = "All time" }
    }
    Column {
      visible: !!cl.view && cl.view.shown.length > 0
      width: parent.width
      topPadding: 4
      Repeater {
        model: cl.view ? cl.view.shown : []
        delegate: Column {
          id: block
          width: parent.width
          readonly property var cat: modelData.c
          readonly property bool open: cl.isOpen(cat.id)
          Rectangle { visible: index > 0; x: 16; width: parent.width - 32; height: Theme.hair; color: Theme.tableSeparator }
          MaintListRow {
            id: catRow
            minHeight: 52
            contentHeight: catText.height
            name: block.cat.title
            expandable: true
            open: block.open
            onClicked: cl.toggleExpanded(block.cat.id)
            Disclosure { anchors.verticalCenter: parent.verticalCenter; open: block.open; onToggled: cl.toggleExpanded(block.cat.id) }
            MaintCheck { x: 20; anchors.verticalCenter: parent.verticalCenter; label: block.cat.title; value: cl.stateOf(modelData.items)
                         onClicked: cl.toggle(modelData.items) }
            Column {
              id: catText
              x: 44
              width: catRow.contentWidth - x - 8 - 96 - 8 - 80
              spacing: 2
              Row {
                spacing: 6
                width: parent.width
                Txt { id: catTitle; width: Math.min(implicitWidth, parent.width - (badge.visible ? badge.width + 6 : 0)); text: block.cat.title; elide: Text.ElideRight
                      ToolTipArea { text: block.cat.title } }
                Badge { id: badge; visible: block.cat.risk === "caution"; text: "Check first"; dot: Theme.amber; anchors.verticalCenter: catTitle.verticalCenter }
              }
              Txt { width: parent.width; role: "secondary"; color: Theme.secondary; text: block.cat.detail; wrapMode: Text.Wrap
                    maximumLineCount: 2; elide: Text.ElideRight; ToolTipArea { text: block.cat.detail } }
            }
            CountCol { x: catRow.contentWidth - 80 - 8 - 96; anchors.verticalCenter: parent.verticalCenter; count: modelData.items.length }
            SizeCol { x: catRow.contentWidth - 80; anchors.verticalCenter: parent.verticalCenter; bytes: modelData.bytes }
          }
          // grouped by project: project rows (indent 28), their items at indent 56
          Column {
            visible: block.open && block.cat.byProject
            width: parent.width
            Repeater {
              model: block.open && block.cat.byProject ? modelData.groups : []
              delegate: Column {
                id: grp
                width: parent.width
                readonly property bool open: cl.isOpen(modelData.id)
                readonly property string name: modelData.path === "" ? "No project" : F.lastComponent(modelData.path)
                MaintListRow {
                  id: prow
                  indent: 28
                  name: grp.name
                  expandable: true
                  open: grp.open
                  onClicked: cl.toggleExpanded(modelData.id)
                  Disclosure { anchors.verticalCenter: parent.verticalCenter; open: grp.open; onToggled: cl.toggleExpanded(modelData.id) }
                  MaintCheck { x: 20; anchors.verticalCenter: parent.verticalCenter; label: grp.name; value: cl.stateOf(modelData.items); onClicked: cl.toggle(modelData.items) }
                  readonly property real avail: prow.contentWidth - 44 - 8 - 96 - 8 - 80 - 8
                  Txt { id: pname; x: 44; anchors.verticalCenter: parent.verticalCenter; width: Math.min(implicitWidth, prow.avail * 0.6); text: grp.name; elide: Text.ElideMiddle
                        ToolTipArea { text: modelData.path === "" ? "No project folder" : grp.name + "\n" + modelData.path } }
                  Txt { x: pname.x + pname.width + 8; anchors.verticalCenter: parent.verticalCenter; visible: modelData.path !== ""
                        width: Math.min(implicitWidth, prow.avail - pname.width - 8); role: "secondary"; color: Theme.secondary; font.family: "monospace"
                        text: F.home(modelData.path, cl.page ? cl.page.userHome : ""); elide: Text.ElideLeft; ToolTipArea { text: parent.text } }
                  CountCol { x: prow.contentWidth - 80 - 8 - 96; anchors.verticalCenter: parent.verticalCenter; count: modelData.items.length }
                  SizeCol { x: prow.contentWidth - 80; anchors.verticalCenter: parent.verticalCenter; bytes: modelData.bytes }
                }
                ItemList { visible: grp.open; items: grp.open ? modelData.items : []; indent: 56; owner: cl }
              }
            }
          }
          ItemList { visible: block.open && !block.cat.byProject; items: block.open && !block.cat.byProject ? modelData.items : []; indent: 28; owner: cl }
        }
      }
    }
  }

  // MARK: 4 Switch's own cache (Codex)

  MaintCard {
    visible: !!cl.scan && cl.isCodex && (cl.samples.length > 0 || cl.cacheSizes.conversationBytes > 0)
    title: "Switch's own cache"
    enabled: !cl.busy
    accessory: Txt { role: "secondary"; color: Theme.secondary; tabular: true; text: F.size(cl.cacheSizes.usageBytes + cl.cacheSizes.conversationBytes) }
    MaintRow {
      MaintCheck {
        readonly property int n: cl.view ? cl.view.samples.length : 0
        text: "Usage readings · " + F.num(n) + " in this range"
        enabled: n > 0
        value: cl.useSamples && n > 0 ? 2 : 0
        onClicked: { cl.useSamples = !cl.useSamples; cl.review = null }
      }
    }
    MaintRow {
      MaintCheck {
        text: "Conversation index · " + F.size(cl.cacheSizes.conversationBytes)
        enabled: cl.range === "All time" && cl.cacheSizes.conversationBytes > 0
        value: cl.clearIndex ? 2 : 0
        onClicked: cl.clearIndex = !cl.clearIndex
        ToolTipArea { text: "Choose All time to clear the search index. It rebuilds when Chat History opens." }
      }
    }
    MaintRow { Txt { role: "secondary"; color: Theme.secondary; text: "These caches rebuild when needed. Daily activity totals stay saved." } }
  }

  // MARK: 5 selection

  MaintCard {
    visible: !!cl.source && !!cl.scan
    MaintRow {
      visible: !!cl.scan && !!cl.scan.untouchedText
      Row {
        spacing: 6
        Icon { name: "info"; size: 14; color: Theme.secondary; anchors.verticalCenter: parent.verticalCenter }
        Txt { role: "secondary"; color: Theme.secondary; text: cl.scan && cl.scan.untouchedText ? cl.scan.untouchedText : "" }
      }
    }
    MaintRow {
      Item {
        width: parent.width
        height: 28
        Row {
          anchors.verticalCenter: parent.verticalCenter
          spacing: 8
          Txt { text: cl.hasSelection ? F.num(cl.picked.items.length) + " items selected" : "Nothing selected" }
          RollText { role: "secondary"; color: Theme.secondary; text: F.size(cl.picked.bytes); anchors.verticalCenter: parent.verticalCenter }
        }
        PushButton { anchors.right: parent.right; text: "Review"; prominent: true; enabled: !cl.busy && cl.hasSelection; onClicked: cl.makeReview() }
      }
    }
  }

  // MARK: 6 review

  MaintCard {
    id: reviewCard
    visible: !!cl.review
    title: "Review before cleanup"
    readonly property var r: cl.review || { groups: [], samples: [], clearIndex: false, itemCount: 0, bytes: 0, plan: null }
    Repeater {
      model: reviewCard.r.groups
      delegate: MaintRow {
        Item { width: parent.width; height: 16
          Txt { text: modelData.title }
          CountCol { x: parent.width - 80 - 8 - 96; count: modelData.count }
          SizeCol { x: parent.width - 80; bytes: modelData.bytes } }
      }
    }
    MaintRow {
      visible: reviewCard.r.samples.length > 0
      Item { width: parent.width; height: 16
        Txt { text: "Usage readings" }
        CountCol { x: parent.width - 80 - 8 - 96; count: reviewCard.r.samples.length }
        SizeCol { x: parent.width - 80; bytes: cl.sum(reviewCard.r.samples) } }
    }
    MaintRow {
      visible: reviewCard.r.clearIndex
      Item { width: parent.width; height: 16
        Txt { text: "Conversation index" }
        SizeCol { x: parent.width - 80; bytes: cl.cacheSizes.conversationBytes } }
    }
    MaintRow {
      Item { width: parent.width; height: 16
        Txt { text: "Total"; wght: 590 }
        CountCol { x: parent.width - 80 - 8 - 96; count: reviewCard.r.itemCount }
        SizeCol { x: parent.width - 80; bytes: reviewCard.r.bytes; wght: 590 } }
    }
    MaintRow {
      visible: !!reviewCard.r.plan
      Item {
        width: parent.width
        height: 16
        Row {
          id: linkRow
          spacing: 6
          Icon { name: "chevronRight"; size: 11; color: Theme.link; anchors.verticalCenter: parent.verticalCenter; rotation: cl.showReviewItems ? 90 : 0
                 Behavior on rotation { NumberAnimation { duration: Theme.motion ? 250 : 0 } } }
          Txt { color: Theme.link; text: cl.showReviewItems ? "Hide the exact items" : "Show the exact " + F.num(reviewCard.r.itemCount) + " items" }
        }
        Item {
          width: linkRow.width; height: 16
          activeFocusOnTab: true
          Accessible.role: Accessible.Button
          Accessible.name: linkRow.children[1].text
          Keys.onSpacePressed: cl.showReviewItems = !cl.showReviewItems
          Keys.onReturnPressed: cl.showReviewItems = !cl.showReviewItems
          FocusFill { anchors.margins: -3; radius: 4 }
          MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: cl.showReviewItems = !cl.showReviewItems }
        }
      }
    }
    MaintRow {
      visible: !!reviewCard.r.plan && cl.showReviewItems
      ListView {
        id: planList
        width: parent.width
        height: reviewCard.r.plan ? Math.min(reviewCard.r.plan.items.length, 8) * 30 : 0
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        cacheBuffer: 1000000      // every row exists, so Tab walks the whole list and scrolls it
        model: reviewCard.r.plan ? reviewCard.r.plan.items : []
        delegate: Item {
          width: planList.width
          height: 30
          MaintCopyPath { x: 4; anchors.verticalCenter: parent.verticalCenter; width: Math.min(implicitWidth, parent.width - 8 - 8 - sz.width); path: modelData.path; tip: modelData.title
                          onActiveFocusChanged: if (activeFocus) planList.positionViewAtIndex(index, ListView.Contain) }
          Txt { id: sz; anchors.right: parent.right; anchors.rightMargin: 4; anchors.verticalCenter: parent.verticalCenter
                role: "secondary"; color: Theme.secondary; tabular: true; text: F.size(modelData.bytes) }
        }
      }
    }
    MaintRow {
      Txt { width: parent.width; role: "secondary"; color: Theme.secondary; wrapMode: Text.Wrap
            text: cl.review ? F.reviewNote(cl.review, cl.toolTitle, cl.isCodex) : "" }
    }
    MaintRow {
      Item {
        width: parent.width
        height: 28
        PushButton { text: "Cancel"; onClicked: cl.review = null }
        PushButton { anchors.right: parent.right; text: "Move to trash"; icon: "trash"; prominent: true; enabled: !cl.busy; onClicked: cl.confirmApply() }
      }
    }
  }

  // MARK: 7 recoverable trash

  MaintCard {
    visible: !!cl.scan && cl.trash.length > 0
    title: "Recoverable trash"
    accessory: Txt { role: "secondary"; color: Theme.secondary; text: F.plural(cl.trash.length, "batch", "batches") }
    Repeater {
      model: cl.trash
      delegate: MaintRow {
        Item {
          width: parent.width
          height: 32
          Column {
            anchors.verticalCenter: parent.verticalCenter
            spacing: 2
            Txt { text: F.num(modelData.items.length) + " items · " + F.size(modelData.bytes) }
            Txt { role: "secondary"; color: Theme.secondary; tabular: true; text: F.dateTime(modelData.createdAt) }
          }
          Row {
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            spacing: 16
            PushButton { text: "Restore"; enabled: !cl.busy; onClicked: cl.restoreBatch(modelData) }
            PushButton { text: "Remove for good"; enabled: !cl.busy; onClicked: cl.purgeBatch(modelData) }
          }
        }
      }
    }
  }

  // MARK: 8 error

  MaintCard {
    visible: cl.error !== ""
    MaintRow {
      Item {
        width: parent.width
        height: Math.max(16, errText.height)
        Icon { y: 1; name: "info"; size: 14; color: Theme.amber }
        TextEdit {
          id: errText
          x: 22
          width: parent.width - x
          readOnly: true
          selectByMouse: true
          wrapMode: TextEdit.Wrap
          text: cl.error
          color: Theme.label
          selectionColor: Theme.rgba(Theme.accent, 0.3)
          font.family: Theme.fontFamily
          font.pointSize: 13 * Theme.fontScale * 0.75
        }
      }
    }
  }
}
