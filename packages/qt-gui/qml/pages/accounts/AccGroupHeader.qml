import QtQuick
import "Acc.js" as A

// ServiceGroupHeader (accounts.md 2.3): 32 high; tile 16, name (Secondary semibold, primary color), "×N",
// the tray eye (24 square) at the right; a 1 x 4 guide stub under the tile. Right click: the group menu.
Item {
  id: h
  property var ctl
  property var table: null
  property int groupIndex: 0
  property string provider: ""
  property int count: 0
  readonly property bool trayHidden: ctl.serviceHidden(provider)
  readonly property string name: ctl.pname(provider)
  width: parent ? parent.width : 400
  height: 32
  // the header itself only takes the right-click menu and the group drag; both have menu or keyboard twins
  Accessible.role: Accessible.Grouping
  Accessible.name: h.name + ", " + A.plural(h.count, "account", "accounts")

  HoverHandler { id: hover }
  ProviderTile { x: 16; anchors.verticalCenter: parent.verticalCenter; size: 16; provider: h.provider; name: h.name }
  Row {
    x: 40
    anchors.verticalCenter: parent.verticalCenter
    spacing: 8
    Txt { id: nm; role: "secondary"; wght: 600; color: Theme.label; text: h.name; width: Math.min(implicitWidth, h.width - 40 - 16 - 24 - 60); elide: Text.ElideRight
          ToolTipArea { text: h.name } }
    Txt { role: "secondary"; tabular: true; color: Theme.secondary; text: "×" + h.count }
  }
  Item {
    id: eye
    x: parent.width - 16 - 24
    width: 24
    height: 24
    anchors.verticalCenter: parent.verticalCenter
    activeFocusOnTab: true
    opacity: hover.hovered || (activeFocus && App.keyboardMode) ? 1 : (h.trayHidden ? 0.5 : 0)
    Behavior on opacity { NumberAnimation { duration: Theme.motion ? 180 : 0; easing.type: Easing.OutQuad } }
    Accessible.role: Accessible.Button
    Accessible.name: (h.trayHidden ? "Show in the " : "Hide from the ") + Theme.trayName + ": " + h.name
    Keys.onSpacePressed: h.ctl.toggleService(h.provider)
    FocusFill { radius: 6 }
    Icon { anchors.centerIn: parent; size: 13; name: h.trayHidden ? "eyeSlash" : "eye"; color: Theme.secondary }
    ToolTipArea { text: (h.trayHidden ? "Show in the " : "Hide from the ") + Theme.trayName }
    MouseArea { anchors.fill: parent; onClicked: h.ctl.toggleService(h.provider) }
  }
  Rectangle { x: 23.5; y: 28; width: 1; height: 4; color: Theme.guideLine }
  // right click: the group menu; left drag (4 pt threshold): move the whole group (accounts.md 4.2)
  MouseArea {
    anchors.fill: parent
    z: -1
    acceptedButtons: Qt.LeftButton | Qt.RightButton
    preventStealing: true
    property real startY: 0
    property bool dragging: false
    cursorShape: dragging ? Qt.ClosedHandCursor : Qt.ArrowCursor
    onPressed: function (e) { startY = mapToItem(null, e.x, e.y).y; dragging = false }
    onPositionChanged: function (e) {
      if (!h.table || !h.table.canReorder || !(pressedButtons & Qt.LeftButton)) return
      var dy = mapToItem(null, e.x, e.y).y - startY
      if (!dragging && Math.abs(dy) < 4) return
      dragging = true
      h.table.gFrom = h.groupIndex
      h.table.gDy = dy
    }
    onReleased: function (e) { if (dragging) h.table.endGroupDrag(true); dragging = false }
    onCanceled: { if (dragging) h.table.endGroupDrag(false); dragging = false }
    onClicked: function (e) { if (e.button === Qt.RightButton) h.ctl.groupMenu(h, e.x, e.y, h.provider) }
  }
}
