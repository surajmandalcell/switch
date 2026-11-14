import QtQuick

// AIMCheckboxToggleStyle (4.9): 16 x 16, radius 4, label gap 6. Off: control fill + rim. On (or mixed):
// checkedControlFill + white check (or minus), no rim. Pressed 0.8, disabled 0.45.
Item {
  id: cb
  property bool checked: false
  property bool mixed: false
  property string text: ""
  signal toggled(bool value)

  implicitWidth: 16 + (text !== "" ? 6 + label.implicitWidth : 0)
  implicitHeight: 16
  width: implicitWidth
  height: implicitHeight
  opacity: !enabled ? 0.45 : (mouse.pressed ? 0.8 : 1)
  activeFocusOnTab: enabled
  Accessible.role: Accessible.CheckBox
  Accessible.name: text
  Accessible.checked: checked
  Keys.onSpacePressed: flip()
  function flip() { checked = !checked; mixed = false; toggled(checked) }

  Rectangle {
    id: box
    width: 16
    height: 16
    radius: 4
    color: cb.checked || cb.mixed ? Theme.checkedControlFill : Theme.controlFill
    border.width: cb.checked || cb.mixed ? 0 : Theme.hair
    border.color: Theme.controlBorder
    Behavior on color { ColorAnimation { duration: Theme.dState } }
    Icon { anchors.centerIn: parent; size: 12; color: "white"; name: cb.mixed ? "minus" : "check"; visible: cb.checked || cb.mixed }
    FocusFill { radius: 4; visible: cb.activeFocus && App.keyboardMode }
  }
  Txt { id: label; x: 22; anchors.verticalCenter: parent.verticalCenter; text: cb.text; visible: cb.text !== "" }
  MouseArea { id: mouse; anchors.fill: parent; enabled: cb.enabled; onClicked: cb.flip() }
}
