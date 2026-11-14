import QtQuick

// History search field (history.md 1.5): 28 high, radius 6, field chrome, 8 padding, items 6 apart: magnifier,
// input, then a small spinner or a status text, then a clear button when there is text. A click anywhere in the
// field focuses the input; focus is a tint, never a ring.
Rectangle {
  id: f
  property alias text: input.text
  property alias input: input
  property string placeholder: ""
  property string status: ""
  property bool busy: false
  height: 28
  radius: 6
  color: Theme.controlFill
  border.width: Theme.hair
  border.color: Theme.controlBorder

  Rectangle { anchors.fill: parent; radius: 6; color: Theme.focusTint; opacity: input.activeFocus ? 1 : 0
              Behavior on opacity { NumberAnimation { duration: Theme.dHover } } }
  MouseArea { anchors.fill: parent; cursorShape: Qt.IBeamCursor; onPressed: input.forceActiveFocus() }

  Icon { id: glass; x: 8; anchors.verticalCenter: parent.verticalCenter; name: "search"; size: 15; color: Theme.secondary }
  TextInput {
    id: input
    x: glass.x + glass.width + 6
    width: trail.x - 6 - x
    height: parent.height
    verticalAlignment: TextInput.AlignVCenter
    clip: true
    selectByMouse: true
    activeFocusOnTab: true
    color: Theme.label
    selectionColor: Theme.dark ? Theme.w(0.25) : Theme.rgba(Theme.accent, 0.3)
    selectedTextColor: Theme.label
    font.family: Theme.fontFamily
    font.pointSize: 13 * Theme.fontScale * 0.75
    font.variableAxes: ({ "wght": 400 })
    font.letterSpacing: -0.006 * 13 * Theme.fontScale
    font.hintingPreference: Font.PreferNoHinting
    Accessible.role: Accessible.EditableText
    Accessible.name: f.placeholder
    Accessible.description: f.status
    // IME: `text` holds only committed text, so a search never runs on a half-typed composition
    Keys.onEscapePressed: function (e) { if (input.text !== "") { input.text = ""; e.accepted = true } else e.accepted = false }
    Txt { visible: input.text === "" && input.preeditText === ""; text: f.placeholder; color: Theme.tertiary; anchors.verticalCenter: parent.verticalCenter }
  }
  Row {
    id: trail
    x: parent.width - 8 - width
    height: parent.height
    spacing: 6
    ChatSpinner { visible: f.busy; size: 12; anchors.verticalCenter: parent.verticalCenter }
    Txt { visible: !f.busy && f.status !== ""; role: "secondary"; tabular: true; color: Theme.secondary; text: f.status
          anchors.verticalCenter: parent.verticalCenter }
    IconButton { visible: input.text !== ""; icon: "xmarkCircle"; glyph: 13; tip: "Clear search"; anchors.verticalCenter: parent.verticalCenter
                 onClicked: { input.text = ""; input.forceActiveFocus() } }
  }
}
