import QtQuick

// One row of a MaintSection (AIMRows, maintenance.md 1.4): 16 inset, 8 above and below, at least 36 tall,
// a table separator above every row but the first. An untitled section's first row has 14 above; the
// last row always has 14 below and no minimum height. Content is centered in the row.
Item {
  id: row
  default property alias content: box.data
  readonly property bool maintRow: true
  readonly property var rows: {
    var c = parent ? parent.visibleChildren : [], out = []
    for (var i = 0; i < c.length; ++i) if (c[i].maintRow) out.push(c[i])
    return out
  }
  readonly property bool first: rows.length > 0 && rows[0] === row
  readonly property bool last: rows.length > 0 && rows[rows.length - 1] === row
  readonly property bool titled: !!(parent && parent.parent && parent.parent.title)
  readonly property real padTop: first && !titled ? 14 : 8
  readonly property real padBottom: last ? 14 : 8
  readonly property real sep: first ? 0 : Theme.hair
  readonly property real contentWidth: box.width

  width: parent ? parent.width : 0
  height: sep + Math.max(padTop + box.height + padBottom, first || last ? 0 : 36)
  Behavior on opacity { NumberAnimation { duration: Theme.dAppear } }

  Rectangle { visible: !row.first; x: 16; width: parent.width - 32; height: Theme.hair; color: Theme.tableSeparator }
  Item {
    id: box
    x: 16
    width: parent.width - 32
    height: childrenRect.height
    y: row.sep + row.padTop + (row.height - row.sep - row.padTop - row.padBottom - height) / 2
  }
}
