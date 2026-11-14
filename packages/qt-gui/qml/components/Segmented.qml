import QtQuick

// AIMSegmentedPicker (4.11): 28 high track (radius 7), 24 high segments (radius 5) 2 apart,
// the selected fill slides on spring(0.25, 0.12); instant under Reduce Motion.
Item {
  id: seg
  property var model: []
  property var icons: []          // optional icon name per segment (14 pt, label color)
  property real segmentWidth: 0   // fixed width (Maintenance: 120), else padding 12
  property int current: 0
  property string name: ""
  signal picked(int index)

  height: 28
  width: strip.width + 4
  activeFocusOnTab: enabled
  opacity: enabled ? 1 : 0.45
  Accessible.role: Accessible.PageTabList
  Accessible.name: name
  Keys.onLeftPressed: choose(Math.max(0, current - 1))
  Keys.onRightPressed: choose(Math.min(model.length - 1, current + 1))
  function choose(i) { if (i !== current) { current = i; picked(i) } }

  Rectangle { anchors.fill: parent; radius: 7; color: Theme.segmentTrack }
  Rectangle {
    id: pill
    y: 2
    height: 24
    radius: 5
    x: px.value
    width: pw.value
    color: Theme.segmentSelected
    border.width: Theme.hair
    border.color: Theme.controlBorder
    FocusFill { radius: 5; visible: seg.activeFocus && App.keyboardMode }
  }
  SpringValue { id: px }
  SpringValue { id: pw }

  function place(animate) {
    var it = rep.itemAt(current)
    if (!it) return
    if (animate && Theme.motion && !Theme.reduceMotion) { px.target = it.x + 2; pw.target = it.width }
    else { px.snap(it.x + 2); pw.snap(it.width) }
  }
  onCurrentChanged: place(true)
  Component.onCompleted: place(false)

  Row {
    id: strip
    x: 2
    y: 2
    spacing: 2
    onWidthChanged: seg.place(false)
    Repeater {
      id: rep
      model: seg.model
      delegate: Item {
        width: seg.segmentWidth > 0 ? seg.segmentWidth : content.width + 24
        height: 24
        Accessible.role: Accessible.PageTab
        Accessible.name: modelData
        Accessible.selected: index === seg.current
        Row {
          id: content
          anchors.centerIn: parent
          spacing: 6
          Icon { visible: !!seg.icons[index]; name: seg.icons[index] || ""; size: 14; anchors.verticalCenter: parent.verticalCenter }
          Txt { text: modelData; anchors.verticalCenter: parent.verticalCenter }
        }
        MouseArea { anchors.fill: parent; enabled: seg.enabled; onClicked: seg.choose(index) }
      }
    }
  }
}
