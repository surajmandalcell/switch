import QtQuick

// AIMCard (4.1): radius 10, 1 px border inside, 44 high title row, hairline divider, accessory at the right.
Rectangle {
  id: card
  property string title: ""
  property string note: ""
  property bool divider: true
  property real bottomInset: 0
  property alias accessory: accessoryRow.data
  default property alias body: bodyCol.data
  readonly property real headH: title !== "" ? 44 + (divider ? Theme.hair : 0) : 0

  radius: 10
  color: Theme.card
  border.width: Theme.hair
  border.color: Theme.cardBorder
  width: parent ? parent.width : 400
  height: headH + bodyCol.height + bottomInset

  Item {
    visible: card.title !== ""
    width: parent.width
    height: 44
    Txt { id: titleText; x: 16; anchors.verticalCenter: parent.verticalCenter; role: "section"; text: card.title }
    Txt {
      x: titleText.x + titleText.width + 8
      anchors.verticalCenter: parent.verticalCenter
      role: "secondary"
      color: Theme.secondary
      text: card.note
    }
    Row {
      id: accessoryRow
      anchors.right: parent.right
      anchors.rightMargin: 16
      anchors.verticalCenter: parent.verticalCenter
      spacing: 8
    }
  }
  Hair { visible: card.title !== "" && card.divider; y: 44; width: parent.width }
  Column { id: bodyCol; y: card.headH; width: parent.width }
}
