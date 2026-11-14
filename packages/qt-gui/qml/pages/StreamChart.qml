import QtQuick
import QtQuick.Shapes
import QtQuick.Effects
import "Data.js" as D

// "Tokens per day" stream chart (overview.md 2.4): centered stacked bands on monotone curves,
// hover dim, guide line, tooltip that follows the pointer on a spring, date axis.
Item {
  id: chart
  property var series: []          // from Data.series(count)
  property real plotH: 200
  property alias engaged: eng.value
  property int hoverBand: -1       // highlighted series
  property int hoverDay: -1
  property real drawProgress: 1
  readonly property int days: series.length ? series[0].daily.length : 0
  readonly property var geo: series.length ? D.stack(series, plotH) : null
  readonly property var xs: {
    var a = []
    for (var i = 0; i < days; ++i) a.push(width * i / Math.max(1, days - 1))
    return a
  }
  readonly property var tot: series.length ? D.totals(series) : null
  height: plotH + 4 + 16

  QtObject { id: eng; property real value: 0
    Behavior on value { NumberAnimation { duration: Theme.dHover; easing.type: Easing.BezierCurve; easing.bezierCurve: Theme.easeOut } } }

  function replay() {
    if (!Theme.motion || Theme.reduceMotion) return
    draw.restart()
  }
  NumberAnimation { id: draw; target: chart; property: "drawProgress"; from: 0; to: 1; duration: 600; easing.type: Easing.OutCubic }
  onSeriesChanged: replay()

  // bands
  Repeater {
    model: chart.series.length
    delegate: Shape {
      width: chart.width
      height: chart.plotH
      preferredRendererType: Shape.CurveRenderer
      opacity: 1 - chart.engaged * (index === chart.hoverBand ? 0 : 0.62)
      transform: Scale { origin.y: chart.plotH / 2; yScale: chart.drawProgress }
      ShapePath {
        fillColor: Theme.rgba(Theme.brand(chart.series[index].id), 0.82)
        strokeColor: Theme.card
        strokeWidth: 2
        joinStyle: ShapePath.RoundJoin
        PathSvg { path: chart.geo ? D.band(chart.xs, chart.geo.tops[index], chart.geo.bots[index]) : "" }
      }
    }
  }

  // hover guide, 1 pt, primary at 35%
  Rectangle {
    visible: chart.hoverDay >= 0
    x: chart.hoverDay >= 0 ? chart.xs[chart.hoverDay] - 0.5 : 0
    width: 1
    height: chart.plotH
    color: Theme.dark ? Theme.w(0.35 * 0.847) : Theme.k(0.35 * 0.847)
    opacity: chart.engaged
  }

  // date axis, Caption in tertiary, top at y = 2 of the 16 pt band
  Repeater {
    model: chart.series.length ? D.axis(chart.series[0].first, chart.days) : []
    delegate: Txt {
      role: "caption"
      color: Theme.tertiary
      text: modelData.text
      y: chart.plotH + 4 + 2 - 1.5
      readonly property real px: chart.width * modelData.i / Math.max(1, chart.days - 1)
      x: index === 0 ? Math.max(px, 16) : (modelData.i === chart.days - 1 ? Math.min(px, chart.width - 16) - width : px - width / 2)
    }
  }

  // pointer
  MouseArea {
    id: area
    width: chart.width
    height: chart.plotH
    hoverEnabled: true
    onPositionChanged: function (m) { chart.pointer(m.x, m.y) }
    onExited: chart.leave()
  }

  property real px: 0
  property real py: 0
  function pointer(x, y) {
    if (!geo) return
    var day = Math.max(0, Math.min(days - 1, Math.round(x / width * (days - 1))))
    var best = -1, bestD = 1e9
    for (var k = 0; k < series.length; ++k) {
      var t = geo.tops[k][day], b = geo.bots[k][day]
      var dist = (y >= t && y <= b) ? 0 : Math.min(Math.abs(y - t), Math.abs(y - b))
      if (dist < bestD) { bestD = dist; best = k }
    }
    px = x; py = y
    hoverDay = day
    hoverBand = best
    eng.value = 1
    tip.show(x, y)
  }
  function leave() { eng.value = 0; tip.hide(); hoverDay = -1 }

  // tooltip
  Item {
    id: tip
    z: 10
    property bool shown: false
    property real tipOpacity: 0
    property int band: chart.hoverBand
    property int day: chart.hoverDay
    readonly property var s: chart.series[Math.max(0, band)]
    x: sx.value
    y: sy.value
    width: box.width
    height: box.height
    opacity: tipOpacity
    visible: opacity > 0.001
    Behavior on tipOpacity { NumberAnimation { duration: Theme.dHover; easing.type: Easing.BezierCurve; easing.bezierCurve: Theme.easeOut } }

    SpringValue { id: sx; duration: 0.26; bounce: 0.12 }
    SpringValue { id: sy; duration: 0.26; bounce: 0.12 }
    Timer { id: drop; interval: 300; onTriggered: tip.keep = false }
    property bool keep: false

    function place(x, y) {
      var W = chart.width, H = chart.plotH
      var estH = 30 + 18 * 2, room = Math.max(H - estH, 0)
      var tx = x < 0.6 * W ? x + 14 : x - 14 - box.width
      var ty = y < 0.55 * H ? Math.min(y + 14, room) : H - Math.min(Math.max(H - y + 14, 0), room) - box.height
      tx = Math.max(0, Math.min(W - box.width, tx))
      ty = Math.max(0, Math.min(H - box.height, ty))
      return [tx, ty]
    }
    function show(x, y) {
      drop.stop()
      var p = place(x, y)
      if (!shown && !keep) { sx.snap(p[0]); sy.snap(p[1]) } else { sx.target = p[0]; sy.target = p[1] }
      shown = true
      keep = true
      tipOpacity = 1
    }
    function hide() { shown = false; tipOpacity = 0; drop.restart() }

    Rectangle {
      id: box
      layer.enabled: true
      layer.effect: MultiEffect {
        shadowEnabled: true
        shadowColor: "black"
        shadowOpacity: 0.16
        shadowBlur: 0.2
        shadowVerticalOffset: 2
        autoPaddingEnabled: true
      }
      radius: 6
      color: Theme.card
      border.width: Theme.hair
      border.color: Theme.cardBorder
      width: Math.max(120, rows.implicitWidth + 16)
      height: rows.implicitHeight + 16

      Column {
        id: rows
        x: 8
        y: 8
        spacing: 4
        Txt { text: tip.day >= 0 ? D.shortDay((tip.s ? tip.s.first : 0) + tip.day) : "" }
        Item {
          readonly property real valW: v1.implicitWidth
          implicitWidth: 8 + 6 + 13 + 6 + l1.implicitWidth + 12 + valW
          width: implicitWidth
          height: 14
          Rectangle { x: 0; anchors.verticalCenter: parent.verticalCenter; width: 8; height: 8; radius: 4; color: tip.s ? Theme.brand(tip.s.id) : "transparent" }
          ProviderTile { x: 14; anchors.verticalCenter: parent.verticalCenter; size: 13; provider: tip.s ? tip.s.id : "codex" }
          Txt { id: l1; x: 33; anchors.verticalCenter: parent.verticalCenter; role: "secondary"; color: Theme.secondary
                text: tip.s ? tip.s.tool + " · " + tip.s.label : "" }
          Txt { id: v1; x: rows.implicitWidth - width; anchors.verticalCenter: parent.verticalCenter; role: "secondary"; tabular: true; color: Theme.secondary
                text: tip.s && tip.day >= 0 ? D.fmt(tip.s.daily[tip.day]) : "" }
        }
        Item {
          implicitWidth: l2.implicitWidth + 12 + v2.implicitWidth
          width: implicitWidth
          height: 14
          Txt { id: l2; anchors.verticalCenter: parent.verticalCenter; role: "secondary"; color: Theme.secondary; text: "All" }
          Txt { id: v2; x: rows.implicitWidth - width; anchors.verticalCenter: parent.verticalCenter; role: "secondary"; tabular: true; color: Theme.secondary
                text: chart.tot && tip.day >= 0 ? D.fmt(chart.tot.perDay[tip.day]) : "" }
        }
      }
    }
  }
}
