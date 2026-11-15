import QtQuick

// A virtual list with the thin custom scroll bar of history.md 4.3: a 10 pt gutter always reserved at the right,
// no track, the knob hidden at rest. The list never drag-scrolls (that would steal text selection); the wheel
// scrolls from every point of the area, the gutter included. Only user scrolling reveals the bar.
Item {
  id: cl
  property alias view: lv
  property real gutter: 10
  property real leftInset: 0
  property bool barVisible: false
  readonly property real minY: lv.originY
  readonly property real maxY: lv.originY + Math.max(0, lv.contentHeight + lv.topMargin + lv.bottomMargin - lv.height) - lv.topMargin
  readonly property bool overflows: lv.contentHeight + lv.topMargin + lv.bottomMargin > lv.height + 0.5
  readonly property bool engaged: gutterHover.containsMouse || gutterHover.pressed
  signal userScrolled()
  signal keyPressed(var event)

  function scrollTo(y) { lv.contentY = Math.max(minY - lv.topMargin, Math.min(maxY, y)) }
  function scrollBy(dy) { scrollTo(lv.contentY + dy) }
  function reveal() { if (overflows) { barVisible = true; hideTimer.restart() } }

  ListView {
    id: lv
    x: cl.leftInset
    width: cl.width - cl.leftInset - cl.gutter
    height: cl.height
    clip: true
    interactive: false
    boundsBehavior: Flickable.StopAtBounds
    Keys.onPressed: function (e) { cl.keyPressed(e) }
    Accessible.role: Accessible.List
    Accessible.name: cl.accessibleName
  }
  property string accessibleName: ""

  WheelHandler {
    target: null
    acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad
    onWheel: function (e) {
      // pixel deltas from a trackpad or smooth wheel; line steps (120 per notch) move three 16 pt lines
      var dy = e.pixelDelta.y !== 0 ? e.pixelDelta.y : e.angleDelta.y / 120 * 48
      if (dy === 0) return
      cl.scrollBy(-dy)
      cl.reveal()
      cl.userScrolled()
    }
  }

  Timer { id: hideTimer; interval: 1000; onTriggered: if (!cl.engaged) cl.barVisible = false }

  Item {
    id: gut
    anchors.right: parent.right
    width: cl.gutter
    height: parent.height
    visible: cl.overflows
    Accessible.role: Accessible.ScrollBar
    Accessible.name: cl.accessibleName + " scroll bar"
    readonly property real track: height - 2
    readonly property real total: lv.contentHeight + lv.topMargin + lv.bottomMargin
    readonly property real knobH: Math.max(24, track * lv.height / Math.max(1, total))
    readonly property real range: Math.max(1, cl.maxY - cl.minY + lv.topMargin)

    Rectangle {
      id: knob
      readonly property real target: cl.engaged ? 0.40 : (cl.barVisible ? 0.25 : 0)
      property real alpha: target
      property real barW: cl.engaged ? 8 : (cl.barVisible ? 6 : 4)
      width: barW
      height: gut.knobH
      radius: width / 2
      x: (gut.width - width) / 2
      y: 1 + (gut.track - gut.knobH) * Math.max(0, Math.min(1, (lv.contentY - cl.minY + lv.topMargin) / gut.range))
      color: Theme.dark ? Theme.w(1) : Theme.k(1)
      opacity: alpha
      Behavior on alpha { NumberAnimation { duration: knob.target > knob.alpha ? 150 : 300; easing.type: Easing.OutQuad } }
      Behavior on barW { enabled: !Theme.reduceMotion; NumberAnimation { duration: 150; easing.type: Easing.OutQuad } }
    }
    MouseArea {
      id: gutterHover
      anchors.fill: parent
      hoverEnabled: true
      function jump(y) { cl.scrollTo(cl.minY - lv.topMargin + (y - gut.knobH / 2 - 1) / Math.max(1, gut.track - gut.knobH) * gut.range); cl.userScrolled() }
      onPressed: function (m) { jump(m.y) }
      onPositionChanged: function (m) { if (pressed) jump(m.y) }
      onContainsMouseChanged: if (!containsMouse) hideTimer.restart()
    }
  }
}
