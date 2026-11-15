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
  readonly property bool hasPrompt: !!acct.prompt   // 3.8: one 24 high prompt line replaces the usage lines
  signal toggle()
  signal action(string name)   // a band or prompt button title: Switch, Open <tool>, Sign in, Allow access
  signal eye()

  // popover.md 3.13: "<account>, <service>[, Default], <per line: pool label NN% left|used>"; rows that expand take focus
  property string service: provider   // the service display name for the accessible name
  activeFocusOnTab: !!acct.canExpand
  Accessible.role: Accessible.Button
  Accessible.name: {
    var p = [acct.label || "", service]
    if (acct.isDefault) p.push("Default")
    if (hasPrompt) p.push(acct.prompt)
    var ls = acct.lines || []
    for (var i = 0; i < Math.min(ls.length, acct.shown || 0); ++i)
      if (ls[i].label !== undefined) p.push(ls[i].label + " " + Theme.shownPercent(ls[i].used) + "% " + (Theme.showUsed ? "used" : "left"))
    return p.join(", ")
  }
  Accessible.expandable: !!acct.canExpand
  Accessible.expanded: expansion > 0
  Accessible.onPressAction: if (acct.canExpand) toggle()
  Keys.onSpacePressed: if (acct.canExpand) toggle()
  Keys.onReturnPressed: if (acct.canExpand) toggle()
  Rectangle { x: -4; width: 344; height: parent.height + 4; radius: 6; color: Theme.popoverFocus; visible: row.activeFocus && App.keyboardMode }

  width: 336
  readonly property bool hasBand: !!acct.band && acct.band.length > 0
  height: 6 + 18 + (hasPrompt ? 4 + 24 : 4 + shown * 18 + extra * 18 * expansion) + (hasToken ? 4 + 14 : 0) + (hasBand ? 40 * expansion : 0) + 6

  // hover fill, 4 beyond the content on the sides, 4 below
  Rectangle {
    x: -4
    width: 344
    height: parent.height + 4
    radius: 6
    color: Theme.popoverHover
    opacity: hh.hovered ? 1 : 0
    Behavior on opacity { NumberAnimation { duration: Theme.dHover; easing.type: Easing.Bezier; easing.bezierCurve: Theme.easeOut } }
  }
  HoverHandler { id: hh }
  MouseArea { x: -4; width: 344; height: parent.height + 4; enabled: !!row.acct.canExpand; onClicked: row.toggle() }

  // header line
  Item {
    y: 6
    width: parent.width
    height: 18
    Icon { x: 2; anchors.verticalCenter: parent.verticalCenter; name: "check"; size: 12; color: Theme.label; visible: row.acct.isDefault }
    Txt { x: 24; width: parent.width - 24 - 28 - (row.hasPrompt ? 54 : 0); anchors.verticalCenter: parent.verticalCenter; text: row.acct.label; elide: Text.ElideRight }
    // account eye (3.4): shown on row hover or focus; half visible while the account is hidden from the menu bar
    IconButton {
      id: eyeBtn
      x: parent.width - 18 + 3
      anchors.verticalCenter: parent.verticalCenter
      icon: row.acct.showsInTray === false ? "eyeSlash" : "eye"
      glyph: 12
      tip: row.acct.showsInTray === false ? "Show account in menu bar" : "Hide account from menu bar"
      Accessible.name: tip + ": " + row.acct.label
      opacity: hh.hovered || activeFocus ? 1 : (row.acct.showsInTray === false ? 0.5 : 0)
      Behavior on opacity { NumberAnimation { duration: Theme.motion ? 180 : 0; easing.type: Easing.Bezier; easing.bezierCurve: Theme.easeOut } }
      onClicked: row.eye()
    }
  }

  // prompt line (3.8): text left, the Sign in or Allow access button bottom-right over the row
  Txt {
    visible: row.hasPrompt
    x: 24
    y: 6 + 18 + 4
    width: parent.width - 24 - (row.acct.promptButton === "Allow access" ? 90 : 60)
    height: 24
    verticalAlignment: Text.AlignVCenter
    role: "secondary"
    color: Theme.secondary
    text: row.acct.prompt || ""
    elide: Text.ElideRight
  }
  PopButton {
    visible: row.hasPrompt && !!row.acct.promptButton
    x: parent.width - width - 2
    y: parent.height - height - (6 + 2 * row.reveal) - 40 * (row.expansion - row.reveal)   // Rows:54-56, 693-696
    text: row.acct.promptButton || ""
    Accessible.role: Accessible.Button
    Accessible.name: (text === "Allow access" ? "Allow access to " : "Sign in to ") + row.acct.label
    ToolTipArea { text: parent.text === "Allow access" ? "Open Switch to allow access to Droid’s login" : "Open Switch to sign in" }
    onClicked: row.action(text)
  }

  // usage lines: the first `shown` always, the rest revealed
  Item {
    visible: !row.hasPrompt
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
    visible: row.hasToken && !row.hasPrompt
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
          Repeater { model: row.acct.band || []; PopButton { text: modelData; enabled: modelData !== "Switch" || row.acct.isVerified !== false; onClicked: row.action(modelData) } }
        }
      }
    }
  }
}
