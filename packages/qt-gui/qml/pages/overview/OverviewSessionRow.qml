import QtQuick
import "Overview.js" as O

// A day-sheet session row (overview.md 3.4): title and "tool · time", tokens and cost. A row with a
// transcript is a button that opens it; a removed Codex session is dimmed and does nothing.
Item {
  id: row
  property var session: null
  signal open(string chatID)
  readonly property bool link: !!session && !!session.chatID
  readonly property string detail: {
    if (!session) return ""
    var p = [session.tool]
    if (session.start) p.push(session.continued ? "Continued" : session.start.toLocaleTimeString(Qt.locale(), Locale.ShortFormat))
    if (session.removed) p.push("Transcript removed")
    return p.join(" · ")
  }
  height: 6 + 16 + 1 + 14 + 6
  opacity: session && session.removed ? 0.5 : 1
  activeFocusOnTab: link
  Accessible.role: link ? Accessible.Button : Accessible.StaticText
  Accessible.name: session ? session.title + ", " + detail : ""
  Accessible.description: link ? "Opens the conversation" : ""
  Keys.onSpacePressed: if (link) open(session.chatID)

  Rectangle {
    anchors.fill: parent
    radius: 6
    color: Theme.tileFill
    opacity: row.link && hover.hovered ? 1 : 0
    Behavior on opacity { NumberAnimation { duration: Theme.dHover; easing.type: Easing.Bezier; easing.bezierCurve: Theme.easeOut } }
  }
  FocusFill { radius: 6; visible: row.activeFocus && App.keyboardMode }
  Column {
    x: 8
    y: 6
    spacing: 1
    width: parent.width - 16 - 12 - right.width
    Txt { width: Math.min(implicitWidth, parent.width); text: row.session ? row.session.title : ""; elide: Text.ElideMiddle
          ToolTipArea { text: row.session ? row.session.title : "" } }
    Txt { width: Math.min(implicitWidth, parent.width); role: "secondary"; color: Theme.secondary; text: row.detail; elide: Text.ElideRight
          ToolTipArea { text: row.detail } }
  }
  Column {
    id: right
    x: parent.width - 8 - width
    y: 6
    spacing: 1
    Txt { anchors.right: parent.right; tabular: true; text: row.session ? O.tokens(row.session.tokens) : "" }
    Txt { anchors.right: parent.right; role: "secondary"; color: Theme.secondary; tabular: true
          text: row.session && row.session.cost !== null ? O.currency(row.session.cost) : "–" }
  }
  HoverHandler { id: hover; enabled: row.link; cursorShape: Qt.PointingHandCursor }
  MouseArea { anchors.fill: parent; enabled: row.link; onClicked: row.open(row.session.chatID) }
}
