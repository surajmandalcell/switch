import QtQuick

// Label-left, value-right line (LabeledContent): Body label, flexible gap (min 8), Secondary value.
// A value that starts with "/" or "~/" is a copyable path (account-window.md 2.7): mono, middle
// truncation, pointing hand, "Click to copy <path>", a "Copied" badge 18 above for 700 ms.
Item {
  id: f
  property string label: ""
  property string value: ""
  property bool mono: false
  property string tip: ""
  property bool clickable: false
  property var ctl: null
  signal clicked()
  readonly property bool isPath: value.charAt(0) === "/" || value.indexOf("~/") === 0
  width: parent ? parent.width : 400
  height: 16

  Txt { id: lab; text: f.label; width: Math.min(implicitWidth, f.width * 0.45); elide: Text.ElideRight; anchors.verticalCenter: parent.verticalCenter }
  Txt {
    id: val
    anchors.right: parent.right
    anchors.verticalCenter: parent.verticalCenter
    width: Math.min(implicitWidth, f.width - lab.width - 16)
    horizontalAlignment: Text.AlignRight
    role: "secondary"
    tabular: true
    color: Theme.secondary
    font.family: f.isPath || f.mono ? "monospace" : Theme.fontFamily
    elide: Text.ElideMiddle
    text: f.value
    ToolTipArea { text: f.isPath ? "Click to copy " + f.value : (f.tip !== "" ? f.tip : (val.truncated ? f.value : "")) }
    MouseArea {
      anchors.fill: parent
      enabled: f.isPath || f.clickable
      cursorShape: Qt.PointingHandCursor
      onClicked: {
        if (f.isPath && f.ctl) { f.ctl.copy(f.value); copied.opacity = 1; copiedTimer.restart() }
        else f.clicked()
      }
    }
    Accessible.role: f.isPath ? Accessible.Button : Accessible.StaticText
    Accessible.name: f.isPath ? "Copy path: " + f.value : f.value
  }
  Badge {
    id: copied
    opacity: 0
    visible: opacity > 0
    dot: Theme.green
    text: "Copied"
    anchors.right: parent.right
    y: -18
    Behavior on opacity { NumberAnimation { duration: Theme.dHover } }
  }
  Timer { id: copiedTimer; interval: 700; onTriggered: copied.opacity = 0 }
}
