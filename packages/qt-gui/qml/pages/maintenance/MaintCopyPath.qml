import QtQuick

// AIMCopyablePath (maintenance.md 1.4): Secondary monospaced, one line, middle truncation. Click, Return,
// or Space copies the path; a "Copied" Badge shows 18 above the text at its right end for 700 ms.
Item {
  id: cp
  property string path: ""
  property string tip: "Click to copy " + path
  implicitWidth: label.implicitWidth
  implicitHeight: 14
  height: 14
  activeFocusOnTab: true
  Accessible.role: Accessible.Button
  Accessible.name: "Copy path: " + path
  Accessible.onPressAction: copy()
  Keys.onReturnPressed: copy()
  Keys.onSpacePressed: copy()

  function copy() {
    if (path === "") return
    clip.text = path
    clip.selectAll()
    clip.copy()
    copied.opacity = 1
    hideTimer.restart()
  }

  Rectangle { anchors.fill: parent; anchors.margins: -1; radius: 3; color: Theme.focusTint; visible: cp.activeFocus && App.keyboardMode }
  Txt {
    id: label
    width: parent.width
    role: "secondary"
    color: Theme.secondary
    font.family: "monospace"
    text: cp.path
    elide: Text.ElideMiddle
  }
  TextEdit { id: clip; visible: false }
  Badge {
    id: copied
    text: "Copied"
    dot: Theme.green
    opacity: 0
    anchors.right: parent.right
    y: -18
    Behavior on opacity { NumberAnimation { duration: Theme.motion ? 80 : 0 } }
  }
  Timer { id: hideTimer; interval: 700; onTriggered: copied.opacity = 0 }
  ToolTipArea { text: cp.tip }
  MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: cp.copy() }
}
