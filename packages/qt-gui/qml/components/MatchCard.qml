import QtQuick

// Search result card (shell.md 4.2): "Matching accounts" (Settings page) or "Matching settings" (Accounts
// page), up to 5 rows 36 high inset 6, count at the title row's right, chevron at the end. Rows are
// accounts-topic rows ({id, label, providerID}) or settings index entries ({id, title, section}).
Card {
  id: mc
  property var rows: []
  property bool accounts: true
  property var names: ({})   // provider id to display name
  signal picked(var row)

  title: accounts ? "Matching accounts" : "Matching settings"
  accessory: Txt { role: "secondary"; color: Theme.secondary; text: mc.rows.length + (mc.rows.length === 1 ? " match" : " matches") }
  opacity: visible ? 1 : 0
  Behavior on opacity { NumberAnimation { duration: Theme.motion ? 180 : 0; easing.type: Easing.OutCubic } }

  Item { width: 1; height: 6 }
  Repeater {
    model: mc.rows.slice(0, 5)
    delegate: Item {
      width: mc.width
      height: 36
      readonly property string provider: mc.accounts ? (mc.names[modelData.providerID] || modelData.providerID) : ""
      Accessible.role: Accessible.Button
      Accessible.name: mc.accounts ? modelData.label + ", " + provider : modelData.title
      Accessible.onPressAction: mc.picked(modelData)
      activeFocusOnTab: true
      Keys.onReturnPressed: mc.picked(modelData)
      Keys.onSpacePressed: mc.picked(modelData)
      Rectangle { x: 6; width: parent.width - 12; height: parent.height; radius: 6; color: Theme.rowHover; visible: ma.containsMouse }
      FocusFill { anchors.fill: undefined; x: 6; width: parent.width - 12; height: parent.height; radius: 6 }
      Row {
        x: 16
        spacing: 8
        anchors.verticalCenter: parent.verticalCenter
        ProviderTile { visible: mc.accounts; size: 16; anchors.verticalCenter: parent.verticalCenter; provider: mc.accounts ? modelData.providerID : ""; name: parent.parent.provider }
        Txt { anchors.verticalCenter: parent.verticalCenter; text: mc.accounts ? modelData.label : modelData.title }
        Txt { anchors.verticalCenter: parent.verticalCenter; role: "secondary"; color: Theme.secondary; text: mc.accounts ? parent.parent.provider : "· " + modelData.section }
      }
      Icon { x: parent.width - 16 - 12; anchors.verticalCenter: parent.verticalCenter; name: "chevronRight"; size: 12; color: Theme.tertiary }
      ToolTipArea { text: mc.accounts ? modelData.label + ", " + parent.provider : "" }
      MouseArea { id: ma; anchors.fill: parent; hoverEnabled: true; onClicked: mc.picked(modelData) }
    }
  }
  Item { width: 1; height: 6 }
}
