import QtQuick
import "Acc.js" as A

// Account row (accounts.md 2.4): 36 high. Highlight (x 32 .. width - 8, y 2 .. 34, radius 6) for hover,
// keyboard focus and selection; columns: account (flex), usage (340), actions (64 + 8 + 22); separator at
// the top from x 40 (not on the first row of a group); the outline guide at x 23.5.
Item {
  id: r
  property var ctl
  property var table: null
  property var row
  property bool firstInGroup: false
  property bool lastInGroup: false
  readonly property bool selected: ctl.selectedID === row.id
  readonly property bool hovered: hover.hovered
  readonly property var acc: ctl.statusOf(row.id)
  readonly property var w: A.firstWindow(row)
  readonly property string pname: ctl.pname(row.providerID)
  readonly property bool trayHidden: ctl.accountHidden(row.id)
  readonly property real accW: width - 514
  readonly property string action: A.rowAction(row)
  width: parent ? parent.width : 400
  height: 36
  activeFocusOnTab: true
  Keys.onReturnPressed: ctl.select(row.id)
  Keys.onEnterPressed: ctl.select(row.id)
  Accessible.role: Accessible.ListItem
  Accessible.name: row.label
  Accessible.description: row.isDefault ? "Default account" : "Not the default account"
  Accessible.selected: selected

  HoverHandler { id: hover }
  Rectangle {
    x: 32; y: 2
    width: parent.width - 40
    height: 32
    radius: 6
    color: r.selected ? Theme.rowHighlight : (r.activeFocus && App.keyboardMode ? Theme.focusTint : Theme.rowHover)
    opacity: r.selected || r.hovered || (r.activeFocus && App.keyboardMode) ? 1 : 0
    Behavior on opacity { NumberAnimation { duration: Theme.dHover } }
  }
  MouseArea {
    anchors.fill: parent
    acceptedButtons: Qt.LeftButton | Qt.RightButton
    onClicked: function (e) {
      if (e.button === Qt.RightButton) r.ctl.rowMenu(r, e.x, e.y, r.row)
      else r.ctl.select(r.row.id)
    }
  }
  // grip (accounts.md 4.1): x 4..22, hovered row only, drags the row inside its provider
  Item {
    id: grip
    x: 4
    width: 18
    height: 36
    visible: !!r.table
    // pointer-only handle; Move up and Move down in the row menu are its keyboard and reader twin
    Accessible.ignored: true
    opacity: (r.hovered && r.table && r.table.canReorder && !r.table.carried) || gripMa.pressed ? 1 : 0
    Behavior on opacity { NumberAnimation { duration: 120 } }
    Icon { anchors.centerIn: parent; name: "grip"; size: 12; color: gripMa.containsMouse || gripMa.pressed ? Theme.secondary : Theme.tertiary }
    ToolTipArea { text: "Drag to reorder" }
    MouseArea {
      id: gripMa
      anchors.fill: parent
      enabled: !!r.table && r.table.canReorder
      hoverEnabled: true
      preventStealing: true
      cursorShape: pressed ? Qt.ClosedHandCursor : Qt.OpenHandCursor
      onPressed: function (e) { r.table.carried = { id: r.row.id, provider: r.row.providerID, label: r.row.label }; var p = mapToItem(r.table.stackItem, e.x, e.y); r.table.dragTo(p.x, p.y) }
      onPositionChanged: function (e) { if (!pressed) return; var p = mapToItem(r.table.stackItem, e.x, e.y); r.table.dragTo(p.x, p.y) }
      onReleased: r.table.endDrag(true)
      onCanceled: r.table.endDrag(false)
    }
  }

  // column 1: account cell
  Item {
    x: 40
    width: r.accW
    height: parent.height
    Row {
      anchors.verticalCenter: parent.verticalCenter
      spacing: 8
      Txt { id: nm; text: r.row.label; elide: Text.ElideMiddle; anchors.verticalCenter: parent.verticalCenter
            width: Math.min(implicitWidth, r.accW - 18 - 8 - (info.visible ? 22 : 0) - (dot.visible ? 14 : 0))
            ToolTipArea { text: r.row.label } }
      // provider status dot (2.4): amber for minor or maintenance, red for major or critical
      Rectangle {
        id: dot
        readonly property var inc: r.ctl.incident(r.row.providerID)
        visible: !!inc
        anchors.verticalCenter: parent.verticalCenter
        width: 6; height: 6; radius: 3
        color: inc && inc.severity === "critical" ? Theme.red : Theme.amber
        Accessible.name: "Provider status"
        ToolTipArea { margin: 5; text: r.ctl.incidentText(dot.inc) }   // a HoverHandler: margin widens the hover area
      }
      Icon {
        id: info
        visible: !!r.acc && r.acc.autoImported === true
        anchors.verticalCenter: parent.verticalCenter
        name: "info"; size: 12; color: Theme.secondary
        Accessible.name: "Added automatically from the " + r.pname + " login on this Mac."
        ToolTipArea { text: info.Accessible.name }
      }
    }
    Item {
      id: eye
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      width: 18
      height: 18
      opacity: r.hovered || (r.activeFocus && App.keyboardMode) ? 1 : (r.trayHidden ? 0.5 : 0)
      Behavior on opacity { NumberAnimation { duration: Theme.motion ? 180 : 0; easing.type: Easing.OutQuad } }
      Accessible.role: Accessible.Button
      Accessible.name: (r.trayHidden ? "Show account in menu bar" : "Hide account from menu bar") + ": " + r.row.label
      Icon { anchors.centerIn: parent; size: 12; name: r.trayHidden ? "eyeSlash" : "eye"; color: Theme.secondary }
      ToolTipArea { text: r.trayHidden ? "Show account in menu bar" : "Hide account from menu bar" }
      MouseArea { anchors.fill: parent; onClicked: r.ctl.toggleAccount(r.row.id) }
    }
  }

  // column 2: usage cell (340)
  Item {
    x: 40 + r.accW + 12
    width: 340
    height: parent.height
    UsageBar {
      visible: !!r.w
      width: 340 - 8 - 104
      anchors.verticalCenter: parent.verticalCenter
      used: r.w ? r.w.usedPercent : -1
      provider: r.row.providerID
    }
    Row {
      visible: !!r.w
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      width: Math.min(implicitWidth, 104)
      clip: true
      layoutDirection: Qt.RightToLeft
      Txt { id: rst; tabular: true; color: Theme.secondary
            text: r.w && r.w.resetsAt ? " · " + r.ctl.compact(r.w).replace(/^in /, "") : "" }
      RollText { role: "body"; text: r.w ? A.pct(r.w.usedPercent, Theme.showUsed) + "%" : "" }
      ToolTipArea { text: r.w ? A.pct(r.w.usedPercent, Theme.showUsed) + "%" + (r.w.resetsAt ? " · " + r.ctl.compact(r.w) : "") : "" }
    }
    Txt {
      id: why
      visible: !r.w
      anchors.verticalCenter: parent.verticalCenter
      width: parent.width
      role: "secondary"
      color: Theme.secondary
      elide: Text.ElideRight
      text: A.reason(r.row, r.pname, "table")
      ToolTipArea { text: A.reason(r.row, r.pname, "full") }
    }
  }

  // column 3: actions (94)
  Row {
    x: parent.width - 16 - 94
    anchors.verticalCenter: parent.verticalCenter
    spacing: 8
    PushButton {
      controlHeight: 22
      width: 64
      minWidth: 64
      text: r.action
      enabled: r.action === "Default" ? false
             : r.action === "Allow" ? !r.ctl.busy && !r.row.isRefreshing
             : r.action === "Sign in" ? !r.ctl.busy
             : !r.ctl.busy && A.canSwitch(r.row)
      tip: r.action === "Allow" ? "Allow Switch to read Droid's login for usage" : ""
      Accessible.name: r.action === "Default" ? "Using as default" : r.action
      Accessible.description: r.action === "Default" ? "This account is already the default." : (r.action === "Sign in" ? "Signs in to " + r.pname + " again" : "")
      onClicked: r.action === "Allow" ? r.ctl.allow(r.row) : (r.action === "Sign in" ? r.ctl.signIn(r.row) : r.ctl.switchDefault(r.row))
    }
    PushButton {
      id: more
      controlHeight: 22
      square: true
      icon: "ellipsis"
      tip: "More actions for this account"
      Accessible.name: "More actions"
      onClicked: r.ctl.moreMenu(r.row, more)
    }
  }

  // separator and outline guide (2.6)
  Rectangle { visible: !r.firstInGroup; x: 40; width: parent.width - 56; height: Theme.hair; color: Theme.tableSeparator }
  Rectangle { x: 23.5; width: 1; height: r.lastInGroup ? 18.5 : 36; color: Theme.guideLine }
  Rectangle { x: 24.5; y: 18; width: 9; height: 1; color: Theme.guideLine }
}
