import QtQuick
import QtQuick.Window
import QtQuick.Effects

// The tray popover (popover.md 2, 3) as a borderless tool window. The body is 360 wide with a 44 footer;
// the outline (PopoverShape) carries the arrow toward the tray icon, flipped for a bottom tray. A clear
// margin around it holds the soft shadow. Rows expand on a critically damped 250 ms curve; the height is
// reserved at once on expand and released at the end of a collapse (3.9).
Window {
  id: pop
  readonly property int margin: 28                       // shadow room on every side
  readonly property real arrowH: Theme.arrowHeight
  property bool arrowDown: false
  property real arrowX: 180                              // tip x in the 360 body
  property real maxHeight: 100000
  readonly property var groups: Helper.topics.tray ? Helper.topics.tray.groups : []
  readonly property int bodyH: Math.max(94, Math.min(maxHeight - arrowH, Math.round(inner.height + 24 + 44)))

  width: 360 + 2 * margin
  height: bodyH + arrowH + 2 * margin
  color: "transparent"
  flags: Qt.Tool | Qt.FramelessWindowHint | Qt.WindowStaysOnTopHint | Qt.NoDropShadowWindowHint
  title: "Switch"

  signal openMain()
  signal openSettings()
  signal quit()

  property int layoutIndex: -1
  property int expandedIndex: -1
  property var amounts: []
  property var startAmounts: []
  property int targetIndex: -1
  property real bars: 1
  property bool refreshing: false
  property bool wasActive: false

  // Placement from the tray anchor rectangle (global logical pixels), popover.md 8.2.
  function placeAt(rect) {
    var p = Tray.place(rect, 360, bodyH + arrowH)
    arrowDown = p.arrowDown
    arrowX = p.arrowX
    maxHeight = p.maxHeight
    x = p.x - margin
    y = p.y - margin
  }
  function open(rect) { placeAt(rect); wasActive = false; show(); requestActivate(); replayBars() }
  // Focus loss closes it (no global pointer grab on Wayland); only after it was active once.
  onActiveChanged: { if (active) wasActive = true; else if (wasActive) close() }

  function rowCount() { var n = 0; for (var g = 0; g < groups.length; ++g) n += groups[g].accounts.length; return n }
  function base(gi) { var n = 0; for (var g = 0; g < gi; ++g) n += groups[g].accounts.length; return n }
  function amount(i) { return amounts.length > i ? amounts[i] : 0 }

  function ease(t) { return (1 - (1 + 8 * t) * Math.exp(-8 * t)) / (1 - 9 * Math.exp(-8)) }
  function apply(t) {
    var p = ease(t), a = []
    for (var k = 0; k < rowCount(); ++k) {
      var s = startAmounts.length > k ? startAmounts[k] : 0
      a.push(s + ((k === targetIndex ? 1 : 0) - s) * p)
    }
    if (t >= 1) {
      layoutIndex = targetIndex
      for (var j = 0; j < a.length; ++j) a[j] = j === targetIndex ? 1 : 0
    }
    amounts = a
  }
  function toggle(i) {
    startAmounts = amounts.slice()
    expandedIndex = expandedIndex === i ? -1 : i
    targetIndex = expandedIndex
    if (expandedIndex >= 0 && layoutIndex !== expandedIndex) layoutIndex = expandedIndex
    if (Theme.motion) clock.restart(); else apply(1)
  }
  // Deterministic frames for captures: t in seconds since the click.
  function seek(t) { clock.stop(); apply(Math.min(t / 0.25, 1)) }
  function setExpanded(i) { clock.stop(); startAmounts = amounts.slice(); expandedIndex = i; targetIndex = i; layoutIndex = i; apply(1) }

  FrameAnimation {
    id: clock
    onTriggered: {
      var t = Math.min(elapsedTime / 0.25, 1)
      pop.apply(t)
      if (t >= 1) stop()
    }
  }
  NumberAnimation { id: barsIn; target: pop; property: "bars"; from: 0; to: 1; duration: Theme.motion ? 300 : 0
                    easing.type: Easing.BezierCurve; easing.bezierCurve: Theme.easeOut }
  function replayBars() { if (Theme.motion) barsIn.restart() }

  Shortcut { sequence: "Escape"; onActivated: pop.close() }
  Shortcut { sequence: "Ctrl+O"; onActivated: pop.openMain() }
  Shortcut { sequence: "Ctrl+R"; onActivated: refreshBtn.clicked() }

  Item {
    id: frame
    x: pop.margin
    y: pop.margin
    width: 360
    height: pop.bodyH + pop.arrowH

    PopoverShape { id: shadowSrc; anchors.fill: parent; arrowX: pop.arrowX; arrowDown: pop.arrowDown; fill: "black"; stroke: "transparent"
                   layer.enabled: true; visible: false }
    MultiEffect {
      source: shadowSrc
      anchors.fill: shadowSrc
      shadowEnabled: true
      shadowColor: "black"
      shadowOpacity: Theme.dark ? 0.5 : 0.22
      shadowBlur: 0.6
      shadowVerticalOffset: 6
    }
    PopoverShape { anchors.fill: parent; arrowX: pop.arrowX; arrowDown: pop.arrowDown }

    Item {
      id: card
      y: pop.arrowDown ? 0 : pop.arrowH
      width: 360
      height: pop.bodyH

      ScrollArea {
        id: list
        width: parent.width
        height: parent.height - 44
        gutter: 10
        leftInset: 12
        rightInset: 12
        topPad: 12
        bottomPad: 12
        spacing: 0

        Column {
          id: inner
          width: parent.width
          Repeater {
            model: pop.groups
            delegate: Column {
              id: grp
              width: inner.width
              readonly property int gi: index
              readonly property var group: modelData
              // separator frame, 12 high, hairline at half opacity fading at both ends
              Item {
                visible: grp.gi > 0
                width: parent.width
                height: grp.gi > 0 ? 12 : 0
                Rectangle {
                  y: 6 - Theme.hair / 2
                  width: parent.width
                  height: Theme.hair
                  opacity: 0.5
                  gradient: Gradient {
                    orientation: Gradient.Horizontal
                    GradientStop { position: 0; color: Theme.rgba(Theme.separator, 0) }
                    GradientStop { position: 0.12; color: Theme.separator }
                    GradientStop { position: 0.88; color: Theme.separator }
                    GradientStop { position: 1; color: Theme.rgba(Theme.separator, 0) }
                  }
                }
              }
              // group header, 26 high: tile, name, eye on hover
              Item {
                width: parent.width
                height: 26
                HoverHandler { id: gh }
                ProviderTile { y: 5; provider: grp.group.id; name: grp.group.name; size: 16 }
                Txt { x: 24; anchors.verticalCenter: parent.verticalCenter; role: "secondary"; wght: 600; color: Theme.secondary; text: grp.group.name }
                IconButton {
                  x: parent.width - 18
                  anchors.verticalCenter: parent.verticalCenter
                  icon: "eye"
                  glyph: 11
                  tip: "Hide from menu bar"
                  opacity: gh.hovered ? 1 : 0
                  Behavior on opacity { NumberAnimation { duration: Theme.motion ? 180 : 0; easing.type: Easing.BezierCurve; easing.bezierCurve: Theme.easeOut } }
                }
              }
              Column {
                width: parent.width
                spacing: 8
                Repeater {
                  model: grp.group.accounts
                  delegate: PopoverRow {
                    readonly property int ri: pop.base(grp.gi) + index
                    acct: modelData
                    provider: grp.group.id
                    reveal: pop.amount(ri)
                    expansion: pop.layoutIndex === ri ? 1 : 0
                    barProgress: pop.bars
                    onToggle: pop.toggle(ri)
                  }
                }
              }
            }
          }
        }
      }

      // footer, 44 high: Open Switch | space | Refresh, Quit, Settings (3.12)
      Item {
        y: parent.height - 44
        width: parent.width
        height: 44
        PopButton { x: 12; anchors.verticalCenter: parent.verticalCenter; text: "Open Switch"; hint: "Ctrl O"; onClicked: pop.openMain() }
        Row {
          anchors.right: parent.right
          anchors.rightMargin: 12
          anchors.verticalCenter: parent.verticalCenter
          spacing: 6
          PopButton {
            id: refreshBtn
            property real angle: 0
            square: true
            icon: "refresh"
            spin: angle
            enabled: !pop.refreshing
            NumberAnimation on angle { from: 0; to: 360; duration: 800; loops: Animation.Infinite; running: pop.refreshing && Theme.motion }
            onClicked: { pop.refreshing = true; refreshStop.restart() }
            // shortcut: the spin ends on a timer until the helper reports usage.refresh completion
            Timer { id: refreshStop; interval: 1700; onTriggered: { pop.refreshing = false; refreshBtn.angle = 0 } }
          }
          PopButton { square: true; icon: "power"; onClicked: pop.quit() }
          PopButton { square: true; icon: "gear"; onClicked: pop.openSettings() }
        }
      }
    }
  }
}
