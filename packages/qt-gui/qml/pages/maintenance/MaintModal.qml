import QtQuick
import QtQuick.Effects
import QtQuick.Window

// A window-modal panel (sheet or alert, maintenance.md 9): blocks the whole window, sits centered under the
// 52 pt top bar on a solid surface with a soft shadow, and fades in. Escape cancels.
Item {
  id: m
  property Item host: null
  property bool open: false
  property real panelWidth: 520
  property color fill: Theme.page
  property real radius: 12
  default property alias content: body.data
  signal cancelled()
  signal returned()

  parent: host
  anchors.fill: parent
  z: 60
  visible: opacity > 0.001
  opacity: open ? 1 : 0
  Behavior on opacity { NumberAnimation { duration: Theme.dAppear; easing.type: Easing.Bezier; easing.bezierCurve: Theme.easeOut } }
  // Opening moves focus into the panel; closing gives it back to the control that had it.
  property Item returnFocus: null
  onOpenChanged: {
    if (open) { returnFocus = Window.activeFocusItem; panel.forceActiveFocus() }
    else if (returnFocus) { returnFocus.forceActiveFocus(); returnFocus = null }
  }
  // Tab and Shift-Tab stay on the panel's controls, as in a Mac sheet: focus that leaves the panel wraps to
  // its first control (Tab) or its last one (Shift-Tab).
  property Item lastInside: null
  function inside(it) { for (var p = it; p; p = p.parent) if (p === panel) return true; return false }
  function chainInside() {
    var out = [], it = panel
    for (var i = 0; i < 1000; ++i) {
      it = it.nextItemInFocusChain(true)
      if (!it || it === panel || out.indexOf(it) >= 0) break
      if (inside(it)) out.push(it)
    }
    // reading order inside the panel (the chain may start part way through it)
    out.sort(function (a, b) { var pa = a.mapToItem(panel, 0, 0), pb = b.mapToItem(panel, 0, 0); return pa.y - pb.y || pa.x - pb.x })
    return out
  }
  Connections {
    target: m.Window.window
    function onActiveFocusItemChanged() {
      var a = m.Window.activeFocusItem
      if (!m.open || !a) return
      if (m.inside(a)) { m.lastInside = a; return }
      var forward = !!m.lastInside && m.lastInside.nextItemInFocusChain(true) === a
      var items = m.chainInside()
      if (items.length > 0) (forward ? items[0] : items[items.length - 1]).forceActiveFocus(forward ? Qt.TabFocusReason : Qt.BacktabFocusReason)
    }
  }

  MouseArea { anchors.fill: parent; hoverEnabled: true; acceptedButtons: Qt.AllButtons; onWheel: function (w) { w.accepted = true } }
  Rectangle { anchors.fill: parent; color: Theme.k(Theme.dark ? 0.25 : 0.12) }

  Item {
    id: panel
    x: Math.round((parent.width - width) / 2)
    y: 52 + 12
    width: m.panelWidth
    height: body.childrenRect.height
    focus: true
    Keys.onEscapePressed: m.cancelled()
    Keys.onReturnPressed: m.returned()
    // From the panel itself, Tab goes to its first control and Shift-Tab to its last.
    Keys.onTabPressed: { var c = m.chainInside(); if (c.length > 0) c[0].forceActiveFocus(Qt.TabFocusReason) }
    Keys.onBacktabPressed: { var c = m.chainInside(); if (c.length > 0) c[c.length - 1].forceActiveFocus(Qt.BacktabFocusReason) }
    Rectangle {
      anchors.fill: parent
      radius: m.radius
      color: m.fill
      border.width: Theme.hair
      border.color: Theme.popoverBorder
      layer.enabled: true
      layer.effect: MultiEffect { shadowEnabled: true; shadowColor: "black"; shadowOpacity: Theme.dark ? 0.55 : 0.22; shadowBlur: 0.9; shadowVerticalOffset: 10 }
    }
    Item { id: body; width: parent.width; height: childrenRect.height }
  }
}
