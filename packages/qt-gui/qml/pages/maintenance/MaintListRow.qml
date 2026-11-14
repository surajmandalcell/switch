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
  signal clicked()

  width: parent ? parent.width : 0
  height: Math.max(minHeight, contentHeight + 8)

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
  TapHandler { onTapped: r.clicked() }
  Item {
    id: box
    x: 16 + r.indent
    width: parent.width - 32 - r.indent
    height: r.contentHeight
    anchors.verticalCenter: parent.verticalCenter
  }
}
