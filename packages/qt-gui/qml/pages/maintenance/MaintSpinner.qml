import QtQuick

// The small ProgressView (controlSize .small): 16 pt, 12 spokes, the bright spoke steps around once a second.
// With motion off it stays still.
Item {
  id: sp
  property real size: 16
  property int step: 0
  width: size
  height: size
  Accessible.role: Accessible.Indicator
  Accessible.name: "Loading"
  Timer { interval: 83; repeat: true; running: sp.visible && Theme.motion; onTriggered: sp.step = (sp.step + 1) % 12 }
  Repeater {
    model: 12
    delegate: Rectangle {
      x: sp.size / 2 - width / 2
      y: 0
      width: sp.size * 0.11
      height: sp.size * 0.28
      radius: width / 2
      color: Theme.label
      opacity: 0.2 + 0.8 * (((index - sp.step + 12) % 12) / 11)
      transform: Rotation { origin.x: width / 2; origin.y: sp.size / 2; angle: index * 30 }
    }
  }
}
