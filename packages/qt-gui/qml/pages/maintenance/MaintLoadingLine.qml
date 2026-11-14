import QtQuick

// AIMLoadingLine (maintenance.md 1.4): a 20 x 20 block, bars 160 x 10 over 110 x 8 (4 apart), a 70 x 10 bar right.
Item {
  width: parent ? parent.width : 0
  height: 22
  Accessible.role: Accessible.Indicator
  Accessible.name: "Loading"
  Skeleton { width: 20; height: 20; anchors.verticalCenter: parent.verticalCenter }
  Skeleton { x: 28; y: 0; width: Math.min(160, parent.width - 28 - 86); height: 10 }
  Skeleton { x: 28; y: 14; width: Math.min(110, parent.width - 28 - 86); height: 8 }
  Skeleton { anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter; width: 70; height: 10 }
}
