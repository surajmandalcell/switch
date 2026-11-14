import QtQuick
import QtQuick.Effects
import QtQuick.Window
import "MaintFmt.js" as F

// The source button at the right end of the Maintenance tab bar and its 380 pt popover (maintenance.md 2.2).
PushButton {
  id: pk
  property var sources: []          // shown cleanup sources
  property var current: null
  property bool loaded: false
  property bool open: false
  property int hot: -1                // the row Up/Down moved to; Return picks it (else the first match)
  signal chose(string id)
  function close() { open = false; pk.forceActiveFocus() }
  function pick(i) { var s = shown[i]; if (!s) return; close(); chose(s.id) }
  function move(d) {
    if (shown.length === 0) return
    hot = Math.max(0, Math.min(shown.length - 1, hot < 0 ? (d > 0 ? 0 : shown.length - 1) : hot + d))
    list.positionViewAtIndex(hot, ListView.Contain)
  }
  onShownChanged: hot = -1

  readonly property string title: current ? current.title : (loaded ? "No source found" : "Loading sources…")
  minWidth: face.width + 24
  enabled: sources.length > 0
  Accessible.name: "Source"
  Accessible.description: current ? current.title : "None"
  onClicked: { query.text = ""; hot = -1; open = true; query.forceActiveFocus() }

  Row {
    id: face
    anchors.centerIn: parent
    spacing: 8
    opacity: pk.enabled ? 1 : 0.45
    ProviderTile { visible: !!pk.current; size: 18; provider: pk.current ? F.provider(pk.current) : ""; name: pk.current ? pk.current.title : ""
                   anchors.verticalCenter: parent.verticalCenter }
    Txt { text: pk.title; anchors.verticalCenter: parent.verticalCenter; ToolTipArea { text: pk.title } }
    Icon { name: "chevronUD"; size: 12; color: Theme.secondary; anchors.verticalCenter: parent.verticalCenter }
  }

  readonly property var shown: {
    var q = query.text.trim().toLowerCase()
    if (q === "") return sources
    return sources.filter(function (s) { return [s.title, s.detail, s.accountEmail || ""].some(function (t) { return String(t).toLowerCase().indexOf(q) >= 0 }) })
  }

  Item {
    parent: pk.Window.contentItem
    anchors.fill: parent
    z: 55
    visible: pk.open
    MouseArea { anchors.fill: parent; onPressed: pk.close() }

    Item {
      id: pop
      readonly property point at: pk.open ? pk.mapToItem(parent, pk.width / 2, pk.height) : Qt.point(0, 0)
      readonly property real listH: pk.shown.length === 0 ? 48 : Math.min(pk.shown.length, 7) * 48 + 8
      width: 380
      height: Theme.arrowHeight + 44 + Theme.hair + listH
      x: Math.max(8, Math.min(parent.width - width - 8, at.x - width / 2))
      y: at.y + 2
      Keys.onEscapePressed: pk.close()

      PopoverShape {
        anchors.fill: parent
        arrowX: pop.at.x - pop.x
        fill: Theme.page
        layer.enabled: true
        layer.effect: MultiEffect { shadowEnabled: true; shadowColor: "black"; shadowOpacity: Theme.dark ? 0.5 : 0.18; shadowBlur: 0.7; shadowVerticalOffset: 6 }
      }
      MouseArea { anchors.fill: parent }

      // search row: padding 8, a 28 pt field
      Rectangle {
        x: 8; y: Theme.arrowHeight + 8
        width: parent.width - 16
        height: 28
        radius: 6
        color: Theme.controlFill
        border.width: Theme.hair
        border.color: Theme.controlBorder
        Rectangle { anchors.fill: parent; radius: 6; color: Theme.focusTint; opacity: query.activeFocus ? 1 : 0 }
        Icon { id: glass; x: 8; anchors.verticalCenter: parent.verticalCenter; name: "search"; size: 14; color: Theme.secondary }
        TextInput {
          id: query
          x: glass.x + glass.width + 6
          width: parent.width - x - (clear.visible ? clear.width + 14 : 8)
          height: parent.height
          verticalAlignment: TextInput.AlignVCenter
          clip: true
          color: Theme.label
          selectionColor: Theme.rgba(Theme.accent, 0.3)
          font.family: Theme.fontFamily
          font.pointSize: 13 * Theme.fontScale * 0.75
          Accessible.name: "Search sources"
          Keys.onEscapePressed: pk.close()
          Keys.onReturnPressed: pk.pick(pk.hot >= 0 ? pk.hot : 0)
          Keys.onEnterPressed: pk.pick(pk.hot >= 0 ? pk.hot : 0)
          Keys.onDownPressed: pk.move(1)
          Keys.onUpPressed: pk.move(-1)
          Keys.onTabPressed: function (e) { e.accepted = true }    // focus stays in the popover while it is open
          Txt { visible: query.text === ""; text: "Search sources"; color: Theme.secondary; anchors.verticalCenter: parent.verticalCenter }
        }
        IconButton { id: clear; visible: query.text !== ""; x: parent.width - width - 8; anchors.verticalCenter: parent.verticalCenter
                     icon: "xmarkCircle"; glyph: 13; tip: "Clear search"; onClicked: { query.text = ""; query.forceActiveFocus() } }
      }
      Hair { y: Theme.arrowHeight + 44; width: parent.width }

      Txt {
        visible: pk.shown.length === 0
        y: Theme.arrowHeight + 44 + Theme.hair
        width: parent.width
        height: 48
        horizontalAlignment: Text.AlignHCenter
        role: "secondary"
        color: Theme.secondary
        text: "No source matches."
      }
      ListView {
        id: list
        visible: pk.shown.length > 0
        y: Theme.arrowHeight + 44 + Theme.hair
        width: parent.width
        height: pop.listH
        topMargin: 4
        bottomMargin: 4
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        model: pk.shown
        delegate: Item {
          id: srow
          readonly property bool chosen: !!pk.current && modelData.id === pk.current.id
          readonly property string detail: modelData.detail + (modelData.accountEmail ? " · " + modelData.accountEmail : "")
          width: list.width
          height: 48
          Accessible.role: Accessible.Button
          Accessible.name: modelData.title
          Accessible.selected: chosen
          Rectangle {
            x: 4; y: 2
            width: parent.width - 8
            height: parent.height - 4
            radius: 6
            color: srow.chosen ? Theme.rowHighlight : Theme.rowHover
            opacity: srow.chosen || rowHover.hovered ? 1 : 0
            Behavior on opacity { NumberAnimation { duration: Theme.dHover } }
          }
          Rectangle {    // the keyboard row: the design-system focus tint
            x: 4; y: 2
            width: parent.width - 8
            height: parent.height - 4
            radius: 6
            color: Theme.focusTint
            visible: pk.hot === index
          }
          ProviderTile { id: mark; x: 10; anchors.verticalCenter: parent.verticalCenter; size: 28; provider: F.provider(modelData); name: modelData.title }
          Column {
            x: mark.x + 28 + 10
            width: parent.width - x - 10 - (srow.chosen ? 14 + 10 : 0)
            anchors.verticalCenter: parent.verticalCenter
            spacing: 2
            Txt { width: parent.width; text: modelData.title; elide: Text.ElideRight; ToolTipArea { text: modelData.title } }
            Txt { width: parent.width; role: "secondary"; color: Theme.secondary; text: srow.detail; elide: Text.ElideMiddle; ToolTipArea { text: srow.detail } }
          }
          Icon { visible: srow.chosen; anchors.right: parent.right; anchors.rightMargin: 10; anchors.verticalCenter: parent.verticalCenter
                 name: "check"; size: 14; color: Theme.passiveIcon }
          HoverHandler { id: rowHover }
          MouseArea { anchors.fill: parent; onClicked: pk.pick(index) }
        }
      }
    }
  }
}
