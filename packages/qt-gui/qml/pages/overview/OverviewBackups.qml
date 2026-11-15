import QtQuick
import "Overview.js" as O

// Recent backups (overview.md 1.8, the Maintenance card): the newest three backups across all sets,
// loading rows, or a way to set one up. "Open Backup" and "Set up a backup" go to Maintenance > Backup.
Card {
  id: card
  property var rows: []          // { date: Date, source, bytes, state, isSafety }
  property bool loaded: false
  property int pending: 0
  signal openBackup()
  readonly property alias openButton: openBtn   // the capture script clicks it
  title: "Recent backups"
  bottomInset: rows.length ? -2 : 0
  accessory: [
    Badge { visible: card.pending > 0; text: card.pending + " interrupted"; dot: Theme.amber; anchors.verticalCenter: parent.verticalCenter },
    PushButton { id: openBtn; text: "Open Backup"; icon: "database"; onClicked: card.openBackup() }
  ]

  // date.formatted(date: .abbreviated, time: .shortened) in the client locale: the locale's long date without
  // the weekday and with short month names ("Nov 14, 2026", "14. Nov. 2026"), then its short time, which
  // carries the 12 or 24 hour choice (LC_TIME on Linux, the Region settings on Windows).
  function when(d) {
    var loc = Qt.locale()
    var date = loc.dateFormat(Locale.LongFormat).replace(/d{4}[,.]?\s*/, "").replace("MMMM", "MMM").trim()
    var at = loc.name === "C" || loc.name.indexOf("en") === 0 ? " at " : ", "
    return loc.toString(d, date) + at + loc.toString(d, loc.timeFormat(Locale.ShortFormat))
  }

  // loading: three 36 pt rows with a 20 pt block and text lines
  Column {
    visible: !card.loaded && card.rows.length === 0
    width: parent.width
    height: visible ? 3 * 36 - 2 : 0
    Repeater {
      model: 3
      delegate: Item {
        width: parent.width
        height: 36
        Skeleton { x: 16; width: 20; height: 20; anchors.verticalCenter: parent.verticalCenter }
        Column {
          x: 16 + 20 + 8
          spacing: 4
          anchors.verticalCenter: parent.verticalCenter
          Skeleton { width: 160; height: 10 }
          Skeleton { width: 110; height: 8 }
        }
        Skeleton { x: parent.width - 16 - 70; width: 70; height: 10; anchors.verticalCenter: parent.verticalCenter }
      }
    }
  }

  // empty
  Item {
    visible: card.loaded && card.rows.length === 0
    width: parent.width
    height: visible ? 14 + 16 + 2 + 14 + 14 : 0
    Column {
      x: 16
      y: 14
      spacing: 3   // 2 in SwiftUI; Qt's 16 pt Body line sits 1 pt higher than the Mac one
      Txt { text: "No backups yet" }
      Txt { role: "secondary"; color: Theme.secondary; text: "Copy your chats and settings to a drive or folder you choose." }
    }
    PushButton { anchors.right: parent.right; anchors.rightMargin: 16; anchors.verticalCenter: parent.verticalCenter
                 prominent: true; text: "Set up a backup"; onClicked: card.openBackup() }
  }

  // rows
  Repeater {
    model: card.rows
    delegate: Item {
      width: parent.width
      height: 36 + (index > 0 ? Theme.hair : 0)
      Hair { visible: index > 0; x: 16; width: parent.width - 32; tone: Theme.tableSeparator }
      Item {
        y: index > 0 ? Theme.hair : 0
        x: 16
        width: parent.width - 32
        height: 36
        Txt { width: 170; anchors.verticalCenter: parent.verticalCenter; tabular: true; text: card.when(modelData.date); elide: Text.ElideRight
              ToolTipArea { text: card.when(modelData.date) } }
        Txt { x: 170 + 12; width: parent.width - 170 - 88 - 96 - 36; anchors.verticalCenter: parent.verticalCenter
              text: modelData.source; elide: Text.ElideRight
              ToolTipArea { text: modelData.source } }
        Txt { x: parent.width - 96 - 12 - 88; width: 88; horizontalAlignment: Text.AlignRight; anchors.verticalCenter: parent.verticalCenter
              tabular: true; text: O.bytes(modelData.bytes)
              ToolTipArea { text: O.bytes(modelData.bytes) } }
        // Badge look (4.13) in a 96 pt column: a longer state truncates, as the Mac frame does.
        Rectangle {
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          width: Math.min(96, stateText.implicitWidth + 16 + 11)
          height: 16
          radius: 8
          color: Theme.badgeFill
          Rectangle { x: 8; anchors.verticalCenter: parent.verticalCenter; width: 6; height: 6; radius: 3
                      color: modelData.isSafety || modelData.state !== "Complete" ? Theme.amber : Theme.green }
          Txt { id: stateText; x: 19; width: parent.width - 27; anchors.verticalCenter: parent.verticalCenter
                role: "caption"; text: modelData.state; elide: Text.ElideRight
                ToolTipArea { text: modelData.state } }
        }
      }
    }
  }
}
