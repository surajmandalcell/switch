import QtQuick
import QtQuick.Effects

// OverviewTooltipLayer (overview.md 2.9): fills its chart; never takes the pointer. One tip stays once
// shown: its content swaps and its opacity fades; 300 ms after the hover ends the content is dropped,
// so the next tip fades in where it appears instead of sliding there.
// hover: null or { x, y, tip: { title, titleService, rows: [{ color, service, label, value }] } }
Item {
  id: tipLayer
  property var hover: null
  property bool flips: true
  property var cur: null
  anchors.fill: parent
  z: 10

  onHoverChanged: {
    if (!hover) { drop.restart(); return }
    drop.stop()
    var snap = !cur
    cur = hover
    place(snap)
  }
  Timer { id: drop; interval: 300; onTriggered: if (!tipLayer.hover) tipLayer.cur = null }

  function place(snap) {
    if (!cur) return
    var W = width, H = height, p = cur
    var right = !flips || p.x < 0.6 * W, below = p.y < 0.55 * H
    var room = Math.max(H - (30 + 18 * cur.tip.rows.length), 0)
    var tx = right ? p.x + 14 : p.x - 14 - box.width
    var ty = below ? Math.min(p.y + 14, room) : H - Math.min(Math.max(H - p.y + 14, 0), room) - box.height
    if (snap || !Theme.motion || Theme.reduceMotion) { sx.snap(tx); sy.snap(ty) } else { sx.target = tx; sy.target = ty }
  }
  SpringValue { id: sx; duration: 0.26; bounce: 0.12 }
  SpringValue { id: sy; duration: 0.26; bounce: 0.12 }

  Rectangle {
    id: box
    readonly property var tip: tipLayer.cur ? tipLayer.cur.tip : null
    x: sx.value
    y: sy.value
    visible: !!tip && opacity > 0.001
    opacity: tipLayer.hover ? 1 : 0
    Behavior on opacity { NumberAnimation { duration: Theme.dHover; easing.type: Easing.Bezier; easing.bezierCurve: Theme.easeOut } }
    onWidthChanged: tipLayer.place(false)
    onHeightChanged: tipLayer.place(false)
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
    width: Math.max(120, col.contentW + 16)
    height: col.implicitHeight + 16

    Column {
      id: col
      x: 8
      y: 8
      spacing: 4
      readonly property real contentW: {
        var w = head.implicitWidth
        for (var i = 0; i < rowRep.count; ++i) { var r = rowRep.itemAt(i); if (r) w = Math.max(w, r.natural) }
        return w
      }
      Row {
        id: head
        spacing: 6
        height: 16
        ProviderTile { visible: !!(box.tip && box.tip.titleService); size: 13; provider: box.tip && box.tip.titleService ? box.tip.titleService : ""
                       anchors.verticalCenter: parent.verticalCenter }
        Txt { text: box.tip ? box.tip.title : ""; width: Math.min(implicitWidth, 280); elide: Text.ElideMiddle
              anchors.verticalCenter: parent.verticalCenter }
      }
      Repeater {
        id: rowRep
        model: box.tip ? box.tip.rows : []
        delegate: Item {
          readonly property real natural: left.width + 12 + val.implicitWidth
          width: Math.max(natural, col.contentW)
          height: 14
          Row {
            id: left
            spacing: 6
            anchors.verticalCenter: parent.verticalCenter
            Rectangle { visible: !!modelData.color; width: 8; height: 8; radius: 4; color: modelData.color || "transparent"
                        anchors.verticalCenter: parent.verticalCenter }
            ProviderTile { visible: !!modelData.service; size: 13; provider: modelData.service || ""; anchors.verticalCenter: parent.verticalCenter }
            Txt { role: "secondary"; color: Theme.secondary; text: modelData.label; width: Math.min(implicitWidth, 280)
                  elide: Text.ElideMiddle; anchors.verticalCenter: parent.verticalCenter }
          }
          Txt { id: val; anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter
                role: "secondary"; color: Theme.secondary; tabular: true; text: modelData.value }
        }
      }
    }
  }
}
