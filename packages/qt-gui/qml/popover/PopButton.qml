import QtQuick

// MenuBarButtonStyle (popover.md 3.7): 24 high, radius 5, secondary fill, 6% hover veil, 10% press.
Item {
  id: b
  property string text: ""
  property string icon: ""
  property string hint: ""
  property bool square: false
  property real spin: 0
  signal clicked()
  height: 24
  width: square ? 24 : content.width + 12
  opacity: enabled ? 1 : 0.45

  Rectangle { anchors.fill: parent; radius: 5; color: Theme.popButtonFill }
  Rectangle {
    anchors.fill: parent
    radius: 5
    color: m.pressed ? Theme.popButtonPress : Theme.popButtonHover
    opacity: (hh.hovered || m.pressed) && b.enabled ? 1 : 0
    Behavior on opacity { NumberAnimation { duration: Theme.dHover; easing.type: Easing.BezierCurve; easing.bezierCurve: Theme.easeOut } }
  }
  Row {
    id: content
    anchors.centerIn: parent
    spacing: 8
    Icon { visible: b.icon !== ""; anchors.verticalCenter: parent.verticalCenter; name: b.icon; size: 14; rotation: b.spin }
    Txt { visible: b.text !== ""; anchors.verticalCenter: parent.verticalCenter; text: b.text }
    Txt { visible: b.hint !== ""; anchors.verticalCenter: parent.verticalCenter; role: "secondary"; color: Theme.secondary; text: b.hint }
  }
  HoverHandler { id: hh }
  MouseArea { id: m; anchors.fill: parent; onClicked: if (b.enabled) b.clicked() }
}
