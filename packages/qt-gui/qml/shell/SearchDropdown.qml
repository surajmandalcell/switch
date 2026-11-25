import QtQuick
import QtQuick.Effects

// Search drop-down on Overview, Utilities and History (shell.md 4.3): 300 wide under the field, solid
// surface, radius 8, padding 6, 28 rows grouped under "Accounts" and "Settings". It stays open while the
// pointer is over it, because a click on a row first takes focus from the field.
Item {
  id: dd
  property var win
  readonly property bool shown: win.dropdownPage && !win.searchBlank && (win.searchFocused || hover.hovered)
  readonly property int accountCount: Math.min(4, win.accountHits.length) + (win.accountHits.length > 4 ? 1 : 0)

  x: 220 + (980 - 20 - 300)
  y: 44
  width: 300
  height: panel.height
  visible: opacity > 0
  opacity: shown ? 1 : 0
  scale: shown || Theme.reduceMotion ? 1 : 0.98
  transformOrigin: Item.Top
  Behavior on opacity { NumberAnimation { duration: Theme.motion ? (dd.shown ? 160 : 120) : 0; easing.type: Easing.OutCubic } }
  Behavior on scale { NumberAnimation { duration: Theme.motion ? (dd.shown ? 160 : 120) : 0; easing.type: Easing.OutCubic } }
  transform: Translate { y: dd.shown || Theme.reduceMotion ? 0 : -4
                         Behavior on y { NumberAnimation { duration: Theme.motion ? 160 : 0; easing.type: Easing.OutCubic } } }
  Accessible.role: Accessible.List
  Accessible.name: "Search results"

  HoverHandler { id: hover }

  Rectangle {
    id: panel
    width: parent.width
    height: col.height + 12
    radius: 8
    color: Theme.solidSurface
    border.width: Theme.hair
    border.color: Theme.popoverBorder
    layer.enabled: true
    layer.effect: MultiEffect { shadowEnabled: true; shadowColor: "black"; shadowOpacity: Theme.dark ? 0.5 : 0.16; shadowBlur: 0.7; shadowVerticalOffset: 6 }

    Column {
      id: col
      x: 6
      y: 6
      width: parent.width - 12
      Item {
        visible: win.dropRows.length === 0
        width: parent.width; height: 28
        Txt { x: 8; anchors.verticalCenter: parent.verticalCenter; color: Theme.secondary; text: "No accounts or settings match" }
      }
      Repeater {
        model: win.dropRows
        delegate: Column {
          width: col.width
          readonly property bool firstAccount: index === 0 && modelData.kind !== "setting"
          readonly property bool firstSetting: modelData.kind === "setting" && index === dd.accountCount
          Item { visible: firstSetting && dd.accountCount > 0; width: 1; height: 6 }
          Txt {
            visible: firstAccount || firstSetting
            x: 8; height: 22
            role: "caption"; wght: 600; color: Theme.secondary
            text: firstAccount ? "Accounts" : "Settings"
            Accessible.role: Accessible.Heading
            Accessible.name: text
          }
          Rectangle {
            width: col.width
            height: 28
            radius: 6
            color: win.searchHot === index ? Theme.rowHighlight : "transparent"
            Accessible.role: Accessible.ListItem
            Accessible.selected: win.searchHot === index
            Accessible.name: modelData.kind === "all" ? "Show all " + modelData.count + " in Accounts"
                             : modelData.kind === "account" ? modelData.item.label + ", " + (win.providerNames[modelData.item.providerID] || modelData.item.providerID)
                             : modelData.item.title + ", " + modelData.item.section
            Accessible.onPressAction: win.searchChoose(modelData)
            Row {
              x: 8
              spacing: 8
              anchors.verticalCenter: parent.verticalCenter
              ProviderTile { visible: modelData.kind === "account"; anchors.verticalCenter: parent.verticalCenter; size: 16
                             provider: modelData.kind === "account" ? modelData.item.providerID : ""
                             name: modelData.kind === "account" ? (win.providerNames[modelData.item.providerID] || modelData.item.providerID) : "" }
              Txt { anchors.verticalCenter: parent.verticalCenter; width: Math.min(implicitWidth, col.width - 16 - 24 - 90); elide: Text.ElideRight
                    color: modelData.kind === "all" ? Theme.secondary : Theme.label
                    text: modelData.kind === "all" ? "Show all " + modelData.count + " in Accounts"
                          : modelData.kind === "account" ? modelData.item.label : modelData.item.title }
              Txt { anchors.verticalCenter: parent.verticalCenter; role: "secondary"; color: Theme.secondary; visible: modelData.kind !== "all"; elide: Text.ElideRight
                    text: modelData.kind === "account" ? (win.providerNames[modelData.item.providerID] || modelData.item.providerID) : "· " + (modelData.item ? modelData.item.section : "") }
            }
            MouseArea { anchors.fill: parent; hoverEnabled: true; onEntered: win.searchHot = index; onClicked: win.searchChoose(modelData) }
          }
        }
      }
    }
  }
}
