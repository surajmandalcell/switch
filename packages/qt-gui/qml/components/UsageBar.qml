import QtQuick

// UsageBar (4.14): 4 pt capsule track, brand fill (red from 90% used), minimum 4 (a dot), fill eases
// over 0.35 s; `progress` unmasks from the left (popover first show). used < 0 = unknown: dotted track.
// `fill` is the share shown (left or used, 0..1); `pace` (0..1) draws the 1.5 x 8 tick, -1 hides it.
Item {
  id: bar
  property real used: 0
  property real fill: Theme.showUsed ? used / 100 : Math.max(0, 100 - used) / 100
  property string provider: ""
  property real progress: 1
  property real pace: -1
  readonly property bool unknown: used < 0
  height: 4

  Rectangle { visible: !bar.unknown; anchors.fill: parent; radius: 2; color: Theme.usageTrack }
  Row {
    visible: bar.unknown
    clip: true
    width: parent.width
    spacing: 3
    Repeater { model: Math.ceil(bar.width / 7); Rectangle { width: 4; height: 4; radius: 2; color: Theme.quaternary } }
  }
  Item {
    width: bar.width * bar.progress
    height: parent.height
    clip: true
    Rectangle {
      readonly property real share: Math.max(0, Math.min(1, bar.fill))
      width: bar.unknown || share <= 0 ? 0 : Math.min(bar.width, Math.max(4, bar.width * share))
      height: parent.height
      radius: 2
      color: Theme.usageColor(bar.provider, bar.used)
      Behavior on width { NumberAnimation { duration: Theme.dFill; easing.type: Easing.BezierCurve; easing.bezierCurve: Theme.easeOut } }
    }
  }
  Rectangle {
    visible: bar.pace >= 0 && !bar.unknown
    width: 1.5
    height: 8
    y: -2
    x: Math.max(0, Math.min(bar.width - 1.5, bar.pace * bar.width - 0.75))
    color: Theme.ink(0.7)
  }

  NumberAnimation { id: grow; target: bar; property: "progress"; from: 0; to: 1; duration: Theme.motion ? 300 : 0
                    easing.type: Easing.BezierCurve; easing.bezierCurve: Theme.easeOut }
  function replay() { grow.restart() }
}
