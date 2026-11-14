import QtQuick

// OverviewLegend (overview.md 2.8): one line, 18 high, clipped. Dot 8, tool tile 13, name; when the
// names do not fit they all shorten together. The active series brightens; the others dim to 0.38.
Item {
  id: legend
  property var series: []
  property string active: ""
  property var caps: []
  height: 18
  clip: true

  function relayout() {
    var n = rep.count, nat = [], fixed = 0
    for (var i = 0; i < n; ++i) { var it = rep.itemAt(i); if (!it) return; nat.push(it.natural); fixed += it.fixedW }
    var avail = width - 14 * Math.max(0, n - 1) - fixed, out = nat.slice(), left = nat.map(function (_, i) { return i })
    // Water-fill: names shorter than an even share keep their width; the rest share what is left.
    while (left.length) {
      var share = Math.max(0, avail) / left.length, next = []
      for (var k = 0; k < left.length; ++k) if (nat[left[k]] <= share) avail -= nat[left[k]]; else next.push(left[k])
      if (next.length === left.length) { for (k = 0; k < next.length; ++k) out[next[k]] = Math.floor(share); break }
      left = next
    }
    caps = out
  }
  onWidthChanged: Qt.callLater(relayout)
  onSeriesChanged: Qt.callLater(relayout)

  Row {
    y: -1   // the Mac row draws 1 pt above the 18 pt box's center
    spacing: 14
    height: 18
    Repeater {
      id: rep
      model: legend.series
      delegate: Row {
        readonly property real natural: name.implicitWidth
        readonly property real fixedW: 8 + 6 + (modelData.service ? 13 + 6 : 0)
        readonly property bool lit: legend.active === modelData.id
        spacing: 6
        height: 18
        opacity: legend.active === "" || lit ? 1 : 0.38
        Behavior on opacity { NumberAnimation { duration: Theme.dHover; easing.type: Easing.Bezier; easing.bezierCurve: Theme.easeOut } }
        // offsets measured on the Mac capture: the dot sits 1 pt above the tile and name center
        Rectangle { anchors.verticalCenter: parent.verticalCenter; anchors.verticalCenterOffset: -1; width: 8; height: 8; radius: 4; color: modelData.color }
        ProviderTile { visible: !!modelData.service; anchors.verticalCenter: parent.verticalCenter; size: 13; provider: modelData.service || "" }
        Txt {
          id: name
          anchors.verticalCenter: parent.verticalCenter
          role: "secondary"
          color: parent.lit ? Theme.label : Theme.secondary
          text: modelData.label
          width: legend.caps.length > index ? Math.min(implicitWidth, legend.caps[index]) : implicitWidth
          elide: Text.ElideRight
          ToolTipArea { text: modelData.label }
        }
        Component.onCompleted: Qt.callLater(legend.relayout)
      }
    }
  }
}
