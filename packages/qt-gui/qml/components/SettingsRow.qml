import QtQuick

// A form row (4.2, settings.md 1.3): title and one help line on the left, the control on the right.
// The separator is its own one-pixel row below, as on the Mac: rows sit 49 pt apart at 1x.
Item {
  id: row
  property string title: ""
  property string help: ""
  property bool helpWraps: false   // Privacy mode only (settings.md 1.3)
  property string detail: ""       // third line, monospaced, middle ellipsis (Data locations paths)
  property bool last: false
  default property alias control: ctl.data
  readonly property real contentH: Math.max(16 + (help !== "" ? 2 + helpText.height : 0) + (detail !== "" ? 2 + 14 : 0), ctl.height)
  readonly property real sep: last ? 0 : Theme.hair

  width: parent ? parent.width : 400
  height: (last ? 8 + contentH + 14 : Math.max(36, 8 + contentH + 8)) + sep
  Accessible.role: Accessible.Grouping
  Accessible.name: title

  Item {
    y: 8
    width: parent.width
    height: row.contentH
    Column {
      x: 16
      width: Math.max(0, parent.width - ctl.width - 16 - 16 - 16)
      anchors.verticalCenter: parent.verticalCenter
      spacing: 2
      Txt { width: parent.width; text: row.title; elide: Text.ElideRight }
      Txt {
        id: helpText
        visible: row.help !== ""
        width: parent.width
        role: "secondary"
        color: Theme.secondary
        text: row.help
        elide: row.helpWraps ? Text.ElideNone : Text.ElideRight
        wrapMode: row.helpWraps ? Text.Wrap : Text.NoWrap
        ToolTipArea { text: row.helpWraps || !helpText.truncated ? "" : row.help }
      }
      Txt {
        visible: row.detail !== ""
        width: parent.width
        role: "secondary"
        color: Theme.secondary
        font.family: "monospace"
        text: row.detail
        elide: Text.ElideMiddle
      }
    }
    Row {
      id: ctl
      anchors.right: parent.right
      anchors.rightMargin: 16
      anchors.verticalCenter: parent.verticalCenter
      spacing: 8
    }
  }
  Rectangle {
    visible: !row.last
    x: 16
    y: parent.height - Theme.hair
    width: parent.width - 32
    height: Theme.hair
    color: Theme.tableSeparator
  }
}
