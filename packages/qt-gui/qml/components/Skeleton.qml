import QtQuick

// AIMSkeleton (4.21): primary a0.07 rounded 4, one highlight band sweeping every 1.8 s; static with motion off.
Rectangle {
  id: sk
  radius: 4
  color: Theme.skeleton
  clip: true
  Rectangle {
    id: band
    width: sk.width * 0.6
    height: sk.height
    x: -width
    gradient: Gradient {
      orientation: Gradient.Horizontal
      GradientStop { position: 0; color: "transparent" }
      GradientStop { position: 0.5; color: Theme.ink(0.06) }
      GradientStop { position: 1; color: "transparent" }
    }
    NumberAnimation on x {
      running: Theme.motion && !Theme.reduceMotion && sk.visible
      from: -band.width; to: sk.width; duration: 1800; loops: Animation.Infinite
    }
  }
}
