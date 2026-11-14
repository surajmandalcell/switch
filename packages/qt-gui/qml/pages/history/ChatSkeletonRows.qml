import QtQuick

// AIMLoadingRows (history.md 5.1): 16 pt side padding; a 20 x 20 block, a column of a 10 pt bar (max 160) over an
// 8 pt bar (max 110), a spacer, and a 70 x 10 bar, all 8 apart and centered in the row.
Column {
  id: sk
  property int count: 8
  property real rowHeight: 44
  Accessible.role: Accessible.Indicator
  Accessible.name: "Loading"
  Repeater {
    model: sk.count
    Item {
      width: sk.width
      height: sk.rowHeight
      Skeleton { id: blk; x: 16; width: 20; height: 20; anchors.verticalCenter: parent.verticalCenter }
      Column {
        x: blk.x + 28
        anchors.verticalCenter: parent.verticalCenter
        spacing: 4
        readonly property real room: sk.width - 16 - 28 - 8 - 70 - 16
        Skeleton { width: Math.min(160, parent.room); height: 10 }
        Skeleton { width: Math.min(110, parent.room); height: 8 }
      }
      Skeleton { x: parent.width - 16 - 70; width: 70; height: 10; anchors.verticalCenter: parent.verticalCenter }
    }
  }
}
