import QtQuick

// aimTile (4.22): padding 10, radius 6, tileFill, 1 px card border; label, Title-size value, detail.
Rectangle {
  id: tile
  property string label: ""
  property string value: ""
  property string detail: ""
  // Loading: value and detail give way to skeletons (100 x 17, 120 x 10) at the leading edge.
  property bool loading: false
  height: 73   // measured on the Mac capture (spec 1.2 derives about 74)
  radius: 6
  color: Theme.tileFill
  border.width: Theme.hair
  border.color: Qt.tint(Qt.tint(Theme.card, Theme.tileFill), Theme.cardBorder)   // Mac draws the border over the fill

  Column {
    x: 10
    y: 10
    width: parent.width - 20
    spacing: 2
    // 13, not the 14 Qt line: the Mac value and detail sit 1 px higher
    Txt { width: parent.width; height: 13; topPadding: 1; role: "secondary"; color: Theme.secondary; text: tile.label; elide: Text.ElideRight
          ToolTipArea { text: tile.label } }
    RollText { id: roll; width: parent.width; text: tile.value; opacity: tile.loading ? 0 : 1
               ToolTipArea { text: tile.loading ? "" : tile.value } }
    Txt { width: parent.width; role: "secondary"; color: Theme.secondary; text: tile.loading ? "" : tile.detail; elide: Text.ElideRight
          ToolTipArea { text: tile.loading ? "" : tile.detail } }
  }
  Skeleton { visible: tile.loading; x: 10; y: 10 + 13 + 2 + 2.5; width: 100; height: 17 }
  Skeleton { visible: tile.loading && tile.detail !== ""; x: 10; y: 10 + 13 + 2 + 22 + 2 + 2; width: 120; height: 10 }
}
