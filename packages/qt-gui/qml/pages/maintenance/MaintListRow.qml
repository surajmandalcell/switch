import QtQuick

// CleanupRowBox (gui/CleanupPage.swift:43-65): content on the 16 inset (+ indent), 4 above and below, at
// least `minHeight`, and a hover fill (radius 6) 6 in from the card edges and 2 from the row edges.
Item {
  id: r
  property real indent: 0
  property real minHeight: 36
  property real contentHeight: 16      // the tallest content line; children center on it
  default property alias content: box.data
  readonly property real contentWidth: box.width
  property string name: ""             // the row's visible title, for screen readers
  property bool expandable: false      // a category or project row: a click, Return or Space opens it
  property bool open: false
  signal clicked()

  width: parent ? parent.width : 0
  height: Math.max(minHeight, contentHeight + 8)
  Accessible.role: expandable ? Accessible.Button : Accessible.ListItem
  Accessible.name: name
  Accessible.description: expandable ? (open ? "Expanded" : "Collapsed") : ""
  Accessible.onPressAction: if (expandable) clicked()
  activeFocusOnTab: expandable
  Keys.onSpacePressed: clicked()
  Keys.onReturnPressed: clicked()
  Keys.onEnterPressed: clicked()
  Keys.onRightPressed: if (!open) clicked()
  Keys.onLeftPressed: if (open) clicked()
  FocusFill { x: 6; y: 2; width: parent.width - 12; height: parent.height - 4; anchors.fill: undefined; radius: 6 }

  Rectangle {
    x: 6; y: 2
    width: parent.width - 12
    height: parent.height - 4
    radius: 6
    color: Theme.rowHover
    opacity: hover.hovered && r.enabled ? 1 : 0
    Behavior on opacity { NumberAnimation { duration: Theme.dHover; easing.type: Easing.Bezier; easing.bezierCurve: Theme.easeOut } }
  }
  HoverHandler { id: hover }
  TapHandler { enabled: r.expandable; onTapped: r.clicked() }
  Item {
    id: box
    x: 16 + r.indent
    width: parent.width - 32 - r.indent
    height: r.contentHeight
    anchors.verticalCenter: parent.verticalCenter
  }
}
