import QtQuick

// SwiftUI spring(duration, bounce) as a value: stiffness (2 pi / duration)^2, damping ratio 1 - bounce.
QtObject {
  id: s
  property real target: 0
  property real value: 0
  property real duration: 0.25
  property real bounce: 0.12
  property real velocity: 0
  property bool settled: true

  function snap(v) { value = v; target = v; velocity = 0; settled = true }
  onTargetChanged: if (Math.abs(target - value) > 0.001) settled = false

  property FrameAnimation clock: FrameAnimation {
    running: !s.settled
    onTriggered: {
      var dt = Math.min(frameTime, 0.05)
      var w = 2 * Math.PI / s.duration, z = 1 - s.bounce
      var n = Math.max(1, Math.ceil(dt / 0.004)), h = dt / n
      var x = s.value, v = s.velocity
      for (var i = 0; i < n; ++i) {
        v += (-w * w * (x - s.target) - 2 * z * w * v) * h
        x += v * h
      }
      if (Math.abs(x - s.target) < 0.01 && Math.abs(v) < 0.2) { x = s.target; v = 0; s.settled = true }
      s.velocity = v
      s.value = x
    }
  }
}
