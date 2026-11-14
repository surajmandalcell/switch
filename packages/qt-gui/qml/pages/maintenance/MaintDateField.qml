import QtQuick
import QtQuick.Effects
import QtQuick.Window
import "MaintFmt.js" as F

// AIMDateField (maintenance.md 1.4): Body title, 6 gap, a push button with the date (no time). The button
// opens a graphical month calendar (8 pt padding) below it. `after` is the earliest day allowed.
Row {
  id: df
  property string title: ""
  property real date: Date.now()       // ms
  property real after: 0               // ms, 0 = no limit
  property bool open: false
  signal picked(real ms)
  spacing: 6
  height: 28

  Txt { text: df.title; anchors.verticalCenter: parent.verticalCenter }
  PushButton {
    id: btn
    objectName: "date-" + df.title
    text: F.dateOnly(df.date)
    Accessible.name: df.title + ", " + text
    onClicked: { cal.month = new Date(df.date); cal.cursor = F.startOfDay(df.date); df.open = true; cal.forceActiveFocus() }
  }
  function close() { open = false; btn.forceActiveFocus() }
  function allowed(ms) { return after <= 0 || F.startOfDay(ms) >= F.startOfDay(after) }

  Item {
    parent: df.Window.contentItem
    anchors.fill: parent
    z: 55
    visible: df.open
    MouseArea { anchors.fill: parent; onPressed: df.close() }
    Item {
      id: cal
      property var month: new Date()
      property real cursor: 0          // the day the arrow keys move (start of day, ms)
      readonly property var first: new Date(month.getFullYear(), month.getMonth(), 1)
      readonly property point at: df.open ? btn.mapToItem(parent, 0, btn.height + 6) : Qt.point(0, 0)
      x: Math.min(parent.width - width - 8, at.x)
      y: at.y
      width: 7 * 26 + 16
      height: 8 + 24 + 18 + 6 * 22 + 8
      Accessible.role: Accessible.Table
      Accessible.name: df.title + " calendar, " + F.dateOnly(cursor)
      // Arrows move one day or one week, Page Up and Page Down one month; Return picks, Escape closes.
      function go(days, months) {
        var d = new Date(cursor)
        d = months ? new Date(d.getFullYear(), d.getMonth() + months, Math.min(d.getDate(), 28)) : new Date(d.getFullYear(), d.getMonth(), d.getDate() + days)
        cursor = d.getTime()
        if (d.getMonth() !== month.getMonth() || d.getFullYear() !== month.getFullYear()) month = new Date(d.getFullYear(), d.getMonth(), 1)
      }
      Keys.onEscapePressed: df.close()
      Keys.onLeftPressed: go(-1, 0)
      Keys.onRightPressed: go(1, 0)
      Keys.onUpPressed: go(-7, 0)
      Keys.onDownPressed: go(7, 0)
      Keys.onPressed: function (e) {
        if (e.key === Qt.Key_PageUp) { go(0, -1); e.accepted = true }
        else if (e.key === Qt.Key_PageDown) { go(0, 1); e.accepted = true }
        else if (e.key === Qt.Key_Tab || e.key === Qt.Key_Backtab) e.accepted = true   // focus stays in the calendar
      }
      Keys.onReturnPressed: if (df.allowed(cursor)) { df.close(); df.picked(cursor) }
      Keys.onSpacePressed: if (df.allowed(cursor)) { df.close(); df.picked(cursor) }
      Rectangle {
        anchors.fill: parent
        radius: 10
        color: Theme.solidSurface
        border.width: Theme.hair
        border.color: Theme.popoverBorder
        layer.enabled: true
        layer.effect: MultiEffect { shadowEnabled: true; shadowColor: "black"; shadowOpacity: Theme.dark ? 0.5 : 0.16; shadowBlur: 0.6; shadowVerticalOffset: 6 }
      }
      MouseArea { anchors.fill: parent }   // clicks inside never close it
      Item {
        x: 8; y: 8
        width: parent.width - 16
        height: 24
        Txt { anchors.verticalCenter: parent.verticalCenter; role: "section"; text: cal.month.toLocaleDateString(Qt.locale(), "MMMM yyyy") }
        Row {
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          spacing: 10
          IconButton { icon: "chevronLeft"; glyph: 12; tip: "Previous month"
                       onClicked: cal.month = new Date(cal.month.getFullYear(), cal.month.getMonth() - 1, 1) }
          IconButton { icon: "chevronRight"; glyph: 12; tip: "Next month"
                       onClicked: cal.month = new Date(cal.month.getFullYear(), cal.month.getMonth() + 1, 1) }
        }
      }
      Row {
        x: 8; y: 8 + 24
        Repeater {
          model: 7
          delegate: Txt { width: 26; height: 18; horizontalAlignment: Text.AlignHCenter; role: "caption"; color: Theme.secondary
                          text: Qt.locale().dayName((index + Qt.locale().firstDayOfWeek) % 7, 2 /* NarrowFormat */) }
        }
      }
      Grid {
        x: 8; y: 8 + 24 + 18
        columns: 7
        Repeater {
          model: 42
          delegate: Item {
            readonly property int lead: (cal.first.getDay() - Qt.locale().firstDayOfWeek + 7) % 7
            readonly property var day: new Date(cal.month.getFullYear(), cal.month.getMonth(), index - lead + 1)
            readonly property bool inMonth: day.getMonth() === cal.month.getMonth()
            readonly property bool chosen: F.startOfDay(day.getTime()) === F.startOfDay(df.date)
            readonly property bool allowed: df.after <= 0 || F.startOfDay(day.getTime()) >= F.startOfDay(df.after)
            width: 26
            height: 22
            Rectangle { anchors.centerIn: parent; width: 22; height: 20; radius: 5; color: Theme.accent; visible: parent.chosen }
            Rectangle { anchors.centerIn: parent; width: 22; height: 20; radius: 5; color: Theme.rowHover; visible: dayHover.hovered && !parent.chosen && parent.allowed }
            Rectangle { anchors.centerIn: parent; width: 22; height: 20; radius: 5; color: Theme.focusTint
                        visible: cal.activeFocus && App.keyboardMode && F.startOfDay(parent.day.getTime()) === cal.cursor }
            Txt {
              anchors.centerIn: parent
              tabular: true
              text: parent.day.getDate()
              color: parent.chosen ? "white" : (parent.inMonth && parent.allowed ? Theme.label : Theme.tertiary)
            }
            HoverHandler { id: dayHover }
            MouseArea {
              anchors.fill: parent
              enabled: parent.allowed
              onClicked: { df.close(); df.picked(parent.day.getTime()) }
            }
          }
        }
      }
    }
  }
}
