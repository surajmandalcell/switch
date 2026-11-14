import QtQuick

// numericText content transition (0.30 s ease-out): the old value leaves upward, the new one arrives from below.
Item {
  id: r
  property string text: ""
  property string role: "title"
  property bool tabular: true
  property string shown: text
  implicitWidth: cur.implicitWidth
  implicitHeight: cur.height
  clip: true

  onTextChanged: {
    if (text === shown) return
    old.text = shown
    cur.text = text
    shown = text
    anim.restart()
  }
  Txt { id: cur; role: r.role; tabular: r.tabular; text: r.text }
  Txt { id: old; role: r.role; tabular: r.tabular; opacity: 0 }
  ParallelAnimation {
    id: anim
    NumberAnimation { target: cur; property: "opacity"; from: 0; to: 1; duration: 300; easing.type: Easing.BezierCurve; easing.bezierCurve: Theme.easeOut }
    NumberAnimation { target: cur; property: "y"; from: 10; to: 0; duration: 300; easing.type: Easing.BezierCurve; easing.bezierCurve: Theme.easeOut }
    NumberAnimation { target: old; property: "opacity"; from: 1; to: 0; duration: 300; easing.type: Easing.BezierCurve; easing.bezierCurve: Theme.easeOut }
    NumberAnimation { target: old; property: "y"; from: 0; to: -10; duration: 300; easing.type: Easing.BezierCurve; easing.bezierCurve: Theme.easeOut }
  }
}
