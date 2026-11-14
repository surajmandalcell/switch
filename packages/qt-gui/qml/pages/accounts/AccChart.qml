import QtQuick
import "Acc.js" as A

// UsageChartView (account-window.md 3.9): title and "Total …" (or the hovered day), 54 high accent bars,
// the first, middle and last labels. Hover or Left/Right selects a day; the other bars dim to 40%.
Item {
  id: c
  property var chart: ({ title: "", unit: "USD", points: [] })
  readonly property var pts: chart.points || []
  property int sel: -1
  readonly property real total: pts.reduce(function (s, p) { return s + (p.value || 0) }, 0)
  readonly property real peak: pts.reduce(function (s, p) { return Math.max(s, p.value || 0) }, 0)
  readonly property real slot: pts.length ? width / pts.length : width
  width: parent ? parent.width : 400
  height: 16 + 8 + 54 + 4 + 14
  activeFocusOnTab: true
  Accessible.role: Accessible.Chart
  Accessible.name: chart.title
  Accessible.description: A.plural(pts.length, "day", "days") + ", total " + A.chartValue(total, chart.unit)
  Keys.onLeftPressed: sel = sel < 0 ? pts.length - 1 : Math.max(0, sel - 1)
  Keys.onRightPressed: sel = sel < 0 ? pts.length - 1 : Math.min(pts.length - 1, sel + 1)
  onActiveFocusChanged: if (!activeFocus && !hover.hovered) sel = -1

  Txt { text: c.chart.title; width: parent.width - head.width - 8; elide: Text.ElideRight }
  Txt {
    id: head
    anchors.right: parent.right
    role: "secondary"
    tabular: true
    color: c.sel >= 0 ? Theme.label : Theme.secondary
    text: c.sel >= 0 ? c.pts[c.sel].label + " · " + A.chartValue(c.pts[c.sel].value, c.chart.unit) : "Total " + A.chartValue(c.total, c.chart.unit)
  }
  Item {
    id: plot
    y: 24
    width: parent.width
    height: 54
    Repeater {
      model: c.pts
      delegate: Rectangle {
        readonly property real h: c.peak > 0 ? Math.max(modelData.value > 0 ? 2 : 0, 54 * modelData.value / c.peak) : 0
        x: index * c.slot + c.slot * 0.15
        width: Math.max(1, c.slot * 0.7)
        y: 54 - h
        height: h
        radius: 1.5
        color: Theme.accent
        opacity: c.sel < 0 || c.sel === index ? 1 : 0.4
        Behavior on opacity { NumberAnimation { duration: Theme.dHover } }
      }
    }
    HoverHandler {
      id: hover
      onPointChanged: if (hovered && c.pts.length) c.sel = Math.max(0, Math.min(c.pts.length - 1, Math.floor(point.position.x / c.slot)))
      onHoveredChanged: if (!hovered && !c.activeFocus) c.sel = -1
    }
  }
  Item {
    y: 24 + 54 + 4
    width: parent.width
    height: 14
    Repeater {
      model: c.pts.length > 3 ? [0, Math.floor(c.pts.length / 2), c.pts.length - 1] : c.pts.map(function (p, i) { return i })
      delegate: Txt {
        role: "secondary"
        color: Theme.secondary
        text: c.pts[modelData].label
        x: modelData === 0 ? 0 : (modelData === c.pts.length - 1 ? c.width - implicitWidth
                                  : Math.max(0, Math.min(c.width - implicitWidth, (modelData + 0.5) * c.slot - implicitWidth / 2)))
      }
    }
  }
}
