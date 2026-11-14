import QtQuick

// Search field (shell.md 2.3): 300 x 28, radius 6, padding 8, items 6 apart: magnifier, input, then the
// key hint (empty) or a clear button (text). Fill + 1 px rim; keyboard focus tints the whole field.
Rectangle {
  id: field
  property alias text: input.text
  property string placeholder: "Search accounts and settings…"
  property string hint: "Ctrl K"
  signal escaped()
  width: 300
  height: 28
  radius: 6
  color: Theme.controlFill
  border.width: Theme.hair
  border.color: Theme.controlBorder
  Accessible.role: Accessible.EditableText
  Accessible.name: placeholder.replace("…", "")
  function focusInput() { input.forceActiveFocus(); input.selectAll() }

  Rectangle {
    anchors.fill: parent
    radius: 6
    color: Theme.focusTint
    opacity: input.activeFocus ? 1 : 0
    Behavior on opacity { NumberAnimation { duration: Theme.dHover } }
  }
  // the whole field focuses the input (ui-quality: complete control surface is clickable)
  MouseArea { anchors.fill: parent; cursorShape: Qt.IBeamCursor; onPressed: input.forceActiveFocus() }
  Icon { id: glass; x: 8; anchors.verticalCenter: parent.verticalCenter; name: "search"; size: 15; color: Theme.secondary }
  TextInput {
    id: input
    x: glass.x + glass.width + 6
    width: (input.text === "" ? hintBox.x : clear.x) - 6 - x
    height: parent.height
    verticalAlignment: TextInput.AlignVCenter
    clip: true
    color: Theme.label
    selectionColor: Theme.rgba(Theme.accent, 0.3)
    selectedTextColor: Theme.label
    font.family: Theme.fontFamily
    font.pointSize: 13 * Theme.fontScale * 0.75   // points at 96 dpi; pixelSize would round to whole pixels
    font.variableAxes: ({ "wght": 400 })
    font.letterSpacing: -0.006 * 13 * Theme.fontScale
    font.hintingPreference: Font.PreferNoHinting
    Keys.onEscapePressed: { text = ""; focus = false; field.escaped() }
    // The Mac prompt measures near the label tone (black about 75% / white about 76%), not secondary.
    Txt { visible: input.text === ""; text: field.placeholder; color: Theme.ink(0.9); anchors.verticalCenter: parent.verticalCenter }
  }
  Rectangle {
    id: hintBox
    visible: input.text === ""
    x: parent.width - 8 - width
    anchors.verticalCenter: parent.verticalCenter
    width: hintText.implicitWidth + 12
    height: 14
    radius: 4
    color: Theme.ink(0.06)
    Txt { id: hintText; anchors.centerIn: parent; role: "secondary"; color: Theme.secondary; text: field.hint }
  }
  IconButton {
    id: clear
    visible: input.text !== ""
    x: parent.width - 8 - width
    anchors.verticalCenter: parent.verticalCenter
    icon: "xmarkCircle"
    glyph: 13
    tip: "Clear search"
    onClicked: { input.text = ""; input.forceActiveFocus() }
  }
}
