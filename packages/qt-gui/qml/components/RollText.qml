import QtQuick

// numericText content transition (0.30 s ease-out): the old value leaves upward, the new one arrives from below.
Item {
  id: r
  property string text: ""
  property string role: "title"
  property bool tabular: true
  property color color: Theme.label
  property string shown: text
  implicitWidth: cur.implicitWidth
  implicitHeight: cur.height
  clip: true

  onTextChanged: {
    if (text === shown) return
    var first = shown === ""
    old.text = shown
    cur.text = text
    shown = text
    // A first value (data just loaded) appears at once, as SwiftUI shows a view's first content; no motion skips too.
    if (first || !Theme.motion || Theme.reduceMotion) { anim.stop(); cur.y = 0; cur.opacity = 1; old.opacity = 0; return }
    anim.restart()
  }
  Txt { id: cur; role: r.role; tabular: r.tabular; color: r.color; text: r.text }
  Txt { id: old; role: r.role; tabular: r.tabular; color: r.color; opacity: 0 }
  ParallelAnimation {
    id: anim
    NumberAnimation { target: cur; property: "opacity"; from: 0; to: 1; duration: 300; easing.type: Easing.Bezier; easing.bezierCurve: Theme.easeOut }
    NumberAnimation { target: cur; property: "y"; from: 10; to: 0; duration: 300; easing.type: Easing.Bezier; easing.bezierCurve: Theme.easeOut }
    NumberAnimation { target: old; property: "opacity"; from: 1; to: 0; duration: 300; easing.type: Easing.Bezier; easing.bezierCurve: Theme.easeOut }
    NumberAnimation { target: old; property: "y"; from: 0; to: -10; duration: 300; easing.type: Easing.Bezier; easing.bezierCurve: Theme.easeOut }
  }
}
