import QtQuick

// WarningCopyButton (accounts.md 2.9): amber copy icon; after a click a green check for 900 ms.
IconButton {
  id: b
  signal copy()
  property bool done: false
  icon: done ? "check" : "copy"
  tone: "normal"
  onClicked: { b.copy(); done = true; t.restart() }
  Timer { id: t; interval: 900; onTriggered: b.done = false }
  // IconButton tints by tone; amber and green are this control's own colors.
  Component.onCompleted: children[1].color = Qt.binding(function () { return b.done ? Theme.green : Theme.amber })
}
