import QtQuick
import "ChatMarkdown.js" as MD

// Code block (history.md 2.3.2): radius 6, clipped; header strip 30 (language or CODE, copy button) on primary
// 8%, body primary 6%, Secondary mono text that soft-wraps, 12 padding. Past 600 lines or 60,000 characters it
// shows the first part and a "Show all N lines" link button. Bare (tool output): no strip, fill, or padding.
Rectangle {
  id: cb
  property var block: ({})
  property bool bare: false
  property bool open: false
  signal toggle()
  signal copy(string text)
  readonly property string full: block.expanded !== null && block.expanded !== undefined ? block.expanded : block.preview
  readonly property bool isLong: block.expanded !== null && block.expanded !== undefined
  height: col.height
  radius: 6
  clip: true
  color: bare ? "transparent" : Theme.ink(0.06)

  function escHtml(s) { return s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;") }

  Column {
    id: col
    width: parent.width
    Rectangle {
      visible: !cb.bare
      width: parent.width
      height: 30
      color: Theme.ink(0.08)
      Txt { x: 12; anchors.verticalCenter: parent.verticalCenter; role: "secondary"; color: Theme.secondary
            font.family: Theme.monoFamily; font.letterSpacing: 0; text: cb.block.language ? cb.block.language.toUpperCase() : "CODE" }
      ChatCopyIcon { x: parent.width - 12 - width; anchors.verticalCenter: parent.verticalCenter; label: "Copy code"
                     onCopy: cb.copy(cb.full) }
    }
    Item {
      width: parent.width
      height: code.height + (cb.bare ? 0 : 24)
      ChatText {
        id: code
        x: cb.bare ? 0 : 12
        y: cb.bare ? 0 : 12
        width: parent.width - 2 * x
        mono: true
        html: cb.escHtml(cb.open && cb.isLong ? cb.block.expanded : cb.block.preview)
      }
    }
    Item {
      visible: cb.isLong
      width: parent.width
      height: visible ? link.height + (cb.bare ? 6 : 10) : 0
      Txt {
        id: link
        x: cb.bare ? 0 : 12
        y: cb.bare ? 6 : 0
        color: Theme.link
        text: cb.open ? "Show fewer lines" : "Show all " + Number(MD.lineCount(cb.block.expanded || "")).toLocaleString(Qt.locale(), "f", 0) + " lines"
        MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: cb.toggle() }
        activeFocusOnTab: cb.isLong
        Keys.onSpacePressed: cb.toggle()
        Keys.onReturnPressed: cb.toggle()
        Rectangle { anchors.fill: parent; anchors.margins: -3; radius: 4; color: Theme.focusTint; visible: link.activeFocus && App.keyboardMode }
        Accessible.role: Accessible.Button
        Accessible.name: text
        Accessible.onPressAction: cb.toggle()
      }
    }
    Item {
      visible: !cb.isLong && !!cb.block.srcTrunc
      width: parent.width
      height: visible ? 14 + (cb.bare ? 0 : 10) : 0
      Txt { x: cb.bare ? 0 : 12; role: "secondary"; color: Theme.amber; text: "Code shortened" }
    }
  }
}
