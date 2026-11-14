import QtQuick

// AIMSidebar (shell.md 2.1): 220 wide, flat sidebar tone (the Mac captures measure no wash), 1 px right
// hairline. Heading row 52 high with "Switch" at x 86 (outer padding 10 + leading padding 76). Rows 32
// high, 2 apart, radius 8; icon box 20 then 10 gap, so titles start at x 50.
Item {
  id: sb
  property int current: 0
  property var pages: []
  signal select(int index)
  width: 220
  clip: true   // the tone rectangle is 12 wider so only its left corners round
  Accessible.role: Accessible.List
  Accessible.name: "Sidebar"

  // Left corners follow the window radius; the page host covers the right side.
  Rectangle { width: parent.width + 12; height: parent.height; radius: Theme.windowRadius; color: Theme.sidebar }
  Rectangle { x: parent.width - Theme.hair; width: Theme.hair; height: parent.height; color: Theme.separator }

  Txt { x: 86; y: 0; height: 52; role: "section"; text: "Switch" }

  Column {
    x: 10
    y: 54
    width: 200
    spacing: 2
    Repeater {
      model: sb.pages
      delegate: Item {
        id: r
        width: 200
        height: 32
        readonly property bool selected: sb.current === index
        activeFocusOnTab: true
        Accessible.role: Accessible.ListItem
        Accessible.name: modelData.title
        Accessible.selected: selected
        objectName: "sidebar-" + modelData.route
        Keys.onSpacePressed: sb.select(index)
        Keys.onReturnPressed: sb.select(index)
        Keys.onUpPressed: if (index > 0) nextItemInFocusChain(false).forceActiveFocus()
        Keys.onDownPressed: if (index < sb.pages.length - 1) nextItemInFocusChain(true).forceActiveFocus()

        Rectangle {
          anchors.fill: parent
          radius: 8
          color: r.activeFocus && App.keyboardMode && !r.selected ? Theme.focusTint : Theme.rowHover
          opacity: hh.hovered || (r.activeFocus && App.keyboardMode) ? 1 : 0
          visible: !r.selected
          Behavior on opacity { NumberAnimation { duration: Theme.dHover; easing.type: Easing.BezierCurve; easing.bezierCurve: Theme.easeOut } }
        }
        // selection is set instantly (no fade), so the old row never stays lit for a frame
        Rectangle { anchors.fill: parent; radius: 8; color: Theme.sidebarSelection; visible: r.selected }
        // 17 matches the Mac glyph widths (house 15, people 16); our vector box has a little padding.
        Icon { x: 10 + (20 - 17) / 2; anchors.verticalCenter: parent.verticalCenter; name: modelData.icon; size: 17; color: Theme.passiveIcon }
        Txt { x: 40; anchors.verticalCenter: parent.verticalCenter; text: modelData.title }
        HoverHandler { id: hh }
        MouseArea { anchors.fill: parent; onClicked: sb.select(index) }
      }
    }
  }
}
