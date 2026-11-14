import QtQuick

// AIMChipToggleStyle (4.10): 98 x 24, radius 6, check slot 10 (hidden when off), gap 5, Body label.
// On: checkboxSelection fill, no rim. Off: 1 px separator a0.35 border. Fade 0.15.
Item {
  id: chip
  property bool checked: false
  property string text: ""
  signal toggled(bool value)
  width: 98
  height: 24
  opacity: enabled ? 1 : 0.45
  activeFocusOnTab: enabled
  Accessible.role: Accessible.CheckBox
  Accessible.name: text
  Accessible.checked: checked
  Keys.onSpacePressed: flip()
  function flip() { checked = !checked; toggled(checked) }

  Rectangle {
    anchors.fill: parent
    radius: 6
    color: chip.checked ? Theme.checkboxSelection : "transparent"
    border.width: chip.checked ? 0 : 1
    border.color: Theme.rgba(Theme.separator, Theme.separator.a * 0.35)
    Behavior on color { ColorAnimation { duration: Theme.motion ? 150 : 0 } }
  }
  FocusFill { radius: 6 }
  Row {
    x: 8
    anchors.verticalCenter: parent.verticalCenter
    spacing: 5
    Item { width: 10; height: 10; anchors.verticalCenter: parent.verticalCenter
      Icon { anchors.centerIn: parent; size: 10; name: "check"; visible: chip.checked; color: Theme.passiveIcon } }
    Txt { text: chip.text; anchors.verticalCenter: parent.verticalCenter }
  }
  MouseArea { anchors.fill: parent; enabled: chip.enabled; onClicked: chip.flip() }
}
