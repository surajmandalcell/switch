import QtQuick

// A form row (4.2, settings.md 1.3): title and one help line on the left, the control on the right.
// The separator is its own one-pixel row below, as on the Mac: rows sit 49 pt apart at 1x.
Item {
  id: row
  property string title: ""
  property string help: ""
  property bool helpWraps: false   // Privacy mode only (settings.md 1.3)
  property string detail: ""       // third line, monospaced, middle ellipsis (Data locations paths)
  property string error: ""        // extra red line under the help, such as a failed write (claude-shell)
  property bool last: false
  default property alias control: ctl.data
  readonly property real contentH: Math.max(16 + (help !== "" ? 2 + helpText.height : 0) + (detail !== "" ? 2 + 14 : 0)
                                            + (error !== "" ? 2 + errText.height : 0), ctl.height)
  readonly property real sep: last ? 0 : Theme.hair

  width: parent ? parent.width : 400
  height: (last ? 8 + contentH + 14 : Math.max(36, 8 + contentH + 8)) + sep
  Accessible.role: Accessible.Grouping
  Accessible.name: title
  Accessible.description: help
  // A control without its own name (Switch, Segmented, PopUp, FieldBox) takes the row title as its accessible name.
  Component.onCompleted: {
    for (var i = 0; i < ctl.children.length; ++i) {
      var c = ctl.children[i]
      if (typeof c.name === "string" && c.name === "" && "activeFocusOnTab" in c) c.name = Qt.binding(function () { return row.title })
    }
  }

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
      Txt { id: errText; visible: row.error !== ""; width: parent.width; role: "secondary"; color: Theme.red; wrapMode: Text.Wrap; text: row.error }
      Txt {
        visible: row.detail !== ""
        width: parent.width
        role: "secondary"
        color: Theme.secondary
        font.family: Theme.monoFamily
        text: row.detail
        elide: Text.ElideMiddle
        // settings.md 2.7: a click copies the path and a "Copied" badge shows for 700 ms
        activeFocusOnTab: true
        Accessible.role: Accessible.Button
        Accessible.name: "Copy path: " + row.detail
        Accessible.onPressAction: copyPath()
        FocusFill { anchors.fill: undefined; x: -3; width: Math.min(parent.width, parent.contentWidth) + 6; height: parent.height; radius: 3 }
        Keys.onReturnPressed: copyPath()
        Keys.onSpacePressed: copyPath()
        function copyPath() { App.copy(row.detail); copied.opacity = 1; copiedTimer.restart() }
        ToolTipArea { text: "Click to copy " + row.detail }
        MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: parent.copyPath() }
        Timer { id: copiedTimer; interval: 700; onTriggered: copied.opacity = 0 }
        Rectangle {
          id: copied
          opacity: 0
          Behavior on opacity { NumberAnimation { duration: Theme.motion ? 80 : 0 } }
          x: Math.min(parent.width, parent.contentWidth) - width
          y: -height - 2
          width: copiedText.width + 12
          height: 18
          radius: 5
          color: Theme.solidSurface
          border.width: Theme.hair
          border.color: Theme.popoverBorder
          Txt { id: copiedText; anchors.centerIn: parent; role: "caption"; text: "Copied" }
        }
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
