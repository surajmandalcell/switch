import QtQuick

// aimTile (4.22): padding 10, radius 6, tileFill, 1 px card border; label, Title-size value, detail.
Rectangle {
  id: tile
  property string label: ""
  property string value: ""
  property string detail: ""
  height: 74
  radius: 6
  color: Theme.tileFill
  border.width: Theme.hair
  border.color: Theme.cardBorder

  Column {
    x: 10
    y: 10
    width: parent.width - 20
    spacing: 2
    Txt { width: parent.width; role: "secondary"; color: Theme.secondary; text: tile.label; elide: Text.ElideRight }
    RollText { id: roll; width: parent.width; text: tile.value }
    Txt { width: parent.width; role: "secondary"; color: Theme.secondary; text: tile.detail; elide: Text.ElideRight }
  }
}
