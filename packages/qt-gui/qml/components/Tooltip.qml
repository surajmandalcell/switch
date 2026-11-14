import QtQuick
import QtQuick.Effects

// The one tooltip of the main window (4.18): solid surface, padding 3 x 8, radius 5, half-point
// separator border, soft shadow, Secondary text, 6 below the control and right-aligned to it.
Item {
  id: tip
  property Item owner: null
  property string text: ""
  anchors.fill: parent
  z: 1000
  visible: box.opacity > 0.001

  function show(item, t) {
    if (!item || item.Window.window !== tip.Window.window) return
    owner = item
    text = t
    var p = item.mapToItem(tip, item.width, item.height + 6)
    box.x = Math.max(8, Math.min(tip.width - box.width - 8, p.x - box.width))
    box.y = p.y + box.height + 8 > tip.height ? item.mapToItem(tip, 0, 0).y - 6 - box.height : p.y
    box.opacity = 1
  }
  function hide(item) { if (item === owner) box.opacity = 0 }

  Rectangle {
    id: box
    opacity: 0
    width: label.implicitWidth + 16
    height: label.implicitHeight + 6
    radius: 5
    color: Theme.solidSurface
    border.width: 0.5
    border.color: Theme.separator
    layer.enabled: true
    layer.effect: MultiEffect { shadowEnabled: true; shadowColor: "black"; shadowOpacity: 0.2; shadowBlur: 0.25; shadowVerticalOffset: 2 }
    Behavior on opacity { NumberAnimation { duration: Theme.dHover; easing.type: Easing.BezierCurve; easing.bezierCurve: Theme.easeOut } }
    Txt { id: label; x: 8; y: 3; role: "secondary"; color: Theme.secondary; text: tip.text }
  }
}
