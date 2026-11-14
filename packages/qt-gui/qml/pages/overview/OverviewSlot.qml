import QtQuick

// OverviewSlot placeholder (overview.md 2.9): while loading a skeleton block, when empty a tile with the
// reason. It keeps the chart's size; `shape` reproduces the heatmap and waffle frames.
Item {
  id: slot
  property bool loading: true
  property string text: ""
  property string shape: "block"     // "block" | "heatmap" | "waffle"
  readonly property real innerW: width - 32
  // The block the reason or skeleton fills: the whole slot, the heatmap grid, or the waffle split.
  readonly property real blockH: shape === "heatmap" ? innerW / 6.6
                               : (shape === "waffle" ? ((Math.max(innerW - 24, 0) * 0.4 - 57) / 20) * 10 + 27 : height)
  implicitHeight: shape === "heatmap" ? blockH + 8 + 16 : blockH

  Skeleton { visible: slot.loading; x: 16; width: slot.innerW; height: slot.blockH }
  Rectangle {
    visible: !slot.loading
    x: 16
    width: slot.innerW
    height: slot.blockH
    radius: 6
    color: Theme.tileFill
    Txt {
      anchors.centerIn: parent
      width: Math.min(implicitWidth, parent.width - 48)
      role: "secondary"
      color: Theme.secondary
      text: slot.text
      wrapMode: Text.WordWrap
      lineHeightMode: Text.FixedHeight
      horizontalAlignment: Text.AlignHCenter
    }
  }
}
