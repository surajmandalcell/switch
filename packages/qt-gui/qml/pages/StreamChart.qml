import QtQuick
import QtQuick.Shapes
import "Overview.js" as O

// "Tokens per day" (overview.md 2.4): stacked bands around a centered axis on monotone curves, a 2 pt
// card-color stroke between bands, hover dim, a guide line, the shared tooltip, and the date axis.
Item {
  id: chart
  property var series: []
  property var days: []
  property var gate: null
  property real plotH: 200
  property string hoverKey: ""      // the last hovered series; kept while the dim fades out
  property int hoverDay: -1
  property var hover: null
  property real engaged: hover ? 1 : 0
  Behavior on engaged { NumberAnimation { duration: Theme.dHover; easing.type: Easing.Bezier; easing.bezierCurve: Theme.easeOut } }
  readonly property var xs: O.xs(width, days.length)
  readonly property var geo: O.stack(series, plotH)
  height: plotH + 4 + 16
  Accessible.role: Accessible.Graphic
  Accessible.name: summary
  property string summary: ""

  Repeater {
    model: chart.series.length
    delegate: Shape {
      readonly property var s: chart.series[index]
      readonly property bool faded: chart.hoverKey !== "" && s.id !== chart.hoverKey
      width: chart.width
      height: chart.plotH
      preferredRendererType: Shape.CurveRenderer
      ShapePath {
        fillColor: O.fade(s.color, 0.82 * (faded ? 1 - chart.engaged * (1 - O.DIMMED) : 1))
        strokeColor: Theme.card
        strokeWidth: 2
        joinStyle: ShapePath.RoundJoin
        PathSvg { path: chart.days.length > 1 ? O.bandPath(chart.xs, chart.geo.tops[index], chart.geo.bots[index]) : "" }
      }
    }
  }

  // guide: 1 pt, primary at 35%
  Rectangle {
    visible: chart.hoverDay >= 0
    x: chart.hoverDay >= 0 ? chart.xs[chart.hoverDay] - 0.5 : 0
    width: 1
    height: chart.plotH
    color: Theme.ink(0.35 * chart.engaged)
  }

  OverviewDateAxis { y: chart.plotH + 4; width: chart.width; days: chart.days }

  MouseArea {
    width: chart.width
    height: chart.plotH
    hoverEnabled: true
    acceptedButtons: Qt.NoButton
    onPositionChanged: function (m) { chart.pointer(m.x, m.y) }
    onExited: chart.leave()
  }
  Connections { target: chart.gate; function onEndAll() { chart.leave() } }

  function pointer(x, y) {
    if (gate && gate.blocked()) return
    var n = days.length
    if (n < 2 || !series.length) return
    var day = Math.max(0, Math.min(n - 1, Math.round(x / width * (n - 1))))
    var best = 0, bestD = 1e9
    for (var k = 0; k < series.length; ++k) {
      var t = geo.tops[k][day], b = geo.bots[k][day]
      var dist = y < t ? t - y : (y > b ? y - b : 0)
      if (dist < bestD) { bestD = dist; best = k }
    }
    var s = series[best], all = 0
    for (k = 0; k < series.length; ++k) all += series[k].daily[day]
    hoverKey = s.id
    hoverDay = day
    hover = { x: x, y: y, tip: { title: O.short(days[day]), rows: [
      { color: s.color, service: s.service, label: s.tip, value: O.tokens(s.daily[day]) },
      { label: "All", value: O.tokens(all) }] } }
  }
  function leave() { hover = null; hoverDay = -1 }

  Item {
    width: chart.width
    height: chart.plotH
    OverviewTip { hover: chart.hover }
  }
}
