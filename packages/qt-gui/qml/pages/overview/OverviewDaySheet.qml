import QtQuick
import QtQuick.Effects
import "Overview.js" as O

// The day sheet (overview.md 3): a 560 x 680 modal sheet over the window with the day's totals, its
// cost split by account or model, and its sessions. Done, Return, and Escape close it; a click outside
// does nothing. Open with open(day, tokens); `load(day, done)` fetches the usage.day input.
Item {
  id: sheet
  property string day: ""
  property real tokens: 0
  property var detail: null
  property int split: 0            // 0 account, 1 model; kept while the sheet is open
  property var load: null
  property var accounts: []
  property var pal: null
  property bool shown: false
  signal openChat(string chatID)
  anchors.fill: parent
  visible: fade.opacity > 0.001
  z: 900

  function open(d, t) {
    day = d; tokens = t; detail = null; split = 0
    shown = true
    panel.forceActiveFocus()
    if (load) load(d, function (input) { if (sheet.day === d && sheet.shown) sheet.detail = O.dayDetail(d, t, input, sheet.accounts, sheet.pal) })
  }
  function close() { shown = false }

  Item {
    id: fade
    anchors.fill: parent
    opacity: sheet.shown ? 1 : 0
    Behavior on opacity { NumberAnimation { duration: Theme.dAppear; easing.type: Easing.Bezier; easing.bezierCurve: Theme.easeOut } }

    // scrim: eats the pointer, never closes the sheet
    Rectangle {
      anchors.fill: parent
      radius: Theme.windowRadius
      color: Theme.k(Theme.dark ? 0.3 : 0.12)
      MouseArea { anchors.fill: parent; hoverEnabled: true; acceptedButtons: Qt.AllButtons; onWheel: function (w) { w.accepted = true } }
    }

    Rectangle {
      id: panel
      width: 560
      height: 680
      x: (parent.width - width) / 2
      y: 52 + (sheet.shown || !Theme.motion || Theme.reduceMotion ? 0 : -12)
      Behavior on y { NumberAnimation { duration: Theme.dAppear; easing.type: Easing.Bezier; easing.bezierCurve: Theme.easeOut } }
      radius: 12
      color: Theme.page
      border.width: Theme.hair
      border.color: Theme.windowBorder
      focus: true
      layer.enabled: true
      layer.effect: MultiEffect { shadowEnabled: true; shadowColor: "black"; shadowOpacity: 0.3; shadowBlur: 0.6; shadowVerticalOffset: 8; autoPaddingEnabled: true }
      Keys.onEscapePressed: sheet.close()
      Keys.onReturnPressed: sheet.close()
      Keys.onEnterPressed: sheet.close()
      Accessible.role: Accessible.Dialog
      Accessible.name: sheet.day ? O.title(sheet.day) : ""

      readonly property var d: sheet.detail
      readonly property bool both: !!d && d.byAccount.length > 0 && d.byModel.length > 0
      readonly property int shownSplit: both ? sheet.split : (d && d.byAccount.length === 0 ? 1 : 0)
      readonly property var slices: d ? (shownSplit === 0 ? d.byAccount : d.byModel) : []
      readonly property real total: slices.reduce(function (a, s) { return a + s.value }, 0)
      readonly property bool anyService: slices.some(function (s) { return !!s.service })

      Column {
        id: body
        x: 20
        y: 20
        width: parent.width - 40
        spacing: 16
        Txt { role: "section"; text: sheet.day ? O.title(sheet.day) : "" }
        Row {
          spacing: 12
          readonly property real tw: (body.width - 24) / 3
          StatTile { width: parent.tw; height: 58; label: "Tokens"; value: O.tokens(sheet.tokens) }
          StatTile { width: parent.tw; height: 58; label: "Estimated cost"
                     value: panel.d ? (panel.d.cost === null ? "–" : O.currency(panel.d.cost)) : " " }
          StatTile { width: parent.tw; height: 58; label: "Sessions"
                     value: panel.d ? (panel.d.sessions ? String(panel.d.sessions.length) : "–") : " " }
        }
        // split
        Column {
          id: splitCol
          visible: !!panel.d
          width: body.width
          spacing: 8
          opacity: 1
          Item {
            width: parent.width
            height: 28
            Txt { anchors.verticalCenter: parent.verticalCenter; text: panel.d && panel.d.byCost ? "Cost split" : "Token split" }
            Segmented { visible: panel.both; anchors.right: parent.right; name: "Split by"; model: ["Account", "Model"]
                        current: sheet.split; onPicked: function (i) { sheet.split = i; appear.restart() } }
          }
          Txt { visible: panel.slices.length === 0; role: "secondary"; color: Theme.secondary; text: "No split is available for this day." }
          Item {
            visible: panel.slices.length > 0
            width: parent.width
            height: 10
            Rectangle {   // clip shape, radius 4
              anchors.fill: parent
              radius: 4
              color: "transparent"
              clip: true
              layer.enabled: true
              layer.effect: MultiEffect { maskEnabled: true; maskSource: barMask }
              Row {
                spacing: 2
                Repeater {
                  model: panel.slices
                  delegate: Rectangle {
                    width: Math.max(Math.max(splitCol.width - 2 * (panel.slices.length - 1), 1) * modelData.value / Math.max(panel.total, 1), 2)
                    height: 10
                    color: modelData.color
                  }
                }
              }
            }
            Rectangle { id: barMask; anchors.fill: parent; radius: 4; visible: false; layer.enabled: true }
          }
          Column {
            width: parent.width
            Repeater {
              model: panel.slices
              delegate: Item {
                width: splitCol.width
                height: 22
                Row {
                  spacing: 8
                  anchors.verticalCenter: parent.verticalCenter
                  Rectangle { width: 8; height: 8; radius: 4; color: modelData.color; anchors.verticalCenter: parent.verticalCenter }
                  Item { visible: panel.anyService; width: 13; height: 13; anchors.verticalCenter: parent.verticalCenter
                         ProviderTile { visible: !!modelData.service; size: 13; provider: modelData.service || "" } }
                  Txt { anchors.verticalCenter: parent.verticalCenter; text: modelData.label; elide: Text.ElideMiddle
                        width: Math.min(implicitWidth, splitCol.width - (16 + (panel.anyService ? 21 : 0)) - 12 - pc.implicitWidth - 8 - 64)
                        ToolTipArea { text: modelData.label } }
                }
                Txt { id: pc; x: parent.width - 64 - 8 - width; anchors.verticalCenter: parent.verticalCenter; tabular: true
                      text: O.sharePercent(modelData.value, panel.total) }
                Txt { x: parent.width - 64; width: 64; horizontalAlignment: Text.AlignRight; anchors.verticalCenter: parent.verticalCenter
                      role: "secondary"; color: Theme.secondary; tabular: true
                      text: panel.d && panel.d.byCost ? O.currency(modelData.value) : O.tokens(modelData.value) }
              }
            }
          }
          NumberAnimation { id: appear; target: splitCol; property: "opacity"; from: 0.4; to: 1; duration: Theme.dAppear
                            easing.type: Easing.Bezier; easing.bezierCurve: Theme.easeOut }
        }
      }

      // sessions: fills the rest of the content height
      Item {
        id: sessions
        visible: !!panel.d
        x: 20
        y: body.y + body.height + 16
        width: parent.width - 40
        height: Math.max(0, footer.y - 20 - y)
        Txt { id: sessTitle; text: "Sessions" }
        Txt {
          visible: !!panel.d && !panel.d.sessions
          anchors.top: sessTitle.bottom
          anchors.topMargin: 8
          anchors.bottom: parent.bottom
          width: parent.width
          role: "secondary"
          color: Theme.secondary
          wrapMode: Text.WordWrap
          horizontalAlignment: Text.AlignHCenter
          verticalAlignment: Text.AlignVCenter
          lineHeightMode: Text.FixedHeight
          text: "No sessions on this Mac for this day. The totals come from the account's usage report."
        }
        ScrollArea {
          visible: !!panel.d && !!panel.d.sessions
          anchors.top: sessTitle.bottom
          anchors.topMargin: 8
          anchors.bottom: parent.bottom
          width: parent.width + 10
          gutter: 10
          leftInset: 0
          topPad: 0
          bottomPad: 0
          spacing: 0
          Repeater {
            model: panel.d && panel.d.sessions ? panel.d.sessions : []
            delegate: OverviewSessionRow { width: sessions.width; session: modelData; onOpen: function (id) { sheet.close(); sheet.openChat(id) } }
          }
        }
      }

      Hair { id: footerHair; y: footer.y - Theme.hair; width: parent.width }
      Item {
        id: footer
        y: parent.height - height
        width: parent.width
        height: 16 + 28 + 16
        PushButton { anchors.right: parent.right; anchors.rightMargin: 16; anchors.verticalCenter: parent.verticalCenter
                     prominent: true; text: "Done"; onClicked: sheet.close() }
      }
    }
  }
}
