import QtQuick
import QtQuick.Window
import "ChatMarkdown.js" as MD

// History capture and check run (--script history, harness builds only): every state of the page in one theme,
// the parser self-check, a copy check, and frame times while both lists scroll end to end.
Item {
  id: d
  property var page
  readonly property var win: Window.window
  property var steps: []
  property int idx: 0
  readonly property bool active: !!Harness && App.arg("script", "") === "history"

  Timer { id: tm; onTriggered: d.next() }
  // a step that waits (up to `ms`) until cond() is true; the real helper can need tens of seconds to index
  property var waitCond: null
  Timer { id: poll; interval: 200; repeat: true; property int left: 0
          onTriggered: if (d.waitCond() || --left <= 0) { stop(); d.next() } }
  function waitFor(cond, ms) { return function () { d.waitCond = cond; poll.left = ms / 200; poll.start(); return true } }
  function next() {
    while (idx < steps.length) {
      var s = steps[idx++]
      if (typeof s === "number") { tm.interval = s; tm.start(); return }
      if (s() === true) return   // the step calls next() itself
    }
  }
  function tag() { return (Theme.dark ? "dark" : "light") + "@" + App.arg("scale", "1") + "x" }
  function shot(name) { Harness.log("SHOT " + name + "-" + tag() + " " + Harness.shot(win, name + "-" + tag())) }
  function focusName() {
    var f = win.activeFocusItem
    if (!f) return "none"
    var t = f.text !== undefined && f.textFormat !== TextEdit.RichText ? String(f.text).replace(/\s+/g, " ").substring(0, 24) : ""
    return String(f).split("(")[0].replace(/_QML.*/, "") + (f.objectName ? "#" + f.objectName : "") + (t ? ":" + t : "")
  }
  function tabUntil(pred, max) {
    for (var k = 0; k < max; ++k) { Harness.key(win, Qt.Key_Tab); if (win.activeFocusItem && pred(win.activeFocusItem)) return true }
    return false
  }
  function at(item, fx, fy) { var p = item.mapToItem(null, item.width * fx, item.height * fy); return p }

  // frame times while a list scrolls from top to bottom at `step` pt per frame
  property var times: []
  property var list: null
  property real step: 60
  property var after: null
  property string perfName: ""
  FrameAnimation {
    id: fa
    running: false
    onTriggered: {
      d.times.push(frameTime * 1000)
      if (!d.list) { probe.opacity = 1 - probe.opacity; if (d.times.length > 150) { stop(); d.report(); d.after() } return }
      var before = d.list.view.contentY
      d.list.scrollBy(d.step)
      d.alive = Math.max(d.alive, d.list.view.contentItem.children.length)
      if (d.list.view.contentY <= before + 0.01 && !d.page.pageLoading) {
        stop()
        d.report()
        d.after()
      }
    }
  }
  // a whole-window repaint with no list work: the renderer's own cost per frame on this host
  Rectangle { id: probe; width: 1; height: 1; color: "red"; opacity: 0 }
  function report() {
    Harness.log("PERFEND " + d.perfName)
    var t = d.times.slice(2).sort(function (a, b) { return a - b })
    if (t.length === 0) { Harness.log("PERF " + d.perfName + " no frames"); return }
    var sum = 0; for (var k = 0; k < t.length; ++k) sum += t[k]
    Harness.log("PERF " + d.perfName + " frames=" + t.length + " avgMs=" + (sum / t.length).toFixed(1) + " p50Ms=" + t[Math.floor(t.length * 0.5)].toFixed(1)
                + " p95Ms=" + t[Math.floor(t.length * 0.95)].toFixed(1) + " maxMs=" + t[t.length - 1].toFixed(1)
                + " over20ms=" + t.filter(function (x) { return x > 20 }).length + (d.list ? " rows=" + d.list.view.count : ""))
    // GUI thread CPU over the whole pass (QML, bindings, incubation, polish, sync); the render thread is not in it
    var gui = guiCpuMs() - d.cpu0, made = d.page.delegatesMade - d.made0, perFrame = gui / d.times.length
    if (!d.list) { d.idleGui = perFrame; Harness.log("CPU " + d.perfName + " guiMsPerFrame=" + perFrame.toFixed(2)); return }
    Harness.log("CPU " + d.perfName + " frames=" + d.times.length + " guiMsPerFrame=" + perFrame.toFixed(2) + " guiMsTotal=" + gui
                + " delegatesMade=" + made + " msPerDelegate=" + (made ? ((gui - d.idleGui * d.times.length) / made).toFixed(2) : "0")
                + " aliveMax=" + d.alive + " " + mem())
  }
  property real t0: 0
  property real cpu0: 0
  property int made0: 0
  property real idleGui: 0
  property int alive: 0
  // utime + stime of the main (GUI) thread in ms, from /proc/self/task/<pid>/stat (10 ms ticks)
  function guiCpuMs() {
    var pid = readFile("/proc/self/stat").split(" ")[0]
    var st = readFile("/proc/self/task/" + pid + "/stat")
    var f = st.substring(st.lastIndexOf(")") + 2).split(" ")
    return (Number(f[11]) + Number(f[12])) * 10
  }
  // RSS, peak RSS and PSS of the app from /proc (Linux; needs QML_XHR_ALLOW_FILE_READ=1)
  function readFile(p) { var x = new XMLHttpRequest(); x.open("GET", "file://" + p, false); try { x.send(); return x.responseText } catch (e) { return "" } }
  function kb(text, key) { var m = new RegExp("^" + key + ":\\s+(\\d+)", "m").exec(text); return m ? Math.round(m[1] / 1024) + "MB" : "?" }
  function mem() { var s = readFile("/proc/self/status"); return "rss=" + kb(s, "VmRSS") + " peakRss=" + kb(s, "VmHWM") + " pss=" + kb(readFile("/proc/self/smaps_rollup"), "Pss") }
  function perf(name, list, cont, stepPx) {
    perfName = name; d.list = list; times = []; alive = 0; after = cont; step = stepPx || 60
    if (list) list.scrollTo(-1e9)
    cpu0 = guiCpuMs(); made0 = page.delegatesMade
    Harness.log("PERFBEGIN " + name)
    fa.start()
  }

  // Real helper only (make-transcripts.py "Edge:" threads; real.sh deletes the removed one on "EDGE ready-to-remove")
  function edgeId(prefix) { for (var k = 0; k < page.threads.length; ++k) if (page.threads[k].title.indexOf(prefix) === 0) return page.threads[k].id; return "" }
  function openEdge(s, p, prefix) {
    s.push(function () { d.t0 = Date.now(); p.selectChat(edgeId(prefix)) })
    s.push(waitFor(function () { return (!!p.detail && !p.chatLoading && p.detail.thread.title.indexOf(prefix) === 0) || p.listError !== "" }, 120000))
    s.push(function () { Harness.log("EDGE open " + JSON.stringify(prefix) + " in " + (Date.now() - d.t0) + " ms, first page " + p.messages.length + " messages") })
    s.push(500)
  }
  function edgeSteps(s, p) {
    s.push(function () { p.threadSearch.text = "" })
    openEdge(s, p, "Edge: 5,000")
    s.push(function () { perf("huge-5000", p.messageList, function () { d.next() }, 600); return true })
    s.push(function () { Harness.log("EDGE huge loaded=" + p.messages.length + " rows=" + p.msgModel.count + " " + mem()); shot("history-edge-huge") })
    openEdge(s, p, "Edge: a 2,000")
    s.push(function () {
      var m = p.messages[p.messages.length - 1], code = null
      m.pres.blocks.forEach(function (b) { if (b.type === "code") code = b })
      shot("history-edge-code")
      var t0 = Date.now(); p.toggleBlock(m.id, code.id); p.messageList.view.forceLayout()
      Harness.log("EDGE code previewLines=" + MD.lineCount(code.preview) + " fullLines=" + MD.lineCount(code.expanded || "") + " expandMs=" + (Date.now() - t0))
    })
    s.push(800)
    s.push(function () { p.messageList.scrollBy(1500); shot("history-edge-code-open") })
    openEdge(s, p, "Edge: broken")
    s.push(function () { Harness.log("EDGE broken messages=" + p.messages.length + " warning=" + JSON.stringify(p.warningText)); shot("history-edge-broken") })
    openEdge(s, p, "Edge: right to left")
    s.push(function () { Harness.log("EDGE rtl messages=" + p.messages.length); shot("history-edge-rtl") })
    // real.sh deletes the transcript when it sees this line, then the open chat is reloaded
    s.push(function () { Harness.log("EDGE ready-to-remove listed=" + (edgeId("Edge: removed") !== "")) })
    s.push(4000)
    s.push(function () { p.selectChat(edgeId("Edge: removed")) })
    s.push(2000)
    s.push(function () { Harness.log("EDGE removed detail=" + !!p.detail + " error=" + JSON.stringify(p.listError)); shot("history-edge-removed"); p.listSig = ""; p.refreshList() })
    s.push(2000)
    s.push(function () { Harness.log("EDGE removed after refresh total=" + p.total + " listed=" + (edgeId("Edge: removed") !== "") + " selected=" + JSON.stringify(p.selectedID.split("/").pop())) })
  }

  Component.onCompleted: if (active) start()
  function start() {
    var p = page
    var s = [waitFor(function () { return p.threads.length > 2 && !!p.detail && !p.chatLoading }, 120000), 1200]
    s.push(function () {
      var fails = MD.selfCheck()
      Harness.log(fails.length ? "SELFCHECK FAIL " + fails.join(" ; ") : "SELFCHECK ok")
      var y = new Date().getFullYear(), cur = new Date(y, 0, 9, 17, 33), old = new Date(y - 1, 9, 26, 17, 33)
      Harness.log("DATES locale=" + Qt.locale().name + " row=" + p.fmtTime(cur) + " | day=" + p.dayTitle(cur) + " | dayOld=" + p.dayTitle(old)
                  + " | strip=" + p.msgDate(cur.toISOString()) + " | stripOld=" + p.msgDate(old.toISOString())
                  + " | context=" + p.context({ appSource: "exec", model: "m", updatedAt: old.toISOString() }))
      if (App.flag("dates-only")) { shot("history-main"); Harness.quit(0); return true }
      shot("history-main")
    })
    // hover a row with real pointer input, then the row's context menu
    s.push(function () { var q = at(p.threadList.view.itemAtIndex(2), 0.5, 0.5); Harness.move(win, q.x, q.y) })
    s.push(400)
    s.push(function () { shot("history-hover"); var it = p.threadList.view.itemAtIndex(1); Theme.menu.open(it, ["Copy title"], -1, function () { p.copyText(it.thread.title) }) })
    s.push(300)
    s.push(function () { shot("history-menu"); Theme.menu.choose(0) })
    s.push(200)
    s.push(function () { Harness.log("COPY title=" + JSON.stringify(p.lastCopied)); Harness.move(win, 100, win.height - 40) })  // the hover tooltip goes away
    // collapse "Repository" (block 2) and "Inputs" (block 5)
    s.push(function () { p.toggleBlock(p.messages[0].id, 2); p.toggleBlock(p.messages[0].id, 5) })
    s.push(400)
    s.push(function () { shot("history-collapsed"); p.toggleBlock(p.messages[0].id, 2); p.toggleBlock(p.messages[0].id, 5) })
    s.push(function () { p.messageList.view.positionViewAtIndex(0, ListView.Beginning); p.messageList.scrollBy(560) })
    s.push(400)
    s.push(function () { shot("history-table") })
    s.push(function () { p.messageList.view.positionViewAtIndex(1, ListView.Beginning) })
    s.push(400)
    s.push(function () { shot("history-rich") })
    s.push(function () { p.messageList.view.positionViewAtIndex(3, ListView.Beginning) })
    s.push(400)
    s.push(function () { shot("history-code"); p.messageList.scrollBy(10000) })
    s.push(400)
    s.push(function () { shot("history-code-end") })
    // the Copy button with real input: visible messages, raw text
    s.push(function () { p.messageList.scrollTo(-1e9); var q = at(p.messageSearch, 0.08, 1); Harness.click(win, q.x, q.y + 12 + 16) })
    s.push(200)
    s.push(function () { Harness.log("COPY visible=" + p.lastCopied.length + " chars, starts " + JSON.stringify(p.lastCopied.substring(0, 60))); shot("history-copied"); Harness.move(win, 100, win.height - 40) })
    // role filter: Tools off
    s.push(function () { p.toggleFilter(4) })
    s.push(700)
    s.push(function () { shot("history-filter"); p.toggleFilter(4) })
    s.push(700)
    s.push(function () { p.messageSearch.text = "response 1" })
    s.push(900)
    s.push(function () { shot("history-search"); p.messageSearch.text = "zzzz" })
    s.push(900)
    s.push(function () { shot("history-nomatch"); p.messageSearch.text = "" })
    s.push(700)
    s.push(function () { p.threadSearch.text = "zzzz" })
    s.push(700)
    s.push(function () { shot("history-noresults"); p.threadSearch.text = "scroll" })
    s.push(700)
    s.push(function () { shot("history-query"); p.threadSearch.text = "" })
    s.push(700)
    // a click on the long-title row (real input)
    s.push(function () { var q = at(p.threadList.view.itemAtIndex(2), 0.5, 0.5); Harness.click(win, q.x, q.y) })
    s.push(700)
    s.push(function () { shot("history-long"); Harness.move(win, 100, win.height - 40) })
    // keyboard path with real key events: search field, Tab through the chain, filter by Space, list by Down, fold by Space
    s.push(function () { p.threadSearch.input.forceActiveFocus(); Harness.key(win, Qt.Key_Shift) })
    s.push(300)
    s.push(function () { shot("history-focus-search"); var chain = []
      for (var k = 0; k < 7; ++k) { Harness.key(win, Qt.Key_Tab); chain.push(focusName()) }
      Harness.log("KEYS tab chain: " + chain.join(" > ")) })
    s.push(function () { p.messageSearch.input.forceActiveFocus(); tabUntil(function (f) { return f.text === "Prompts" }, 6) })
    s.push(300)
    s.push(function () { shot("history-focus-filter"); var m0 = p.filterMask; Harness.key(win, Qt.Key_Space, 0, " "); var m1 = p.filterMask
      Harness.key(win, Qt.Key_Space, 0, " "); Harness.log("KEYS space on Prompts: mask " + m0 + " -> " + m1 + " -> " + p.filterMask) })
    s.push(700)
    s.push(function () { var a = p.selectedID; p.threadList.view.forceActiveFocus(); Harness.key(win, Qt.Key_Down); Harness.log("KEYS down in list: moved=" + (a !== p.selectedID)); Harness.key(win, Qt.Key_Up) })
    s.push(900)
    s.push(function () { p.selectChat(p.threads[0].id) })   // the Markdown prompt with foldable sections
    s.push(1200)
    s.push(function () {
      p.messageList.scrollTo(-1e9); p.messageList.view.forceActiveFocus()
      var chain = [], ok = false
      for (var k = 0; k < 10 && !ok; ++k) { Harness.key(win, Qt.Key_Tab); chain.push(focusName()); ok = win.activeFocusItem && win.activeFocusItem.objectName === "sectionHead" }
      Harness.log("KEYS message tab chain: " + chain.join(" > "))
      if (ok) shot("history-focus-section")
      var mid = p.messages[0].id, before = (p.toggled[mid] || []).length
      Harness.key(win, Qt.Key_Space, 0, " "); var mid1 = (p.toggled[mid] || []).length
      Harness.key(win, Qt.Key_Space, 0, " ")
      Harness.log("KEYS fold by Space: found=" + ok + " toggled " + before + " -> " + mid1 + " -> " + (p.toggled[mid] || []).length)
      p.titleSel.forceActiveFocus(); p.titleSel.selectAll(); Harness.key(win, Qt.Key_C, Qt.ControlModifier)
      Harness.log("KEYS title selectable: selected=" + JSON.stringify(p.titleSel.selectedText.substring(0, 30)))
      p.threadList.view.forceActiveFocus()
    })
    s.push(300)
    s.push(function () { p.listError = "The chat library could not refresh. The sessions folder is not readable." })
    s.push(300)
    s.push(function () { shot("history-error"); p.listError = "" })
    s.push(function () { p.selectedID = ""; p.detail = null; p.messages = [] })
    s.push(400)
    s.push(function () { shot("history-noselect") })
    s.push(function () { p.listLoading = true; p.threads = []; p.threadIndex = ({}) })
    s.push(400)
    s.push(function () { shot("history-loading"); p.listLoading = false })
    s.push(300)
    s.push(function () { shot("history-empty"); p.listSig = ""; p.refreshList() })
    s.push(900)
    // frame times: the 530-message thread (pages load while it scrolls), then the 1,098-row thread list
    s.push(function () { p.selectChat(p.threads[0].id) })
    s.push(1200)
    s.push(function () {
      perf("repaint-only", null, function () { perf("messages", p.messageList, function () { perf("threads", p.threadList, function () { d.next() }) }) })
      return true
    })
    s.push(function () { shot("history-scrolled") })
    if (!p.demo) edgeSteps(s, p)
    s.push(function () { Harness.quit(0) })
    steps = s
    idx = 0
    next()
  }
}
