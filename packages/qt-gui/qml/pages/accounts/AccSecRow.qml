import QtQuick

// One row of a titled section card (AIMSection, account-window.md 2.6): 16 side inset, 8 above and below
// (14 below the last row), at least 36 high except the last, a table-separator hairline between rows.
Item {
  id: r
  property bool last: false
  default property alias content: box.data
  readonly property real ch: box.childrenRect.height
  width: parent ? parent.width : 400
  height: last ? 8 + ch + 14 : Math.max(36, 8 + ch + 8)

  Item {
    id: box
    x: 16
    y: r.last ? 8 : (r.height - r.ch) / 2
    width: parent.width - 32
    height: r.ch
  }
  Rectangle {
    visible: !r.last
    x: 16
    y: parent.height - Theme.hair
    width: parent.width - 32
    height: Theme.hair
    color: Theme.tableSeparator
  }
}
