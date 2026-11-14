import QtQuick
import "Acc.js" as A

// ProviderWindowMeter (account-window.md 3.2): title + pace badge + percent; bar with the pace tick (or
// the dotted placeholder); reset text + detail. Right click: Hide this row, Show all hidden rows, Refresh.
Item {
  id: m
  property var ctl
  property var w: null            // UsageWindow, or null for a placeholder
  property string title: w ? w.title : ""
  property string provider: ""
  property string tip: ""         // placeholder tooltip ("Rate limits unavailable", …)
  readonly property bool known: A.hasValue(w)
  readonly property var pc: known ? A.pace(w, ctl.now, Theme.showUsed) : ({ badge: "", level: "none", tooltip: "", tick: -1 })
  readonly property string resetLine: known && w.resetsAt ? A.resetText(w.resetsAt, ctl.now, w.usedPercent, ctl.exact, ctl.h24) : ""
  width: parent ? parent.width : 400
  height: 16 + 8 + 4 + 8 + 14
  Accessible.role: Accessible.StaticText
  Accessible.name: title
  Accessible.description: [pctLabel.text, resetLine, w && w.detail ? w.detail : "", pc.tooltip].filter(function (s) { return s !== "" }).join(", ")

  Item {
    width: parent.width
    height: 16
    Txt { id: tt; text: m.title; width: Math.min(implicitWidth, parent.width - 140); elide: Text.ElideRight
          ToolTipArea { text: tt.truncated ? m.title : "" } }
    Badge {
      visible: m.pc.badge !== ""
      x: tt.width + 8
      anchors.verticalCenter: parent.verticalCenter
      text: m.pc.badge
      dot: m.pc.level === "healthy" || m.pc.level === "normal" ? Theme.green
         : (m.pc.level === "close" || m.pc.level === "warning" ? Theme.yellow : Theme.red)
    }
    RollText {
      id: pctLabel
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      role: "body"
      text: m.known ? A.pctWord(m.w.usedPercent, Theme.showUsed) : "–"
      ToolTipArea { text: m.known ? (Theme.showUsed ? "Click to show the percentage left" : "Click to show the percentage used") : "" }
      MouseArea { anchors.fill: parent; enabled: m.known; cursorShape: Qt.PointingHandCursor; onClicked: m.ctl.toggleShowUsed() }
    }
  }
  UsageBar {
    y: 24
    width: parent.width
    used: m.known ? m.w.usedPercent : -1
    provider: m.provider
    pace: m.pc.tick
    ToolTipArea { text: m.known ? m.pc.tooltip : m.tip }
  }
  Item {
    y: 36
    width: parent.width
    height: 14
    Txt {
      id: rl
      role: "secondary"
      color: Theme.secondary
      text: m.resetLine
      ToolTipArea { text: m.resetLine !== "" ? m.resetLine + "\n" + A.resetText(m.w.resetsAt, m.ctl.now, m.w.usedPercent, !m.ctl.exact, m.ctl.h24) : "" }
      MouseArea { anchors.fill: parent; enabled: m.resetLine !== ""; cursorShape: Qt.PointingHandCursor; onClicked: m.ctl.toggleExact() }
    }
    Txt {
      id: det
      anchors.right: parent.right
      width: Math.min(implicitWidth, parent.width - rl.width - 16)
      horizontalAlignment: Text.AlignRight
      role: "secondary"
      tabular: true
      color: Theme.secondary
      elide: Text.ElideRight
      text: m.w && m.w.detail ? m.w.detail : ""
      ToolTipArea { text: det.text }
    }
  }
  MouseArea {
    anchors.fill: parent
    acceptedButtons: Qt.RightButton
    enabled: !!m.w && !!m.w.id
    onClicked: function (e) { m.ctl.meterMenu(m, e.x, e.y, m.w.id) }
  }
}
