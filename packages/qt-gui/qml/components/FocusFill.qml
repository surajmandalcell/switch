import QtQuick

// Keyboard focus is a tint in the control's own shape, never a ring (4.17), and only after a key moved
// focus: a click never shows it.
Rectangle {
  anchors.fill: parent
  color: Theme.focusTint
  visible: parent.activeFocus && App.keyboardMode
}
