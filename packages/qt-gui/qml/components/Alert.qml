import QtQuick
import QtQuick.Effects

// Confirmation alert (design-system.md 4.19), drawn by the app because the Mac one is AppKit's: the app
// icon, a bold title, the message, then Cancel and the action side by side. A destructive action has red
// text. Escape cancels; Return runs the action unless it is destructive. Clicks outside do nothing.
// Use: Theme.alert.open({ title, message, action, destructive, onAccept })
Item {
  id: root
  property var spec: ({})
  visible: false
  anchors.fill: parent
  z: 110

  function open(s) { spec = s; visible = true; panel.forceActiveFocus() }
  function close() { visible = false }
  // spec.field (a string) adds one text field, pre-filled; onAccept then gets its text (Rename).
  function accept() { var f = spec.onAccept; close(); if (f) f(field.text) }

  MouseArea { anchors.fill: parent; hoverEnabled: true; onWheel: function (w) { w.accepted = true }; Accessible.ignored: true }

  Item {
    id: panel
    objectName: "alert"
    width: 260
    height: col.height + 32
    anchors.horizontalCenter: parent.horizontalCenter
    y: Math.round((parent.height - height) / 3)
    Keys.onEscapePressed: root.close()
    Keys.onReturnPressed: if (!root.spec.destructive) root.accept()
    // Tab stays inside the alert (application-modal): field, Cancel, action
    function cycle(d) {
      var l = field.visible ? [field.input, cancelBtn, acceptBtn] : [cancelBtn, acceptBtn]
      var i = -1
      for (var k = 0; k < l.length; ++k) if (l[k].activeFocus) i = k
      l[(i + d + l.length) % l.length].forceActiveFocus(Qt.TabFocusReason)
    }
    Keys.onTabPressed: cycle(1)
    Keys.onBacktabPressed: cycle(-1)
    Accessible.role: Accessible.AlertMessage
    Accessible.name: root.spec.title || ""
    Accessible.description: root.spec.message || ""

    Rectangle {
      anchors.fill: parent
      radius: 12
      color: Theme.solidSurface
      border.width: Theme.hair
      border.color: Theme.popoverBorder
      layer.enabled: true
      layer.effect: MultiEffect { shadowEnabled: true; shadowColor: "black"; shadowOpacity: Theme.dark ? 0.55 : 0.22; shadowBlur: 0.8; shadowVerticalOffset: 10 }
    }

    Column {
      id: col
      x: 16
      y: 16
      width: parent.width - 32
      spacing: 0
      Image { source: "assets/appicon.png"; width: 64; height: 64; sourceSize: Qt.size(128, 128); anchors.horizontalCenter: parent.horizontalCenter; Accessible.ignored: true }
      Item { width: 1; height: 10 }
      Txt { width: parent.width; text: root.spec.title || ""; role: "section"; horizontalAlignment: Text.AlignHCenter; wrapMode: Text.Wrap }
      Item { width: 1; height: 6 }
      Txt { width: parent.width; visible: text !== ""; role: "secondary"; text: root.spec.message || ""; horizontalAlignment: Text.AlignHCenter; wrapMode: Text.Wrap }
      Item { width: 1; height: root.spec.field !== undefined ? 12 : 0 }
      FieldBox { id: field; visible: root.spec.field !== undefined; width: parent.width; placeholder: root.spec.fieldLabel || ""
                 name: root.spec.fieldLabel || root.spec.title || ""
                 text: root.spec.field !== undefined ? root.spec.field : "" }
      Item { width: 1; height: 16 }
      Row {
        width: parent.width
        spacing: 8
        PushButton { id: cancelBtn; objectName: "alert-cancel"; width: (parent.width - 8) / 2; text: "Cancel"; onClicked: root.close() }
        PushButton {
          id: acceptBtn
          objectName: "alert-accept"
          width: (parent.width - 8) / 2
          text: root.spec.action || "OK"
          prominent: !root.spec.destructive
          textColor: root.spec.destructive ? Theme.red : "white"
          onClicked: root.accept()
        }
      }
    }
  }
}
