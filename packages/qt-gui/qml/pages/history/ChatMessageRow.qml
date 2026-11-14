import QtQuick

// One message (history.md 2.1): at most 820 wide, 12 left, 2 right (+ the 10 pt gutter), top 12 at a role change
// else 4, bottom 4. A 36 pt header strip (role, Response model, date, copy), 12 gap, then the section panels 10
// apart and the shortened note. Every role shares the same layout.
Item {
  id: row
  property var msg: ({})
  property bool separated: true
  property var toggled: []
  property string dateText: ""
  property bool fadeIn: false
  signal toggle(int id)
  signal copy(string text)
  readonly property var roleNames: ({ user: "Prompt", assistant: "Response", tool: "Tool", other: "Other" })
  height: col.y + col.height + 4
  opacity: 1
  Accessible.role: Accessible.ListItem
  Accessible.name: (roleNames[msg.role] || "Other") + (dateText ? ", " + dateText : "")

  Component.onCompleted: if (fadeIn) { opacity = 0.4; fade.start() }
  NumberAnimation { id: fade; target: row; property: "opacity"; to: 1; duration: Theme.dAppear
                    easing.type: Easing.Bezier; easing.bezierCurve: Theme.easeOut }

  Column {
    id: col
    x: 12
    y: row.separated ? 12 : 4
    width: Math.min(820, row.width - 24)
    spacing: 12

    Rectangle {
      width: parent.width
      height: 36
      radius: 10
      color: Theme.ink(0.02)
      border.width: Theme.hair
      border.color: Theme.separator
      Item {
        x: 12
        width: parent.width - 24
        height: 20
        anchors.verticalCenter: parent.verticalCenter
        Txt { id: roleT; role: "section"; text: row.roleNames[row.msg.role] || "Other"; anchors.verticalCenter: parent.verticalCenter }
        Txt { id: mdot; visible: modelT.visible; x: roleT.width + 6; role: "secondary"; color: Theme.secondary; text: "·"
              anchors.verticalCenter: parent.verticalCenter }
        Txt {
          id: modelT
          visible: row.msg.role === "assistant" && !!row.msg.model
          x: mdot.x + mdot.width + 6
          width: Math.max(0, Math.min(implicitWidth, copyB.x - 6 - (dateT.visible ? 30 + dateT.implicitWidth : 0) - x))
          role: "secondary"; color: Theme.secondary; elide: Text.ElideRight
          text: row.msg.model || ""
          anchors.verticalCenter: parent.verticalCenter
          ToolTipArea { text: row.msg.model || "" }
        }
        Txt {
          id: dateT
          visible: row.dateText !== ""
          x: (modelT.visible ? modelT.x + modelT.width : roleT.width) + 6 + 24
          role: "secondary"; tabular: true; color: Theme.secondary; text: row.dateText
          anchors.verticalCenter: parent.verticalCenter
          ToolTipArea { text: row.dateText }
        }
        ChatCopyIcon { id: copyB; x: parent.width - width; anchors.verticalCenter: parent.verticalCenter; label: "Copy message"
                       onCopy: row.copy(row.msg.text) }
      }
    }

    Column {
      width: parent.width
      spacing: 10
      Repeater {
        model: row.msg.pres ? row.msg.pres.sections : []
        ChatSection {
          width: col.width
          section: modelData
          bare: row.msg.role === "tool"
          toggled: row.toggled
          onToggle: function (id) { row.toggle(id) }
          onCopy: function (t) { row.copy(t) }
        }
      }
      Txt {
        visible: !!row.msg.pres && row.msg.pres.truncated
        role: "secondary"; color: Theme.amber
        text: "This long message is shortened in the reader."
      }
    }
  }
}
