import QtQuick

// Accounts table card (accounts.md 2.2): title row 44, then groups (header 32, rows 36, 6 between groups),
// 7 below the last row. Loading: a skeleton header and two indented skeleton rows. Empty: one line.
Card {
  id: card
  property var ctl
  title: "Accounts"
  divider: false

  // skeleton row (PRT:1146-1177): 20 block, two bars (160 x 10, 110 x 8, 4 apart), 70 x 10 at the right
  component SkelRow: Item {
    property real indent: 0
    width: parent ? parent.width : 400
    Skeleton { x: 16 + parent.indent; width: 20; height: 20; anchors.verticalCenter: parent.verticalCenter }
    Column {
      x: 16 + parent.indent + 20 + 8
      anchors.verticalCenter: parent.verticalCenter
      spacing: 4
      Skeleton { width: 160; height: 10 }
      Skeleton { width: 110; height: 8 }
    }
    Skeleton { x: parent.width - 16 - 70; width: 70; height: 10; anchors.verticalCenter: parent.verticalCenter }
  }

  Column {
    visible: !card.ctl.loaded
    width: parent.width
    Accessible.name: "Loading"
    SkelRow { height: 32 }
    SkelRow { height: 36; indent: 24 }
    SkelRow { height: 36; indent: 24 }
    Item { width: 1; height: 7 }
  }
  Item {
    visible: card.ctl.loaded && card.ctl.groups.length === 0
    width: parent.width
    height: 36 + 7
    Txt {
      x: 16
      height: 36
      role: "secondary"
      color: Theme.secondary
      text: card.ctl.query.trim() === "" ? "No accounts yet." : "No accounts match “" + card.ctl.query.trim() + "”."
    }
  }
  // ---- drag reorder (accounts.md 4). Row geometry is fixed (header 32, rows 36, 6 between groups), so the
  // pointer y maps to a row or group by arithmetic; only window-local pointer events are used.
  readonly property Item stackItem: stack
  readonly property bool canReorder: ctl.query.trim() === "" && !ctl.busy
  readonly property var geo: {
    var y = 0, out = []
    ctl.groups.forEach(function (g, i) {
      if (i > 0) y += 6
      var top = y
      y += 32
      var rows = g.rows.map(function (r) { var o = { id: r.id, provider: g.provider, label: r.label, y: y }; y += 36; return o })
      out.push({ provider: g.provider, top: top, height: y - top, rows: rows })
    })
    return out
  }
  // account drag: carried row, pointer y in the groups column, drop target {id, y} (y = the line's center)
  property var carried: null
  property real dragX: 0
  property real dragY: 0
  property var dropAt: null
  function rowAt(y) {
    for (var i = 0; i < geo.length; ++i)
      for (var j = 0; j < geo[i].rows.length; ++j) { var r = geo[i].rows[j]; if (y >= r.y && y < r.y + 36) return r }
    return null
  }
  function dragTo(x, y) {
    dragX = x; dragY = y
    var t = rowAt(y), order = ctl.order()
    if (!carried || !t || t.id === carried.id || t.provider !== carried.provider) { dropAt = null; return }
    var up = order.indexOf(carried.id) > order.indexOf(t.id)
    dropAt = { id: t.id, y: up ? t.y - 1 : t.y + 36 + 1 }
  }
  function endDrag(drop) {
    if (drop && carried && dropAt) ctl.moveAccount(carried.id, dropAt.id)
    carried = null; dropAt = null
  }
  // group drag: dragged group index, pointer offset, and the slot it would take
  property int gFrom: -1
  property real gDy: 0
  readonly property int gTo: {
    if (gFrom < 0) return -1
    var top = geo[gFrom].top + gDy, t = gFrom
    if (gDy > 0) { for (var i = gFrom + 1; i < geo.length; ++i) if (geo[i].top < top) t = i }
    else for (var j = gFrom - 1; j >= 0; --j) if (geo[j].top > top) t = j
    return t
  }
  function groupShift(i) {
    if (gFrom < 0 || i === gFrom) return i === gFrom ? gDy : 0
    var h = geo[gFrom].height + 6
    if (gTo > gFrom && i > gFrom && i <= gTo) return -h
    if (gTo < gFrom && i >= gTo && i < gFrom) return h
    return 0
  }
  function endGroupDrag(drop) {
    if (drop && gFrom >= 0 && gTo >= 0 && gTo !== gFrom) ctl.moveService(geo[gFrom].provider, gTo - gFrom)
    gFrom = -1; gDy = 0
  }

  Column {
    id: stack
    visible: card.ctl.loaded && card.ctl.groups.length > 0
    width: parent.width
    Repeater {
      model: card.ctl.groups
      delegate: Column {
        width: card.width
        z: index === card.gFrom ? 1 : 0
        transform: Translate {
          y: card.groupShift(index)
          Behavior on y { enabled: Theme.motion && index !== card.gFrom; SpringAnimation { spring: 6; damping: 0.85 } }
        }
        Item { visible: index > 0; width: 1; height: 6 }
        AccGroupHeader { ctl: card.ctl; table: card; groupIndex: index; provider: modelData.provider; count: modelData.rows.length }
        Repeater {
          id: rep
          model: modelData.rows
          delegate: AccRow {
            ctl: card.ctl
            table: card
            row: modelData
            firstInGroup: index === 0
            lastInGroup: index === rep.count - 1
          }
        }
      }
    }
    Item { width: 1; height: 7 }
    // drop line (2 pt accent capsule, 32 from the left, 8 from the right) and the drag pill; the Column puts
    // this last, so children subtract its y to draw in stack coordinates
    Item {
    width: stack.width
    height: 0
    z: 2
    Rectangle {
      x: 32
      y: (card.dropAt ? card.dropAt.y : 0) - 1 - parent.y
      width: parent.width - 40
      height: 2
      radius: 1
      color: Theme.accent
      opacity: card.dropAt ? 1 : 0
      Behavior on opacity { NumberAnimation { duration: 120 } }
    }
    Rectangle {
      visible: !!card.carried
      x: card.dragX + 8
      y: card.dragY - 14 - parent.y
      width: pill.implicitWidth + 20
      height: 28
      radius: 6
      color: Theme.controlFill
      border.width: Theme.hair
      border.color: Theme.separator
      Txt { id: pill; anchors.centerIn: parent; text: card.carried ? card.carried.label : "" }
    }
    }
  }
}
