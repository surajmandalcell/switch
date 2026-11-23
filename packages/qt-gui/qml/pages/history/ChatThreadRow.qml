import QtQuick

// Thread row (history.md 1.3): 280 x 44, 6 pt side padding. Title (Body, one line), then app label · model
// (shrinks first) ... time (tabular, never shrinks). Selected: radius 6 row highlight; hover: tile fill. A 45%
// hairline inset 6 at the bottom of every row. Right-click opens the copy menu (title, path, thread ID, model).
Item {
  id: r
  property var thread: ({})
  property string time: ""
  property bool selected: false
  signal activated()
  signal menuRequested()
  height: 44
  Accessible.role: Accessible.ListItem
  Accessible.name: thread.title + ", " + label + ", " + (thread.model ? thread.model + " · " : "") + r.time
  Accessible.selected: selected
  readonly property string label: ({ codex: "Codex", cli: "Codex CLI", exec: "Codex exec", app: "Codex app", chrome: "Codex Chrome",
                                      subagent: "Subagent", vscode: "VS Code", claude: "Claude Code" })[thread.appSource] || "Codex"

  Rectangle {
    anchors.fill: parent
    radius: 6
    color: Theme.rowHighlight
    opacity: r.selected ? 1 : 0
    Behavior on opacity { NumberAnimation { duration: Theme.dState } }
  }
  Rectangle {
    anchors.fill: parent
    radius: 6
    color: Theme.tileFill
    opacity: hover.hovered && !r.selected ? 1 : 0
    Behavior on opacity { NumberAnimation { duration: Theme.dHover } }
  }

  Column {
    x: 6
    width: parent.width - 12
    anchors.verticalCenter: parent.verticalCenter
    Txt {
      width: parent.width
      text: r.thread.title || ""
      elide: Text.ElideRight
      ToolTipArea { text: r.thread.title || "" }
    }
    Item {
      width: parent.width
      height: 14
      Txt { id: app; role: "secondary"; color: Theme.secondary; text: r.label }
      Txt { id: dot; visible: !!r.thread.model; x: app.width + 6; role: "secondary"; color: Theme.secondary; text: "·" }
      Txt {
        visible: !!r.thread.model
        x: dot.x + dot.width + 6
        width: Math.max(0, Math.min(implicitWidth, timeT.x - 6 - x))
        role: "secondary"; color: Theme.secondary; elide: Text.ElideRight
        text: r.thread.model || ""
        ToolTipArea { text: r.thread.model || "" }
      }
      Txt { id: timeT; x: parent.width - width; role: "secondary"; tabular: true; color: Theme.secondary; text: r.time }
    }
  }
  Rectangle { x: 6; width: parent.width - 12; y: parent.height - height; height: Theme.hair; color: Theme.separator; opacity: 0.45 }

  HoverHandler { id: hover }
  MouseArea {
    anchors.fill: parent
    acceptedButtons: Qt.LeftButton | Qt.RightButton
    onClicked: function (m) { if (m.button === Qt.RightButton) r.menuRequested(); else r.activated() }
  }
}
