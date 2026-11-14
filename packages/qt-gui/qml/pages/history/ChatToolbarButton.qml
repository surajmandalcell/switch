import QtQuick

// The five buttons under "Search this chat" (history.md 1.4): 32 high, radius 6, 10 padding, icon and title 6
// apart and centered. Fill: pressed, else hover, else primary 4.5% when selected. Rim: primary 22% selected,
// 12% not, 8% disabled. Press scales 0.97. Keyboard focus is a tint in the same shape.
Item {
  id: b
  property string text: ""
  property string icon: ""
  property bool selected: true
  property string tip: ""
  signal clicked()
  height: 32
  activeFocusOnTab: enabled
  Accessible.role: Accessible.Button
  Accessible.name: text
  Accessible.onPressAction: if (enabled) clicked()
  Keys.onSpacePressed: if (enabled) clicked()
  Keys.onReturnPressed: if (enabled) clicked()
  scale: mouse.pressed && enabled && !Theme.reduceMotion ? 0.97 : 1
  Behavior on scale { NumberAnimation { duration: Theme.dHover } }

  Rectangle {
    anchors.fill: parent
    radius: 6
    color: mouse.pressed && b.enabled ? Theme.controlPressed : (hover.hovered && b.enabled ? Theme.rowHover : Theme.ink(b.selected ? 0.045 : 0))
    border.width: Theme.hair
    border.color: Theme.ink(!b.enabled ? 0.08 : (b.selected ? 0.22 : 0.12))
    Behavior on color { ColorAnimation { duration: Theme.dHover } }
    Behavior on border.color { ColorAnimation { duration: Theme.dState } }
  }
  Rectangle { anchors.fill: parent; radius: 6; color: Theme.focusTint; visible: b.activeFocus && App.keyboardMode && b.enabled }

  Row {
    anchors.centerIn: parent
    spacing: 6
    opacity: b.enabled ? 1 : 0.45
    Icon { name: b.icon; size: 14; color: Theme.label; anchors.verticalCenter: parent.verticalCenter }
    Txt { id: label; text: b.text; height: 16; elide: Text.ElideRight
          width: Math.min(implicitWidth, b.width - 20 - 20) }
  }
  HoverHandler { id: hover }
  ToolTipArea { text: b.tip }
  MouseArea { id: mouse; anchors.fill: parent; onClicked: if (b.enabled) b.clicked() }
}
