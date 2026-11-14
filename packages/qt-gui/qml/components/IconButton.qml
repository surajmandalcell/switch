import QtQuick

// AIMIconButtonStyle (4.5): borderless icon in Body size, secondary by default (danger red, active accent).
// Hover or focus: a radius 6 fill 4 pt beyond the glyph on every side, without changing layout.
// Pressed: opacity 0.7 and scale 0.97. Tooltip and accessibility name always.
Item {
  id: b
  property string icon: ""
  property string tip: ""
  property string tone: "normal"   // "normal" | "danger" | "active"
  property real glyph: 14
  signal clicked()
  width: glyph
  height: glyph
  opacity: !enabled ? 0.45 : (mouse.pressed ? 0.7 : 1)
  scale: mouse.pressed && !Theme.reduceMotion ? 0.97 : 1
  activeFocusOnTab: enabled
  Accessible.role: Accessible.Button
  Accessible.name: tip
  Accessible.onPressAction: clicked()
  Keys.onSpacePressed: clicked()

  Rectangle {
    x: -4; y: -4
    width: parent.width + 8
    height: parent.height + 8
    radius: 6
    color: b.activeFocus && App.keyboardMode ? Theme.focusTint : Theme.rowHover
    opacity: hover.hovered || (b.activeFocus && App.keyboardMode) ? 1 : 0
    Behavior on opacity { NumberAnimation { duration: Theme.dHover; easing.type: Easing.BezierCurve; easing.bezierCurve: Theme.easeOut } }
  }
  Icon {
    anchors.centerIn: parent
    name: b.icon
    size: b.glyph
    color: b.tone === "danger" ? Theme.red : (b.tone === "active" ? Theme.accent : Theme.secondary)
  }
  HoverHandler { id: hover }
  ToolTipArea { text: b.tip }
  MouseArea { id: mouse; x: -4; y: -4; width: parent.width + 8; height: parent.height + 8; onClicked: if (b.enabled) b.clicked() }
}
