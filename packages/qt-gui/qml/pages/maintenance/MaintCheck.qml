import QtQuick

// CleanupCheck (maintenance.md 1.4): the shared 16 x 16 checkbox, driven from outside, with a third state.
// value: 0 off, 1 mixed, 2 on. Optional label 6 to the right (AIMCheckboxToggleStyle).
Item {
  id: c
  property int value: 0
  property string label: ""
  property string text: ""
  signal clicked()
  implicitWidth: 16 + (text !== "" ? 6 + lbl.implicitWidth : 0)
  width: implicitWidth
  height: 16
  opacity: !enabled ? 0.45 : (mouse.pressed ? 0.8 : 1)
  activeFocusOnTab: enabled
  Accessible.role: Accessible.CheckBox
  Accessible.name: label !== "" ? label : text
  Accessible.checked: value === 2
  Accessible.description: value === 2 ? "Checked" : (value === 1 ? "Some checked" : "Unchecked")
  Keys.onSpacePressed: clicked()

  Rectangle {
    width: 16
    height: 16
    radius: 4
    color: c.value === 0 ? Theme.controlFill : Theme.checkedControlFill
    border.width: c.value === 0 ? Theme.hair : 0
    border.color: Theme.controlBorder
    Behavior on color { ColorAnimation { duration: Theme.dState } }
    Icon { anchors.centerIn: parent; size: 12; color: "white"; name: c.value === 1 ? "minus" : "check"; visible: c.value !== 0 }
    FocusFill { radius: 4 }
  }
  Txt { id: lbl; x: 22; anchors.verticalCenter: parent.verticalCenter; text: c.text; visible: c.text !== "" }
  MouseArea { id: mouse; anchors.fill: parent; enabled: c.enabled; onClicked: c.clicked() }
}
