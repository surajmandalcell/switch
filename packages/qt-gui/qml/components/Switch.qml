import QtQuick

// AIMToggleStyle (4.8): 38 x 22 capsule, 18 pt white knob, 100 ms ease-out, Accent when on.
Item {
  id: sw
  property bool checked: false
  property string name: ""
  signal toggled(bool value)

  width: 38
  height: 22
  opacity: !enabled ? 0.45 : (mouse.pressed ? 0.8 : 1)
  activeFocusOnTab: enabled
  Accessible.role: Accessible.CheckBox
  Accessible.name: name
  Accessible.checked: checked
  Keys.onSpacePressed: flip()
  function flip() { checked = !checked; toggled(checked) }

  Rectangle {
    id: track
    anchors.fill: parent
    radius: height / 2
    color: sw.checked ? Theme.accent : Theme.switchOff
    border.width: Theme.hair
    border.color: Theme.controlBorder
    Behavior on color { ColorAnimation { duration: Theme.dState; easing.type: Easing.BezierCurve; easing.bezierCurve: Theme.easeOut } }

    // controlShadow: black 6%, blur 0.5, y 0.5, Light only
    Rectangle { x: knob.x - 0.25; y: knob.y + 0.5; width: 18.5; height: 18.5; radius: 9.25; color: Theme.controlShadow }
    Rectangle {
      id: knob
      width: 18
      height: 18
      radius: 9
      y: 2
      x: sw.checked ? track.width - 20 : 2
      color: "white"
      Behavior on x { enabled: !Theme.reduceMotion; NumberAnimation { duration: Theme.dState; easing.type: Easing.BezierCurve; easing.bezierCurve: Theme.easeOut } }
    }
  }
  FocusFill { radius: height / 2 }
  MouseArea { id: mouse; anchors.fill: parent; enabled: sw.enabled; onClicked: sw.flip() }
}
