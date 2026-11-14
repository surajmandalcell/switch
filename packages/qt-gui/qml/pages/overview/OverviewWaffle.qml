import QtQuick
import "Overview.js" as O

// Share of tokens (overview.md 1.6, 2.7): a 20 x 10 waffle (each cell half a percent) on the left 40%,
// the legend on the right 60% after a 24 gap. Hovering a cell or a legend row highlights a series.
Item {
  id: wf
  property var series: []
  property var gate: null
  readonly property var cells: O.cells(series.map(function (s) { return s.tokens }))
  readonly property var owners: O.owners(cells)
  readonly property real free: Math.max(width - O.WAFFLE.legendGap, 0)
  readonly property real waffleW: free * O.WAFFLE.share
  readonly property real legendW: free - waffleW
  readonly property real side: O.cellSide(waffleW)
  readonly property real waffleH: O.waffleHeight(waffleW)
  readonly property real rowH: Math.max(O.WAFFLE.minRow, Math.min(O.WAFFLE.maxRow, waffleH / Math.max(1, series.length)))
  readonly property bool anyService: series.some(function (s) { return !!s.service })
  property var hover: null
  property string legendKey: ""
  readonly property string active: hover ? hover.key : legendKey
  property string lastKey: ""
  onActiveChanged: if (active !== "") lastKey = active
  property real engaged: active !== "" ? 1 : 0
  Behavior on engaged { NumberAnimation { duration: Theme.dHover; easing.type: Easing.Bezier; easing.bezierCurve: Theme.easeOut } }
  height: Math.round(Math.max(waffleH, O.WAFFLE.minRow * series.length))   // whole points, as on the Mac
  property string summary: ""
  Accessible.role: Accessible.Graphic
  Accessible.name: summary

  Item {
    width: wf.waffleW
    height: wf.waffleH
    Repeater {
      model: wf.owners.length
      delegate: Rectangle {
        readonly property var s: wf.series[wf.owners[index]]
        x: (index % 20) * (wf.side + O.WAFFLE.gap)
        y: Math.floor(index / 20) * (wf.side + O.WAFFLE.gap)
        width: wf.side
        height: wf.side
        radius: wf.side * 0.22
        color: s.color
        opacity: wf.lastKey !== "" && s.id !== wf.lastKey ? 1 - wf.engaged * 0.75 : 1
      }
    }
    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      acceptedButtons: Qt.NoButton
      onPositionChanged: function (m) { wf.pointer(m.x, m.y) }
      onExited: wf.hover = null
    }
  }

  Column {
    x: wf.width - wf.legendW
    width: wf.legendW
    Repeater {
      model: wf.series
      delegate: Item {
        width: wf.legendW
        height: wf.rowH
        opacity: wf.active === "" || wf.active === modelData.id ? 1 : O.DIMMED
        Behavior on opacity { NumberAnimation { duration: Theme.dHover; easing.type: Easing.Bezier; easing.bezierCurve: Theme.easeOut } }
        Row {
          id: lead
          spacing: 8
          anchors.verticalCenter: parent.verticalCenter
          Rectangle { width: 8; height: 8; radius: 4; color: modelData.color; anchors.verticalCenter: parent.verticalCenter }
          Item {
            visible: wf.anyService
            width: 13
            height: 13
            anchors.verticalCenter: parent.verticalCenter
            ProviderTile { visible: !!modelData.service; size: 13; provider: modelData.service || "" }
          }
          Txt {
            anchors.verticalCenter: parent.verticalCenter
            anchors.verticalCenterOffset: 1   // the Mac glyph rows
            text: modelData.label
            width: Math.min(implicitWidth, Math.max(0, wf.legendW - (16 + (wf.anyService ? 21 : 0)) - 12 - pct.implicitWidth - 8 - 56))
            elide: Text.ElideMiddle
            ToolTipArea { text: modelData.label }
          }
        }
        RollText { id: pct; role: "body"; text: O.percent(wf.cells[index]); anchors.verticalCenter: parent.verticalCenter
                   x: parent.width - 56 - 8 - width }
        Txt { anchors.verticalCenter: parent.verticalCenter; x: parent.width - 56; width: 56; horizontalAlignment: Text.AlignRight
              role: "secondary"; color: Theme.secondary; tabular: true; text: O.tokens(modelData.tokens)
              ToolTipArea { text: O.tokens(modelData.tokens) } }
        HoverHandler {
          onHoveredChanged: {
            if (hovered && wf.gate && wf.gate.blocked()) return
            wf.legendKey = hovered ? modelData.id : ""
          }
        }
      }
    }
  }

  // The tooltip belongs to the whole split, so it draws over the legend column.
  OverviewTip { hover: wf.hover; flips: false }
  Connections { target: wf.gate; function onEndAll() { wf.hover = null; wf.legendKey = "" } }

  function pointer(x, y) {
    if (gate && gate.blocked()) return
    var col = Math.floor(x / (side + O.WAFFLE.gap)), row = Math.floor(y / (side + O.WAFFLE.gap))
    var slot = row * 20 + col
    if (x < 0 || y < 0 || col >= 20 || row >= 10 || slot >= owners.length) { hover = null; return }
    var i = owners[slot], s = series[i]
    hover = { x: x, y: y, key: s.id, tip: { title: s.tip, titleService: s.service, rows: [
      { color: s.color, label: "Share", value: O.percent(cells[i]) }, { label: "Tokens", value: O.tokens(s.tokens) }] } }
  }
}
