import QtQuick

// MenuBarRow (popover.md 3.3 to 3.9): header line, usage lines, token line, action band.
// `expansion` is the binary layout flag; `reveal` is the animated amount (0 to 1).
Item {
  id: row
  property var acct: ({})
  property string provider: "codex"
  property real reveal: 0
  property real expansion: 0
  property real barProgress: 1
  readonly property bool hovered: hh.hovered
  readonly property int shown: acct.shown
  readonly property int extra: acct.lines.length - acct.shown
  readonly property bool hasToken: !!acct.token
  signal toggle()

  width: 336
  readonly property bool hasBand: !!acct.band && acct.band.length > 0
  height: 6 + 18 + 4 + (shown * 18 + extra * 18 * expansion) + (hasToken ? 4 + 14 : 0) + (hasBand ? 40 * expansion : 0) + 6

  // hover fill, 4 beyond the content on the sides, 4 below
  Rectangle {
    x: -4
    width: 344
    height: parent.height + 4
    radius: 6
    color: Theme.popoverHover
    opacity: hh.hovered ? 1 : 0
    Behavior on opacity { NumberAnimation { duration: Theme.dHover; easing.type: Easing.BezierCurve; easing.bezierCurve: Theme.easeOut } }
  }
  HoverHandler { id: hh }
  MouseArea { x: -4; width: 344; height: parent.height + 4; onClicked: row.toggle() }

  // header line
  Item {
    y: 6
    width: parent.width
    height: 18
    Icon { x: 2; anchors.verticalCenter: parent.verticalCenter; name: "check"; size: 12; color: Theme.label; visible: row.acct.isDefault }
    Txt { x: 24; width: parent.width - 24 - 28; anchors.verticalCenter: parent.verticalCenter; text: row.acct.label; elide: Text.ElideRight }
    Item {
      x: parent.width - 18
      width: 18
      height: 18
      opacity: hh.hovered ? 1 : 0
      Behavior on opacity { NumberAnimation { duration: 180; easing.type: Easing.BezierCurve; easing.bezierCurve: Theme.easeOut } }
      Icon { anchors.centerIn: parent; name: "eye"; size: 12; color: Theme.secondary }
    }
  }

  // usage lines: the first `shown` always, the rest revealed
  Item {
    y: 6 + 18 + 4
    width: parent.width
    height: row.shown * 18 + row.extra * 18 * row.expansion
    clip: true
    Item {
      width: parent.width
      height: row.shown * 18 + row.extra * 18 * row.reveal
      clip: true
      Column {
        width: parent.width
        Repeater {
          model: row.acct.lines
          delegate: Item {
            width: row.width
            height: 18
            readonly property bool late: index >= row.shown
            readonly property bool heading: modelData.heading !== undefined
            opacity: late ? row.reveal : 1
            transform: Translate { y: late ? 4 * (1 - row.reveal) : 0 }
            Txt {
              visible: parent.heading
              x: 24
              width: parent.width - 24
              anchors.verticalCenter: parent.verticalCenter
              role: "caption"
              color: Theme.secondary
              text: modelData.heading || ""
              elide: Text.ElideRight
            }
            Txt {
              visible: !parent.heading
              x: 24
              width: 56
              anchors.verticalCenter: parent.verticalCenter
              role: "secondary"
              color: Theme.secondary
              text: modelData.label || ""
              elide: Text.ElideRight
            }
            UsageBar {
              visible: !parent.heading
              x: 24 + 56 + 6
              width: 138
              anchors.verticalCenter: parent.verticalCenter
              used: modelData.used || 0
              provider: row.provider
              progress: row.barProgress
            }
            Txt {
              visible: !parent.heading
              x: 230
              width: 36
              anchors.verticalCenter: parent.verticalCenter
              role: "secondary"
              tabular: true
              color: Theme.secondary
              horizontalAlignment: Text.AlignRight
              text: parent.heading ? "" : Theme.shownPercent(modelData.used) + "%"
            }
            Txt {
              visible: !parent.heading
              x: 272
              width: 64
              anchors.verticalCenter: parent.verticalCenter
              role: "secondary"
              tabular: true
              color: Theme.secondary
              horizontalAlignment: Text.AlignRight
              text: modelData.reset || ""
            }
          }
        }
      }
    }
  }

  // token line, kept under the last visible line while the extra lines reveal
  Item {
    visible: row.hasToken
    y: 6 + 18 + 4 + row.shown * 18 + row.extra * 18 * row.expansion + 4 - row.extra * 18 * (row.expansion - Math.min(row.reveal, row.expansion))
    width: parent.width
    height: 14
    Txt { x: 24; width: 56; anchors.verticalCenter: parent.verticalCenter; role: "secondary"; color: Theme.secondary; text: "Tokens" }
    Txt { x: 24 + 56 + 6; width: parent.width - x; anchors.verticalCenter: parent.verticalCenter; role: "secondary"; tabular: true
          color: Theme.secondary; text: row.acct.token || ""; elide: Text.ElideRight }
  }

  // action band: 40 high, clip follows reveal inside the layout frame
  Item {
    visible: row.hasBand
    y: parent.height - 6 - 40 * row.expansion
    width: parent.width
    height: 40 * row.expansion
    clip: true
    Item {
      width: parent.width
      height: 40 * row.reveal
      clip: true
      Item {
        width: parent.width
        height: 40
        opacity: row.reveal
        y: 4 * (1 - row.reveal)
        Row {
          x: 24
          anchors.verticalCenter: parent.verticalCenter
          spacing: 6
          Repeater { model: row.acct.band || []; PopButton { text: modelData } }
        }
      }
    }
  }
}
