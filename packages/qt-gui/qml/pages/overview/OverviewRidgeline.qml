import QtQuick
import QtQuick.Shapes
import "Overview.js" as O

// Trends (overview.md 2.6): one ridge per series, each scaled to its own peak, drawn back to front.
// Hover lifts the nearest ridge 6 pt, dims the rest, and shows a guide and a dot at the day.
// Slot 300 = plot 272 + 10 + legend 18; the date axis sits in the plot's bottom 16.
Item {
  id: chart
  property var series: []
  property var days: []
  property var gate: null
  readonly property real plotH: height - 10 - 18
  readonly property var lay: O.ridgeLayout(plotH, series.length)
  property bool h24: false
  readonly property var drawn: O.padded(series)   // Today: started hours only, one hour one slot wide
  readonly property int count: drawn.length ? drawn[0].daily.length : 0
  readonly property var xs: O.xs(width, days.length)
  readonly property var px: xs.slice(0, count)
  property string hoverKey: ""
  property int hoverDay: -1
  property var hover: null
  property real engaged: hover ? 1 : 0
  Behavior on engaged { NumberAnimation { duration: Theme.dHover; easing.type: Easing.Bezier; easing.bezierCurve: Theme.easeOut } }
  height: 300
  property string summary: ""
  Accessible.role: Accessible.Graphic
  Accessible.name: summary

  Item {
    id: plot
    width: chart.width
    height: chart.plotH
    Repeater {
      model: chart.days.length > 1 && chart.count > 1 ? chart.series.length : 0
      delegate: Item {
        id: ridge
        readonly property var s: chart.series[index]
        readonly property real base: O.ridgeBase(chart.lay, index)
        readonly property bool lit: chart.hoverKey === s.id
        readonly property real op: chart.hoverKey !== "" && !lit ? 1 - chart.engaged * (1 - O.DIMMED) : 1
        readonly property var ys: O.ridgeYs(chart.drawn[index], chart.lay, index)
        readonly property string line: O.curve(chart.px, ys, false)
        width: chart.width
        height: chart.plotH

        Rectangle { y: ridge.base - 0.5; width: parent.width; height: 1; color: Theme.rgba(Theme.hairline, Theme.hairline.a * 0.6 * ridge.op) }
        Shape {
          width: chart.width
          height: chart.plotH
          y: ridge.lit ? -O.RIDGE.lift * chart.engaged : 0
          preferredRendererType: Shape.CurveRenderer
          // the card color first, so a ridge in front hides the one behind it
          ShapePath {
            fillColor: Theme.card
            strokeColor: "transparent"
            PathSvg { path: ridge.line + " L" + chart.px[chart.px.length - 1] + " " + ridge.base + " L0 " + ridge.base + " Z" }
          }
          ShapePath {
            strokeColor: "transparent"
            fillGradient: LinearGradient {
              x1: 0; y1: ridge.base - chart.lay.peak; x2: 0; y2: ridge.base
              GradientStop { position: 0; color: O.fade(ridge.s.color, 0.55 * ridge.op) }
              GradientStop { position: 1; color: O.fade(ridge.s.color, 0.05 * ridge.op) }
            }
            PathSvg { path: ridge.line + " L" + chart.px[chart.px.length - 1] + " " + ridge.base + " L0 " + ridge.base + " Z" }
          }
          ShapePath {
            fillColor: "transparent"
            strokeColor: O.fade(ridge.s.color, ridge.op)
            strokeWidth: 1.5
            joinStyle: ShapePath.RoundJoin
            capStyle: ShapePath.FlatCap
            PathSvg { path: ridge.line }
          }
        }
        // guide from the baseline to the day's point, then a 7 pt dot
        Rectangle {
          visible: ridge.lit && chart.hoverDay >= 0
          readonly property real py: chart.hoverDay >= 0 ? ridge.ys[chart.hoverDay] - O.RIDGE.lift * chart.engaged : 0
          x: chart.hoverDay >= 0 ? chart.xs[chart.hoverDay] - 0.5 : 0
          y: py
          width: 1
          height: Math.max(0, ridge.base - py)
          color: Theme.ink(0.35 * chart.engaged)
        }
        Rectangle {
          visible: ridge.lit && chart.hoverDay >= 0
          x: chart.hoverDay >= 0 ? chart.xs[chart.hoverDay] - 3.5 : 0
          y: chart.hoverDay >= 0 ? ridge.ys[chart.hoverDay] - O.RIDGE.lift * chart.engaged - 3.5 : 0
          width: 7
          height: 7
          radius: 3.5
          color: O.fade(ridge.s.color, chart.engaged)
        }
      }
    }
    OverviewDateAxis { y: chart.plotH - 16; width: chart.width; days: chart.days; h24: chart.h24 }

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      acceptedButtons: Qt.NoButton
      onPositionChanged: function (m) { chart.pointer(m.x, m.y) }
      onExited: chart.leave()
    }
    OverviewTip { hover: chart.hover }
  }
  Connections { target: chart.gate; function onEndAll() { chart.leave() } }

  OverviewLegend {
    x: 16
    y: chart.plotH + 10
    width: chart.width - 32
    series: chart.series
    active: chart.hover ? chart.hoverKey : ""
  }

  function pointer(x, y) {
    if (gate && gate.blocked()) return
    var n = days.length, real = series.length ? series[0].daily.length : 0
    if (n < 2 || real < 1 || x < 0 || x > width) return
    var day = Math.max(0, Math.min(real - 1, Math.round(x / width * (n - 1))))
    var s = series[O.ridgeRow(lay,series.length, y)]
    hoverKey = s.id
    hoverDay = day
    hover = { x: x, y: y, tip: { title: O.bucket(days[day], h24), rows: [
      { color: s.color, service: s.service, label: s.tip, value: O.tokens(s.daily[day]) }] } }
  }
  function leave() { hover = null; hoverDay = -1 }
}
