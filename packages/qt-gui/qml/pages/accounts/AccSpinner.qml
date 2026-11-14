import QtQuick

// Small indeterminate spinner (ProgressView .small): 8 spokes, the bright one turns once a second.
// Static under reduced motion or a capture run.
Item {
  id: s
  property real size: 14
  property int step: 0
  width: size
  height: size
  Accessible.role: Accessible.Indicator
  Repeater {
    model: 8
    delegate: Rectangle {
      width: Math.max(1.5, s.size * 0.12)
      height: s.size * 0.28
      radius: width / 2
      x: s.size / 2 - width / 2
      y: 0
      color: Theme.label
      opacity: 0.25 + 0.65 * (((index - s.step) % 8 + 8) % 8 === 0 ? 1 : (((s.step - index) % 8 + 8) % 8) < 3 ? 0.4 : 0)
      transform: Rotation { origin.x: width / 2; origin.y: s.size / 2; angle: index * 45 }
    }
  }
  Timer { interval: 125; repeat: true; running: s.visible && Theme.motion && !Theme.reduceMotion; onTriggered: s.step = (s.step + 1) % 8 }
}
