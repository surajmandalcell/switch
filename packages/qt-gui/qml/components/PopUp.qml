import QtQuick

// AIMPopUp (4.15): a push button with the current label and an up/down chevron; opens the menu panel.
PushButton {
  id: p
  property var options: []
  property int current: 0
  property string name: ""
  signal picked(int index)
  text: options[current] || ""
  trailingIcon: "chevronUD"
  Accessible.role: Accessible.ComboBox
  Accessible.name: name
  Accessible.description: text
  onClicked: Theme.menu.open(p, options, current, function (i) { p.current = i; p.picked(i) })
}
