import QtQuick

// A section panel (history.md 2.2): primary 2% fill, radius 10, separator rim. Heading row (min 34): icon,
// headline, spacer, chevron for level 2-3 headings (the whole row toggles). Hairline inset 12 under the heading
// while open. Blocks: 12 padding, 10 apart.
Rectangle {
  id: sec
  property var section: ({})
  property bool bare: false
  property var toggled: []          // block ids moved away from their default (collapsed section, code shown in full)
  signal toggle(int id)
  signal copy(string text)
  readonly property bool collapsed: section.collapsible && toggled.indexOf(section.id) >= 0
  height: col.height
  radius: 10
  color: Theme.ink(0.02)
  border.width: Theme.hair
  border.color: Theme.separator

  Column {
    id: col
    width: parent.width
    // built only for a section with a heading; most messages have one section without one
    Loader {
      active: !!sec.section.heading
      width: parent.width
      sourceComponent: headRow
    }
    Component {
      id: headRow
    Item {
      id: head
      objectName: "sectionHead"
      width: parent ? parent.width : 0
      height: Math.max(34, ht.height)
      activeFocusOnTab: !!sec.section.collapsible
      Keys.onSpacePressed: sec.toggle(sec.section.id)
      Keys.onReturnPressed: sec.toggle(sec.section.id)
      Rectangle { anchors.fill: parent; anchors.margins: 3; radius: 7; color: Theme.focusTint; visible: head.activeFocus && App.keyboardMode }
      Accessible.role: sec.section.collapsible ? Accessible.Button : Accessible.Heading
      Accessible.name: sec.section.heading ? sec.section.heading.plain : ""
      Accessible.description: sec.section.collapsible ? (sec.collapsed ? "Collapsed" : "Expanded") : ""
      Accessible.onPressAction: if (sec.section.collapsible) sec.toggle(sec.section.id)
      Icon { id: hi; x: 12; anchors.verticalCenter: parent.verticalCenter; size: 15; name: sec.section.icon || "docText"; color: Theme.label }
      Txt {
        id: ht
        x: hi.x + hi.width + 10
        width: parent.width - x - 12 - (chev.active ? 11 + 10 : 0)
        anchors.verticalCenter: parent.verticalCenter
        role: "section"
        textFormat: Text.RichText
        wrapMode: Text.Wrap
        text: sec.section.heading ? sec.section.heading.html : ""
      }
      Loader { id: chev; active: !!sec.section.collapsible; x: parent.width - 12 - 11; anchors.verticalCenter: parent.verticalCenter
               sourceComponent: Icon { size: 11; name: sec.collapsed ? "chevronRight" : "chevronDown"; color: Theme.label } }
      MouseArea { anchors.fill: parent; enabled: !!sec.section.collapsible; onClicked: sec.toggle(sec.section.id) }
    }
    }
    Rectangle { visible: !!sec.section.heading && !sec.collapsed; x: 12; width: parent.width - 24; height: Theme.hair; color: Theme.separator }
    Item {
      visible: !sec.collapsed
      width: parent.width
      height: visible ? blocks.height + 24 : 0
      Column {
        id: blocks
        x: 12
        y: 12
        width: parent.width - 24
        spacing: 10
        Repeater {
          model: sec.section.blocks
          ChatBlock {
            block: modelData
            bare: sec.bare
            open: sec.toggled.indexOf(modelData.id) >= 0
            onToggle: sec.toggle(modelData.id)
            onCopy: function (t) { sec.copy(t) }
          }
        }
      }
    }
  }
}
