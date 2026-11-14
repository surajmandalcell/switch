import QtQuick

// A page scroll view with the thin custom bar of 4.20: no track, hidden at rest.
Item {
  id: sa
  property real gutter: 20
  property real leftInset: gutter
  property real rightInset: gutter
  property real topPad: 12
  property real bottomPad: 20
  property real spacing: 12
  default property alias content: col.data
  property alias flick: flick
  property bool barVisible: false     // set by user scrolling
  readonly property bool overflows: flick.contentHeight > flick.height + 0.5
  property bool engaged: gutterHover.containsMouse || gutterHover.pressed

  property bool appeared: false
  // 3.4 "appear": cards fade in from 0.4 on the first show; they never move.
  function appear() { if (!appeared) { appeared = true; appearAnim.restart() } }
  NumberAnimation { id: appearAnim; target: col; property: "opacity"; from: 0.4; to: 1; duration: Theme.dAppear
                    easing.type: Easing.BezierCurve; easing.bezierCurve: Theme.easeOut }

  function scrollTo(y) { flick.contentY = Math.max(0, Math.min(flick.contentHeight - flick.height, y)) }

  Flickable {
    id: flick
    anchors.fill: parent
    clip: true
    contentWidth: width
    contentHeight: col.height + sa.topPad + sa.bottomPad
    boundsBehavior: Flickable.StopAtBounds
    flickableDirection: Flickable.VerticalFlick
    onContentYChanged: if (sa.overflows) { sa.barVisible = true; hideTimer.restart() }
    Column {
      id: col
      x: sa.leftInset
      y: sa.topPad
      width: sa.width - sa.leftInset - sa.rightInset
      spacing: sa.spacing
    }
  }

  Timer { id: hideTimer; interval: 1000; onTriggered: if (!sa.engaged) sa.barVisible = false }

  Item {
    id: gutterItem
    anchors.right: parent.right
    width: sa.gutter
    height: parent.height
    visible: sa.overflows

    readonly property real track: height - 2
    readonly property real knobH: Math.max(24, track * flick.height / flick.contentHeight)
    readonly property real range: Math.max(1, flick.contentHeight - flick.height)

    Rectangle {
      id: knob
      property real alpha: sa.engaged ? 0.40 : (sa.barVisible ? 0.25 : 0)
      property real barW: sa.engaged ? 8 : (sa.barVisible ? 6 : 4)
      width: barW
      height: gutterItem.knobH
      radius: width / 2
      x: (gutterItem.width - width) / 2
      y: 1 + (gutterItem.track - gutterItem.knobH) * flick.contentY / gutterItem.range
      color: Theme.dark ? Theme.w(1) : Theme.k(1)
      opacity: alpha
      Behavior on alpha { NumberAnimation { duration: knob.alpha < (sa.engaged ? 0.40 : (sa.barVisible ? 0.25 : 0)) ? 150 : 300
                                            easing.type: Easing.OutQuad } }
      Behavior on barW { enabled: !Theme.reduceMotion; NumberAnimation { duration: 150; easing.type: Easing.OutQuad } }
    }
    MouseArea {
      id: gutterHover
      anchors.fill: parent
      hoverEnabled: true
      acceptedButtons: Qt.LeftButton
      onPressed: function (m) {
        // a click on the track jumps so the knob centers on the click
        sa.scrollTo((m.y - gutterItem.knobH / 2 - 1) / (gutterItem.track - gutterItem.knobH) * gutterItem.range)
      }
      onPositionChanged: function (m) {
        if (pressed) sa.scrollTo((m.y - gutterItem.knobH / 2 - 1) / (gutterItem.track - gutterItem.knobH) * gutterItem.range)
      }
      onContainsMouseChanged: if (!containsMouse) hideTimer.restart()
    }
  }
}
