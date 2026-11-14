import QtQuick
import QtQuick.Effects

// The pop-up and More menus (4.15), drawn by the app because the Mac one is AppKit's: a solid surface
// (owner rule: menus are not see-through), the chosen item lined up over its button, check mark,
// accent highlight. An option "-" is a separator. Keys: Up, Down, Return, Escape.
Item {
  id: root
  property var options: []
  property int current: 0
  property var callback: null
  property int hot: -1
  property Item anchorItem: null

  readonly property real itemH: 22
  readonly property real sepH: 10
  readonly property real pad: 5
  readonly property real panelW: Math.max(150, (anchorItem ? anchorItem.width + 20 : 0), widest + 28 + 16)
  readonly property real panelH: pad * 2 + top(options.length)
  property real widest: 0

  visible: false
  anchors.fill: parent
  z: 100

  function top(i) { var y = 0; for (var k = 0; k < i; ++k) y += options[k] === "-" ? sepH : itemH; return y }
  function step(d) {
    var i = hot
    do { i += d } while (i >= 0 && i < options.length && options[i] === "-")
    if (i >= 0 && i < options.length) hot = i
  }
  function open(anchor, opts, cur, cb) {
    anchorItem = anchor
    options = opts
    current = cur
    callback = cb
    hot = cur
    var p = anchor.mapToItem(root, 0, 0)
    panel.x = Math.max(8, Math.min(root.width - panelW - 8, p.x - 10))
    // the chosen item sits over the button, as a macOS pop-up does; a plain menu opens below
    var y = cur >= 0 ? p.y + anchor.height / 2 - (pad + top(cur) + itemH / 2) : p.y + anchor.height + 4
    panel.y = Math.max(8, Math.min(root.height - panelH - 8, y))
    visible = true
    panel.forceActiveFocus()
  }
  function close() { visible = false; if (anchorItem) anchorItem.forceActiveFocus() }
  function choose(i) { var cb = callback; close(); if (cb && i >= 0) cb(i) }

  MouseArea { anchors.fill: parent; onPressed: root.close() }

  Item {
    id: panel
    width: root.panelW
    height: root.panelH
    Keys.onUpPressed: root.step(-1)
    Keys.onDownPressed: root.step(1)
    Keys.onReturnPressed: root.choose(root.hot)
    Keys.onEscapePressed: root.close()

    Rectangle {
      anchors.fill: parent
      radius: 8
      color: Theme.solidSurface
      border.width: Theme.hair
      border.color: Theme.popoverBorder
      layer.enabled: true
      layer.effect: MultiEffect { shadowEnabled: true; shadowColor: "black"; shadowOpacity: Theme.dark ? 0.5 : 0.16; shadowBlur: 0.6; shadowVerticalOffset: 6 }
    }

    Column {
      y: root.pad
      width: parent.width
      Repeater {
        model: root.options
        delegate: Item {
          readonly property bool sep: modelData === "-"
          readonly property bool hot: root.hot === index
          width: panel.width
          height: sep ? root.sepH : root.itemH
          Component.onCompleted: if (!sep) root.widest = Math.max(root.widest, label.implicitWidth)
          Rectangle { visible: parent.sep; x: 10; width: parent.width - 20; y: 5; height: Theme.hair; color: Theme.separator }
          Rectangle { x: root.pad; width: parent.width - root.pad * 2; height: parent.height; radius: 5; color: Theme.accent; visible: parent.hot && !parent.sep }
          Icon { x: 11; anchors.verticalCenter: parent.verticalCenter; name: "check"; size: 12; visible: index === root.current
                 color: parent.hot ? "white" : Theme.label }
          Txt { id: label; visible: !parent.sep; x: 28; anchors.verticalCenter: parent.verticalCenter; text: modelData; color: parent.hot ? "white" : Theme.label }
          MouseArea {
            anchors.fill: parent
            enabled: !parent.sep
            hoverEnabled: true
            onEntered: root.hot = index
            onClicked: root.choose(index)
          }
        }
      }
    }
  }
}
