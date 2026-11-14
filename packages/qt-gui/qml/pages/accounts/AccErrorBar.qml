import QtQuick

// Error bar (shell.md 2, AW:843-857): a card with one row (16 x 8 padding, 8 apart): red warning icon,
// the message (Body, at most 2 lines, tooltip), "Copy error" icon, "Dismiss".
Card {
  id: bar
  property string text: ""
  signal dismiss()
  signal copy()
  Item {
    width: parent.width
    height: Math.max(28, msg.height) + 16
    Icon { id: warn; x: 16; anchors.verticalCenter: parent.verticalCenter; name: "warnFill"; size: 14; color: Theme.red }
    Txt {
      id: msg
      x: warn.x + warn.width + 8
      anchors.verticalCenter: parent.verticalCenter
      width: copyBtn.x - 8 - x
      height: implicitHeight
      lineHeightMode: Text.FixedHeight
      wrapMode: Text.Wrap
      maximumLineCount: 2
      elide: Text.ElideRight
      text: bar.text
      ToolTipArea { text: msg.truncated ? bar.text : "" }
    }
    AccCopyIcon { id: copyBtn; x: dismiss.x - 8 - width - 4; anchors.verticalCenter: parent.verticalCenter; tip: "Copy error"; onCopy: bar.copy() }
    PushButton { id: dismiss; x: parent.width - 16 - width; anchors.verticalCenter: parent.verticalCenter; text: "Dismiss"; onClicked: bar.dismiss() }
  }
}
