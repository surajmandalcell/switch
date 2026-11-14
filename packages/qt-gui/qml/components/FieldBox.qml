import QtQuick

// AIMFieldChrome (4.7): 28 high text field, radius 6, padding 8, rim (Light only), focus tint.
Rectangle {
  id: f
  property alias text: input.text
  property string placeholder: ""
  property alias input: input
  property bool secure: false
  height: 28
  radius: 6
  color: Theme.controlFill
  border.width: Theme.hair
  border.color: Theme.controlBorder
  opacity: enabled ? 1 : 0.45

  Rectangle {
    anchors.fill: parent
    radius: 6
    color: Theme.focusTint
    opacity: input.activeFocus ? 1 : 0
    Behavior on opacity { NumberAnimation { duration: Theme.dHover } }
  }

  TextInput {
    id: input
    anchors.fill: parent
    anchors.leftMargin: 8
    anchors.rightMargin: 8
    verticalAlignment: TextInput.AlignVCenter
    clip: true
    activeFocusOnTab: true
    echoMode: f.secure ? TextInput.Password : TextInput.Normal
    color: Theme.label
    selectionColor: Theme.dark ? Theme.w(0.12) : Theme.rgba(Theme.accent, 0.3)
    selectedTextColor: Theme.label
    selectByMouse: true
    font.family: Theme.fontFamily
    font.pointSize: 13 * Theme.fontScale * 0.75
    font.variableAxes: ({ "wght": 400 })
    font.letterSpacing: -0.006 * 13 * Theme.fontScale
    font.hintingPreference: Font.PreferNoHinting
    Accessible.name: f.placeholder
    Txt { visible: input.text === ""; text: f.placeholder; color: Theme.secondary; anchors.verticalCenter: parent.verticalCenter }
  }
  MouseArea { anchors.fill: parent; acceptedButtons: Qt.NoButton; cursorShape: Qt.IBeamCursor }
}
