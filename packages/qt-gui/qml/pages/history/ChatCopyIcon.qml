import QtQuick

// Copy icon button (history.md 2.4): 20 x 20 hit area, the copy glyph cross-fades to a green check in place for
// `hold` ms, then back. Tooltip and name: the label, then "Copied". The warning copy button uses it with the
// Body size, amber, and 900 ms (1.3).
Item {
  id: c
  property string label: "Copy message"
  property string tip: label
  property color tint: Theme.secondary
  property real glyph: 12
  property int hold: 1200
  property bool copied: false
  signal copy()
  width: 20
  height: 20
  activeFocusOnTab: true
  Accessible.role: Accessible.Button
  Accessible.name: copied ? "Copied" : label
  Accessible.onPressAction: activate()
  Keys.onSpacePressed: activate()

  function activate() { copy(); copied = true; back.restart() }
  Timer { id: back; interval: c.hold; onTriggered: c.copied = false }

  Rectangle { anchors.fill: parent; radius: 5; color: Theme.focusTint; visible: c.activeFocus && App.keyboardMode }
  Icon { anchors.centerIn: parent; name: "copy"; size: c.glyph; color: c.tint
         opacity: c.copied ? 0 : 1; Behavior on opacity { NumberAnimation { duration: Theme.dState } } }
  // the check is made on the first copy only: an Icon is a Shape, and a long chat has hundreds of these buttons
  property bool used: false
  onCopiedChanged: if (copied) used = true
  Loader {
    active: c.used
    anchors.centerIn: parent
    sourceComponent: Icon { name: "check"; size: c.glyph; color: Theme.green
                            opacity: c.copied ? 1 : 0; Behavior on opacity { NumberAnimation { duration: Theme.dState } } }
  }
  ToolTipArea { text: c.copied ? "Copied" : c.tip }
  MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: c.activate() }
}
