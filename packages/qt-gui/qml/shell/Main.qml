import QtQuick
import QtQuick.Window

// Main window (shell.md 1, 2): 1200 wide, height-only resizable (min 800), custom 52 pt bar with the
// window buttons, 220 sidebar, page host. Pages build on first visit and stay alive; a switch swaps them
// in one frame with no animation (2.4).
Window {
  id: win
  width: 1200
  height: 900
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
      { title: "Accounts", route: "Accounts", icon: "people", spec: "accounts.md", placeholder: "Search accounts…" },
      { title: "Settings", route: "Settings", icon: "gearFill" },
      { title: "Maintenance", route: "Maintenance", icon: "tools", spec: "maintenance.md" },
      { title: "History", route: "Conversations", icon: "history", spec: "history.md" }
    ]
    if (App.flag("gallery")) p.push({ title: "Gallery", route: "Gallery", icon: "gear" })
    return p
  }
  property int pageIndex: 0
  property string searchQuery: ""
  property var popover: null
  property var restoreRect: null
  property real popoverClosedAt: 0

  function show(i) { if (i >= 0 && i < pages.length) pageIndex = i }
  function page(i) { var l = loaders.itemAt(i); return l ? l.item : null }
  function present() { win.visible = true; if (win.visibility === Window.Minimized) win.showNormal(); win.raise(); win.requestActivate() }
  function refreshAll() { if (Helper.hasMethod("usage.refresh")) Helper.call("usage.refresh", {}, function () {}) }
  function focusSearch() { present(); var p = page(pageIndex); if (p) p.header.focusSearch() }
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
  Component { id: popComp; PopoverWindow { onOpenMain: { close(); win.present() } onOpenSettings: { close(); win.present(); win.show(2) } onQuit: Qt.quit()
                                           onVisibleChanged: if (!visible) win.popoverClosedAt = Date.now() } }
  function togglePopover(rect) {
    if (!popover) popover = popComp.createObject(null)
    if (popover.visible) popover.close()
    else if (Date.now() - popoverClosedAt > 150) popover.open(rect)
  }
  Connections {
    target: Tray
    function onToggleRequested(rect) { win.togglePopover(rect) }
    function onOpenRequested() { win.present() }
    function onRefreshRequested() { win.refreshAll() }
    function onSettingsRequested() { win.present(); win.show(2) }
    function onQuitRequested() { Qt.quit() }
  }

  Shortcut { sequences: ["Ctrl+1"]; onActivated: win.show(0) }
  Shortcut { sequences: ["Ctrl+2"]; onActivated: win.show(1) }
  Shortcut { sequences: ["Ctrl+3", "Ctrl+,"]; onActivated: win.show(2) }
  Shortcut { sequences: ["Ctrl+4"]; onActivated: win.show(3) }
  Shortcut { sequences: ["Ctrl+5"]; onActivated: win.show(4) }
  Shortcut { sequence: "Ctrl+K"; onActivated: win.focusSearch() }
  Shortcut { sequence: "Ctrl+R"; onActivated: win.refreshAll() }
  Shortcut { sequence: "Ctrl+W"; onActivated: win.closeWindow() }
  Shortcut { sequence: "Ctrl+M"; onActivated: win.showMinimized() }
  Shortcut { sequence: "Ctrl+Q"; onActivated: Qt.quit() }

  Driver { id: driver; win: win }

  Component.onCompleted: {
    Theme.dpr = Screen.devicePixelRatio
    Theme.fontFamily = App.fontFamily
    Theme.mode = App.arg("theme", "system")
    Theme.motion = !App.flag("no-motion")
    if (App.flag("content-only")) Theme.windowRadius = 0
    Theme.pageHost = pageHost
    Theme.menu = menu
    Theme.tooltip = tooltip
    var want = App.arg("page", "Overview").toLowerCase()
    for (var i = 0; i < pages.length; ++i) if (pages[i].title.toLowerCase() === want || pages[i].route.toLowerCase() === want) pageIndex = i
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
          sourceComponent: {
            var r = modelData.route
            if (r === "Overview") return overviewPage
            if (r === "Settings") return settingsPage
            if (r === "Gallery") return galleryPage
            return placeholderPage
          }
          onLoaded: if (modelData.spec) { item.title = modelData.title; item.spec = modelData.spec; if (modelData.placeholder) item.placeholder = modelData.placeholder }
        }
      }
      Component { id: overviewPage; OverviewPage {} }
      Component { id: settingsPage; SettingsPage {} }
      Component { id: galleryPage; GalleryPage {} }
      Component { id: placeholderPage; PlaceholderPage {} }
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
    MenuPanel { id: menu; parent: overlay }
    Tooltip { id: tooltip; parent: overlay }
  }
}
