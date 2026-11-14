import QtQuick

// Indeterminate progress (ProgressView small 16 / mini 12): twelve spokes, the bright one steps around once a
// second. Static with motion off.
Item {
  id: sp
  property real size: 16
  property real phase: 0
  width: size
  height: size
  Accessible.role: Accessible.Indicator
  Accessible.name: "Loading"

  Repeater {
    model: 12
    Rectangle {
      x: (sp.size - width) / 2
      width: Math.max(1.5, sp.size * 0.11)
      height: sp.size * 0.28
      radius: width / 2
      color: Theme.label
      opacity: 0.18 + 0.7 * (((index - Math.floor(sp.phase)) % 12 + 12) % 12) / 11
      transform: Rotation { origin.x: width / 2; origin.y: sp.size / 2; angle: index * 30 }
    }
  }
  NumberAnimation on phase { running: Theme.motion && sp.visible; from: 0; to: 12; duration: 1000; loops: Animation.Infinite }
}
