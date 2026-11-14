import QtQuick

// Scripted capture runs (--script shots): every page, the popover (top and bottom arrow, collapsed and
// expanded) and, with --gallery, the component gallery. Files are named <surface>-<theme>@<scale>x.png.
// Input goes through the harness, so it takes the same path as real pointer events.
Item {
  id: d
  property var win
  property var steps: []
  property int idx: 0

  Timer { id: tm; onTriggered: d.next() }
  function run(list) { steps = list; idx = 0; next() }
  function next() {
    while (idx < steps.length) {
      var s = steps[idx++]
      if (typeof s === "number") { tm.interval = s; tm.start(); return }
      s()
    }
  }
  function tag() { return (Theme.dark ? "dark" : "light") + "@" + App.arg("scale", "1") + "x" }
  function shot(w, surface) { Harness.log("SHOT " + surface + "-" + tag() + " " + Harness.shot(w, surface + "-" + tag())) }
  function anchor(bottom) {
    var a = App.workArea(win)
    return Qt.rect(a.x + a.width / 2 - 12, bottom ? a.y + a.height : a.y - 24, 24, 24)
  }

  function find(item, name) {
    if (item.objectName === name) return item
    for (var i = 0; i < item.children.length; ++i) { var f = find(item.children[i], name); if (f) return f }
    return null
  }
  function clickItem(name) {
    var it = find(win.contentItem, name)
    if (!it) { Harness.log("MISSING " + name); return }
    var p = it.mapToItem(null, it.width / 2, it.height / 2)
    Harness.click(win, p.x, p.y)
  }
  // --script prefs [--toggle KEY]: logs a setting's stored value; with --toggle it clicks that row's switch
  // first, so two runs on one --root prove a write survives a restart.
  function prefs() {
    var key = App.arg("toggle", "minimizeToTray")
    var s = [1500, function () { win.show(2) }, 500]
    if (App.flag("toggle")) s.push(function () { clickItem("pref-" + key) }, 1500)
    s.push(function () { Harness.log("PREF " + key + " shown=" + Prefs.value(key) + " stored=" + Prefs.stored[key] + " status=" + Helper.status) })
    s.push(function () { Harness.quit(0) })
    run(s)
  }

  // --script states --page <title>: the shown page's own capture steps (its captureSteps(driver) list).
  function states() {
    run([1200, function () {
      var p = win.page(win.pageIndex)
      if (!p || typeof p.captureSteps !== "function") { Harness.log("NO STATES"); Harness.quit(1); return }
      run(p.captureSteps(d).concat([function () { Harness.quit(0) }]))
    }])
  }

  // A page or popover that failed to load is logged as FAILED and still captured (its placeholder); the run
  // goes on and exits 1 at the end only because of those failures.
  property var failed: []
  function done() {
    if (failed.length) Harness.log("FAILED " + failed.join(", "))
    Harness.quit(failed.length ? 1 : 0)
  }
  function start(script) {
    if (Harness && script === "prefs") return prefs()
    if (Harness && script === "states") return states()
    if (!Harness || script !== "shots") return
    var s = [1200]
    var only = App.arg("pages", "")   // comma list of page titles; no popover when set
    for (var i = 0; i < win.pages.length; ++i) {
      if (only !== "" && only.split(",").indexOf(win.pages[i].title.toLowerCase()) < 0) continue;
      (function (i) {
        s.push(function () { win.show(i) })
        s.push(700)
        s.push(function () {
          var name = win.pages[i].title.toLowerCase()
          if (win.pageFailure(i)) { failed.push(name); Harness.log("FAILED " + name + ": " + win.pageFailure(i)) }
          shot(win, name)
        })
      })(i)
    }
    if (only !== "") { s.push(done); run(s); return }
    s.push(function () { win.togglePopover(anchor(false)) })
    s.push(900)
    s.push(function () { if (!win.popover) { failed.push("popover"); Harness.log("FAILED popover"); steps = [done]; idx = 0 } })
    s.push(function () { shot(win.popover, "popover") })
    s.push(function () { win.popover.setExpanded(0) })
    s.push(400)
    s.push(function () { shot(win.popover, "popover-expanded") })
    s.push(function () { win.popover.setExpanded(-1); win.popover.close() })
    s.push(300)
    s.push(function () { win.popoverClosedAt = 0; win.togglePopover(anchor(true)) })
    s.push(900)
    s.push(function () { shot(win.popover, "popover-bottom") })
    s.push(done)
    run(s)
  }
}
