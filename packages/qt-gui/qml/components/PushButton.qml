import QtQuick

// AIMPushButtonStyle (4.4): 28 high (22 in table rows), radius 6, fill + 1 px rim (Light only),
// hover veil, pressed fill + scale 0.97, disabled 0.45 per part, keyboard focus tint.
Item {
  id: b
  property string text: ""
  property string icon: ""
  property string trailingIcon: ""
  property string tip: ""
  property bool prominent: false
  property bool square: false
  property real controlHeight: 28
  property real minWidth: 0
  property color textColor: prominent ? "white" : Theme.label
  property alias hovered: hover.hovered
  readonly property bool pressed: mouse.pressed
  signal clicked()

  implicitHeight: controlHeight
  implicitWidth: square ? controlHeight : Math.max(minWidth, content.width + (controlHeight < 28 ? 20 : 24))
  width: implicitWidth
  height: implicitHeight
  activeFocusOnTab: enabled
  Accessible.role: Accessible.Button
  Accessible.name: text !== "" ? text : tip
  Accessible.onPressAction: clicked()
  Keys.onSpacePressed: clicked()
  Keys.onReturnPressed: clicked()

  scale: pressed && enabled && !Theme.reduceMotion ? 0.97 : 1
  Behavior on scale { NumberAnimation { duration: Theme.dHover; easing.type: Easing.BezierCurve; easing.bezierCurve: Theme.easeOut } }
  readonly property real dim: enabled ? 1 : 0.45

  Rectangle {
    anchors.fill: parent
    radius: 6
    opacity: b.dim
    color: b.prominent ? (b.pressed ? Theme.rgba(Theme.accent, 0.8) : Theme.accent) : (b.pressed ? Theme.controlPressed : Theme.controlFill)
    Behavior on color { ColorAnimation { duration: Theme.dHover; easing.type: Easing.BezierCurve; easing.bezierCurve: Theme.easeOut } }
    Rectangle {
      anchors.fill: parent
      radius: 6
      color: b.prominent ? Theme.w(0.14) : Theme.rowHover
      opacity: hover.hovered && b.enabled && !b.pressed ? 1 : 0
      Behavior on opacity { NumberAnimation { duration: Theme.dHover; easing.type: Easing.BezierCurve; easing.bezierCurve: Theme.easeOut } }
    }
    Rectangle {
      anchors.fill: parent
      radius: 6
      color: "transparent"
      border.width: Theme.hair
      border.color: b.prominent ? Theme.primaryBorder : Theme.controlBorder
    }
  }
  FocusFill { radius: 6; visible: b.activeFocus && App.keyboardMode && b.enabled }

  Row {
    id: content
    anchors.centerIn: parent
    spacing: 6
    opacity: b.dim
    Icon { visible: b.icon !== ""; name: b.icon; size: 14; color: b.textColor; anchors.verticalCenter: parent.verticalCenter }
    Txt { visible: b.text !== ""; text: b.text; color: b.textColor; height: 16 }
    Icon { visible: b.trailingIcon !== ""; name: b.trailingIcon; size: 12; color: Theme.secondary; anchors.verticalCenter: parent.verticalCenter }
  }

  HoverHandler { id: hover }
  ToolTipArea { text: b.tip }
  MouseArea { id: mouse; anchors.fill: parent; onClicked: if (b.enabled) b.clicked() }
}
