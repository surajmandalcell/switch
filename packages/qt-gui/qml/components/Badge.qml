import QtQuick

// Badge (4.13): capsule, Badge.fill, padding 8 x 2, 6 pt state dot + gap 5 + Caption label (never tinted).
Rectangle {
  id: badge
  property string text: ""
  property color dot: Theme.green
  width: row.width + 16
  height: 16
  radius: height / 2
  color: Theme.badgeFill
  Row {
    id: row
    x: 8
    anchors.verticalCenter: parent.verticalCenter
    spacing: 5
    Rectangle { width: 6; height: 6; radius: 3; color: badge.dot; anchors.verticalCenter: parent.verticalCenter }
    Txt { role: "caption"; text: badge.text; anchors.verticalCenter: parent.verticalCenter }
  }
}
