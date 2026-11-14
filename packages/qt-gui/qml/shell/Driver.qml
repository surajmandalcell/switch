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

  function start(script) {
    if (!Harness || script !== "shots") return
    var s = [1200]
    var only = App.arg("pages", "")   // comma list of page titles; no popover when set
    for (var i = 0; i < win.pages.length; ++i) {
      if (only !== "" && only.split(",").indexOf(win.pages[i].title.toLowerCase()) < 0) continue;
      (function (i) {
        s.push(function () { win.show(i) })
        s.push(700)
        s.push(function () { shot(win, win.pages[i].title.toLowerCase()) })
      })(i)
    }
    if (only !== "") { s.push(function () { Harness.quit(0) }); run(s); return }
    s.push(function () { win.togglePopover(anchor(false)) })
    s.push(900)
    s.push(function () { shot(win.popover, "popover") })
    s.push(function () { win.popover.setExpanded(0) })
    s.push(400)
    s.push(function () { shot(win.popover, "popover-expanded") })
    s.push(function () { win.popover.setExpanded(-1); win.popover.close() })
    s.push(300)
    s.push(function () { win.popoverClosedAt = 0; win.togglePopover(anchor(true)) })
    s.push(900)
    s.push(function () { shot(win.popover, "popover-bottom") })
    s.push(function () { Harness.quit(0) })
    run(s)
  }
}
