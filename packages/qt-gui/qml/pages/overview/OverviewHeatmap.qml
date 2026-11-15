import QtQuick
import "Overview.js" as O

// Activity (overview.md 2.5): 53 week columns by 7 weekday rows (Sunday first) at width:height 6.6,
// month labels on top, Mon/Wed/Fri at left, then the Less-More legend. Hover outlines a day and shows
// its tools; a click on a day with tokens opens the day sheet; a legend swatch dims the other levels.
Item {
  id: hm
  property var ds: null
  property var gate: null
  signal selected(string day, real tokens)
  readonly property real gridH: width / O.HEAT.aspect
  readonly property var lay: ds ? O.heatLayout(width, gridH, ds.yearOffset, ds.yearDays.length) : null
  property var hover: null
  property int hoverIndex: -1
  property int level: -1        // the hovered legend swatch
  property int lastLevel: -1
  property real engaged: level >= 0 ? 1 : 0
  Behavior on engaged { NumberAnimation { duration: Theme.dHover; easing.type: Easing.Bezier; easing.bezierCurve: Theme.easeOut } }
  height: Math.round(gridH + 8 + 16)   // whole points, as the Mac card ends on a pixel row
  property string summary: ""
  Accessible.role: Accessible.Table
  Accessible.name: "Daily activity"

  function heatColor(level) { return level === 0 ? Theme.ink(0.065) : Theme.rgba(Theme.accent, [0.26, 0.5, 0.76, 1][Math.min(level, 4) - 1]) }

  Item {
    id: grid
    width: hm.width
    height: hm.gridH
    Repeater {
      model: hm.ds ? hm.ds.yearDays.length : 0
      delegate: Rectangle {
        readonly property var r: hm.lay ? O.heatRect(hm.lay, index) : ({ x: 0, y: 0, w: 0, h: 0 })
        readonly property int lv: hm.ds ? O.heatLevel(hm.ds, hm.ds.yearTotals[index]) : 0
        x: r.x
        y: r.y
        width: r.w
        height: r.h
        radius: Math.min(r.w, r.h) * 0.28
        color: hm.heatColor(lv)
        opacity: hm.lastLevel >= 0 && lv !== hm.lastLevel ? 1 - hm.engaged * 0.8 : 1
      }
    }
    Repeater {
      model: hm.ds && hm.lay ? O.heatMonths(hm.ds) : []
      delegate: Txt { role: "caption"; color: Theme.secondary; text: modelData.text; x: O.heatRect(hm.lay, modelData.i).x; y: 0.5 }
    }
    Repeater {
      model: [[1, "Mon"], [3, "Wed"], [5, "Fri"]]
      delegate: Txt {
        role: "caption"
        color: Theme.secondary
        text: modelData[1]
        x: 0
        y: hm.lay ? O.HEAT.top + modelData[0] * (hm.lay.ch + O.HEAT.gap) + hm.lay.ch / 2 - height / 2 + 1.5 : 0   // + 1.5: the Mac glyph rows
      }
    }
    // the hovered day's ring
    Rectangle {
      readonly property var r: hm.hoverIndex >= 0 ? O.heatRect(hm.lay, hm.hoverIndex) : null
      visible: !!r
      x: r ? r.x - 0.5 - 0.75 : 0
      y: r ? r.y - 0.5 - 0.75 : 0
      width: r ? r.w + 1 + 1.5 : 0
      height: r ? r.h + 1 + 1.5 : 0
      radius: r ? Math.min(r.w + 1, r.h + 1) * 0.3 + 0.75 : 0
      color: "transparent"
      border.width: 1.5
      border.color: Theme.ink(0.7)
    }
    MouseArea {
      id: area
      anchors.fill: parent
      Accessible.ignored: true   // the pointer path; the "Daily activity" table above is the accessible one
      hoverEnabled: true
      cursorShape: hm.hoverIndex >= 0 && hm.ds.yearTotals[hm.hoverIndex] > 0 ? Qt.PointingHandCursor : Qt.ArrowCursor
      property point down
      onPressed: function (m) { down = Qt.point(m.x, m.y) }
      onClicked: function (m) {
        if (Math.abs(m.x - down.x) > 3 || Math.abs(m.y - down.y) > 3 || !hm.lay) return
        var i = O.heatIndex(hm.lay, m.x, m.y)
        if (i < 0 || hm.ds.yearTotals[i] <= 0) return
        hm.leave()
        hm.selected(hm.ds.yearDays[i], hm.ds.yearTotals[i])
      }
      onPositionChanged: function (m) { hm.pointer(m.x, m.y) }
      onExited: hm.leave()
    }
    OverviewTip { hover: hm.hover }
  }
  Connections { target: hm.gate; function onEndAll() { hm.leave(); hm.level = -1 } }

  Row {
    anchors.right: parent.right
    y: hm.gridH + 8
    height: 16
    spacing: 4
    Txt { role: "secondary"; color: Theme.secondary; text: "Less"; anchors.verticalCenter: parent.verticalCenter }
    Repeater {
      model: 5
      delegate: Rectangle {
        anchors.verticalCenter: parent.verticalCenter
        width: 12
        height: 12
        radius: 3
        color: hm.heatColor(index)
        HoverHandler {
          onHoveredChanged: {
            if (hovered && hm.gate && hm.gate.blocked()) return
            if (hovered) hm.lastLevel = index
            hm.level = hovered ? index : -1
          }
        }
      }
    }
    Txt { role: "secondary"; color: Theme.secondary; text: "More"; anchors.verticalCenter: parent.verticalCenter }
  }

  // Keyboard (fills the spec 2.5 gap): Tab focuses the grid on the newest day; the arrow keys move a day
  // (up, down) or a week (left, right); Return or Space opens the day sheet for a day with tokens.
  activeFocusOnTab: true
  // the focused day ("Sat, Oct 3, 2026, 1.3B tokens"), else the year summary
  Accessible.description: hoverIndex >= 0 && ds
    ? O.long(ds.yearDays[hoverIndex]) + ", " + (ds.yearTotals[hoverIndex] > 0 ? O.tokens(ds.yearTotals[hoverIndex]) + " tokens" : "no tokens")
    : summary
  onActiveFocusChanged: if (activeFocus && ds && lay) key(hoverIndex >= 0 ? hoverIndex : ds.yearDays.length - 1); else if (!activeFocus) leave()
  Keys.onPressed: function (e) {
    if (!ds || !lay) return
    var i = hoverIndex >= 0 ? hoverIndex : ds.yearDays.length - 1
    var step = { [Qt.Key_Left]: -7, [Qt.Key_Right]: 7, [Qt.Key_Up]: -1, [Qt.Key_Down]: 1 }[e.key]
    if (step !== undefined) { key(Math.max(0, Math.min(ds.yearDays.length - 1, i + step))); e.accepted = true }
    else if ((e.key === Qt.Key_Return || e.key === Qt.Key_Enter || e.key === Qt.Key_Space) && ds.yearTotals[i] > 0) {
      leave(); selected(ds.yearDays[i], ds.yearTotals[i]); e.accepted = true
    }
  }
  function key(i) { var r = O.heatRect(lay, i); show(i, r.x + r.w / 2, r.y + r.h / 2) }

  function pointer(x, y) {
    if (gate && gate.blocked()) return
    show(lay ? O.heatIndex(lay, x, y) : -1, x, y)
  }
  function show(i, x, y) {
    hoverIndex = i
    if (i < 0) { hover = null; return }
    var rows = []
    for (var k = 0; k < ds.yearTools.length && rows.length < 3; ++k) {
      var t = ds.yearTools[k]
      if (t.daily[i] > 0) rows.push({ service: t.service, label: O.toolName(t.service), value: O.tokens(t.daily[i]) })
    }
    rows.push({ label: "Tokens", value: ds.yearTotals[i] === 0 ? "None" : O.tokens(ds.yearTotals[i]) })
    hover = { x: x, y: y, tip: { title: O.long(ds.yearDays[i]), rows: rows } }
  }
  function leave() { hover = null; hoverIndex = -1 }
}
