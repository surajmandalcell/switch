import QtQuick
import "Overview.js" as O

// OverviewDateAxis (overview.md 2.3): 16 high, Caption in tertiary, top at y = 2. The first label starts
// and the last ends 16 inside the edges, so labels keep the card inset while the marks run edge to edge.
Item {
  id: ax
  property var days: []
  property bool h24: false
  height: 16
  Repeater {
    model: O.axis(ax.days, ax.h24)
    delegate: Txt {
      readonly property real px: ax.width * modelData.i / Math.max(1, ax.days.length - 1)
      readonly property bool first: index === 0
      readonly property bool last: modelData.i === ax.days.length - 1
      role: "caption"
      color: Theme.tertiary
      text: modelData.text
      y: 2.5   // glyph tops land on the Mac capture's rows
      x: first ? Math.max(px, 16) : (last ? Math.min(px, ax.width - 16) - width : px - width / 2)
    }
  }
}
