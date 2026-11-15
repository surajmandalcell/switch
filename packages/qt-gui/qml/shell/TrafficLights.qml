import QtQuick

// Window buttons in the 52 pt bar: 12 pt discs, 20 pt apart, glyphs on group hover.
Item {
  id: tl
  signal close()
  signal minimize()
  signal zoom()
  width: 12 + 40
  height: 12

  HoverHandler { id: group }

  Repeater {
    model: [
      { c: "#FF5F57", g: "tlClose", n: "Close" },
      { c: "#FEBC2E", g: "tlMin", n: "Minimize" },
      { c: "#28C840", g: "tlZoom", n: "Zoom" }
    ]
    delegate: Item {
      x: index * 20
      width: 12
      height: 12
      // pointer only, like the Mac window buttons; Ctrl+W and Ctrl+M are the keyboard path
      Accessible.role: Accessible.Button
      Accessible.name: modelData.n
      Accessible.onPressAction: index === 0 ? tl.close() : (index === 1 ? tl.minimize() : tl.zoom())
      Rectangle {
        anchors.fill: parent
        radius: 6
        color: modelData.c
        Rectangle { anchors.fill: parent; radius: 6; color: "transparent"; border.width: 0.5; border.color: Theme.k(0.22) }
        Rectangle { anchors.fill: parent; radius: 6; color: Theme.k(0.12); visible: m.pressed }
      }
      Icon {
        anchors.centerIn: parent
        size: 12
        name: modelData.g
        color: Theme.k(0.58)
        visible: group.hovered
      }
      MouseArea {
        id: m
        anchors.fill: parent
        onClicked: index === 0 ? tl.close() : (index === 1 ? tl.minimize() : tl.zoom())
      }
    }
  }
}
