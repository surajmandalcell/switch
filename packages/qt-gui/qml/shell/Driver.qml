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
  property int gen: 0
  function run(list) { steps = list; idx = 0; gen++; next() }
  function next() {
    var g = gen
    while (idx < steps.length) {
      var s = steps[idx++]
      if (typeof s === "number") { tm.interval = s; tm.start(); return }
      s()
      if (gen !== g) return   // the step started a new run (states()); that run owns the list and the timer now
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
  // --script shortcut: records Ctrl+Alt+S as the menu shortcut, logs the portal state, waits 20 s for an
  // outside press (kglobalaccel invokeShortcut in the test), logs each toggle, and captures Settings.
  function shortcut() {
    App.shortcutActivated.connect(function () {
      Qt.callLater(function () { Harness.log("SHORTCUT activated popover=" + (win.popover ? win.popover.visible : "none")) })
    })
    App.shortcutRefused.connect(function () { Harness.log("SHORTCUT refused") })
    run([2500, function () {
      Harness.log("SHORTCUT available=" + App.globalShortcuts)
      Prefs.set("globalShortcut", { keyCode: App.macKeyCode(Qt.Key_S), modifiers: 4096 | 2048 })   // Ctrl+Alt+S
    }, 20000, function () {
      Harness.log("SHORTCUT stored=" + JSON.stringify(Prefs.value("globalShortcut")))
      // Open at Login round trip (the test reads the autostart file while it is on)
      App.loginEnabled = true
      Harness.log("LOGIN on=" + App.loginEnabled + " error=" + App.loginError)
      // A notification (D-Bus on Linux, the tray balloon or toast on Windows), for a desktop capture to show
      Notify.post("shortcut-test", "Switch", "Notification test", "Posted by the shortcut script.", false)
      Harness.log("NOTIFY posted tray=" + Tray.available)
      win.show(2)
    }, 3000, function () {
      shot(win, "settings-shortcut")
      App.loginEnabled = false
      Harness.log("LOGIN off=" + !App.loginEnabled + " error=" + App.loginError)
      Harness.quit(0)
    }])
  }

  // --script states --page <title>: the shown page's own capture steps (its captureSteps(driver) list).
  function states() {
    run([1200, function () {
      var p = win.page(win.pageIndex)
      if (!p || typeof p.captureSteps !== "function") { Harness.log("NO STATES"); Harness.quit(1); return }
      run(p.captureSteps(d).concat([function () { Harness.quit(0) }]))
    }])
  }

  // --script a11y: accessibility dump. Walks every page, the search drop-down, the menu, the alert and the
  // popover, and logs each interactive item (on the Tab chain, taking clicks, or a control role) with its
  // scope, role, name and path. "A11Y MISSING" = no name, "A11Y NOROLE" = clickable with no role. Then it
  // tabs through Settings, logs the Tab order, and captures the focus tint. Exits 1 when a shared part
  // (shell, header, overlay, popover, Settings) has a defect; page scopes are only reported.
  readonly property var roleNames: {
    var m = {}
    m[Accessible.Button] = "Button"; m[Accessible.CheckBox] = "CheckBox"; m[Accessible.RadioButton] = "RadioButton"
    m[Accessible.ComboBox] = "ComboBox"; m[Accessible.PageTab] = "PageTab"; m[Accessible.PageTabList] = "PageTabList"
    m[Accessible.ListItem] = "ListItem"; m[Accessible.EditableText] = "EditableText"; m[Accessible.Slider] = "Slider"
    m[Accessible.SpinBox] = "SpinBox"; m[Accessible.Link] = "Link"; m[Accessible.MenuItem] = "MenuItem"
    m[Accessible.ButtonMenu] = "ButtonMenu"; m[Accessible.ButtonDropDown] = "ButtonDropDown"; m[Accessible.ScrollBar] = "ScrollBar"
    m[Accessible.Grouping] = "Grouping"; m[Accessible.PopupMenu] = "PopupMenu"; m[Accessible.AlertMessage] = "AlertMessage"
    m[Accessible.List] = "List"; m[Accessible.Table] = "Table"; m[Accessible.Cell] = "Cell"; m[Accessible.StaticText] = "StaticText"
    return m
  }
  function roleName(r) { return roleNames[r] || ("role" + r) }
  function typeName(o) { return String(o).split("(")[0].replace(/_QMLTYPE_\d+|_QML_\d+/, "") }
  function hint(it, depth) {
    if (typeof it.text === "string" && it.text !== "") return it.text
    if (typeof it.tip === "string" && it.tip !== "") return "tip " + it.tip
    if (typeof it.icon === "string" && it.icon !== "") return "icon " + it.icon
    if (depth > 0) for (var i = 0; i < it.children.length; ++i) { var h = hint(it.children[i], depth - 1); if (h) return h }
    return ""
  }
  function clicks(it) {
    for (var i = 0; i < it.children.length; ++i) {
      var c = it.children[i]
      if ("pressAndHoldInterval" in c && c.visible && c.enabled && c.acceptedButtons !== Qt.NoButton && !c.Accessible.ignored) return true
    }
    for (var k = 0; k < it.resources.length; ++k) if ("tapCount" in it.resources[k] && it.resources[k].enabled) return true
    return false
  }
  property var seen: new Set()
  property var tally: ({})
  property bool a11yBad: false
  function walk(it, scope, path) {
    if (!it || !it.visible) return
    var fresh = !seen.has(it)   // walk again (new pages and rows appear below), report once
    seen.add(it)
    if (it.objectName === "page-header") scope = "header"
    else if (Theme.pageHost && it.parent === Theme.pageHost && "status" in it) scope = "page:" + win.pages[win.pageIndex].title
    var name = it.objectName !== "" ? it.objectName : typeName(it)
    path = path.concat([name]).slice(-5)
    var acc = it.Accessible
    var control = acc.role in roleNames && [Accessible.PageTabList, Accessible.ScrollBar, Accessible.Grouping, Accessible.PopupMenu,
                                            Accessible.AlertMessage, Accessible.List, Accessible.Table, Accessible.Cell,
                                            Accessible.StaticText].indexOf(acc.role) < 0
    if (fresh && !acc.ignored && (it.activeFocusOnTab || control || clicks(it))) {
      var t = tally[scope] || (tally[scope] = { items: 0, missing: 0, norole: 0 })
      t.items++
      var shared = scope.indexOf("page:") !== 0 || scope === "page:Settings"
      var line = scope + " " + roleName(acc.role) + " \"" + acc.name + "\" " + path.join("/") + " [" + hint(it, 3) + "]"
      if (acc.name === "") { t.missing++; Harness.log("A11Y MISSING " + line); if (shared) a11yBad = true }
      else if (!(acc.role in roleNames)) { t.norole++; Harness.log("A11Y NOROLE " + line); if (shared) a11yBad = true }
      else Harness.log("A11Y OK " + line)
    }
    for (var i = 0; i < it.children.length; ++i) walk(it.children[i], scope, path)
  }
  function focusDesc() {
    var a = win.activeFocusItem
    return a ? typeName(a) + " " + roleName(a.Accessible.role) + " \"" + a.Accessible.name + "\" [" + hint(a, 2) + "] focus=" + a.activeFocus + " keyboard=" + App.keyboardMode : "none"
  }
  function a11y() {
    var s = [1200]
    for (var i = 0; i < win.pages.length; ++i) (function (i) {
      s.push(function () { win.show(i) }, 700, function () { walk(win.contentItem, "shell", []) })
    })(i)
    // search drop-down (Overview), the More menu, a Rename-style alert with a field, the expanded popover
    s.push(function () { win.show(0); win.searchQuery = "a"; win.searchFocused = true }, 400,
           function () { walk(win.contentItem, "shell", []); win.searchFocused = false; win.searchQuery = "" })
    s.push(function () { Theme.menu.open(win.page(0).header, ["Refresh All Usage", "Add Account", "-", "Settings"], -1, null) }, 200,
           function () { walk(Theme.menu, "menu", []); Theme.menu.close() })
    s.push(function () { Theme.alert.open({ title: "Rename account", message: "Shown in Switch only.", action: "Rename", field: "Work", fieldLabel: "Name" }) }, 200,
           function () { walk(Theme.alert, "alert", []) },
           function () { Harness.key(win, Qt.Key_Tab) }, 200, function () { shot(win, "a11y-focus-alert") },
           function () { Theme.alert.close() })
    s.push(function () { win.togglePopover(anchor(false)) }, 900,
           function () { if (win.popover) { win.popover.setExpanded(0) } }, 400,
           function () { if (win.popover) { walk(win.popover.contentItem, "popover", []); win.popover.close() } }, 300)
    // Tab order: from the sidebar through the Settings header and rows; capture the first of each control kind
    var kinds = {}
    s.push(function () { win.show(2); win.requestActivate(); win.contentItem.forceActiveFocus() }, 500)
    for (var n = 1; n <= 45; ++n) (function (n) {
      s.push(function () { Harness.key(win, Qt.Key_Tab) }, 80, function () {
        Harness.log("TAB " + n + " " + focusDesc())
        var a = win.activeFocusItem
        var k = a ? (a.objectName.indexOf("sidebar-") === 0 ? "sidebar" : roleName(a.Accessible.role)) : ""
        if (k !== "" && !kinds[k]) { kinds[k] = true; shot(win, "a11y-focus-" + k.toLowerCase()) }
      })
    })(n)
    s.push(function () {
      for (var sc in tally) Harness.log("A11Y COUNT " + sc + " items=" + tally[sc].items + " missing=" + tally[sc].missing + " norole=" + tally[sc].norole)
      Harness.quit(a11yBad ? 1 : 0)
    })
    run(s)
  }

  // --script popactions --homes <a,b,c>: on a real helper with a temporary root, imports three synthetic Codex
  // homes (the container script marks the third signed out), then clicks the popover's account eye, service eye, Switch, Open
  // and Sign in, logging the stored setting, the tray topic, and the action outcome after each (ACT lines).
  function trayRows() {
    var g = Helper.topics.tray && Helper.topics.tray.groups ? Helper.topics.tray.groups : [], out = []
    for (var i = 0; i < g.length; ++i) for (var j = 0; j < g[i].rows.length; ++j) out.push(g[i].rows[j])
    return out
  }
  function logTray(tag) {
    var g = Helper.topics.tray && Helper.topics.tray.groups ? Helper.topics.tray.groups : []
    Harness.log("ACT " + tag + " groups=" + g.map(function (x) { return x.providerID + (x.showsInTray ? "" : "(hidden)") }).join(",")
                + " rows=" + trayRows().map(function (r) { return r.id.slice(0, 8) + (r.isDefault ? "*" : "") + (r.showsInTray ? "" : "(hidden)")
                                                            + (r.prompt ? "[" + r.promptButton + "]" : "") }).join(","))
  }
  function popClick(name) {
    var it = win.popover ? find(win.popover.contentItem, name) : null
    if (!it || !it.visible) { Harness.log("ACT MISSING " + name); return }
    var p = it.mapToItem(null, it.width / 2, it.height / 2)
    Harness.click(win.popover, p.x, p.y)
  }
  function popActions() {
    var other = "", first = ""
    function pickRows() { var r = trayRows(); first = r.length ? r[0].id : ""; other = ""
                          for (var i = 0; i < r.length; ++i) if (!r[i].isDefault && !r[i].prompt) other = r[i].id }
    function open() { win.popoverClosedAt = 0; if (!win.popover || !win.popover.visible) win.togglePopover(anchor(false)) }
    function stored(k) { return JSON.stringify(Prefs.stored[k] || []) }
    function importHome(folder) {
      Helper.call("import.plan", { source: folder, mode: "authOnly" }, function (r, e) {
        if (e || !r) { Harness.log("ACT import.plan error " + (e ? e.code + " " + e.message : "")); return }
        var plan = r.plan || r
        Helper.call("import.commit", { planID: plan.planID }, function (r2, e2) { Harness.log("ACT import.commit " + (e2 ? "error " + e2.code + " " + e2.message : "ok")) })
      })
    }
    // three homes: --homes a,b,c; the container script marks the third one signed out once it is saved
    var homes = App.arg("homes", "").split(",")
    run([2500, function () { importHome(homes[0]) }, 2500, function () { importHome(homes[1]) }, 2500, function () { importHome(homes[2]) },
    6000, function () { Helper.call("app.refresh", {}, function () {}) }, 3000,
    function () { pickRows(); logTray("start"); open() }, 1200, function () { shot(win.popover, "act-1-open") },
    // account eye on the non-default row, then back
    function () { var row = find(win.popover.contentItem, "pop-row-" + other); var eye = row ? find(row, "eye") : null
                  if (!eye) { Harness.log("ACT MISSING eye"); return }
                  var p = eye.mapToItem(null, eye.width / 2, eye.height / 2); Harness.click(win.popover, p.x, p.y) }, 1500,
    function () { Harness.log("ACT eye stored menuBarHiddenAccounts=" + stored("menuBarHiddenAccounts")); logTray("after-account-eye"); shot(win.popover, "act-2-account-eye") },
    function () { var row = find(win.popover.contentItem, "pop-row-" + other), eye = find(row, "eye"), p = eye.mapToItem(null, eye.width / 2, eye.height / 2)
                  Harness.click(win.popover, p.x, p.y) }, 1500,
    function () { Harness.log("ACT eye restored menuBarHiddenAccounts=" + stored("menuBarHiddenAccounts")); logTray("after-account-eye-2") },
    // service eye, then back
    function () { popClick("pop-svc-eye-codex") }, 1500,
    function () { Harness.log("ACT svc stored menuBarHiddenServices=" + stored("menuBarHiddenServices")); logTray("after-service-eye"); shot(win.popover, "act-3-service-eye") },
    function () { popClick("pop-svc-eye-codex") }, 1500,
    function () { Harness.log("ACT svc restored menuBarHiddenServices=" + stored("menuBarHiddenServices")); logTray("after-service-eye-2") },
    // Switch on the non-default row
    function () { var r = trayRows(); for (var i = 0; i < r.length; ++i) if (r[i].id === other) win.popover.setExpanded(i) }, 600,
    function () { shot(win.popover, "act-4-expanded"); var row = find(win.popover.contentItem, "pop-row-" + other), b = row ? find(row, "act-Switch") : null
                  if (!b) { Harness.log("ACT MISSING act-Switch"); return }
                  var p = b.mapToItem(null, b.width / 2, b.height / 2); Harness.click(win.popover, p.x, p.y) }, 2500,
    function () { Harness.log("ACT switch result=" + win.lastPopAction + " popoverVisible=" + win.popover.visible); logTray("after-switch") },
    // Open Codex on the (new) default row
    function () { pickRows(); open() }, 1000,
    function () { var r = trayRows(), id = ""; for (var i = 0; i < r.length; ++i) if (r[i].isDefault) { id = r[i].id; win.popover.setExpanded(i) }
                  first = id }, 600,
    function () { var row = find(win.popover.contentItem, "pop-row-" + first), b = row ? find(row, "act-Open Codex") : null
                  if (!b) { Harness.log("ACT MISSING act-Open Codex"); return }
                  var p = b.mapToItem(null, b.width / 2, b.height / 2); Harness.click(win.popover, p.x, p.y) }, 2500,
    function () { Harness.log("ACT open result=" + win.lastPopAction + " popoverVisible=" + win.popover.visible) },
    // Sign in on the signed-out row
    function () { logTray("before-signin"); open() }, 1200,
    function () { shot(win.popover, "act-5-prompt"); var r = trayRows(), id = ""
                  for (var i = 0; i < r.length; ++i) if (r[i].prompt) id = r[i].id
                  if (!id) { Harness.log("ACT NO PROMPT ROW"); return }
                  var row = find(win.popover.contentItem, "pop-row-" + id), b = row ? find(row, "act-prompt") : null
                  var p = b.mapToItem(null, b.width / 2, b.height / 2); Harness.click(win.popover, p.x, p.y) }, 2500,
    function () { var a = win.page(1)
                  Harness.log("ACT signin result=" + win.lastPopAction + " popoverVisible=" + win.popover.visible + " page=" + win.pages[win.pageIndex].route
                              + " sheet=" + (a && a.sheet ? a.sheet.visible : "none")); shot(win, "act-6-signin") },
    function () { Harness.quit(0) }])
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
    if (Harness && script === "shortcut") return shortcut()
    if (Harness && script === "states") return states()
    if (Harness && script === "a11y") return a11y()
    if (Harness && script === "popactions") return popActions()
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
